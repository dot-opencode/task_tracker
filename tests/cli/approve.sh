# shellcheck shell=bash
# Spec approval (→ planning) and plan approval (→ implementing or the wait). Uses at_task / at_folder from signal.sh.
# Approval while automation is on is tested in auto.sh.

test_approve_spec_moves_to_planning_and_starts() {
  local fo f
  for fo in 03_brainstorming 04_spec_review; do
    rm -rf "$AGENT_TASKS_HOME"
    at_task "$fo" T-0001 "Spec"
    assert_eq "$("$TASK" approve 1)" "start"
    f="$(task_path_of T-0001)"
    assert_contains "$f" "/work/05_planning/"
    assert_contains "$(tail -n 1 "$f")" "task: $fo → 05_planning — spec approved — planning starts now"
    assert_eq "$(last_subject)" "tasks(work): T-0001 $fo → 05_planning"
  done
}

test_approve_spec_now_means_the_same() {
  at_task 04_spec_review T-0001 "Spec"
  assert_eq "$("$TASK" approve T-0001 --now | head -n 1)" "start"
  assert_eq "$(at_folder T-0001)" 05_planning
}

test_approve_plan_without_automation_defers() {
  at_task 06_plan_review T-0001 "Plan"
  local out f
  out="$("$TASK" approve 1)"
  assert_eq "$out" "deferred"
  f="$(task_path_of T-0001)"
  assert_contains "$f" "/work/07_approved/"
  assert_contains "$(tail -n 1 "$f")" "task: 06_plan_review → 07_approved — plan approved — waiting for the worker"
  assert_eq "$(last_subject)" "tasks(work): T-0001 06_plan_review → 07_approved"
}

test_approve_plan_now_starts_implementing() {
  at_task 06_plan_review T-0001 "Plan"
  assert_eq "$("$TASK" approve T-0001 --now | head -n 1)" "start"
  assert_eq "$(at_folder T-0001)" 08_implementing
  assert_contains "$(tail -n 1 "$(task_path_of T-0001)")" "06_plan_review → 08_implementing — plan approved — implementation starts now"
}

test_approve_from_planning_needs_plan() {
  local out rc=0
  at_task 05_planning T-0001 "Plan"
  out="$("$TASK" approve 1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" "task: T-0001 has no plan recorded yet"
  assert_eq "$(at_folder T-0001)" 05_planning
}

test_approve_from_planning_with_plan_behaves_like_review() {
  at_task 05_planning T-0001 "Plan" plan docs/superpowers/plans/x.md
  assert_eq "$("$TASK" approve 1)" "deferred"
  assert_eq "$(at_folder T-0001)" 07_approved
  rm -rf "$AGENT_TASKS_HOME"
  at_task 05_planning T-0001 "Plan" plan docs/superpowers/plans/x.md
  assert_eq "$("$TASK" approve 1 --now | head -n 1)" "start"
  assert_eq "$(at_folder T-0001)" 08_implementing
}

test_approve_wrong_folder_dies() {
  local fo out rc
  for fo in 00_backlog 01_ready 02_exploring 08_implementing 09_finishing 11_done blocked; do
    rm -rf "$AGENT_TASKS_HOME"
    at_task "$fo" T-0083 "Spec"
    rc=0; out="$("$TASK" approve 83 2>&1)" || rc=$?
    assert_eq "$rc" 1
    assert_eq "$out" "task: T-0083 is in $fo; approve applies to 03_brainstorming, 04_spec_review (spec), 05_planning (plan recorded), 06_plan_review (plan), 07_approved with --now"
    assert_eq "$(at_folder T-0083)" "$fo"
  done
  rm -rf "$AGENT_TASKS_HOME"
  at_task 07_approved T-0083 "Spec"
  rc=0; out="$("$TASK" approve 83 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "T-0083 is in 07_approved; approve applies to"
}

test_approve_rejects_bad_input() {
  at_task 04_spec_review T-0001 "Spec"
  local out rc=0
  out="$("$TASK" approve 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: task approve <id> [--now]"
  rc=0; out="$("$TASK" approve 1 --later 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown option: --later"
  rc=0; out="$("$TASK" approve 1 2 2>&1)" || rc=$?
  assert_eq "$rc" 1
  rc=0; out="$("$TASK" approve 7 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "no task T-0007"
  assert_eq "$(at_folder T-0001)" 04_spec_review
}

