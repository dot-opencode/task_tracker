# shellcheck shell=bash
# Archive: done tasks that stay finished for archive_after_days leave the view.

# "Now" as `YYYY-MM-DD HH:MM` (local time, like the log). AGENT_TASKS_NOW is a
# test affordance and takes the same format.
archive_now() {
  if [ -n "${AGENT_TASKS_NOW:-}" ]; then printf '%s\n' "$AGENT_TASKS_NOW"; else date '+%Y-%m-%d %H:%M'; fi
}

ARCHIVED_N=0

# Prints `path<TAB>import|age` for every 11_done task that was archived in
# ai_task_tracker (`import`) or whose done age is at least $1 days (`age`).
# Done age: now minus the newest `## Log` entry that is not an import/migration
# marker; without one, the `created` date.
archive_due_files() {
  local days="$1" dir="${2:-11_done}" now f
  local -a files=()
  now="$(archive_now)"
  for f in "$STORE"/*/"$dir"/T-[0-9]*.md; do
    [ -e "$f" ] || continue
    files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  awk -v now="$now" -v days="$days" '
    function mins(d, t,   y, m, dd, hh, mm, a, b, era, yoe, doy, doe, days_) {
      split(d, a, "-"); y = a[1] + 0; m = a[2] + 0; dd = a[3] + 0
      split(t, b, ":"); hh = b[1] + 0; mm = b[2] + 0
      if (m <= 2) y--
      era = int(y / 400)
      yoe = y - era * 400
      doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + dd - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      days_ = era * 146097 + doe
      return days_ * 1440 + hh * 60 + mm
    }
    function flush() {
      if (file == "") return
      if (arch) { print file "\timport"; return }
      if (last == "") last = created
      if (last != "" && nowm - last >= days * 1440) print file "\tage"
    }
    BEGIN { split(now, n, " "); nowm = mins(n[1], n[2]) }
    FNR == 1 {
      flush()
      file = FILENAME; created = ""; last = ""; fm = 0; inlog = 0; arch = 0
    }
    FNR == 1 && $0 == "---" { fm = 1; next }
    fm == 1 {
      if ($0 == "---") { fm = 2; next }
      if ($0 ~ /^created:[ \t]*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
        v = $0; sub(/^created:[ \t]*/, "", v); created = mins(substr(v, 1, 10), "00:00")
      }
      next
    }
    $0 == "## Log" { inlog = 1; next }
    inlog && $0 ~ /^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] / {
      rest = substr($0, 3)
      d = substr(rest, 1, 10); t = substr(rest, 12, 5)
      msg = substr(rest, 18)
      i = index(msg, ": ")
      if (i > 0) msg = substr(msg, i + 2)
      if (msg ~ /^imported from ai_task_tracker \(status [^,)]+, archived[,)]/) arch = 1
      if (msg ~ /^imported from ai_task_tracker/ || msg ~ /^folder layout migration/) next
      v = mins(d, t)
      if (last == "" || v > last) last = v
    }
    END { flush() }
  ' "${files[@]}"
}

# Moves every due task to archive in one commit. Silent and lock-free when
# nothing is due (it runs often); prints `archived N task(s)` otherwise.
archive_due() {
  local days f why n=0 due took=0
  ARCHIVED_N=0
  days="$(config_get archive_after_days 14)"
  case "$days" in ''|*[!0-9]*) return 0 ;; esac
  [ "$((10#$days))" -gt 0 ] || return 0
  days=$((10#$days))
  [ -n "$(archive_due_files "$days")" ] || return 0
  if [ "$LOCK_HELD" -eq 0 ]; then took=1; fi
  lock_acquire
  due="$(archive_due_files "$days")"
  while IFS=$'\t' read -r f why; do
    [ -n "$f" ] || continue
    if [ "$why" = "import" ]; then
      move_task "$f" archive task "archived (already archived in ai_task_tracker)"
    else
      move_task "$f" archive task "archived after $days days in done"
    fi
    n=$((n + 1))
  done <<< "$due"
  if [ "$n" -gt 0 ]; then
    store_commit || true
    ARCHIVED_N="$n"
    echo "archived $n task(s)"
  fi
  if [ "$took" -eq 1 ]; then lock_release; fi
}

cmd_archive() {
  local id="" due=0 f tid from
  while [ $# -gt 0 ]; do
    case "$1" in
      --due) due=1; shift ;;
      -*) die "unknown option: $1" ;;
      *) [ -z "$id" ] || die "usage: task archive <id> | --due"; id="$1"; shift ;;
    esac
  done
  if [ "$due" -eq 1 ]; then
    [ -z "$id" ] || die "usage: task archive <id> | --due"
    archive_due
    if [ "$ARCHIVED_N" -eq 0 ]; then echo "nothing to archive"; fi
    return 0
  fi
  [ -n "$id" ] || die "usage: task archive <id> | --due"
  lock_acquire
  f="$(task_file "$id")"
  fm_require "$f"
  tid="$(normalize_id "$id")"
  from="$(folder_of_file "$f")"
  [ "$from" = "11_done" ] || die "$tid is in $from; only done tasks can be archived"
  move_task "$f" archive task "archived"
  store_commit || true
  echo "$tid: 11_done → archive"
}

cmd_unarchive() {
  [ $# -eq 1 ] || die "usage: task unarchive <id>"
  local f tid from
  lock_acquire
  f="$(task_file "$1")"
  fm_require "$f"
  tid="$(normalize_id "$1")"
  from="$(folder_of_file "$f")"
  [ "$from" = "archive" ] || die "$tid is in $from; not archived"
  move_task "$f" 11_done task "unarchived"
  store_commit || true
  echo "$tid: archive → 11_done"
}
