# shellcheck shell=bash
# Postponed: set aside by the user, hidden from the default view.
# Uses the at_* helpers of signal.sh.

pp_has() { grep -q "^$2: $3\$" "$(task_path_of "$1")"; }
pp_hasnot() { ! grep -q "^$2:" "$(task_path_of "$1")"; }

test_postpone_and_resume_return_to_stage() {
  local f
  for f in 00_backlog 04_spec_review 06_plan_review; do
    rm -rf "$AGENT_TASKS_HOME"
    at_task "$f" T-0001 "Stage"
    assert_eq "$("$TASK" postpone 1)" "T-0001: $f → postponed (from $f)"
    assert_eq "$(at_folder T-0001)" postponed
    pp_has T-0001 postponed_from "$f" || fail "postponed_from missing"
    assert_contains "$(last_subject)" "T-0001 $f → postponed"
    assert_eq "$("$TASK" resume T-0001)" "T-0001: postponed → $f"
    assert_eq "$(at_folder T-0001)" "$f"
    pp_hasnot T-0001 postponed_from || fail "postponed_from not cleared"
    assert_contains "$(tail -n 1 "$(task_path_of T-0001)")" "task: resumed"
  done
}

test_postpone_reason_is_logged() {
  at_task 01_ready T-0001 "Why"
  "$TASK" postpone 1 --reason "waiting for design" >/dev/null
  assert_contains "$(cat "$(task_path_of T-0001)")" "task: postponed — waiting for design"
  assert_contains "$(cat "$(task_path_of T-0001)")" "task: 01_ready → postponed"
}

test_postpone_from_blocked_records_blocked_from() {
  at_task blocked T-0001 "Blk" blocked_from 06_plan_review
  "$TASK" postpone 1 >/dev/null
  pp_has T-0001 postponed_from 06_plan_review || fail "wrong postponed_from"
  pp_hasnot T-0001 blocked_from || fail "blocked_from kept"
  "$TASK" resume 1 >/dev/null
  assert_eq "$(at_folder T-0001)" 06_plan_review
}

test_postpone_agent_folder_warns_and_resume_blocks() {
  local err out
  at_task 08_implementing T-0001 "Busy" session ses_a1
  err="$("$TASK" postpone 1 2>&1 >/dev/null)"
  assert_eq "$err" "warning: session ses_a1 may still be running; stop it in OpenCode (task open T-0001)"
  pp_has T-0001 postponed_from 08_implementing || fail "postponed_from"
  out="$("$TASK" resume 1)"
  assert_eq "$out" "T-0001: postponed → blocked (from 08_implementing); continue with: task open T-0001"
  assert_eq "$(at_folder T-0001)" blocked
  pp_has T-0001 blocked_from 08_implementing || fail "blocked_from"
  pp_hasnot T-0001 postponed_from || fail "postponed_from kept"
  assert_contains "$(tail -n 1 "$(task_path_of T-0001)")" "resumed; open the session to continue"
}

test_postpone_no_warning_without_session_or_outside_agent_folder() {
  at_task 08_implementing T-0001 "NoSes"
  at_task 04_spec_review T-0002 "Spec" session ses_b1
  assert_eq "$("$TASK" postpone 1 2>&1 >/dev/null)" ""
  assert_eq "$("$TASK" postpone 2 2>&1 >/dev/null)" ""
}

test_resume_falls_back_to_backlog() {
  at_task postponed T-0001 "Manual"
  assert_eq "$("$TASK" resume 1)" "T-0001: postponed → 00_backlog"
  assert_eq "$(at_folder T-0001)" 00_backlog
  at_task postponed T-0002 "Bad" postponed_from nonsense
  "$TASK" resume 2 >/dev/null
  assert_eq "$(at_folder T-0002)" 00_backlog
}

test_postpone_errors() {
  local out rc=0
  at_task 11_done T-0001 "Done"
  at_task postponed T-0002 "Again" postponed_from 00_backlog
  at_task 01_ready T-0003 "Ready"
  out="$("$TASK" postpone 1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" "task: T-0001 is in 11_done; done/archived tasks cannot be postponed"
  "$TASK" mv 1 archive >/dev/null
  out="$("$TASK" postpone 1 2>&1)" || true
  assert_eq "$out" "task: T-0001 is in archive; done/archived tasks cannot be postponed"
  out="$("$TASK" postpone 2 2>&1)" || true
  assert_eq "$out" "task: T-0002 is already postponed"
  out="$("$TASK" resume 3 2>&1)" || rc=$?
  assert_eq "$out" "task: T-0003 is in 01_ready; not postponed"
  out="$("$TASK" postpone 3 --reason $'a\nb' 2>&1)" || true
  assert_contains "$out" "single line"
  out="$("$TASK" postpone 2>&1)" || true
  assert_contains "$out" "usage: task postpone"
  out="$("$TASK" resume 2>&1)" || true
  assert_contains "$out" "usage: task resume"
}

test_postpone_mv_records_postponed_from() {
  at_task 06_plan_review T-0001 "Mv"
  "$TASK" mv T-0001 postponed >/dev/null
  pp_has T-0001 postponed_from 06_plan_review || fail "mv did not record"
  "$TASK" mv T-0001 00_backlog >/dev/null
  pp_hasnot T-0001 postponed_from || fail "mv out did not clear"
  at_task blocked T-0002 "Blk" blocked_from 05_planning
  "$TASK" mv T-0002 postponed >/dev/null
  pp_has T-0002 postponed_from 05_planning || fail "blocked mv"
}

test_postpone_ls_views() {
  local out
  at_task 01_ready T-0001 "Visible"
  at_task 02_exploring T-0002 "Away" session ses_a1
  at_task 11_done T-0003 "Finished"
  "$TASK" mv 3 archive >/dev/null
  "$TASK" postpone 2 >/dev/null 2>&1
  out="$("$TASK" ls)"
  assert_contains "$out" "T-0001"
  assert_not_contains "$out" "T-0002"
  assert_contains "$out" "postponed: 1 (task ls postponed)"
  assert_contains "$out" "archive: 1 (task ls archive)"
  case "$out" in *"postponed: 1"*"archive: 1"*) ;; *) fail "footer order" ;; esac
  out="$("$TASK" ls postponed)"
  assert_contains "$out" "T-0002"
  assert_contains "$out" "postponed"
  assert_not_contains "$out" "T-0001"
  assert_not_contains "$out" "postponed: 1"
  out="$("$TASK" ls --all)"
  assert_contains "$out" "T-0002"
  assert_not_contains "$out" "(task ls postponed)"
  assert_eq "$("$TASK" ls --json | jq -r 'map(.id) | join(",")')" "T-0001"
  assert_eq "$("$TASK" ls postponed --json | jq -r '.[0].status')" postponed
  assert_eq "$("$TASK" ls --json --all | jq -r 'map(select(.id=="T-0002"))[0].folder')" postponed
  out="$("$TASK" ls --waiting)"
  assert_not_contains "$out" "T-0002"
}

test_postpone_not_waiting_not_active_not_next() {
  at_stubs
  at_task 04_spec_review T-0001 "Wait" session ses_a1
  "$TASK" postpone 1 >/dev/null
  assert_not_contains "$("$TASK" ls --waiting)" "T-0001"
  assert_eq "$("$TASK" next)" "nothing is waiting for you"
  assert_contains "$("$TASK" auto)" "active agents: 0/2"
  at_task 08_implementing T-0002 "Busy" session ses_b1
  "$TASK" postpone 2 >/dev/null 2>&1
  assert_contains "$("$TASK" auto)" "active agents: 0/2"
}

test_postpone_not_archived_automatically() {
  at_task 11_done T-0001 "Old"
  at_task 01_ready T-0002 "Old postponed"
  "$TASK" postpone 2 >/dev/null
  AGENT_TASKS_NOW="2030-01-01 00:00" "$TASK" archive --due >/dev/null
  assert_eq "$(at_folder T-0002)" postponed
  assert_eq "$(at_folder T-0001)" archive
}

test_postpone_signals_only_log() {
  at_stubs
  local s out
  at_task 05_planning T-0001 "Sig" session ses_a1
  "$TASK" postpone 1 >/dev/null 2>&1
  for s in question turn-end permission error stalled input answered finishing; do
    out="$("$TASK" signal 1 "$s" --session ses_a1 --text hi)"
    assert_eq "$(at_folder T-0001)" postponed
    pp_has T-0001 postponed_from 05_planning || fail "postponed_from lost after $s"
  done
  assert_contains "$out" "T-0001: finishing noted"
  assert_no_file "$AGENT_TASKS_HOME/.notify/T-0001.alerter-pid"
}

test_postpone_doctor() {
  at_task 01_ready T-0001 "A"
  "$TASK" postpone 1 >/dev/null
  at_task 08_implementing T-0002 "B" session ses_b1
  "$TASK" postpone 2 >/dev/null 2>&1
  assert_contains "$("$TASK" doctor)" "ok: 2 tasks"
  at_task postponed T-0003 "Missing"
  at_task 01_ready T-0004 "Outside" postponed_from 00_backlog
  at_task postponed T-0005 "Invalid" postponed_from nonsense
  at_task postponed T-0006 "Self" postponed_from postponed
  local out rc=0
  out="$("$TASK" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "in postponed without postponed_from"
  assert_contains "$out" "postponed_from outside postponed"
  assert_contains "$out" "invalid postponed_from 'nonsense'"
  assert_contains "$out" "invalid postponed_from 'postponed'"
}

test_postpone_help_lists_commands() {
  local out
  out="$("$TASK" --help)"
  assert_contains "$out" "task postpone <id> [--reason TEXT]"
  assert_contains "$out" "task resume <id>"
}
