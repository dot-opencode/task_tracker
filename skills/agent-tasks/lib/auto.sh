# shellcheck shell=bash
# Active period: `.auto` in the store plus the launchd job that runs `task run --once`.

AUTO_LABEL="agent-tasks.run"

auto_file() { printf '%s\n' "$STORE/.auto"; }
auto_plist() { printf '%s\n' "$HOME/Library/LaunchAgents/$AUTO_LABEL.plist"; }

# Prints the value of `<key>=` from .auto (empty when absent or not a number).
auto_field() {
  local v=""
  [ -f "$STORE/.auto" ] || return 0
  v="$(AUTO_KEY="$1" awk -F= '$1 == ENVIRON["AUTO_KEY"] { print $2; exit }' "$STORE/.auto")"
  case "$v" in ''|*[!0-9]*) v="" ;; esac
  printf '%s\n' "$v"
}

# 0 when .auto exists and has not expired (until=0 means no end).
auto_enabled() {
  local until
  [ -f "$STORE/.auto" ] || return 1
  until="$(auto_field until)"
  [ -n "$until" ] || until=0
  [ "$until" -eq 0 ] || [ "$(date +%s)" -lt "$until" ]
}

# 0 when .auto exists but its end has passed.
auto_expired() { [ -f "$STORE/.auto" ] && ! auto_enabled; }

# Seconds left, or ∞ for no end.
auto_remaining() {
  local until left
  until="$(auto_field until)"
  if [ -z "$until" ] || [ "$until" -eq 0 ]; then echo "∞"; return 0; fi
  left=$((until - $(date +%s)))
  if [ "$left" -lt 0 ]; then left=0; fi
  echo "$left"
}

# 30m 2h 1h30m 90m → seconds; non-zero exit when unparsable.
parse_duration() {
  local d="$1" h=0 m=0 re='^([0-9]+h)?([0-9]+m)?$'
  [ -n "$d" ] && [[ "$d" =~ $re ]] || return 1
  if [ -n "${BASH_REMATCH[1]}" ]; then h="${BASH_REMATCH[1]%h}"; fi
  if [ -n "${BASH_REMATCH[2]}" ]; then m="${BASH_REMATCH[2]%m}"; fi
  [ "${#h}" -le 4 ] && [ "${#m}" -le 6 ] || return 1
  h=$((10#$h)); m=$((10#$m))
  [ $((h * 60 + m)) -gt 0 ] || return 1
  printf '%s\n' "$(( (h * 60 + m) * 60 ))"
}

fmt_duration() {   # seconds → 1h42m / 5m
  local s="$1" h m
  m=$(( (s + 59) / 60 )); h=$((m / 60)); m=$((m % 60))
  if [ "$h" -gt 0 ]; then printf '%sh%02dm\n' "$h" "$m"; else printf '%sm\n' "$m"; fi
}

fmt_until() {   # epoch → HH:MM today, else YYYY-MM-DD HH:MM
  if [ "$(date -r "$1" +%Y-%m-%d)" = "$(date +%Y-%m-%d)" ]; then
    date -r "$1" +%H:%M
  else
    date -r "$1" '+%Y-%m-%d %H:%M'
  fi
}

xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

auto_write_plist() {
  local tpl="$TASK_ROOT/launchd/$AUTO_LABEL.plist.tpl" dest path
  dest="$(auto_plist)"
  [ -f "$tpl" ] || die "launchd template not found: $tpl"
  path="$HOME/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  mkdir -p "$(dirname "$dest")" "$HOME/Library/Logs"
  P_BIN="$(xml_escape "$TASK_BIN")" P_PATH="$(xml_escape "$path")" \
  P_STORE="$(xml_escape "$STORE")" P_LOG="$(xml_escape "$(worker_log_path)")" awk '
    { gsub(/__TASK_BIN__/, ENVIRON["P_BIN"]); gsub(/__PATH__/, ENVIRON["P_PATH"])
      gsub(/__STORE__/, ENVIRON["P_STORE"]); gsub(/__LOG__/, ENVIRON["P_LOG"]); print }
  ' "$tpl" > "$dest.tmp" || { rm -f "$dest.tmp"; die "cannot write $dest"; }
  mv "$dest.tmp" "$dest"
}

auto_unload() {
  launchctl bootout "gui/$(id -u)/$AUTO_LABEL" >/dev/null 2>&1 || true
}

# Loads the job, or restarts it when it is already loaded: the plist is the
# same between `on` calls, and bootout followed at once by bootstrap races
# (bootstrap fails with 5/36 while the old instance is being torn down).
auto_load() {
  local plist="$1" domain tries=0
  domain="gui/$(id -u)"
  if launchctl print "$domain/$AUTO_LABEL" >/dev/null 2>&1; then
    # The plist is unchanged, so a failed kickstart still leaves a loaded job.
    launchctl kickstart -k "$domain/$AUTO_LABEL" >/dev/null 2>&1 || true
    return 0
  fi
  while ! launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge 5 ]; then
      # `print` can fail for reasons other than "not loaded"; if the job turns
      # out to be loaded after all, that is the state we wanted.
      launchctl print "$domain/$AUTO_LABEL" >/dev/null 2>&1 && return 0
      return 1
    fi
    sleep 0.2
  done
}

auto_on() {
  local secs=0 until=0 now plist
  if [ $# -gt 0 ]; then
    secs="$(parse_duration "$1")" || die "invalid duration '$1' (examples: 30m 2h 1h30m)"
  fi
  command -v launchctl >/dev/null 2>&1 || die "launchctl not found"
  now="$(date +%s)"
  if [ "$secs" -gt 0 ]; then until=$((now + secs)); fi
  printf 'until=%s\nsince=%s\n' "$until" "$now" > "$STORE/.auto"
  auto_write_plist
  plist="$(auto_plist)"
  if ! auto_load "$plist"; then
    rm -f "$STORE/.auto" "$plist"
    die "launchctl could not load $plist"
  fi
  if [ "$until" -gt 0 ]; then
    echo "automation on (until $(fmt_until "$until"))"
  else
    echo "automation on (until 'task auto off')"
  fi
}

auto_off() {
  # Files and the message first, bootout last: when `task run` (the job
  # itself) turns automation off at expiry, bootout SIGTERMs this very
  # process, and anything after it would never run.
  rm -f "$(auto_plist)" "$STORE/.auto"
  echo "automation off"
  if command -v launchctl >/dev/null 2>&1; then auto_unload; fi
}

auto_status() {
  local left approved ready
  if auto_enabled; then
    left="$(auto_remaining)"
    if [ "$left" = "∞" ]; then
      echo "automation: on (until 'task auto off')"
    else
      echo "automation: on, $(fmt_duration "$left") left"
    fi
  elif [ -f "$STORE/.auto" ]; then
    echo "automation: off (expired)"
  else
    echo "automation: off"
  fi
  echo "active agents: $(active_count)/$(max_active)"
  if resolve_task_model; then
    echo "model: $MODEL_LABEL"
  else
    echo "model: unresolved (preset '$(config_get preset "")' not found in $(slim_config_file))"
  fi
  approved="$(count_tasks_in 07_approved)"; ready="$(count_tasks_in 01_ready)"
  echo "queue: $approved approved, $ready ready"
}

cmd_auto() {
  local sub="${1:-}"
  if [ $# -gt 0 ]; then shift; fi
  case "$sub" in
    "") [ $# -eq 0 ] || die "usage: task auto [on [DURATION] | off]"; auto_status ;;
    on) [ $# -le 1 ] || die "usage: task auto [on [DURATION] | off]"; auto_on "$@" ;;
    off) [ $# -eq 0 ] || die "usage: task auto [on [DURATION] | off]"; auto_off ;;
    *) die "usage: task auto [on [DURATION] | off]" ;;
  esac
}
