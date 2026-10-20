# shellcheck shell=bash
# Task 7: doctor.

# Overwrites a task file with exact frontmatter lines (no trailing log unless asked).
raw_task() {   # raw_task <folder> <file-name> <frontmatter-lines...>; log section is added
  local folder="$1" name="$2" f
  shift 2
  mkdir -p "$AGENT_TASKS_HOME/work/$folder"
  f="$AGENT_TASKS_HOME/work/$folder/$name"
  { printf -- '---\n'; printf '%s\n' "$@"; printf -- '---\n\nbody\n\n## Log\n- 2026-10-01 09:00 task: created\n'; } > "$f"
}

doctor_run() {   # sets DOC_OUT and DOC_RC
  DOC_RC=0
  DOC_OUT="$("$TASK" doctor 2>&1)" || DOC_RC=$?
}

test_doctor_clean_store() {
  mkdir -p "$TMP/code/api"
  "$TASK" project add api "$TMP/code/api" >/dev/null
  "$TASK" new "One" --project api >/dev/null
  "$TASK" new "Two" >/dev/null
  assert_eq "$("$TASK" doctor)" "ok: 2 tasks, 1 project"
}

test_doctor_empty_store() {
  assert_eq "$("$TASK" doctor)" "ok: 0 tasks, 0 projects"
}

test_doctor_is_read_only() {
  "$TASK" new "One" >/dev/null
  printf 'x\n' >> "$(task_path_of T-0001)"
  local before
  before="$(git -C "$AGENT_TASKS_HOME" rev-list --count HEAD)"
  "$TASK" doctor >/dev/null
  assert_eq "$(git -C "$AGENT_TASKS_HOME" rev-list --count HEAD)" "$before"
  assert_not_contains "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" "XX"
}

test_doctor_duplicate_ids() {
  write_task_file 00_backlog T-0001 "One"
  write_task_file 01_ready T-0001 "One again"
  doctor_run
  assert_eq "$DOC_RC" 1
  assert_contains "$DOC_OUT" "work/01_ready/T-0001-one-again.md: duplicate id T-0001 (also work/00_backlog/T-0001-one.md)"
}

test_doctor_frontmatter_structure() {
  mkdir -p "$AGENT_TASKS_HOME/work/00_backlog"
  printf 'no frontmatter\n\n## Log\n' > "$AGENT_TASKS_HOME/work/00_backlog/T-0001.md"
  printf -- '---\nid: T-0002\ntitle: "x"\ncreated: 2026-10-01\n\n## Log\n' > "$AGENT_TASKS_HOME/work/00_backlog/T-0002.md"
  raw_task 00_backlog T-0003.md 'id: T-0003' 'title: "x"' 'created: 2026-10-01' 'junk line'
  raw_task 00_backlog T-0004.md 'id: T-0004' 'title: "x"' 'created: 2026-10-01' 'created: 2026-10-02'
  raw_task 00_backlog T-0005.md 'id: T-0005' 'title: "x"' 'created: 2026-10-01' 'mood: happy'
  doctor_run
  assert_eq "$DOC_RC" 1
  assert_contains "$DOC_OUT" "work/00_backlog/T-0001.md: no frontmatter"
  assert_contains "$DOC_OUT" "work/00_backlog/T-0002.md: frontmatter not closed"
  assert_contains "$DOC_OUT" "work/00_backlog/T-0003.md: bad frontmatter line 'junk line'"
  assert_contains "$DOC_OUT" "work/00_backlog/T-0004.md: duplicate key 'created'"
  assert_contains "$DOC_OUT" "work/00_backlog/T-0005.md: unknown key 'mood'"
}

test_doctor_value_checks() {
  raw_task 00_backlog T-0001.md 'id: T-0009' 'title: "x"' 'created: 2026-10-01'
  raw_task 00_backlog T-0002.md 'id: T-0002' 'title: ""' 'created: 2026-10-01'
  raw_task 00_backlog T-0003.md 'id: T-0003' 'title: "x"' 'created: 2026-02-30'
  raw_task 00_backlog T-0004.md 'id: T-0004' 'title: "x"'
  raw_task 11_done T-0005.md 'id: T-0005' 'title: "x"' 'created: 2026-10-01' 'result: won'
  raw_task 00_backlog T-0006.md 'id: T-0006' 'title: "x"' 'created: 2026-10-01' 'project: ghost'
  raw_task 00_backlog T-0007.md 'id: T-0007' 'title: "x"' 'created: 2026-10-01' 'session: bad'
  doctor_run
  assert_eq "$DOC_RC" 1
  assert_contains "$DOC_OUT" "T-0001.md: id 'T-0009' does not match file name"
  assert_contains "$DOC_OUT" "T-0002.md: empty title"
  assert_contains "$DOC_OUT" "T-0003.md: invalid created date '2026-02-30'"
  assert_contains "$DOC_OUT" "T-0004.md: invalid created date ''"
  assert_contains "$DOC_OUT" "T-0005.md: invalid result 'won'"
  assert_contains "$DOC_OUT" "T-0006.md: unknown project 'ghost'"
  assert_contains "$DOC_OUT" "T-0007.md: invalid session id 'bad'"
}

test_doctor_blocked_and_session_rules() {
  raw_task blocked T-0001.md 'id: T-0001' 'title: "x"' 'created: 2026-10-01'
  raw_task 00_backlog T-0002.md 'id: T-0002' 'title: "x"' 'created: 2026-10-01' 'blocked_from: 02_exploring'
  raw_task blocked T-0003.md 'id: T-0003' 'title: "x"' 'created: 2026-10-01' 'blocked_from: nowhere'
  raw_task 02_exploring T-0004.md 'id: T-0004' 'title: "x"' 'created: 2026-10-01'
  raw_task 08_implementing T-0005.md 'id: T-0005' 'title: "x"' 'created: 2026-10-01'
  raw_task 08_implementing T-0006.md 'id: T-0006' 'title: "x"' 'created: 2026-10-01' 'session: ses_ok1'
  raw_task 05_planning T-0007.md 'id: T-0007' 'title: "x"' 'created: 2026-10-01'
  raw_task 06_plan_review T-0008.md 'id: T-0008' 'title: "x"' 'created: 2026-10-01'
  doctor_run
  assert_eq "$DOC_RC" 1
  assert_contains "$DOC_OUT" "work/blocked/T-0001.md: in blocked without blocked_from"
  assert_contains "$DOC_OUT" "work/00_backlog/T-0002.md: blocked_from outside blocked"
  assert_contains "$DOC_OUT" "work/blocked/T-0003.md: invalid blocked_from 'nowhere'"
  assert_contains "$DOC_OUT" "work/02_exploring/T-0004.md: in 02_exploring without session"
  assert_contains "$DOC_OUT" "work/08_implementing/T-0005.md: in 08_implementing without session"
  assert_not_contains "$DOC_OUT" "T-0006.md"
  assert_contains "$DOC_OUT" "work/05_planning/T-0007.md: in 05_planning without session"
  assert_not_contains "$DOC_OUT" "T-0008.md"
}

test_doctor_missing_log_section() {
  mkdir -p "$AGENT_TASKS_HOME/work/00_backlog"
  printf -- '---\nid: T-0001\ntitle: "x"\ncreated: 2026-10-01\n---\n\nbody\n' > "$AGENT_TASKS_HOME/work/00_backlog/T-0001.md"
  doctor_run
  assert_eq "$DOC_RC" 1
  assert_contains "$DOC_OUT" "work/00_backlog/T-0001.md: no ## Log section"
}

test_doctor_project_path_missing_and_summary() {
  mkdir -p "$TMP/code/api"
  "$TASK" project add api "$TMP/code/api" >/dev/null
  rmdir "$TMP/code/api"
  doctor_run
  assert_eq "$DOC_RC" 1
  assert_contains "$DOC_OUT" "work/.projects/api: path does not exist: $TMP/code/api"
  assert_contains "$DOC_OUT" "1 problem(s)"
}

test_doctor_counts_problems() {
  write_task_file 00_backlog T-0001 "One"
  write_task_file 01_ready T-0001 "One again"
  doctor_run
  assert_contains "$DOC_OUT" "1 problem(s)"
}

test_doctor_rejects_arguments() {
  local out rc=0
  out="$("$TASK" doctor extra 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: task doctor"
}

test_doctor_accepts_quoted_and_escaped_titles() {
  "$TASK" new 'Quote "me" \ please' --source 'https://a.example/x: y' >/dev/null
  assert_eq "$("$TASK" doctor)" "ok: 1 task, 0 projects"
}

test_doctor_reports_tab_in_title() {
  local f="$AGENT_TASKS_HOME/work/00_backlog/T-0001.md"
  mkdir -p "$AGENT_TASKS_HOME/work/00_backlog"
  printf -- '---\nid: T-0001\ntitle: "a\tb"\ncreated: 2026-10-01\n---\n\n## Log\n- 2026-10-01 09:00 task: x\n' > "$f"
  doctor_run
  assert_eq "$DOC_RC" 1
  assert_contains "$DOC_OUT" "work/00_backlog/T-0001.md: title contains a tab"
}

test_doctor_reports_invalid_project_name() {
  raw_task 00_backlog T-0001.md 'id: T-0001' 'title: "x"' 'project: ../../config.toml' 'created: 2026-10-01'
  doctor_run
  assert_eq "$DOC_RC" 1
  assert_contains "$DOC_OUT" "work/00_backlog/T-0001.md: invalid project name '../../config.toml'"
  assert_not_contains "$DOC_OUT" "unknown project"
}

# `task doctor` belongs to task 7, so the doctor half of the dead-pid race
# check lives here (the id half is in tasks.sh).
test_doctor_clean_after_parallel_new_with_dead_pid_lock() {
  export AGENT_TASKS_LOCK_TIMEOUT=30
  "$TASK" backup >/dev/null
  local i
  mkdir "$AGENT_TASKS_HOME/.lock"
  echo 999999 > "$AGENT_TASKS_HOME/.lock/pid"
  for i in 1 2 3 4 5 6; do "$TASK" new "Race $i" >/dev/null 2>&1 & done
  wait
  assert_eq "$("$TASK" doctor)" "ok: 6 tasks, 0 projects"
}
