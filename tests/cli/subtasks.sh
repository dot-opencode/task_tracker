# shellcheck shell=bash
# Subtasks (parent) and dependencies (depends_on). Uses the at_* helpers of signal.sh.

st_fm() { "$TASK" show "$1" | awk -v k="$2: " 'NR > 1 && $0 == "---" { exit } index($0, k) == 1 { print substr($0, length(k) + 1); exit }'; }

test_subtasks_new_with_parent_and_depends() {
  "$TASK" new "Epic" >/dev/null
  "$TASK" new "A" --parent 1 >/dev/null
  "$TASK" new "B" --parent t-1 --depends "1,2" >/dev/null
  assert_eq "$(st_fm T-0002 parent)" "T-0001"
  assert_eq "$(st_fm T-0003 parent)" "T-0001"
  assert_eq "$(st_fm T-0003 depends_on)" "T-0001 T-0002"
  "$TASK" new "C" --depends 1 --depends 2 >/dev/null
  assert_eq "$(st_fm T-0004 depends_on)" "T-0001 T-0002"
  "$TASK" new "bad" --parent 99 2>/dev/null && fail "missing parent accepted"
  "$TASK" new "bad" --depends 99 2>/dev/null && fail "missing dependency accepted"
  return 0
}

test_subtasks_new_inherits_parent_project() {
  "$TASK" ls >/dev/null
  mkdir -p "$TMP/proj" "$AGENT_TASKS_HOME/work/.projects"
  printf '%s\n' "$TMP/proj" > "$AGENT_TASKS_HOME/work/.projects/crm"
  "$TASK" new "Epic" --project crm >/dev/null
  "$TASK" new "Kid" --parent 1 >/dev/null
  assert_eq "$(st_fm T-0002 project)" crm
}

test_subtasks_set_unset_validation() {
  "$TASK" new "A" >/dev/null; "$TASK" new "B" >/dev/null; "$TASK" new "C" >/dev/null
  "$TASK" set 2 parent 1 >/dev/null
  assert_eq "$(st_fm T-0002 parent)" T-0001
  "$TASK" set 3 parent 2 >/dev/null
  "$TASK" set 1 parent 3 2>/dev/null && fail "parent cycle accepted"
  "$TASK" set 1 parent 1 2>/dev/null && fail "self parent accepted"
  "$TASK" set 1 parent 77 2>/dev/null && fail "missing parent accepted"
  "$TASK" unset 2 parent >/dev/null
  assert_eq "$(st_fm T-0002 parent)" ""
  "$TASK" set 1 depends_on "2, 3" >/dev/null
  assert_eq "$(st_fm T-0001 depends_on)" "T-0002 T-0003"
  "$TASK" set 2 depends_on 3 >/dev/null
  "$TASK" set 3 depends_on 1 2>/dev/null && fail "dependency cycle accepted"
  "$TASK" set 3 depends_on 3 2>/dev/null && fail "self dependency accepted"
  "$TASK" set 3 depends_on 55 2>/dev/null && fail "missing dependency accepted"
  "$TASK" unset 1 depends_on >/dev/null
  assert_eq "$(st_fm T-0001 depends_on)" ""
}

test_subtasks_parent_other_workspace_rejected() {
  "$TASK" new "A" >/dev/null
  mkdir -p "$TMP/p2" "$AGENT_TASKS_HOME/other/.projects"
  "$TASK" project add p2 "$TMP/p2" --ws other >/dev/null
  "$TASK" new "B" --project p2 --ws other >/dev/null
  "$TASK" new "C" --project p2 --ws other --parent 1 2>/dev/null && fail "cross-ws parent in new"
  "$TASK" set 2 parent 1 2>/dev/null && fail "cross-ws parent in set"
  return 0
}

test_subtasks_ls_json_fields() {
  "$TASK" new "Epic" >/dev/null
  "$TASK" new "Kid" --parent 1 --depends 1 >/dev/null
  local j
  j="$("$TASK" ls --json)"
  assert_eq "$(jq -c '.[] | select(.id == "T-0001") | [.parent, .depends_on, .blocked_by, .children]' <<< "$j")" '[null,[],[],["T-0002"]]'
  assert_eq "$(jq -c '.[] | select(.id == "T-0002") | [.parent, .depends_on, .blocked_by, .children]' <<< "$j")" '["T-0001",["T-0001"],["T-0001"],[]]'
  "$TASK" mv 1 11_done --force >/dev/null
  assert_eq "$("$TASK" ls --json | jq -c '.[] | select(.id == "T-0002") | .blocked_by')" '[]'
  "$TASK" set 2 depends_on 42 2>/dev/null && fail "missing accepted"
  # a missing dependency counts as blocking
  sed_i 's/^depends_on: .*/depends_on: T-0042/' "$(task_path_of T-0002)"
  assert_eq "$("$TASK" ls --json | jq -c '.[] | select(.id == "T-0002") | .blocked_by')" '["T-0042"]'
}

test_subtasks_ls_parent_filter_and_text() {
  "$TASK" new "Epic" >/dev/null
  "$TASK" new "Solo" >/dev/null
  "$TASK" new "Kid one" --parent 1 >/dev/null
  "$TASK" new "Kid two" --parent 1 --depends 2 >/dev/null
  assert_eq "$("$TASK" ls --parent 1 --json | jq -r '[.[].id] | join(" ")')" "T-0003 T-0004"
  local out
  out="$("$TASK" ls)"
  assert_contains "$out" "Epic [0/2]"
  assert_contains "$out" "↳ Kid one"
  assert_contains "$out" "↳ Kid two (waits T-0002)"
  # children follow the parent directly, before Solo
  assert_eq "$(printf '%s\n' "$out" | awk 'NR > 1 { print $1 }' | tr '\n' ' ')" "T-0001 T-0003 T-0004 T-0002 "
  "$TASK" mv 3 11_done >/dev/null
  assert_contains "$("$TASK" ls)" "Epic [1/2]"
}

test_subtasks_show_footer() {
  "$TASK" new "Epic" >/dev/null
  "$TASK" new "Kid" --parent 1 >/dev/null
  assert_contains "$("$TASK" show 1)" "subtasks: T-0002 00_backlog Kid"
  assert_not_contains "$(cat "$(task_path_of T-0001)")" "subtasks:"
  assert_not_contains "$("$TASK" show 2)" "subtasks:"
}

test_subtasks_parent_waits_and_force() {
  "$TASK" new "Epic" >/dev/null
  "$TASK" new "K1" --parent 1 >/dev/null
  "$TASK" new "K2" --parent 1 >/dev/null
  local err
  err="$("$TASK" mv 1 11_done 2>&1)" && fail "mv should die"
  assert_contains "$err" "T-0001 has open subtasks: T-0002 T-0003 (use --force)"
  "$TASK" mv 1 09_finishing 2>/dev/null && fail "mv 09 should die"
  "$TASK" done 1 --result discarded 2>/dev/null && fail "done should die"
  "$TASK" done 1 --result pr 2>/dev/null && fail "done pr should die"
  assert_eq "$(at_folder T-0001)" 00_backlog
  "$TASK" mv 1 05_planning >/dev/null
  "$TASK" mv 1 11_done --force >/dev/null
  assert_eq "$(at_folder T-0001)" 11_done
  "$TASK" mv 1 10_unmerged --force >/dev/null
  "$TASK" merged 1 2>/dev/null && fail "merged should die"
  "$TASK" merged 1 --force >/dev/null
  assert_eq "$(at_folder T-0001)" 11_done
}

test_subtasks_signal_finishing_does_not_die() {
  at_stubs
  at_task 08_implementing T-0001 "Epic" session ses_a
  at_task 00_backlog T-0002 "Kid" parent T-0001
  local out
  out="$("$TASK" signal 1 finishing --session ses_a)" || fail "signal died"
  assert_eq "$(at_folder T-0001)" 08_implementing
  assert_contains "$(cat "$(task_path_of T-0001)")" "waiting for subtasks: T-0002"
  assert_contains "$out" "waiting for subtasks"
  "$TASK" mv 2 11_done >/dev/null
  "$TASK" signal 1 finishing --session ses_a >/dev/null
  # the parent closed itself when its last child finished
  assert_eq "$(at_folder T-0001)" 11_done
}

test_subtasks_autoclose_recursive() {
  "$TASK" new "Grand" >/dev/null
  "$TASK" new "Parent" --parent 1 >/dev/null
  "$TASK" new "Leaf1" --parent 2 >/dev/null
  "$TASK" new "Leaf2" --parent 2 >/dev/null
  "$TASK" mv 3 11_done >/dev/null
  assert_eq "$(at_folder T-0002)" 00_backlog
  "$TASK" done 4 --result discarded >/dev/null
  assert_eq "$(at_folder T-0002)" 11_done
  assert_eq "$(at_folder T-0001)" 11_done
  assert_eq "$(st_fm T-0002 result)" subtasks
  assert_contains "$(cat "$(task_path_of T-0002)")" "T-0003"
  assert_contains "$(cat "$(task_path_of T-0002)")" "task: 00_backlog → 11_done — all subtasks done"
  assert_eq "$(st_fm T-0001 result)" subtasks
}

test_subtasks_autoclose_skips_postponed_parent() {
  "$TASK" new "Epic" >/dev/null
  "$TASK" new "Kid" --parent 1 >/dev/null
  "$TASK" postpone 1 >/dev/null
  "$TASK" mv 2 11_done >/dev/null
  assert_eq "$(at_folder T-0001)" postponed
}

test_subtasks_run_sweep_closes_hand_moved() {
  at_stubs
  "$TASK" new "Epic" >/dev/null
  "$TASK" new "Kid" --parent 1 >/dev/null
  mv "$(task_path_of T-0002)" "$AGENT_TASKS_HOME/work/11_done/"
  "$TASK" run --once >/dev/null 2>&1
  assert_eq "$(at_folder T-0001)" 11_done
  assert_eq "$(st_fm T-0001 result)" subtasks
}

test_subtasks_worker_skips_blocked_ready() {
  at_stubs
  "$TASK" ls >/dev/null
  at_project
  at_task 01_ready T-0001 "Waits" project crm depends_on T-0003
  at_task 01_ready T-0002 "Free" project crm
  at_task 00_backlog T-0003 "Dep"
  at_age T-0001 90
  at_auto_on
  "$TASK" run --once >/dev/null 2>&1
  assert_eq "$(at_folder T-0001)" 01_ready
  assert_eq "$(at_folder T-0002)" 02_exploring
}

test_subtasks_doctor_reports_problems() {
  "$TASK" new "A" >/dev/null; "$TASK" new "B" >/dev/null
  "$TASK" doctor >/dev/null || fail "clean store should pass"
  local f out
  f="$(task_path_of T-0001)"
  sed_i 's/^created:/parent: T-0042\ndepends_on: T-0002 T-0077\ncreated:/' "$f"
  f="$(task_path_of T-0002)"
  sed_i 's/^created:/depends_on: T-0001\ncreated:/' "$f"
  out="$("$TASK" doctor 2>&1)" && fail "doctor should fail"
  assert_contains "$out" "parent T-0042 does not exist"
  assert_contains "$out" "depends_on T-0077 does not exist"
  assert_contains "$out" "dependency cycle"
}

test_subtasks_doctor_parent_cycle_and_workspace() {
  "$TASK" new "A" >/dev/null; "$TASK" new "B" >/dev/null
  sed_i 's/^created:/parent: T-0002\ncreated:/' "$(task_path_of T-0001)"
  sed_i 's/^created:/parent: T-0001\ncreated:/' "$(task_path_of T-0002)"
  assert_contains "$("$TASK" doctor 2>&1 || true)" "parent cycle"
  sed_i '/^parent:/d' "$(task_path_of T-0001)" "$(task_path_of T-0002)"
  mkdir -p "$TMP/p2"
  "$TASK" project add p2 "$TMP/p2" --ws other >/dev/null
  "$TASK" new "C" --project p2 --ws other >/dev/null
  sed_i 's/^created:/parent: T-0001\ncreated:/' "$(task_path_of T-0003)"
  assert_contains "$("$TASK" doctor 2>&1 || true)" "in another workspace"
}
