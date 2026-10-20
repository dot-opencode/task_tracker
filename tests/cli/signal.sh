# shellcheck shell=bash
# Stage 2, task 1: session signals and the transition table.
# The helpers here (at_*) are shared by the later stage-2 test files.

# Stubs for every external tool stage 2 calls; nothing real is reached.
# opencode: logs "$*" to $TMP/opencode.log and the --data payload to
# $TMP/opencode.data; answers from $TMP/active.json, $TMP/children.json,
# $TMP/session.json when present; $TMP/oc-fail-<name> makes a call fail.
at_stubs() {
  cat > "$TMP/bin/opencode" <<'EOF'
#!/bin/sh
T="${AT_TMP:?}"
printf '%s\n' "$*" >> "$T/opencode.log"
if [ "${3:-}" != "" ] && [ "${4:-}" = "--data" ]; then printf '%s\n' "$5" >> "$T/opencode.data"; fi
case "$1 $2 $3" in
  "api get /api/session/active")
    [ ! -e "$T/oc-fail-active" ] || exit 1
    if [ -f "$T/active.json" ]; then cat "$T/active.json"; else echo '{"data":{}}'; fi ;;
  "api get /api/session?parentID="*)
    [ ! -e "$T/oc-fail-children" ] || exit 1
    if [ -f "$T/children.json" ]; then cat "$T/children.json"; else echo '{"data":[]}'; fi ;;
  "api get /api/session/"*)
    [ ! -e "$T/oc-fail-session" ] || exit 1
    if [ -f "$T/session.json" ]; then cat "$T/session.json"
    else printf '{"data":{"id":"%s","location":{"directory":"%s"}}}\n' "${3#/api/session/}" "$T/proj"; fi ;;
  "api post /api/session")
    [ ! -e "$T/oc-fail-create" ] || exit 1
    echo '{"data":{"id":"ses_test1","title":"x"}}' ;;
  "api post /api/session/"*)
    [ ! -e "$T/oc-fail-prompt" ] || exit 1
    echo '{"data":{}}' ;;
  "api patch "*) echo '{}' ;;
  *) exit 2 ;;
esac
EOF
  # alerter: logs its arguments, then prints $TMP/alerter.answer (empty = closed).
  cat > "$TMP/bin/alerter" <<'EOF'
#!/bin/sh
T="${AT_TMP:?}"
printf '%s\n' "$*" >> "$T/alerter.log"
case "$1" in --remove) exit 0 ;; esac
if [ -f "$T/alerter.answer" ]; then cat "$T/alerter.answer"; else echo "@TIMEOUT"; fi
EOF
  # osascript: logs the env it was given, prints $TMP/osascript.answer.
  cat > "$TMP/bin/osascript" <<'EOF'
#!/bin/sh
T="${AT_TMP:?}"
cat > "$T/osascript.script"
printf 'TAG=%s|DIR=%s|CMD=%s|MARK=%s\n' "$TASK_TAG" "$TASK_DIR" "$TASK_CMD" "$TASK_MARK" >> "$T/osascript.log"
[ ! -e "$T/oc-fail-osascript" ] || exit 1
if [ -f "$T/osascript.answer" ]; then cat "$T/osascript.answer"; else echo "opened 4242"; fi
EOF
  # launchctl: logs its arguments. `print` succeeds while $TMP/launchctl.loaded
  # exists (bootstrap creates it, bootout removes it; a test may create it).
  # $TMP/oc-fail-launchctl fails every call; $TMP/launchctl.bootstrap-fails
  # holds how many bootstraps fail before one succeeds.
  cat > "$TMP/bin/launchctl" <<'EOF'
#!/bin/sh
T="${AT_TMP:?}"
printf '%s\n' "$*" >> "$T/launchctl.log"
[ ! -e "$T/oc-fail-launchctl" ] || exit 1
case "$1" in
  print) [ -e "$T/launchctl.loaded" ] || exit 113 ;;
  bootout) [ -e "$T/launchctl.loaded" ] || exit 3; rm -f "$T/launchctl.loaded" ;;
  bootstrap)
    n="$(cat "$T/launchctl.bootstrap-fails" 2>/dev/null || echo 0)"
    if [ "$n" -gt 0 ]; then echo "$((n - 1))" > "$T/launchctl.bootstrap-fails"; exit 5; fi
    : > "$T/launchctl.loaded" ;;
esac
exit 0
EOF
  chmod +x "$TMP/bin/opencode" "$TMP/bin/alerter" "$TMP/bin/osascript" "$TMP/bin/launchctl"
  export AT_TMP="$TMP"
  mkdir -p "$TMP/proj"
  : > "$TMP/opencode.log"
}

# at_task <folder> <id> <title> [key value]... — a task file with extra
# frontmatter, committed; the store is created first.
at_task() {
  local folder="$1" id="$2" title="$3" f
  shift 3
  if [ ! -d "$AGENT_TASKS_HOME/.git" ]; then "$TASK" ls >/dev/null; fi
  write_task_file "$folder" "$id" "$title"
  f="$(task_path_of "$id")"
  while [ $# -ge 2 ]; do
    AT_LINE="$1: $2" awk 'NR > 1 && $0 == "---" && !d { print ENVIRON["AT_LINE"]; d = 1 } { print }' "$f" > "$f.tmp"
    mv "$f.tmp" "$f"
    shift 2
  done
  git -C "$AGENT_TASKS_HOME" add -A
  git -C "$AGENT_TASKS_HOME" commit -q -m "test: $id in $folder"
}

at_folder() { basename "$(dirname "$(task_path_of "$1")")"; }
at_commits() { git -C "$AGENT_TASKS_HOME" rev-list --count HEAD; }

# Waits up to 5 s for a file to contain a string (background alerters).
at_wait_for() {   # at_wait_for <file> <text>
  local i=0
  while [ "$i" -lt 50 ]; do
    if [ -f "$1" ] && grep -qF -- "$2" "$1"; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  fail "no '$2' in ${1#"$TMP"/} after 5 s"
}

# at_expect <folder> <signal> <expected folder> [key value]... — one fresh task.
at_expect() {
  local from="$1" sig="$2" want="$3"
  shift 3
  rm -rf "$AGENT_TASKS_HOME"
  at_task "$from" T-0001 "Case" session ses_a1 "$@"
  "$TASK" signal 1 "$sig" --session ses_a1 --text "why" >/dev/null 2>&1 || fail "signal $sig in $from failed"
  [ "$(at_folder T-0001)" = "$want" ] || fail "$sig in $from: expected $want, got $(at_folder T-0001)"
}

test_signal_question_from_exploring_moves_to_brainstorming() {
  at_stubs
  at_task 02_exploring T-0001 "Explore" session ses_a1
  local out f
  out="$("$TASK" signal 1 question --session ses_a1 --text $'Which DB?\nPostgres / SQLite')"
  assert_eq "$out" "T-0001: 02_exploring → 03_brainstorming"
  f="$(task_path_of T-0001)"
  assert_contains "$f" "/work/03_brainstorming/"
  assert_contains "$(tail -n 1 "$f")" "task: 02_exploring → 03_brainstorming — question — Which DB?"
  assert_eq "$(last_subject)" "tasks(work): T-0001 02_exploring → 03_brainstorming"
}

test_signal_question_log_only_folders() {
  at_stubs
  local fo out before
  for fo in 03_brainstorming 04_spec_review 06_plan_review 07_approved 09_finishing blocked; do
    rm -rf "$AGENT_TASKS_HOME"
    at_task "$fo" T-0001 "Asking" session ses_a1
    before="$(at_commits)"
    out="$("$TASK" signal 1 question --session ses_a1 --text "Pick one")"
    assert_eq "$out" "T-0001: question noted"
    assert_eq "$(at_folder T-0001)" "$fo"
    assert_contains "$(tail -n 1 "$(task_path_of T-0001)")" "task: question: Pick one"
    assert_eq "$(at_commits)" "$((before + 1))"
    assert_eq "$(last_subject)" "tasks(work): T-0001 log"
  done
}

test_signal_question_while_planning_or_implementing_blocks() {
  at_stubs
  at_task 08_implementing T-0001 "Build" session ses_a1
  assert_eq "$("$TASK" signal 1 question --session ses_a1 --text "Merge?")" "T-0001: 08_implementing → blocked"
  assert_contains "$(cat "$(task_path_of T-0001)")" "blocked_from: 08_implementing"
  at_expect 05_planning question blocked
  assert_contains "$(cat "$(task_path_of T-0001)")" "blocked_from: 05_planning"
}

test_signal_question_in_planning_with_plan_goes_to_review() {
  at_stubs
  at_expect 05_planning question 06_plan_review plan docs/superpowers/plans/x.md
  at_expect 06_plan_review question 06_plan_review plan docs/superpowers/plans/x.md
}

test_signal_turn_end_table() {
  at_stubs
  at_expect 02_exploring turn-end 04_spec_review spec docs/superpowers/specs/x-design.md
  at_expect 02_exploring turn-end 03_brainstorming
  at_expect 03_brainstorming turn-end 04_spec_review spec docs/superpowers/specs/x-design.md
  at_expect 03_brainstorming turn-end 03_brainstorming
  at_expect 04_spec_review turn-end 04_spec_review
  at_expect 05_planning turn-end 06_plan_review plan docs/superpowers/plans/x.md
  at_expect 05_planning turn-end blocked
  at_expect 06_plan_review turn-end 06_plan_review
  at_expect 09_finishing turn-end 09_finishing
  at_expect blocked turn-end blocked
  at_expect 08_implementing turn-end blocked
}

test_signal_turn_end_in_planning_notifies_plan_ready() {
  at_stubs
  at_task 05_planning T-0001 "Plan it" session ses_a1 plan docs/superpowers/plans/x.md
  "$TASK" signal 1 turn-end --session ses_a1 --text "" >/dev/null
  at_wait_for "$TMP/alerter.log" "Plan ready for review: docs/superpowers/plans/x.md"
  assert_eq "$(at_folder T-0001)" 06_plan_review
  at_reap_alerters
}

test_signal_turn_end_log_only_and_nothing_in_approved() {
  at_stubs
  at_task 04_spec_review T-0001 "Review" session ses_a1
  assert_eq "$("$TASK" signal 1 turn-end --session ses_a1 --text "")" "T-0001: turn-end noted"
  assert_contains "$(tail -n 1 "$(task_path_of T-0001)")" "task: turn-end"
  rm -rf "$AGENT_TASKS_HOME"
  at_task 07_approved T-0001 "Approved" session ses_a1
  local before
  before="$(cat "$(task_path_of T-0001)")"
  assert_eq "$("$TASK" signal 1 turn-end --session ses_a1)" "T-0001: turn-end ignored (07_approved)"
  assert_eq "$(cat "$(task_path_of T-0001)")" "$before"
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
}

test_signal_permission_error_stalled_block() {
  at_stubs
  local s fo
  for s in permission error stalled; do
    for fo in 02_exploring 03_brainstorming 04_spec_review 05_planning 06_plan_review 07_approved 08_implementing 09_finishing; do
      at_expect "$fo" "$s" blocked
    done
  done
  rm -rf "$AGENT_TASKS_HOME"
  at_task 04_spec_review T-0001 "Perm" session ses_a1
  "$TASK" signal 1 permission --session ses_a1 --text "bash: rm -rf build" >/dev/null
  assert_contains "$(tail -n 1 "$(task_path_of T-0001)")" "04_spec_review → blocked — permission — bash: rm -rf build"
  assert_contains "$(cat "$(task_path_of T-0001)")" "blocked_from: 04_spec_review"
}

test_signal_error_in_blocked_changes_nothing() {
  at_stubs
  at_task blocked T-0001 "Stuck" session ses_a1 blocked_from 08_implementing
  local before
  before="$(at_commits)"
  assert_eq "$("$TASK" signal 1 error --session ses_a1 --text boom)" "T-0001: error ignored (blocked)"
  assert_eq "$(at_commits)" "$before"
}

test_signal_input_and_answered_unblock() {
  at_stubs
  at_task blocked T-0001 "Stuck" session ses_a1 blocked_from 08_implementing
  assert_eq "$("$TASK" signal 1 answered --session ses_a1)" "T-0001: blocked → 08_implementing"
  assert_not_contains "$(cat "$(task_path_of T-0001)")" "blocked_from"
  assert_file "$AGENT_TASKS_HOME/.notify/T-0001.last-user"
  [ "$(cat "$AGENT_TASKS_HOME/.notify/T-0001.last-user")" -ge "$(($(date +%s) - 5))" ] || fail "stale last-user"
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
  rm -rf "$AGENT_TASKS_HOME"
  at_task blocked T-0001 "No origin" session ses_a1
  assert_eq "$("$TASK" signal 1 input --session ses_a1 --text "go on")" "T-0001: blocked → 03_brainstorming"
}

test_signal_input_elsewhere_only_records_activity() {
  at_stubs
  at_task 03_brainstorming T-0001 "Talk" session ses_a1
  local before
  before="$(at_commits)"
  assert_eq "$("$TASK" signal 1 input --session ses_a1 --text hi)" "T-0001: input ignored (03_brainstorming)"
  assert_eq "$(at_commits)" "$before"
  assert_file "$AGENT_TASKS_HOME/.notify/T-0001.last-user"
}

test_signal_finishing() {
  at_stubs
  local fo
  for fo in 02_exploring 03_brainstorming 04_spec_review 05_planning 06_plan_review 07_approved 08_implementing; do
    at_expect "$fo" finishing 09_finishing
  done
  at_expect blocked finishing blocked
}

test_signal_never_moves_backlog_ready_done() {
  at_stubs
  local fo s before
  for fo in 00_backlog 01_ready 11_done; do
    for s in question turn-end permission error stalled finishing answered input; do
      rm -rf "$AGENT_TASKS_HOME"
      at_task "$fo" T-0001 "Idle" session ses_a1 blocked_from 02_exploring
      before="$(cat "$(task_path_of T-0001)")"
      "$TASK" signal 1 "$s" --session ses_a1 --text x >/dev/null
      assert_eq "$(at_folder T-0001)" "$fo"
      assert_eq "$(cat "$(task_path_of T-0001)")" "$before"
    done
  done
  assert_eq "$(grep -c 'api get' "$TMP/opencode.log" || true)" 0
}

test_signal_from_other_session_is_ignored() {
  at_stubs
  at_task 02_exploring T-0001 "Bound" session ses_a1
  at_task 02_exploring T-0002 "Unbound"
  local out err rc=0 before
  before="$(at_commits)"
  err="$("$TASK" signal 1 question --session ses_old 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" 0
  assert_eq "$err" "T-0001: ignored question from ses_old (bound to ses_a1)"
  out="$("$TASK" signal 2 turn-end --session ses_old 2>&1)" || rc=$?
  assert_eq "$rc" 0
  assert_eq "$out" "T-0002: ignored turn-end from ses_old (bound to none)"
  assert_eq "$(at_folder T-0001)" 02_exploring
  assert_eq "$(at_commits)" "$before"
  assert_no_file "$AGENT_TASKS_HOME/.notify/T-0001.last-user"
}

test_signal_turn_end_ignored_while_children_run() {
  at_stubs
  at_task 02_exploring T-0001 "Orchestrated" session ses_a1
  echo '{"data":{"ses_kid1":{"type":"running"}}}' > "$TMP/active.json"
  echo '{"data":[{"id":"ses_kid1","parentID":"ses_a1"}]}' > "$TMP/children.json"
  local before
  before="$(at_commits)"
  assert_eq "$("$TASK" signal 1 turn-end --session ses_a1)" "T-0001: turn-end ignored (child sessions are running)"
  assert_eq "$(at_folder T-0001)" 02_exploring
  assert_eq "$(at_commits)" "$before"
  assert_contains "$(cat "$TMP/opencode.log")" "api get /api/session/active"
  assert_contains "$(cat "$TMP/opencode.log")" "api get /api/session?parentID=ses_a1"
  # A finished child (not in the active map) does not hold the turn.
  echo '{"data":{"ses_other":{"type":"running"}}}' > "$TMP/active.json"
  assert_eq "$("$TASK" signal 1 turn-end --session ses_a1)" "T-0001: 02_exploring → 03_brainstorming"
}

test_signal_turn_end_ignores_unrelated_sessions_in_child_list() {
  at_stubs
  at_task 08_implementing T-0001 "Filter" session ses_a1
  echo '{"data":{"ses_x":{"type":"running"}}}' > "$TMP/active.json"
  echo '{"data":[{"id":"ses_x","parentID":"ses_zz"}]}' > "$TMP/children.json"
  assert_eq "$("$TASK" signal 1 turn-end --session ses_a1)" "T-0001: 08_implementing → blocked"
}

test_signal_turn_end_proceeds_when_opencode_fails() {
  at_stubs
  at_task 02_exploring T-0001 "Offline" session ses_a1
  : > "$TMP/oc-fail-active"
  local out err
  err="$("$TASK" signal 1 turn-end --session ses_a1 2>&1 >/dev/null)"
  assert_contains "$err" "task: cannot list active sessions"
  assert_eq "$(at_folder T-0001)" 03_brainstorming
  rm -rf "$AGENT_TASKS_HOME" "$TMP/oc-fail-active"
  at_task 02_exploring T-0001 "Offline" session ses_a1
  : > "$TMP/oc-fail-children"
  out="$("$TASK" signal 1 turn-end --session ses_a1 2>/dev/null)"
  assert_eq "$out" "T-0001: 02_exploring → 03_brainstorming"
}

test_signal_rejects_bad_input() {
  at_stubs
  at_task 02_exploring T-0001 "Valid" session ses_a1
  local out rc=0
  out="$("$TASK" signal 1 shout --session ses_a1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown signal 'shout' (signals: question turn-end"
  rc=0; out="$("$TASK" signal 1 question 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: task signal <id> <signal> --session <session-id> [--text TEXT]"
  rc=0; out="$("$TASK" signal 1 question --session bogus 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid session id 'bogus'"
  rc=0; out="$("$TASK" signal 9 question --session ses_a1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "no task T-0009"
  rc=0; out="$("$TASK" signal x1 question --session ses_a1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid task id 'x1'"
  assert_eq "$(at_folder T-0001)" 02_exploring
}

test_signal_refuses_malformed_frontmatter() {
  at_stubs
  at_task 02_exploring T-0001 "Broken" session ses_a1
  local f out rc=0
  f="$(task_path_of T-0001)"
  printf -- '---\nid: T-0001\nsession: ses_a1\n\n## Log\n' > "$f"
  out="$("$TASK" signal 1 question --session ses_a1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "malformed frontmatter"
}

test_signal_active_count_and_oldest() {
  at_stubs
  at_task 02_exploring T-0001 "A"
  at_task 08_implementing T-0002 "B"
  at_task 07_approved T-0003 "C"
  at_task 07_approved T-0004 "D" session ses_d1
  at_task 05_planning T-0005 "E"
  at_task 06_plan_review T-0006 "F"
  assert_eq "$("$TASK" auto | sed -n 2p)" "active agents: 3/2"
  assert_eq "$("$TASK" auto | sed -n 4p)" "queue: 2 approved, 0 ready"
  printf 'max_active = 5\n' > "$AGENT_TASKS_HOME/config.toml"
  assert_eq "$("$TASK" auto | sed -n 2p)" "active agents: 3/5"
}

test_signal_input_with_old_auto_prompt_marker_counts() {
  at_stubs
  at_task 03_brainstorming T-0001 "Old marker" session ses_a1
  mkdir -p "$AGENT_TASKS_HOME/.notify"
  touch -t "$(minutes_ago 2)" "$AGENT_TASKS_HOME/.notify/T-0001.auto-prompt"
  "$TASK" signal 1 input --session ses_a1 --text hi >/dev/null
  assert_file "$AGENT_TASKS_HOME/.notify/T-0001.last-user"
  assert_no_file "$AGENT_TASKS_HOME/.notify/T-0001.auto-prompt"
}

test_signal_input_with_fresh_auto_prompt_marker_is_not_user_activity() {
  at_stubs
  at_task 03_brainstorming T-0001 "Fresh marker" session ses_a1
  mkdir -p "$AGENT_TASKS_HOME/.notify"
  : > "$AGENT_TASKS_HOME/.notify/T-0001.auto-prompt"
  "$TASK" signal 1 input --session ses_a1 --text kickoff >/dev/null
  assert_no_file "$AGENT_TASKS_HOME/.notify/T-0001.last-user"
  assert_no_file "$AGENT_TASKS_HOME/.notify/T-0001.auto-prompt"
  "$TASK" signal 1 input --session ses_a1 --text "user typed" >/dev/null
  assert_file "$AGENT_TASKS_HOME/.notify/T-0001.last-user"
}
