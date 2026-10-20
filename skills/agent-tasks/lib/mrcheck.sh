# shellcheck shell=bash
# Auto-check of MR/PR state for tasks in 10_unmerged.


mr_debug() { if [ -n "${AGENT_TASKS_DEBUG:-}" ]; then warn "mrcheck: $*"; fi; return 0; }

# Runs a command with a ~15 s timeout (portable: no coreutils timeout on macOS).
mr_run() {
  local out rc=0 pid wd tmp
  tmp="$(mktemp)" || return 1
  "$@" > "$tmp" 2>/dev/null < /dev/null &
  pid=$!
  ( sleep "${AGENT_TASKS_MRCHECK_TIMEOUT:-15}"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  out="$(cat "$tmp")"
  rm -f "$tmp"
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$out"
}

# Prints merged|closed|open for a MR/PR URL; fails (silently) when unknown.
mr_state() {   # mr_state <url>
  local url="$1" rest host path n proj st
  case "$url" in
    https://*/-/merge_requests/[0-9]*)
      command -v glab >/dev/null 2>&1 || { mr_debug "glab not found"; return 1; }
      rest="${url#https://}"
      host="${rest%%/*}"
      path="${rest#*/}"
      n="${path##*/-/merge_requests/}"
      n="${n%%[!0-9]*}"
      proj="${path%%/-/merge_requests/*}"
      proj="${proj//\//%2F}"
      if [ "$host" != "gitlab.com" ]; then
        st="$(GITLAB_HOST="$host" mr_run glab api "projects/$proj/merge_requests/$n" | jq -r '.state // empty' 2>/dev/null)" || st=""
      else
        st="$(mr_run glab api "projects/$proj/merge_requests/$n" | jq -r '.state // empty' 2>/dev/null)" || st=""
      fi
      case "$st" in
        merged) echo merged ;;
        closed) echo closed ;;
        opened|locked) echo open ;;
        *) mr_debug "glab: no state for $url"; return 1 ;;
      esac ;;
    https://github.com/*/*/pull/[0-9]*)
      command -v gh >/dev/null 2>&1 || { mr_debug "gh not found"; return 1; }
      st="$(mr_run gh pr view "$url" --json state | jq -r '.state // empty' 2>/dev/null)" || st=""
      case "$st" in
        MERGED) echo merged ;;
        CLOSED) echo closed ;;
        OPEN) echo open ;;
        *) mr_debug "gh: no state for $url"; return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

# mr_check_run <force>: checks every unmerged task with a pr URL. Output lines
# (per task) go to stdout only when <force> is 1.
mr_check_run() {
  local force="$1" f url tid st n=0 took=0 line open
  local -a files=()
  for f in "$STORE"/*/10_unmerged/T-[0-9]*.md; do
    [ -e "$f" ] || continue
    [ -n "$(fm_get "$f" pr)" ] || continue
    files+=("$f")
  done
  mkdir -p "$STORE/.notify"
  date +%s > "$STORE/.notify/mrcheck.last"
  if [ "${#files[@]}" -eq 0 ]; then
    if [ "$force" -eq 1 ]; then echo "no unmerged tasks with a pr link"; fi
    return 0
  fi
  if [ "$LOCK_HELD" -eq 0 ]; then took=1; fi
  lock_acquire
  for f in "${files[@]}"; do
    [ -e "$f" ] || continue
    url="$(fm_get "$f" pr)"
    tid="$(id_of_file "$f")"
    st="$(mr_state "$url")" || st=""
    line=""
    case "$st" in
      merged)
        open="$(st_open_list "$tid")"
        if [ -n "$open" ]; then
          line="$tid: merged, waiting for subtasks: $open"
          if [ "$force" -eq 1 ]; then echo "$line"; fi
          continue
        fi
        move_task "$f" 11_done task "MR merged (auto-check)" merged
        fm_set "$MOVED_TO" result merged || true
        rm -f "$STORE/.notify/$tid.mrclosed"
        n=$((n + 1))
        line="$tid: merged → 11_done" ;;
      closed)
        if [ ! -f "$STORE/.notify/$tid.mrclosed" ]; then
          log_append "$f" task "MR closed without merge; run task done $tid --result discarded or keep working"
          : > "$STORE/.notify/$tid.mrclosed"
          n=$((n + 1))
        fi
        line="$tid: closed without merge" ;;
      open) line="$tid: open" ;;
      *) line="$tid: unknown (check skipped)" ;;
    esac
    if [ "$force" -eq 1 ]; then echo "$line"; fi
  done
  if [ "$n" -gt 0 ]; then store_commit || true; fi
  if [ "$took" -eq 1 ]; then lock_release; fi
  if [ "$n" -gt 0 ] && [ "$force" -eq 0 ]; then echo "merged $n task(s)" >&2; fi
  return 0
}

# Cheap when not due: a config read and a timestamp compare.
mr_check_due() {
  local mins last now
  [ "${AGENT_TASKS_MRCHECK:-1}" != "0" ] || return 0
  mins="$(config_get mr_check_minutes 10)"
  case "$mins" in ''|*[!0-9]*) return 0 ;; esac
  [ "$((10#$mins))" -gt 0 ] || return 0
  last=""
  if [ -f "$STORE/.notify/mrcheck.last" ]; then
    { IFS= read -r last < "$STORE/.notify/mrcheck.last"; } 2>/dev/null || last=""
  fi
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  now="$(date +%s)"
  [ $((now - last)) -ge $((10#$mins * 60)) ] || return 0
  mr_check_run 0 || true
}

cmd_check_mrs() {
  [ $# -eq 0 ] || die "usage: task check-mrs"
  mr_check_run 1
}
