# shellcheck shell=bash
# Postponed: a task the user set aside; it leaves the default view and the pipeline.

cmd_postpone() {
  local id="" reason="" f tid from ses target msg
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) need_value "$@"; reason="$(trim "$2")"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) [ -z "$id" ] || die "usage: task postpone <id> [--reason TEXT]"; id="$1"; shift ;;
    esac
  done
  [ -n "$id" ] || die "usage: task postpone <id> [--reason TEXT]"
  single_line "$reason" || die "reason must be a single line"
  lock_acquire
  f="$(task_file "$id")"
  fm_require "$f"
  tid="$(normalize_id "$id")"
  from="$(folder_of_file "$f")"
  case "$from" in
    10_unmerged|11_done|archive) die "$tid is in $from; done/archived tasks cannot be postponed" ;;
    postponed) die "$tid is already postponed" ;;
  esac
  ses="$(fm_get "$f" session)"
  move_task "$f" postponed task
  f="$MOVED_TO"
  target="$(fm_get "$f" postponed_from)"
  msg="postponed"
  if [ -n "$reason" ]; then msg="postponed — $reason"; fi
  log_append "$f" task "$msg"
  store_commit || true
  echo "$tid: $from → postponed (from $target)"
  case "$from" in
    02_exploring|05_planning|08_implementing)
      if [ -n "$ses" ]; then
        echo "warning: session $ses may still be running; stop it in OpenCode (task open $tid)" >&2
      fi ;;
  esac
}

cmd_resume() {
  [ $# -eq 1 ] || die "usage: task resume <id>"
  local f tid from target
  lock_acquire
  f="$(task_file "$1")"
  fm_require "$f"
  tid="$(normalize_id "$1")"
  from="$(folder_of_file "$f")"
  [ "$from" = "postponed" ] || die "$tid is in $from; not postponed"
  target="$(fm_get "$f" postponed_from)"
  target="$(resolve_folder "$target" 2>/dev/null)" || target=""
  case "$target" in ''|postponed|blocked|archive|11_done|10_unmerged) target=00_backlog ;; esac
  case "$target" in
    02_exploring|05_planning|08_implementing)
      # No agent runs there any more: wait for the user in blocked.
      move_task "$f" blocked task
      fm_set "$MOVED_TO" blocked_from "$target" || die "cannot update $MOVED_TO"
      log_append "$MOVED_TO" task "resumed; open the session to continue"
      store_commit || true
      echo "$tid: postponed → blocked (from $target); continue with: task open $tid"
      ;;
    *)
      move_task "$f" "$target" task
      log_append "$MOVED_TO" task "resumed"
      store_commit || true
      echo "$tid: postponed → $target"
      ;;
  esac
}
