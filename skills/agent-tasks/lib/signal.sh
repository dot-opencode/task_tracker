# shellcheck shell=bash
# Session signals from the OpenCode plugin: the transition table.

SIGNALS="question turn-end input answered permission error stalled finishing"

# Number of task files in the given folders across all workspaces.
count_tasks_in() {
  local ws fo f n=0
  for ws in $(list_workspaces); do
    for fo in "$@"; do
      for f in "$STORE/$ws/$fo"/T-[0-9]*.md; do
        [ -e "$f" ] || continue
        n=$((n + 1))
      done
    done
  done
  printf '%s\n' "$n"
}

# Agents at work: tasks in 02_exploring, 05_planning and 08_implementing.
# shellcheck disable=SC2086 # folder list
active_count() { count_tasks_in $AGENT_FOLDERS; }

# Path of the least recently touched task in the folders: ctime is the last
# inode change (a move, but also every log append or edit), which is the
# intended queue order. Ties go to the lower path. --with-session skips unbound tasks.
oldest_task_in() { oldest_tasks_in "$@" | awk 'NR == 1 { print }'; }

# Same ordering, every task (one path per line).
oldest_tasks_in() {
  local need=0 ws fo f list="" t
  if [ "${1:-}" = "--with-session" ]; then need=1; shift; fi
  for ws in $(list_workspaces); do
    for fo in "$@"; do
      for f in "$STORE/$ws/$fo"/T-[0-9]*.md; do
        [ -e "$f" ] || continue
        if [ "$need" -eq 1 ] && [ -z "$(fm_get "$f" session)" ]; then continue; fi
        t="$(stat -f %Fc "$f" 2>/dev/null)" || t="$(stat -f %c "$f")"
        list="$list$t"$'\t'"$f"$'\n'
      done
    done
  done
  [ -n "$list" ] || return 0
  printf '%s' "$list" | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2 | awk -F'\t' '{ print $2 }'
}

max_active() {
  local n
  n="$(config_get max_active 2)"
  case "$n" in ''|*[!0-9]*) n=2 ;; esac
  printf '%s\n' "$((10#$n))"
}

# The user acted in the task's session (quiet rule of notify_task).
record_user_activity() {
  mkdir -p "$STORE/.notify"
  date +%s > "$STORE/.notify/$1.last-user"
}

# 0 when a child session of $1 is running. $2 is the /api/session/active answer
# (fetched when empty). Any failure counts as "no running children", with a warning.
session_has_running_children() {
  local s="$1" active="${2:-}" kids rc=0
  if ! command -v opencode >/dev/null 2>&1; then
    warn "opencode not found; child sessions of $s not checked"
    return 1
  fi
  if [ -z "$active" ]; then
    active="$(opencode api get "/api/session/active" 2>/dev/null)" \
      || { warn "cannot list active sessions; child sessions of $s not checked"; return 1; }
  fi
  kids="$(opencode api get "/api/session?parentID=$s" 2>/dev/null)" \
    || { warn "cannot list child sessions of $s; assuming none"; return 1; }
  # The parentID filter is re-applied here: a server that ignored the query
  # would otherwise make every running session look like a child.
  AT_ACTIVE="$active" jq -e --arg s "$s" '
    (env.AT_ACTIVE | fromjson | .data // {}) as $a
    | [ .data
        | (if type == "array" then . elif type == "object" then (.items // .sessions // []) else [] end)
        | .[]? | select(type == "object" and .id != $s and ((.parentID // $s) == $s)) | .id ]
    | any(.[]; . as $id | ($a | type == "object") and ($a | has($id)))
  ' <<< "$kids" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  warn "unexpected answer when listing child sessions of $s; assuming none"
  return 1
}

# Text of the notification for a signal.
signal_body() {   # signal_body <signal> <text> <new folder> <spec> <plan>
  if [ "$1" = "turn-end" ] && [ "$3" = "04_spec_review" ] && [ -n "$4" ]; then
    printf 'Spec ready for review: %s\n' "$4"; return 0
  fi
  if [ "$1" = "turn-end" ] && [ "$3" = "06_plan_review" ] && [ -n "${5:-}" ]; then
    printf 'Plan ready for review: %s\n' "$5"; return 0
  fi
  if [ -n "$2" ]; then printf '%s\n' "$2"; return 0; fi
  case "$1" in
    question) echo "The agent has a question." ;;
    turn-end) echo "The agent is waiting for you." ;;
    permission) echo "The agent asks for a permission." ;;
    error) echo "The session failed." ;;
    stalled) echo "The session stopped." ;;
    *) echo "$1" ;;
  esac
}

# The transition table: sets S_TARGET (folder or empty), S_LOG (1 = log only)
# and S_NOTIFY for <signal> in <folder>. In postponed every signal is only
# logged: the user set the task aside, nothing moves and nobody is notified.
# question in 02/03 + spec → 04, in 05 + plan → 06 (review asked with the question tool); without → blocked/03.
signal_plan() {   # signal_plan <signal> <folder> <spec> <blocked_from> [<plan>]
  local signal="$1" folder="$2" spec="$3" from="$4" plan="${5:-}"
  S_TARGET=""; S_LOG=0; S_NOTIFY=0
  case "$folder" in
    00_backlog|01_ready|11_done) folder="" ;;
  esac
  case "$signal:$folder" in
    *:) ;;
    *:postponed) S_LOG=1 ;;
    # Finished, waiting for the merge: follow-up work happens in place; the folder never moves.
    question:10_unmerged) S_LOG=1; S_NOTIFY=1 ;;
    turn-end:10_unmerged) S_LOG=1 ;;
    *:10_unmerged) ;;
    question:02_exploring) S_TARGET=03_brainstorming; S_NOTIFY=1 ;;
    question:07_approved) S_LOG=1 ;;
    question:05_planning)
      # The plan review asked with the question tool: the plan is recorded, so it is in review.
      if [ -n "$plan" ]; then S_TARGET=06_plan_review; else S_TARGET=blocked; fi
      S_NOTIFY=1 ;;
    question:08_implementing) S_TARGET=blocked; S_NOTIFY=1 ;;
    question:*) S_LOG=1; S_NOTIFY=1 ;;
    turn-end:02_exploring)
      if [ -n "$spec" ]; then S_TARGET=04_spec_review; else S_TARGET=03_brainstorming; fi
      S_NOTIFY=1 ;;
    turn-end:03_brainstorming)
      if [ -n "$spec" ]; then S_TARGET=04_spec_review; else S_LOG=1; fi
      S_NOTIFY=1 ;;
    turn-end:05_planning)
      if [ -n "$plan" ]; then S_TARGET=06_plan_review; else S_TARGET=blocked; fi
      S_NOTIFY=1 ;;
    turn-end:07_approved) ;;
    turn-end:08_implementing) S_TARGET=blocked; S_NOTIFY=1 ;;
    turn-end:*) S_LOG=1; S_NOTIFY=1 ;;
    permission:blocked|error:blocked|stalled:blocked) ;;
    permission:*|error:*|stalled:*) S_TARGET=blocked; S_NOTIFY=1 ;;
    input:blocked|answered:blocked)
      S_TARGET="$(resolve_folder "$from" 2>/dev/null)" || S_TARGET=""
      case "$S_TARGET" in ''|blocked) S_TARGET=03_brainstorming ;; esac
      ;;
    finishing:09_finishing|finishing:blocked) ;;
    finishing:*) S_TARGET=09_finishing ;;
  esac
}

# 0 when `task run` posted a prompt to this task's session less than 60 s ago:
# the plugin reports that prompt as `input`, but the user did not type it.
# The marker is consumed.
auto_prompt_pending() {
  local m="$STORE/.notify/$1.auto-prompt" age
  [ -f "$m" ] || return 1
  age=$(( $(date +%s) - $(stat -f %m "$m") ))
  rm -f "$m"
  [ "$age" -lt 60 ]
}

cmd_signal() {
  local usage="usage: task signal <id> <signal> --session <session-id> [--text TEXT]"
  local id="" signal="" session="" text="" tid f cur folder spec plan first
  local clear=0 shown msg open
  local S_TARGET S_LOG S_NOTIFY
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) need_value "$@"; session="$2"; shift 2 ;;
      # Empty text is fine: the plugin always passes --text.
      --text) [ $# -ge 2 ] || die "--text requires a value"; text="$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *)
        if [ -z "$id" ]; then id="$1"
        elif [ -z "$signal" ]; then signal="$1"
        else die "$usage"
        fi
        shift ;;
    esac
  done
  [ -n "$id" ] && [ -n "$signal" ] && [ -n "$session" ] || die "$usage"
  tid="$(normalize_id "$id")" || die "invalid task id '$id'"
  case " $SIGNALS " in
    *" $signal "*) ;;
    *) die "unknown signal '$signal' (signals: $SIGNALS)" ;;
  esac
  valid_session "$session" || die "invalid session id '$session'"
  while [ "${text%$'\n'}" != "$text" ]; do text="${text%$'\n'}"; done
  first="$(trim "${text%%$'\n'*}")"

  # The orchestrator ends its turn while background subagents still work.
  # Asking OpenCode takes a while, so it happens before the lock, on an
  # unlocked read; the table is evaluated again under the lock.
  if [ "$signal" = "turn-end" ]; then
    f="$(task_file "$tid")"
    fm_require "$f"
    if [ "$(fm_get "$f" session)" = "$session" ]; then
      signal_plan "$signal" "$(folder_of_file "$f")" "$(fm_get "$f" spec)" "" "$(fm_get "$f" plan)"
      if { [ -n "$S_TARGET" ] || [ "$S_LOG" -eq 1 ]; } && session_has_running_children "$session"; then
        echo "$tid: turn-end ignored (child sessions are running)"
        return 0
      fi
    fi
  fi

  lock_acquire
  f="$(task_file "$tid")"
  fm_require "$f"
  cur="$(fm_get "$f" session)"
  if [ "$cur" != "$session" ]; then
    echo "$tid: ignored $signal from $session (bound to ${cur:-none})" >&2
    return 0
  fi
  case "$signal" in
    input)
      if ! auto_prompt_pending "$tid"; then record_user_activity "$tid"; fi
      clear=1 ;;
    answered) record_user_activity "$tid"; clear=1 ;;
  esac
  folder="$(folder_of_file "$f")"
  spec="$(fm_get "$f" spec)"; plan="$(fm_get "$f" plan)"
  signal_plan "$signal" "$folder" "$spec" "$(fm_get "$f" blocked_from)" "$plan"

  shown="$folder"
  if [ -n "$S_TARGET" ] && st_parent_wait_folder "$S_TARGET"; then
    open="$(st_open_list "$tid")"
    if [ -n "$open" ]; then
      log_append "$f" task "waiting for subtasks: $open"
      store_commit || true
      echo "$tid: $signal → $S_TARGET deferred (waiting for subtasks: $open)"
      S_TARGET=""; S_LOG=2
    fi
  fi
  if [ "$S_LOG" -eq 2 ]; then
    :
  elif [ -n "$S_TARGET" ]; then
    msg="$signal"
    if [ -n "$first" ]; then msg="$signal — $first"; fi
    move_task "$f" "$S_TARGET" task "$msg"
    store_commit || true
    echo "$tid: $folder → $S_TARGET"
    shown="$S_TARGET"
  elif [ "$S_LOG" -eq 1 ]; then
    msg="$signal"
    if [ -n "$first" ]; then msg="$signal: $first"; fi
    log_append "$f" task "$msg"
    store_commit || true
    echo "$tid: $signal noted"
  else
    echo "$tid: $signal ignored ($folder)"
  fi

  # lib/open.sh is optional here: without it signals still move tasks.
  if [ "$clear" -eq 1 ] && declare -F notify_clear >/dev/null; then notify_clear "$tid"; fi
  if [ "$S_NOTIFY" -eq 1 ] && declare -F notify_task >/dev/null; then
    notify_task "$tid" "$tid · $shown" "$(signal_body "$signal" "$text" "$shown" "$spec" "$plan")" "$signal"
  fi
  return 0
}
