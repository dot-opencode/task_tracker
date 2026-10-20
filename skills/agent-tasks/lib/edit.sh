# shellcheck shell=bash
# Changing tasks: move, log, set/unset, done.

MOVED_TO=""

# Moves the file, keeps blocked_from in step, logs the move; sets MOVED_TO to the
# new path. A move into 11_done cleans up the task's worktree; <result> (default:
# the task's result field) decides about its branch. Not run in a command substitution: errexit is off there, and a failed
# mv would go on to create an orphan file.
move_task() {
  local file="$1" folder="$2" author="$3" reason="${4:-}" result="${5:-}" from ws dest msg blocked_prev="" pfrom
  from="$(folder_of_file "$file")"
  if [ "$from" = "blocked" ]; then blocked_prev="$(fm_get "$file" blocked_from)"; fi
  if [ "$from" = "$folder" ]; then MOVED_TO="$file"; return 0; fi
  ws="$(ws_of_file "$file")"
  dest="$STORE/$ws/$folder/$(basename "$file")"
  [ ! -e "$dest" ] || die "cannot move: $dest already exists"
  mkdir -p "$STORE/$ws/$folder"
  mv "$file" "$dest" || die "cannot move $file to $dest"
  if [ "$folder" = "blocked" ]; then fm_set "$dest" blocked_from "$from" || die "cannot update $dest"; fi
  if [ "$from" = "blocked" ]; then fm_unset "$dest" blocked_from || die "cannot update $dest"; fi
  if [ "$folder" = "postponed" ]; then
    # From blocked the stage itself is remembered, so resume returns there.
    if [ "$from" = "blocked" ] && [ -n "$blocked_prev" ]; then pfrom="$blocked_prev"; else pfrom="$from"; fi
    fm_set "$dest" postponed_from "$pfrom" || die "cannot update $dest"
  fi
  if [ "$from" = "postponed" ]; then fm_unset "$dest" postponed_from || die "cannot update $dest"; fi
  msg="$from → $folder"
  if [ -n "$reason" ]; then msg="$msg — $reason"; fi
  log_append "$dest" "$author" "$msg"
  MOVED_TO="$dest"
  if [ "$folder" = "11_done" ]; then
    if [ -z "$result" ]; then result="$(fm_get "$dest" result)"; fi
    worktree_cleanup "$dest" "$result" || true
  fi
  # The last open subtask finished: the parent closes too (recursively, through move_task).
  case "$folder" in
    11_done|archive) if declare -F st_autoclose >/dev/null; then st_autoclose "$dest"; MOVED_TO="$dest"; fi ;;
  esac
}

cmd_mv() {
  local id="" fol="" reason="" folder f tid from force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) need_value "$@"; reason="$(trim "$2")"; shift 2 ;;
      --force) force=1; shift ;;
      -*) die "unknown option: $1" ;;
      *)
        if [ -z "$id" ]; then id="$1"
        elif [ -z "$fol" ]; then fol="$1"
        else die "usage: task mv <id> <folder> [--reason TEXT] [--force]"
        fi
        shift ;;
    esac
  done
  [ -n "$id" ] && [ -n "$fol" ] || die "usage: task mv <id> <folder> [--reason TEXT] [--force]"
  folder="$(resolve_folder "$fol")" || die "unknown folder '$fol' (folders: $FOLDERS)"
  single_line "$reason" || die "reason must be a single line"
  lock_acquire
  f="$(task_file "$id")"
  fm_require "$f"
  tid="$(normalize_id "$id")"
  from="$(folder_of_file "$f")"
  if [ "$from" = "$folder" ]; then
    echo "$tid is already in $folder"
    return 0
  fi
  if [ "$force" -eq 0 ] && st_parent_wait_folder "$folder"; then st_guard_open "$tid"; fi
  move_task "$f" "$folder" task "$reason"
  store_commit || true
  echo "$tid: $from → $folder"
}

cmd_log() {
  local id="" msg="" have_msg=0 author="agent" f opts=1
  while [ $# -gt 0 ]; do
    if [ "$opts" -eq 1 ] && [ "$1" = "--" ]; then opts=0; shift; continue; fi
    case "$opts:$1" in
      1:--author) need_value "$@"; author="$2"; shift 2 ;;
      *)
        if [ -z "$id" ]; then id="$1"
        elif [ "$have_msg" -eq 0 ]; then msg="$1"; have_msg=1
        else die "usage: task log <id> <message|-> [--author A]"
        fi
        shift ;;
    esac
  done
  if [ -z "$id" ] || [ "$have_msg" -eq 0 ]; then die "usage: task log <id> <message|-> [--author A]"; fi
  msg="$(read_text_arg "$msg")"
  [ -n "$(trim "$msg")" ] || die "log message is empty"
  single_line "$author" || die "author must be a single line"
  [ -n "$author" ] || die "author is empty"
  case "$author" in *:*) die "author must not contain ':'" ;; esac
  lock_acquire
  f="$(task_file "$id")"
  fm_require "$f"
  log_append "$f" "$author" "$msg"
  store_commit || true
  echo "$(normalize_id "$id"): logged"
}

cmd_set() {
  # `--` may precede the arguments or the value, so a value can start with '-'.
  if [ "${1:-}" = "--" ]; then shift; fi
  if [ $# -eq 4 ] && [ "$3" = "--" ]; then set -- "$1" "$2" "$4"; fi
  [ $# -eq 3 ] || die "usage: task set <id> <key> <value>"
  local id="$1" key="$2" val f ws tid
  case "$key" in
    title|project|source|session|spec|plan|pr|result|parent|depends_on) ;;
    *) die "cannot set '$key' (keys: title project source session spec plan pr result parent depends_on); links go to source (ticket), pr (MR/PR), spec or plan (docs)" ;;
  esac
  val="$(trim "$3")"
  [ -n "$val" ] || die "empty value for $key (use 'task unset $id $key' to remove it)"
  single_line "$val" || die "value must be a single line"
  case "$key" in
    project) valid_project "$val" || die "invalid project name '$val'" ;;
    session) valid_session "$val" || die "invalid session id '$val'" ;;
    result) valid_result "$val" || die "invalid result '$val' (one of: $RESULTS)" ;;
  esac
  lock_acquire
  f="$(task_file "$id")"
  fm_require "$f"
  tid="$(normalize_id "$id")"
  if [ "$key" = "project" ]; then
    ws="$(ws_of_file "$f")"
    [ -f "$STORE/$ws/.projects/$val" ] \
      || die "unknown project '$val' in workspace $ws (register it: task project add $val <path>)"
  fi
  if [ "$key" = "parent" ]; then
    val="$(normalize_id "$val")" || die "invalid task id '$val'"
    st_validate_parent "$tid" "$f" "$val"
    fm_set "$f" parent "$val"
  elif [ "$key" = "depends_on" ]; then
    val="$(st_parse_ids "$val")"
    [ -n "$val" ] || die "empty value for depends_on"
    st_validate_depends "$tid" "$val"
    val="$(printf '%s' "$val" | tr '\n' ' ')"
    val="$(trim "$val")"
    fm_set "$f" depends_on "$val"
  elif [ "$key" = "title" ]; then
    fm_set "$f" title "$(fm_quote_always "$val")"
  else
    fm_set "$f" "$key" "$(fm_quote "$val")"
  fi
  store_commit || true
  echo "$tid: $key = $val"
}

cmd_unset() {
  [ $# -eq 2 ] || die "usage: task unset <id> <key>"
  local id="$1" key="$2" f tid
  case "$key" in
    project|source|session|spec|plan|pr|result|worktree|parent|depends_on) ;;
    *) die "cannot unset '$key' (keys: project source session spec plan pr result worktree parent depends_on)" ;;
  esac
  lock_acquire
  f="$(task_file "$id")"
  fm_require "$f"
  tid="$(normalize_id "$id")"
  if [ -z "$(fm_get "$f" "$key")" ]; then
    echo "$tid has no $key"
    return 0
  fi
  fm_unset "$f" "$key"
  store_commit || true
  echo "$tid: $key removed"
}

cmd_done() {
  local id="" result="" summary="" have_summary=0 f tid from dest force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --result) need_value "$@"; result="$2"; shift 2 ;;
      --summary) need_value "$@"; summary="$2"; have_summary=1; shift 2 ;;
      --force) force=1; shift ;;
      -*) die "unknown option: $1" ;;
      *)
        [ -z "$id" ] || die "usage: task done <id> --result R [--summary TEXT|-] [--force]"
        id="$1"; shift ;;
    esac
  done
  [ -n "$id" ] || die "usage: task done <id> --result R [--summary TEXT|-] [--force]"
  [ -n "$result" ] || die "task done requires --result ($RESULTS)"
  valid_result "$result" || die "invalid result '$result' (one of: $RESULTS)"
  if [ "$have_summary" -eq 1 ]; then
    summary="$(read_text_arg "$summary")"
    reject_sections summary "$summary"
  fi
  lock_acquire
  f="$(task_file "$id")"
  fm_require "$f"
  tid="$(normalize_id "$id")"
  from="$(folder_of_file "$f")"
  case "$result" in pr|kept) dest=10_unmerged ;; *) dest=11_done ;; esac
  if [ "$force" -eq 0 ]; then st_guard_open "$tid"; fi
  if [ "$from" = "$dest" ]; then
    log_append "$f" task "result: $result"
  else
    move_task "$f" "$dest" task "result: $result" "$result"
    f="$MOVED_TO"
  fi
  fm_set "$f" result "$result"
  if [ -n "$summary" ]; then result_append "$f" "$summary"; fi
  store_commit || true
  echo "$tid: $from → $dest (result: $result)"
}

cmd_merged() {
  local id="" summary="" have_summary=0 f tid from force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --summary) need_value "$@"; summary="$2"; have_summary=1; shift 2 ;;
      --force) force=1; shift ;;
      -*) die "unknown option: $1" ;;
      *)
        [ -z "$id" ] || die "usage: task merged <id> [--summary TEXT|-] [--force]"
        id="$1"; shift ;;
    esac
  done
  [ -n "$id" ] || die "usage: task merged <id> [--summary TEXT|-] [--force]"
  if [ "$have_summary" -eq 1 ]; then
    summary="$(read_text_arg "$summary")"
    reject_sections summary "$summary"
  fi
  lock_acquire
  f="$(task_file "$id")"
  fm_require "$f"
  tid="$(normalize_id "$id")"
  from="$(folder_of_file "$f")"
  [ "$from" = "10_unmerged" ] || die "$tid is in $from; only unmerged tasks can be marked merged"
  if [ "$force" -eq 0 ]; then st_guard_open "$tid"; fi
  move_task "$f" 11_done task "merged" merged
  f="$MOVED_TO"
  fm_set "$f" result merged
  if [ -n "$summary" ]; then result_append "$f" "$summary"; fi
  store_commit || true
  echo "$tid: 10_unmerged → 11_done (result: merged)"
}
