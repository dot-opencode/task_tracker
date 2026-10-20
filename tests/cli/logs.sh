# shellcheck shell=bash
# task logs: worker log and per-task `## Log`.

logs_write_worker_log() {   # logs_write_worker_log <lines>
  local i
  mkdir -p "$HOME/Library/Logs"
  : > "$HOME/Library/Logs/agent-tasks.log"
  for i in $(seq 1 "$1"); do echo "worker line $i" >> "$HOME/Library/Logs/agent-tasks.log"; done
}

# Waits (max ~10 s) until <file> contains the fixed string.
logs_wait_for() {   # logs_wait_for <file> <text>
  local i
  for i in $(seq 1 100); do
    if grep -qF -- "$2" "$1"; then return 0; fi
    sleep 0.1
  done
  fail "timed out waiting for '$2' in $1: $(cat "$1")"
}

test_logs_worker_missing_prints_message() {
  local out
  out="$("$TASK" logs)"
  assert_eq "$out" "no worker log yet ($HOME/Library/Logs/agent-tasks.log): automation has not run"
  out="$("$TASK" logs -f)"
  assert_contains "$out" "no worker log yet"
}

test_logs_worker_default_and_n() {
  local out
  logs_write_worker_log 60
  out="$("$TASK" logs)"
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 50
  assert_eq "$(printf '%s\n' "$out" | head -n 1)" "worker line 11"
  assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "worker line 60"
  out="$("$TASK" logs -n 3)"
  assert_eq "$out" "worker line 58
worker line 59
worker line 60"
}

test_logs_worker_follow_execs_tail_f() {
  logs_write_worker_log 5
  printf '#!/bin/sh\necho "tail $*"\n' > "$TMP/bin/tail"
  chmod +x "$TMP/bin/tail"
  assert_eq "$("$TASK" logs -f)" "tail -n 50 -F $HOME/Library/Logs/agent-tasks.log"
  assert_eq "$("$TASK" logs -f -n 7)" "tail -n 7 -F $HOME/Library/Logs/agent-tasks.log"
}

test_logs_task_header_and_log_lines_only() {
  write_task_file 00_backlog T-0088 "Fix the thing"
  local f out
  f="$(task_path_of T-0088)"
  printf -- '- 2026-10-01 09:05 me: first\n  continued here\n- 2026-10-01 09:10 me: second\n' >> "$f"
  out="$("$TASK" logs 88)"
  assert_eq "$out" "T-0088 · 00_backlog · Fix the thing
- 2026-10-01 09:00 task: created in 00_backlog
- 2026-10-01 09:05 me: first
  continued here
- 2026-10-01 09:10 me: second"
  assert_not_contains "$out" "Body of"
  assert_not_contains "$out" "created: 2026"
}

test_logs_task_n_limits_lines() {
  write_task_file 01_ready T-0001 "Limit"
  local f out
  f="$(task_path_of T-0001)"
  printf -- '- 2026-10-01 09:05 me: first\n- 2026-10-01 09:10 me: second\n' >> "$f"
  out="$("$TASK" logs T-0001 -n 2)"
  assert_eq "$out" "T-0001 · 01_ready · Limit
- 2026-10-01 09:05 me: first
- 2026-10-01 09:10 me: second"
  out="$("$TASK" logs 1 -n 0)"
  assert_eq "$out" "T-0001 · 01_ready · Limit"
}

test_logs_task_default_is_last_20() {
  write_task_file 01_ready T-0001 "Many"
  local f out i
  f="$(task_path_of T-0001)"
  for i in $(seq 1 30); do printf -- '- 2026-10-01 10:00 me: entry %s\n' "$i" >> "$f"; done
  out="$("$TASK" logs 1)"
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 21
  assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "- 2026-10-01 10:00 me: entry 30"
  assert_eq "$(printf '%s\n' "$out" | sed -n 2p)" "- 2026-10-01 10:00 me: entry 11"
}

test_logs_task_without_log_section_prints_header_only() {
  write_task_file 01_ready T-0001 "No log"
  local f
  f="$(task_path_of T-0001)"
  printf -- '---\nid: T-0001\ntitle: "No log"\ncreated: 2026-10-01\n---\n\nJust a body.\n' > "$f"
  assert_eq "$("$TASK" logs 1)" "T-0001 · 01_ready · No log"
}

test_logs_task_follow_sees_new_entry_and_move() {
  write_task_file 00_backlog T-0001 "Follow me"
  local out="$TMP/follow.out" pid
  # Deterministic: the follower polls every 0.1 s (up to 600 polls) and is
  # started first; we wait for its header, then change the task, wait until
  # the output shows the move, and stop it. No fixed sleeps.
  AGENT_TASKS_LOGS_INTERVAL=0.1 AGENT_TASKS_LOGS_POLLS=600 "$TASK" logs T-0001 -f > "$out" &
  pid=$!
  logs_wait_for "$out" "T-0001 · 00_backlog · Follow me"
  "$TASK" log 1 "brand new entry" --author tester > /dev/null
  "$TASK" mv 1 ready > /dev/null
  logs_wait_for "$out" "-- moved to 01_ready"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  local text n
  text="$(cat "$out")"
  assert_contains "$text" "tester: brand new entry"
  n="$(grep -cF "tester: brand new entry" "$out")"
  assert_eq "$n" 1
  n="$(grep -cF -- "-- moved to 01_ready" "$out")"
  assert_eq "$n" 1
  assert_eq "$(grep -cF "created in 00_backlog" "$out")" 1
}

test_logs_task_follow_exits_when_task_disappears() {
  write_task_file 00_backlog T-0001 "Gone"
  local out="$TMP/follow.out" pid rc=0
  AGENT_TASKS_LOGS_INTERVAL=0.1 AGENT_TASKS_LOGS_POLLS=600 "$TASK" logs 1 -f > "$out" &
  pid=$!
  logs_wait_for "$out" "T-0001 · 00_backlog · Gone"
  rm -f "$(task_path_of T-0001)"
  wait "$pid" || rc=$?
  assert_eq "$rc" 0
  assert_contains "$(cat "$out")" "-- task no longer exists"
}

test_logs_task_follow_stops_after_polls() {
  write_task_file 00_backlog T-0001 "Polls"
  local out rc=0
  out="$(AGENT_TASKS_LOGS_INTERVAL=0 AGENT_TASKS_LOGS_POLLS=2 "$TASK" logs 1 -f)" || rc=$?
  assert_eq "$rc" 0
  assert_eq "$out" "T-0001 · 00_backlog · Polls
- 2026-10-01 09:00 task: created in 00_backlog"
}

test_logs_rejects_bad_args() {
  write_task_file 00_backlog T-0001 "Args"
  local out rc=0
  out="$("$TASK" logs -n x 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" "task: invalid -n 'x'"
  rc=0; out="$("$TASK" logs 1 -n -3 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid -n '-3'"
  rc=0; out="$("$TASK" logs 1 2 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" "task: usage: task logs [<id>] [-n N] [-f]"
  rc=0; out="$("$TASK" logs --bogus 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" "task: usage: task logs [<id>] [-n N] [-f]"
  rc=0; out="$("$TASK" logs 7 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "no task T-0007"
}

# The plist path itself is asserted by the auto tests (unchanged).
test_logs_helper_path_and_usage_text() {
  # worker_log_path() is asserted by the Rust unit test and via `task logs` above.
  logs_write_worker_log 1
  assert_eq "$("$TASK" logs)" "worker line 1"
  assert_contains "$("$TASK" --help)" "task logs [<id>] [-n N] [-f]"
}
