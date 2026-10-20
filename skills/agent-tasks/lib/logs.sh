# shellcheck shell=bash
# task logs: the automation worker log and a task's own `## Log` section.

LOGS_USAGE="usage: task logs [<id>] [-n N] [-f]"

# Also used by auto.sh (launchd StandardOutPath / StandardErrorPath).
worker_log_path() { printf '%s\n' "$HOME/Library/Logs/agent-tasks.log"; }

# Non-empty lines after the `## Log` heading (the heading is looked up only
# after the closing frontmatter `---`).
logs_task_lines() {
  awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm { if ($0 == "---") infm = 0; next }
    inlog { if ($0 != "") print; next }
    $0 == "## Log" { inlog = 1 }
  ' "$1"
}

# Number of lines in a text held in a variable (0 for the empty text).
logs_count() {
  if [ -z "$1" ]; then echo 0; return 0; fi
  printf '%s\n' "$1" | wc -l | tr -d ' '
}

logs_worker() {   # logs_worker <n> <follow>
  local n="$1" follow="$2" path
  path="$(worker_log_path)"
  if [ ! -f "$path" ]; then
    echo "no worker log yet ($path): automation has not run"
    return 0
  fi
  if [ "$follow" -eq 1 ]; then exec tail -n "$n" -F "$path"; fi
  tail -n "$n" "$path"
}

logs_task() {   # logs_task <id> <n> <follow>
  local raw="$1" n="$2" follow="$3" id f folder nf nfolder err all count printed polls=0 i=0 fresh
  id="$(normalize_id "$raw")" || die "invalid task id '$raw'"
  f="$(task_file "$id")"
  folder="$(folder_of_file "$f")"
  printf '%s · %s · %s\n' "$id" "$folder" "$(fm_get "$f" title)"
  all="$(logs_task_lines "$f")"
  printed="$(logs_count "$all")"
  if [ "$printed" -gt 0 ]; then printf '%s\n' "$all" | tail -n "$n"; fi
  if [ "$follow" -eq 0 ]; then return 0; fi

  if [ -n "${AGENT_TASKS_LOGS_POLLS:-}" ]; then polls="$AGENT_TASKS_LOGS_POLLS"; fi
  while [ -z "${AGENT_TASKS_LOGS_POLLS:-}" ] || [ "$i" -lt "$polls" ]; do
    sleep "${AGENT_TASKS_LOGS_INTERVAL:-1}"
    i=$((i + 1))
    if ! nf="$(task_file "$id" 2>&1)"; then
      err="$nf"
      case "$err" in
        *duplicate*) continue ;;   # mid-move or a broken store: look again next time
      esac
      echo "-- task no longer exists"
      return 0
    fi
    f="$nf"
    all="$(logs_task_lines "$f")" || continue   # moved right after the lookup
    count="$(logs_count "$all")"
    if [ "$count" -gt "$printed" ]; then
      fresh="$(printf '%s\n' "$all" | tail -n +$((printed + 1)))"
      printf '%s\n' "$fresh"
    fi
    printed="$count"
    nfolder="$(folder_of_file "$f")"
    if [ "$nfolder" != "$folder" ]; then
      echo "-- moved to $nfolder"
      folder="$nfolder"
    fi
  done
}

cmd_logs() {
  local n="" follow=0 id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -n)
        need_value "$@"
        [[ "$2" =~ ^[0-9]+$ ]] || die "invalid -n '$2'"
        n="$2"; shift 2 ;;
      -f) follow=1; shift ;;
      -*) die "$LOGS_USAGE" ;;
      *)
        [ -z "$id" ] || die "$LOGS_USAGE"
        id="$1"; shift ;;
    esac
  done
  if [ -z "$id" ]; then
    logs_worker "${n:-50}" "$follow"
  else
    logs_task "$id" "${n:-20}" "$follow"
  fi
}
