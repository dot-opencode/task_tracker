# shellcheck shell=bash
# Binding OpenCode sessions to tasks.

# Ids of the tasks whose `session` equals $1.
find_by_session() {
  local session="$1" files row
  set --
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    set -- "$@" "$row"
  done <<< "$(all_task_files)"
  [ $# -gt 0 ] || return 0
  files="$(task_rows "$@")"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    split_row "$row"
    if [ "$R_SESSION" = "$session" ]; then id_of_file "$R_PATH"; fi
  done <<< "$files"
  return 0
}

cmd_find() {
  [ $# -eq 2 ] && [ "$1" = "--session" ] || die "usage: task find --session <session-id>"
  valid_session "$2" || die "invalid session id '$2'"
  local ids
  ids="$(find_by_session "$2")"
  [ -n "$ids" ] || return 1
  printf '%s\n' "$ids"
}

cmd_bind() {
  local id="" session="" tid resp merged payload f other
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) need_value "$@"; session="$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *)
        [ -z "$id" ] || die "usage: task bind <id> --session <session-id>"
        id="$1"; shift ;;
    esac
  done
  [ -n "$id" ] && [ -n "$session" ] || die "usage: task bind <id> --session <session-id>"
  tid="$(normalize_id "$id")" || die "invalid task id '$id'"
  valid_session "$session" || die "invalid session id '$session'"
  command -v opencode >/dev/null 2>&1 || die "opencode not found on PATH"

  resp="$(opencode api get "/api/session/$session" 2>/dev/null)" \
    || die "session $session not found (is OpenCode running?)"
  jq -e --arg s "$session" '.data.id == $s' <<< "$resp" >/dev/null 2>&1 \
    || die "session $session not found (is OpenCode running?)"
  merged="$(jq -c --arg id "$tid" '(.data.metadata // {}) + {agent_tasks: {id: $id}}' <<< "$resp")"
  payload="$(jq -cn --argjson m "$merged" '{metadata: $m}')"

  lock_acquire
  f="$(task_file "$tid")"
  fm_require "$f"
  while IFS= read -r other; do
    [ -n "$other" ] || continue
    if [ "$other" != "$tid" ]; then die "session $session is already bound to $other"; fi
  done <<< "$(find_by_session "$session")"
  opencode api patch "/api/session/$session" --data "$payload" >/dev/null \
    || die "could not update metadata of session $session; $tid left unchanged"
  fm_set "$f" session "$session"
  log_append "$f" agent "bound session $session"
  store_commit || true
  echo "$tid: bound to $session"
}
