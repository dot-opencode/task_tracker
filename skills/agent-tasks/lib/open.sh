# shellcheck shell=bash
# Notifications (alerter) and opening a task's session in Ghostty.

# 0 when $1 is $$ or one of its ancestors. `task open` started by the Open
# button runs inside the alerter's subshell, whose pid is in the pid file.
is_own_ancestor() {
  local p="$$" n=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$n" -lt 64 ]; do
    if [ "$p" = "$1" ]; then return 0; fi
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    n=$((n + 1))
  done
  return 1
}

# Kills $1 and its descendants (the alerter runs inside a detached subshell).
# On macOS `pgrep -P` lists only direct children and never the calling
# process or its ancestors, so the walk itself cannot reach this shell;
# notify_kill additionally refuses a pid that is one of our ancestors.
kill_tree() {
  local pid="$1" kid
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  for kid in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$kid"; done
  kill "$pid" 2>/dev/null || true
}

# Ends the previous alerter of a task, if any. When we run inside that
# alerter's subshell (the Open button), the pid file is just removed: the
# alerter has already exited and killing the subshell would kill us.
notify_kill() {
  local pidf="$STORE/.notify/$1.alerter-pid" pid=""
  [ -f "$pidf" ] || return 0
  { IFS= read -r pid < "$pidf"; } 2>/dev/null || true
  rm -f "$pidf"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  if is_own_ancestor "$pid"; then return 0; fi
  kill_tree "$pid"
}

# 0 when the user acted in the task's session less than quiet_minutes ago.
notify_quiet() {
  local f="$STORE/.notify/$1.last-user" last="" q now
  [ -f "$f" ] || return 1
  { IFS= read -r last < "$f"; } 2>/dev/null || true
  case "$last" in ''|*[!0-9]*) last="$(stat -f %m "$f")" ;; esac
  q="$(config_get quiet_minutes 3)"
  case "$q" in ''|*[!0-9]*) q=3 ;; esac
  now="$(date +%s)"
  [ $((now - last)) -lt $((10#$q * 60)) ]
}

# notify_task <id> <title> <body> [<signal>]: one alert per task; Open runs
# `task open <id>`. The quiet rule covers the user's own conversation only:
# errors and stalled sessions always alert.
notify_task() {
  local id="$1" title="$2" body="$3" signal="${4:-}" project="" f pid
  case "$signal" in
    error|stalled) ;;
    *) if notify_quiet "$id"; then return 0; fi ;;
  esac
  if ! command -v alerter >/dev/null 2>&1; then
    warn "alerter not found; notification skipped"
    return 0
  fi
  f="$(task_file "$id" 2>/dev/null)" || f=""
  if [ -n "$f" ]; then project="$(fm_get "$f" project)"; fi
  [ -n "$project" ] || project="no project"
  mkdir -p "$STORE/.notify"
  notify_kill "$id"
  # Detached and with every stream closed: the caller (the plugin, launchd)
  # must not wait for the user to react.
  (
    # --opt=value: a body starting with '-' must not be read as an option.
    ans="$(alerter --title="$title" --subtitle="$project" --message="$body" \
      --actions Open --group "$id" --timeout 86400 --sound default 2>/dev/null)" || ans=""
    case "$ans" in
      Open|@CONTENTCLICKED|@ACTIONCLICKED) "$TASK_BIN" open "$id" ;;
    esac
  ) </dev/null >/dev/null 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  printf '%s\n' "$pid" > "$STORE/.notify/$id.alerter-pid"
}

notify_clear() {
  local id="$1"
  if command -v alerter >/dev/null 2>&1; then
    alerter --remove "$id" </dev/null >/dev/null 2>&1 || true
  fi
  notify_kill "$id"
}

cmd_open() {
  [ $# -eq 1 ] || die "usage: task open <id>"
  local tid f session title resp dir mark="" markf out short
  tid="$(normalize_id "$1")" || die "invalid task id '$1'"
  f="$(task_file "$tid")"
  session="$(fm_get "$f" session)"
  short="${tid#T-}"; short="$((10#$short))"
  [ -n "$session" ] || die "$tid has no session; start it with 'task mv $short ready' or bind one"
  # The value reaches a URL and a command typed into a terminal.
  valid_session "$session" || die "$tid has an invalid session field"
  title="$(fm_get "$f" title)"
  command -v opencode >/dev/null 2>&1 || die "opencode not found on PATH"
  resp="$(opencode api get "/api/session/$session" 2>/dev/null)" \
    || die "session $session not found (is OpenCode running?)"
  dir="$(jq -r '.data.location.directory // .data.directory // empty' <<< "$resp" 2>/dev/null)" || dir=""
  [ -n "$dir" ] || die "session $session not found (is OpenCode running?)"
  notify_clear "$tid"
  markf="$STORE/.notify/$tid.tab"
  if [ -f "$markf" ]; then { IFS= read -r mark < "$markf"; } 2>/dev/null || true; fi
  command -v osascript >/dev/null 2>&1 || die "osascript not found; open the session with: opencode --session $session"
  # Tab titles are overwritten by OpenCode, so a tab is recognised by its
  # working directory plus the terminal id remembered in the marker file.
  out="$(TASK_TAG="$tid $title" TASK_DIR="$dir" TASK_CMD="opencode --session $session" TASK_MARK="$mark" \
    osascript <<'APPLESCRIPT'
set tag to system attribute "TASK_TAG"
set dir to system attribute "TASK_DIR"
set cmd to system attribute "TASK_CMD"
set mark to system attribute "TASK_MARK"
tell application "Ghostty"
  activate
  if mark is not "" then
    repeat with w in windows
      repeat with t in tabs of w
        repeat with term in terminals of t
          if ((working directory of term) as text) is dir and ((id of term) as text) is mark then
            focus term
            return "focused"
          end if
        end repeat
      end repeat
    end repeat
  end if
  set cfg to new surface configuration
  set initial working directory of cfg to dir
  set initial input of cfg to cmd & linefeed
  if (count of windows) > 0 then
    set newTab to new tab in (item 1 of windows) with configuration cfg
  else
    set newWin to new window with configuration cfg
    set newTab to item 1 of tabs of newWin
  end if
  set term to item 1 of terminals of newTab
  perform action ("set_tab_title:" & tag) on term
  return "opened " & ((id of term) as text)
end tell
APPLESCRIPT
)" || die "could not open a Ghostty tab (osascript failed)"
  case "$out" in
    focused) echo "focused $tid" ;;
    "opened "*)
      mkdir -p "$STORE/.notify"
      printf '%s\n' "${out#opened }" > "$markf"
      echo "opened $tid in a new tab"
      ;;
    *) die "unexpected answer from osascript: $out" ;;
  esac
}

cmd_next() {
  [ $# -eq 0 ] || die "usage: task next"
  local f
  # shellcheck disable=SC2086 # folder list
  f="$(oldest_task_in --with-session $WAITING_FOLDERS)"
  if [ -z "$f" ]; then echo "nothing is waiting for you"; return 0; fi
  cmd_open "$(id_of_file "$f")"
}
