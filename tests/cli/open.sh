# shellcheck shell=bash
# Stage 2, task 3: notifications and opening sessions. Uses the at_* helpers from signal.sh.

# Ends background alerters left by a test (they block on the stub's answer).
at_reap_alerters() {
  local p pid
  for p in "$AGENT_TASKS_HOME"/.notify/*.alerter-pid; do
    [ -f "$p" ] || continue
    pid="$(cat "$p")"
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done
}

test_open_notify_on_question_runs_alerter_detached() {
  at_stubs
  at_task 02_exploring T-0001 "Ask" session ses_a1 project crm
  echo '@CLOSED' > "$TMP/alerter.answer"
  "$TASK" signal 1 question --session ses_a1 --text $'Which DB?\nA / B' >/dev/null
  at_wait_for "$TMP/alerter.log" "--group T-0001"
  local line
  line="$(cat "$TMP/alerter.log")"
  assert_contains "$line" "--title=T-0001 · 03_brainstorming --subtitle=crm --message=Which DB?"$'\n'"A / B --actions"
  assert_contains "$line" "--actions Open --group T-0001 --timeout 86400 --sound default"
  assert_file "$AGENT_TASKS_HOME/.notify/T-0001.alerter-pid"
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
  at_reap_alerters
}

test_open_notify_follows_the_table() {
  at_stubs
  # 07_approved question, finishing, input/answered never notify.
  at_task 07_approved T-0001 "Quiet" session ses_a1
  "$TASK" signal 1 question --session ses_a1 --text q >/dev/null
  at_task 04_spec_review T-0002 "Finish" session ses_b1
  "$TASK" signal 2 finishing --session ses_b1 >/dev/null
  at_task 08_implementing T-0003 "Fail" session ses_c1
  "$TASK" signal 3 error --session ses_c1 --text "boom" >/dev/null
  at_wait_for "$TMP/alerter.log" "--group T-0003"
  sleep 0.3
  assert_not_contains "$(cat "$TMP/alerter.log")" "--group T-0001"
  assert_not_contains "$(cat "$TMP/alerter.log")" "--group T-0002"
  assert_contains "$(cat "$TMP/alerter.log")" "--title=T-0003 · blocked --subtitle=no project --message=boom"
  at_reap_alerters
}

test_open_notify_spec_review_body() {
  at_stubs
  at_task 03_brainstorming T-0001 "Spec" session ses_a1 spec docs/superpowers/specs/a-design.md
  "$TASK" signal 1 turn-end --session ses_a1 >/dev/null
  at_wait_for "$TMP/alerter.log" "--message=Spec ready for review: docs/superpowers/specs/a-design.md"
  at_reap_alerters
}

test_open_notify_quiet_after_user_activity() {
  at_stubs
  at_task 02_exploring T-0001 "Ask" session ses_a1
  "$TASK" signal 1 input --session ses_a1 --text "hello" >/dev/null
  "$TASK" signal 1 question --session ses_a1 --text "Q?" >/dev/null
  sleep 0.3
  assert_eq "$(grep -c -- '--group' "$TMP/alerter.log" 2>/dev/null || true)" 0
  # Older than quiet_minutes: alerts again.
  printf '%s\n' "$(($(date +%s) - 181))" > "$AGENT_TASKS_HOME/.notify/T-0001.last-user"
  "$TASK" signal 1 question --session ses_a1 --text "Q2?" >/dev/null
  at_wait_for "$TMP/alerter.log" "--message=Q2?"
  at_reap_alerters
}

test_open_notify_replaces_previous_alerter() {
  at_stubs
  # This alerter waits until killed, like a real one.
  cat > "$TMP/bin/alerter" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$AT_TMP/alerter.log"
case "$1" in --remove) exit 0 ;; esac
exec sleep 30
EOF
  at_task 03_brainstorming T-0001 "Ask" session ses_a1
  "$TASK" signal 1 question --session ses_a1 --text one >/dev/null
  at_wait_for "$TMP/alerter.log" "--message=one"
  local first
  first="$(cat "$AGENT_TASKS_HOME/.notify/T-0001.alerter-pid")"
  kill -0 "$first" 2>/dev/null || fail "first alerter is not running"
  "$TASK" signal 1 question --session ses_a1 --text two >/dev/null
  at_wait_for "$TMP/alerter.log" "--message=two"
  sleep 0.2
  if kill -0 "$first" 2>/dev/null; then fail "first alerter still runs"; fi
  [ "$(cat "$AGENT_TASKS_HOME/.notify/T-0001.alerter-pid")" != "$first" ] || fail "pid file not replaced"
  # answered clears the alert: --remove and the process is gone.
  local second
  second="$(cat "$AGENT_TASKS_HOME/.notify/T-0001.alerter-pid")"
  "$TASK" signal 1 answered --session ses_a1 >/dev/null
  assert_contains "$(cat "$TMP/alerter.log")" "--remove T-0001"
  sleep 0.2
  if kill -0 "$second" 2>/dev/null; then fail "alerter survived notify_clear"; fi
  assert_no_file "$AGENT_TASKS_HOME/.notify/T-0001.alerter-pid"
}

test_open_notify_open_button_runs_task_open() {
  at_stubs
  echo 'Open' > "$TMP/alerter.answer"
  at_task 02_exploring T-0001 "Click" session ses_a1
  "$TASK" signal 1 question --session ses_a1 --text "Q" >/dev/null
  at_wait_for "$TMP/osascript.log" "CMD=opencode --session ses_a1"
  at_wait_for "$AGENT_TASKS_HOME/.notify/T-0001.tab" "4242"
}

test_open_notify_without_alerter_warns() {
  at_stubs
  rm "$TMP/bin/alerter"
  at_task 02_exploring T-0001 "Ask" session ses_a1
  local err
  # Only system dirs besides the stubs: hides a real alerter in /opt/homebrew/bin.
  err="$(PATH="$TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$TASK" signal 1 question --session ses_a1 --text Q 2>&1 >/dev/null)"
  assert_contains "$err" "task: alerter not found; notification skipped"
  assert_eq "$(at_folder T-0001)" 03_brainstorming
}

test_open_new_tab() {
  at_stubs
  at_task 04_spec_review T-0083 "Fix port drift" session ses_a1
  local out
  out="$("$TASK" open 83)"
  assert_eq "$out" "opened T-0083 in a new tab"
  assert_eq "$(cat "$TMP/osascript.log")" "TAG=T-0083 Fix port drift|DIR=$TMP/proj|CMD=opencode --session ses_a1|MARK="
  assert_eq "$(cat "$AGENT_TASKS_HOME/.notify/T-0083.tab")" "4242"
  assert_contains "$(cat "$TMP/opencode.log")" "api get /api/session/ses_a1"
  assert_contains "$(cat "$TMP/alerter.log")" "--remove T-0083"
  assert_contains "$(cat "$TMP/osascript.script")" "new surface configuration"
  assert_contains "$(cat "$TMP/osascript.script")" 'set_tab_title:'
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
}

test_open_focuses_marked_tab() {
  at_stubs
  at_task 04_spec_review T-0083 "Fix" session ses_a1
  "$TASK" open 83 >/dev/null
  echo focused > "$TMP/osascript.answer"
  assert_eq "$("$TASK" open T-0083)" "focused T-0083"
  assert_contains "$(tail -n 1 "$TMP/osascript.log")" "MARK=4242"
  assert_eq "$(cat "$AGENT_TASKS_HOME/.notify/T-0083.tab")" "4242"
}

test_open_errors() {
  at_stubs
  at_task 03_brainstorming T-0083 "No session"
  local out rc=0
  out="$("$TASK" open 83 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" "task: T-0083 has no session; start it with 'task mv 83 ready' or bind one"
  rm -rf "$AGENT_TASKS_HOME"
  at_task 03_brainstorming T-0083 "Gone" session ses_gone
  : > "$TMP/oc-fail-session"
  rc=0; out="$("$TASK" open 83 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "session ses_gone not found"
  rm "$TMP/oc-fail-session"
  : > "$TMP/oc-fail-osascript"
  rc=0; out="$("$TASK" open 83 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "could not open a Ghostty tab"
  assert_no_file "$AGENT_TASKS_HOME/.notify/T-0083.tab"
  rc=0; out="$("$TASK" open 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: task open <id>"
}

test_open_next_picks_oldest_waiting() {
  at_stubs
  assert_eq "$("$TASK" next)" "nothing is waiting for you"
  at_task 09_finishing T-0001 "Old" session ses_a1
  sleep 1
  at_task blocked T-0002 "New" session ses_b1
  at_task 08_implementing T-0003 "Busy" session ses_c1
  at_task 04_spec_review T-0004 "Unbound"
  at_task 05_planning T-0005 "Planning" session ses_e1
  assert_eq "$("$TASK" next)" "opened T-0001 in a new tab"
  assert_contains "$(cat "$TMP/osascript.log")" "CMD=opencode --session ses_a1"
  sleep 1
  touch "$(task_path_of T-0001)"
  "$TASK" next >/dev/null
  assert_contains "$(tail -n 1 "$TMP/osascript.log")" "CMD=opencode --session ses_b1"
}

test_open_refuses_invalid_session_field() {
  at_stubs
  at_task 04_spec_review T-0083 "Injected" session '"ses_x; echo pwned"'
  local out rc=0
  out="$("$TASK" open 83 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" "task: T-0083 has an invalid session field"
  assert_no_file "$TMP/osascript.log"
  assert_eq "$(cat "$TMP/opencode.log")" ""
}

test_open_notify_errors_ignore_quiet_rule() {
  at_stubs
  at_task 08_implementing T-0001 "Err" session ses_a1
  at_task 02_exploring T-0002 "Stall" session ses_b1
  at_task 04_spec_review T-0003 "Perm" session ses_c1
  mkdir -p "$AGENT_TASKS_HOME/.notify"
  local i
  for i in 1 2 3; do date +%s > "$AGENT_TASKS_HOME/.notify/T-000$i.last-user"; done
  "$TASK" signal 1 error --session ses_a1 --text "crashed" >/dev/null
  "$TASK" signal 2 stalled --session ses_b1 --text "no activity" >/dev/null
  "$TASK" signal 3 permission --session ses_c1 --text "bash: rm" >/dev/null
  at_wait_for "$TMP/alerter.log" "--group T-0001"
  at_wait_for "$TMP/alerter.log" "--group T-0002"
  sleep 0.3
  assert_not_contains "$(cat "$TMP/alerter.log")" "--group T-0003"
  at_reap_alerters
}

test_open_notify_body_starting_with_dash() {
  at_stubs
  at_task 02_exploring T-0001 "Dash" session ses_a1
  "$TASK" signal 1 question --session ses_a1 --text "--timeout 1 is that ok?" >/dev/null
  at_wait_for "$TMP/alerter.log" "--message=--timeout 1 is that ok? --actions Open"
  at_reap_alerters
}

test_open_notify_kill_spares_own_ancestor() {
  at_stubs
  load_lib core
  load_lib open
  mkdir -p "$AGENT_TASKS_HOME/.notify"
  printf '%s\n' "$$" > "$AGENT_TASKS_HOME/.notify/T-0001.alerter-pid"
  ( notify_kill T-0001 )
  assert_no_file "$AGENT_TASKS_HOME/.notify/T-0001.alerter-pid"
  is_own_ancestor "$$" || fail "\$\$ must be its own ancestor"
  sleep 30 &
  local child=$!
  if is_own_ancestor "$child"; then fail "a child is not an ancestor"; fi
  printf '%s\n' "$child" > "$AGENT_TASKS_HOME/.notify/T-0001.alerter-pid"
  notify_kill T-0001
  sleep 0.2
  if kill -0 "$child" 2>/dev/null; then fail "notify_kill spared a foreign alerter"; fi
}
