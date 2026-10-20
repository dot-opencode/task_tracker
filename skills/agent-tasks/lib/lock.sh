# shellcheck shell=bash
# Store lock: a mkdir-based mutex with the holder's pid inside.

LOCK_HELD=0

# Dead pid, or no pid file for over a minute (the holder died between mkdir and
# writing it). An unreadable or odd pid counts as alive: never steal on doubt.
lock_is_stale() {
  local lock="$1" pid=""
  if [ -f "$lock/pid" ]; then
    { IFS= read -r pid < "$lock/pid"; } 2>/dev/null || true
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    ! kill -0 "$pid" 2>/dev/null
  else
    [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]
  fi
}

lock_acquire() {
  if [ "$LOCK_HELD" -eq 1 ]; then return 0; fi
  local lock="$STORE/.lock" timeout="${AGENT_TASKS_LOCK_TIMEOUT:-10}" pid="" tries=0 max
  max=$((timeout * 10))
  while ! mkdir "$lock" 2>/dev/null; do
    # Two waiters can both see a dead holder; if each simply removed the lock,
    # the second rm would delete the first one's fresh lock. The steal is
    # serialised by a second mkdir and staleness is re-checked under it.
    if [ -d "$lock.steal" ] && [ -n "$(find "$lock.steal" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$lock.steal" 2>/dev/null || true   # a stealer died inside the window
    fi
    if lock_is_stale "$lock" && mkdir "$lock.steal" 2>/dev/null; then
      if lock_is_stale "$lock"; then rm -rf "$lock"; fi
      rmdir "$lock.steal"
      continue
    fi
    pid=""
    if [ -f "$lock/pid" ]; then { IFS= read -r pid < "$lock/pid"; } 2>/dev/null || true; fi
    case "$pid" in *[!0-9]*) pid="" ;; esac
    if [ "$tries" -ge "$max" ]; then
      die "store is locked by pid ${pid:-unknown} ($lock)"
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  printf '%s\n' "$$" > "$lock/pid"
  LOCK_HELD=1
  trap lock_release EXIT
  trap 'exit 130' INT TERM HUP
}

lock_release() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    rm -rf "$STORE/.lock"
    LOCK_HELD=0
  fi
}
