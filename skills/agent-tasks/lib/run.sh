# shellcheck shell=bash
# One automation tick, `task run --once`, started by launchd every minute.

run_say() { echo "[agent-tasks] $*"; }

# Moves the task to blocked with a reason, under the lock.
run_block() {   # run_block <id> <reason>
  local f from
  lock_acquire
  f="$(task_file "$1")"
  from="$(folder_of_file "$f")"
  if [ "$from" != "blocked" ]; then
    move_task "$f" blocked task "$2"
    store_commit || true
  fi
  lock_release
  run_say "$1: $from → blocked — $2"
}

# Fails with the response on stderr when the request fails.
run_api() {   # run_api <method> <path> [<json>]
  if [ $# -ge 3 ]; then
    opencode api "$1" "$2" --data "$3"
  else
    opencode api "$1" "$2"
  fi
}

# Marks the task's next `input` signal as ours, not the user's (quiet rule):
# the plugin's prompt hook also fires for prompts posted through the API.
run_mark_prompt() {
  mkdir -p "$STORE/.notify"
  : > "$STORE/.notify/$1.auto-prompt"
}

# Posts a prompt to a session; automated prompts carry
# metadata.agent_tasks.automated so the plugin does not count them as input.
run_send_prompt() {   # run_send_prompt <id> <session> <payload json without metadata>
  local payload
  payload="$(jq -c '. + {metadata: {agent_tasks: {automated: true}}}' <<< "$3")" || return 1
  run_mark_prompt "$1"
  if ! run_api post "/api/session/$2/prompt" "$payload" >/dev/null 2>&1; then
    rm -f "$STORE/.notify/$1.auto-prompt"
    return 1
  fi
}

# The "plan approved, implement it" prompt (also used by `task approve --now`).
run_send_implement() {   # run_send_implement <id> <session>
  local payload
  payload="$(jq -cn '{
    text: "The implementation plan was approved. Implement it with subagent-driven-development, following the plan.",
    skills: [{id: "subagent-driven-development"}],
    delivery: "queue"}')"
  run_send_prompt "$1" "$2" "$payload"
}

# Sessions of 02_exploring/05_planning/08_implementing that do nothing for stale_minutes get `stalled`.
run_stale_check() {
  local active="$1" stale now f s id mtime
  stale="$(config_get stale_minutes 30)"
  case "$stale" in ''|*[!0-9]*) stale=30 ;; esac
  stale=$((10#$stale))
  now="$(date +%s)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$(folder_of_file "$f")" in 02_exploring|05_planning|08_implementing) ;; *) continue ;; esac
    s="$(fm_get "$f" session)"
    [ -n "$s" ] || continue
    id="$(id_of_file "$f")"
    if ! valid_session "$s"; then warn "$id has an invalid session field; skipped"; continue; fi
    if AT_S="$s" jq -e '(.data // {}) | type == "object" and has(env.AT_S)' <<< "$active" >/dev/null 2>&1; then
      continue
    fi
    mtime="$(stat -f %m "$f")"
    [ $((now - mtime)) -ge $((stale * 60)) ] || continue
    if session_has_running_children "$s" "$active"; then continue; fi
    run_say "$id: no activity for $stale min"
    "$TASK_BIN" signal "$id" stalled --session "$s" --text "no activity for $stale min" \
      | sed 's/^/[agent-tasks] /' || warn "signal stalled failed for $id"
  done <<< "$(all_task_files)"
}

# 07_approved → 08_implementing, then tell the session to implement the plan.
run_continue() {   # run_continue <file>
  local f="$1" id s
  id="$(id_of_file "$f")"
  lock_acquire
  f="$(task_file "$id")"
  if [ "$(folder_of_file "$f")" != "07_approved" ]; then lock_release; return 0; fi
  s="$(fm_get "$f" session)"
  if [ -z "$s" ]; then
    lock_release
    run_block "$id" "approved task has no session to continue"
    return 0
  fi
  if ! valid_session "$s"; then
    lock_release
    run_block "$id" "$id has an invalid session field"
    return 0
  fi
  move_task "$f" 08_implementing task "implementation starts (active period)"
  store_commit || true
  lock_release
  if ! run_send_implement "$id" "$s"; then
    run_block "$id" "could not send the implementation prompt to session $s"
    return 0
  fi
  run_say "$id: 07_approved → 08_implementing (session $s)"
}

# 01_ready → 02_exploring in a new session started with brainstorming.
run_start() {   # run_start <file>
  local f="$1" id ws project dir title agent model body resp s old payload text
  id="$(id_of_file "$f")"
  ws="$(ws_of_file "$f")"
  project="$(fm_get "$f" project)"
  if [ -z "$project" ]; then run_block "$id" "task has no project"; return 0; fi
  dir="$(project_path "$ws" "$project")"
  if [ -z "$dir" ]; then run_block "$id" "project $project is not registered"; return 0; fi
  if [ ! -d "$dir" ]; then run_block "$id" "project directory missing: $dir"; return 0; fi
  title="$(fm_get "$f" title)"
  agent="$(config_get agent "")"
  model="$(config_get model "")"
  case "$model" in
    ""|?*/?*) ;;
    *) run_block "$id" "invalid model '$model' in config.toml (expected provider/model)"; return 0 ;;
  esac
  if ! resolve_task_model; then
    run_block "$id" "preset '$(config_get preset "")' not found in $(slim_config_file)"
    return 0
  fi
  model="$MODEL_REF"
  body="$(jq -cn --arg dir "$dir" --arg title "$id: $title" --arg id "$id" \
    --arg agent "$agent" --arg model "$model" '
    {location: {directory: $dir}, title: $title, metadata: {agent_tasks: {id: $id}}}
    + (if $agent == "" then {} else {agent: $agent} end)
    + (if $model == "" then {} else {model: ($model | fromjson)} end)')"
  resp="$(run_api post /api/session "$body" 2>/dev/null)" || resp=""
  s="$(jq -r '.data.id // empty' <<< "$resp" 2>/dev/null)" || s=""
  if ! valid_session "$s"; then run_block "$id" "could not create an OpenCode session"; return 0; fi

  lock_acquire
  f="$(task_file "$id")"
  if [ "$(folder_of_file "$f")" != "01_ready" ]; then
    lock_release
    run_say "$id: left 01_ready meanwhile; session $s is unused"
    return 0
  fi
  old="$(fm_get "$f" session)"
  if [ -n "$old" ] && [ "$old" != "$s" ]; then log_append "$f" task "restart: previous session $old"; fi
  fm_set "$f" session "$s" || die "cannot update $f"
  move_task "$f" 02_exploring task "started session $s"
  f="$MOVED_TO"
  store_commit || true
  lock_release

  text="You are working on task $id (attached). Explore the codebase yourself first. Then ask the user your first question with the question tool: one question, with options and your recommendation. Do not start implementing."
  # The path becomes a URI: percent-encode everything but "/" (a store path may contain spaces).
  payload="$(jq -cn --arg text "$text" --arg path "$f" --arg name "$id.md" '{
    text: $text, skills: [{id: "brainstorming"}],
    files: [{uri: ("file://" + ($path | split("/") | map(@uri) | join("/"))), name: $name}], delivery: "queue"}')"
  if ! run_send_prompt "$id" "$s" "$payload"; then
    run_block "$id" "could not send the first prompt to session $s"
    return 0
  fi
  run_say "$id: 01_ready → 02_exploring (session $s)"
}

cmd_run() {
  [ $# -eq 1 ] && [ "$1" = "--once" ] || die "usage: task run --once"
  local active max f
  # Before the .auto checks: archiving must also happen while automation is off.
  if declare -F archive_due >/dev/null; then archive_due; fi
  if declare -F mr_check_due >/dev/null; then mr_check_due || true; fi
  st_sweep
  if [ ! -f "$STORE/.auto" ]; then
    # A job left behind (e.g. `auto off` killed half-way): unload it.
    if [ -f "$(auto_plist)" ]; then
      rm -f "$(auto_plist)"
      auto_unload
    fi
    return 0
  fi
  if ! auto_enabled; then
    # Message first: auto_off ends with a bootout that kills this job.
    run_say "automation off (the active period ended)"
    auto_off >/dev/null
    return 0
  fi
  lock_acquire
  store_commit || true
  lock_release

  if ! command -v opencode >/dev/null 2>&1; then
    run_say "opencode not found on PATH; nothing to do" >&2
    return 1
  fi
  if active="$(run_api get /api/session/active 2>/dev/null)" \
     && jq -e '.data | type == "object"' <<< "$active" >/dev/null 2>&1; then
    run_stale_check "$active"
  else
    run_say "cannot list active sessions (is OpenCode running?); stale check skipped" >&2
  fi

  max="$(max_active)"
  while [ "$(active_count)" -lt "$max" ]; do
    f="$(oldest_unblocked_in 07_approved)"
    if [ -n "$f" ]; then run_continue "$f"; continue; fi
    f="$(oldest_unblocked_in 01_ready)"
    if [ -n "$f" ]; then run_start "$f"; continue; fi
    break
  done
}
