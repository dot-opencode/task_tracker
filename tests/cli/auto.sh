# shellcheck shell=bash
# Stage 2, task 4: the active period. launchctl is a stub; HOME is temporary,
# so the plist lands in $HOME/Library/LaunchAgents of the test.

AT_PLIST_REL="Library/LaunchAgents/agent-tasks.run.plist"

test_auto_on_without_duration() {
  at_stubs
  local out plist
  out="$("$TASK" auto on)"
  assert_eq "$out" "automation on (until 'task auto off')"
  assert_eq "$(sed -n 1p "$AGENT_TASKS_HOME/.auto")" "until=0"
  assert_contains "$(sed -n 2p "$AGENT_TASKS_HOME/.auto")" "since="
  plist="$HOME/$AT_PLIST_REL"
  assert_file "$plist"
  plutil -lint "$plist" >/dev/null || fail "plist is not valid"
  assert_eq "$(plutil -extract Label raw "$plist")" "agent-tasks.run"
  assert_eq "$(plutil -extract ProgramArguments.0 raw "$plist")" "$ROOT/skills/agent-tasks/bin/task"
  assert_eq "$(plutil -extract ProgramArguments.1 raw "$plist") $(plutil -extract ProgramArguments.2 raw "$plist")" "run --once"
  assert_eq "$(plutil -extract StartInterval raw "$plist")" 60
  assert_eq "$(plutil -extract RunAtLoad raw "$plist")" true
  assert_eq "$(plutil -extract ProcessType raw "$plist")" Background
  assert_eq "$(plutil -extract EnvironmentVariables.PATH raw "$plist")" \
    "$HOME/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  assert_eq "$(plutil -extract EnvironmentVariables.AGENT_TASKS_HOME raw "$plist")" "$AGENT_TASKS_HOME"
  assert_eq "$(plutil -extract StandardOutPath raw "$plist")" "$HOME/Library/Logs/agent-tasks.log"
  assert_eq "$(plutil -extract StandardErrorPath raw "$plist")" "$HOME/Library/Logs/agent-tasks.log"
  assert_eq "$(cat "$TMP/launchctl.log")" "print gui/$(id -u)/agent-tasks.run
bootstrap gui/$(id -u) $plist"
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
}

test_auto_on_with_durations() {
  at_stubs
  local d secs now until out
  for d in 30m:1800 2h:7200 1h30m:5400 90m:5400; do
    secs="${d#*:}"
    now="$(date +%s)"
    out="$("$TASK" auto on "${d%%:*}")"
    until="$(sed -n 's/^until=//p' "$AGENT_TASKS_HOME/.auto")"
    [ "$until" -ge $((now + secs)) ] && [ "$until" -le $((now + secs + 2)) ] \
      || fail "${d%%:*}: until=$until, now=$now"
    case "$out" in "automation on (until "[0-2][0-9]:[0-5][0-9]")"|"automation on (until "*-*" "*")") ;;
      *) fail "unexpected: $out" ;; esac
  done
}

test_auto_on_rejects_bad_duration() {
  at_stubs
  local d out rc
  for d in 0m 10 1d h 1m30h -5m 30M; do
    rc=0; out="$("$TASK" auto on "$d" 2>&1)" || rc=$?
    assert_eq "$rc" 1
    assert_contains "$out" "invalid duration '$d'"
  done
  assert_no_file "$AGENT_TASKS_HOME/.auto"
  assert_no_file "$HOME/$AT_PLIST_REL"
  assert_no_file "$TMP/launchctl.log"
  rc=0; out="$("$TASK" auto sideways 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: task auto [on [DURATION] | off]"
}

test_auto_on_again_kickstarts_loaded_job() {
  at_stubs
  "$TASK" auto on >/dev/null
  : > "$TMP/launchctl.log"
  assert_contains "$("$TASK" auto on 2h)" "automation on (until "
  assert_eq "$(cat "$TMP/launchctl.log")" "print gui/$(id -u)/agent-tasks.run
kickstart -k gui/$(id -u)/agent-tasks.run"
  assert_file "$HOME/$AT_PLIST_REL"
  assert_not_contains "$(cat "$AGENT_TASKS_HOME/.auto")" "until=0"
}

test_auto_on_retries_bootstrap() {
  at_stubs
  echo 3 > "$TMP/launchctl.bootstrap-fails"
  assert_eq "$("$TASK" auto on)" "automation on (until 'task auto off')"
  assert_eq "$(grep -c '^bootstrap ' "$TMP/launchctl.log")" 4
  assert_file "$TMP/launchctl.loaded"
}

test_auto_on_bootstrap_failure_leaves_nothing() {
  at_stubs
  echo 9 > "$TMP/launchctl.bootstrap-fails"
  local out rc=0
  out="$("$TASK" auto on 1h 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "launchctl could not load $HOME/$AT_PLIST_REL"
  assert_eq "$(grep -c '^bootstrap ' "$TMP/launchctl.log")" 5
  assert_no_file "$AGENT_TASKS_HOME/.auto"
  assert_no_file "$HOME/$AT_PLIST_REL"
}

test_auto_off() {
  at_stubs
  "$TASK" auto on >/dev/null
  : > "$TMP/launchctl.log"
  assert_eq "$("$TASK" auto off)" "automation off"
  assert_eq "$(cat "$TMP/launchctl.log")" "bootout gui/$(id -u)/agent-tasks.run"
  assert_no_file "$AGENT_TASKS_HOME/.auto"
  assert_no_file "$HOME/$AT_PLIST_REL"
  assert_eq "$("$TASK" auto off)" "automation off"
}

test_auto_status() {
  at_stubs
  at_task 02_exploring T-0001 "A"
  at_task 07_approved T-0002 "B"
  at_task 01_ready T-0003 "C"
  at_task 01_ready T-0004 "D"
  assert_eq "$("$TASK" auto)" "automation: off
active agents: 1/2
model: OpenCode default
queue: 1 approved, 2 ready"
  at_task 05_planning T-0005 "E"
  assert_eq "$("$TASK" auto | sed -n 2p)" "active agents: 2/2"
  "$TASK" auto on >/dev/null
  assert_eq "$("$TASK" auto | head -n 1)" "automation: on (until 'task auto off')"
  printf 'until=%s\nsince=1\n' "$(($(date +%s) + 6120))" > "$AGENT_TASKS_HOME/.auto"
  assert_eq "$("$TASK" auto | head -n 1)" "automation: on, 1h42m left"
  printf 'until=%s\nsince=1\n' "$(($(date +%s) + 300))" > "$AGENT_TASKS_HOME/.auto"
  assert_eq "$("$TASK" auto | head -n 1)" "automation: on, 5m left"
  printf 'until=%s\nsince=1\n' "$(($(date +%s) - 1))" > "$AGENT_TASKS_HOME/.auto"
  assert_eq "$("$TASK" auto | head -n 1)" "automation: off (expired)"
}

test_auto_helpers() {
  "$TASK" ls >/dev/null
  assert_eq "$("$TASK" auto | head -n 1)" "automation: off"
  printf 'until=0\nsince=1\n' > "$AGENT_TASKS_HOME/.auto"
  assert_eq "$("$TASK" auto | head -n 1)" "automation: on (until 'task auto off')"
  printf 'until=%s\nsince=1\n' "$(($(date +%s) + 100))" > "$AGENT_TASKS_HOME/.auto"
  assert_eq "$("$TASK" auto | head -n 1)" "automation: on, 2m left"
  printf 'until=%s\nsince=1\n' "$(($(date +%s) - 1))" > "$AGENT_TASKS_HOME/.auto"
  assert_eq "$("$TASK" auto | head -n 1)" "automation: off (expired)"
  # parse_duration / fmt_duration: 1h30m is 5400 s, shown back as 1h30m
  at_stubs
  "$TASK" auto on 1h30m >/dev/null
  local until
  until="$(sed -n 's/^until=//p' "$AGENT_TASKS_HOME/.auto")"
  [ "$((until - $(date +%s)))" -le 5400 ] && [ "$((until - $(date +%s)))" -ge 5398 ] || fail "until $until"
  assert_eq "$("$TASK" auto | head -n 1)" "automation: on, 1h30m left"
}

# task approve while automation is on (lib/approve.sh asks lib/auto.sh).
# Spec approval never waits for the active period; plan approval does.
test_auto_approve_spec_always_starts_planning() {
  at_stubs
  at_task 03_brainstorming T-0001 "Spec"
  at_task 02_exploring T-0002 "Busy"
  at_task 08_implementing T-0003 "Busy too"
  "$TASK" auto on >/dev/null
  assert_eq "$("$TASK" approve 1)" "start"
  assert_eq "$(at_folder T-0001)" 05_planning
}

test_auto_approve_plan_with_free_slot_defers() {
  at_stubs
  at_task 06_plan_review T-0001 "Plan"
  at_task 02_exploring T-0002 "Busy"
  "$TASK" auto on >/dev/null
  assert_eq "$("$TASK" approve 1)" "deferred"
  assert_eq "$(at_folder T-0001)" 07_approved
}

test_auto_approve_plan_now_starts_even_without_slot() {
  at_stubs
  at_task 06_plan_review T-0001 "Plan"
  at_task 02_exploring T-0002 "Busy"
  at_task 05_planning T-0003 "Busy too"
  "$TASK" auto on 2h >/dev/null
  assert_eq "$("$TASK" approve 1 --now)" "start"
  assert_eq "$(at_folder T-0001)" 08_implementing
}

test_auto_approve_plan_after_expiry_defers() {
  at_stubs
  at_task 06_plan_review T-0001 "Plan"
  "$TASK" auto on 30m >/dev/null
  printf 'until=%s\nsince=1\n' "$(($(date +%s) - 10))" > "$AGENT_TASKS_HOME/.auto"
  assert_eq "$("$TASK" approve 1)" "deferred"
}
