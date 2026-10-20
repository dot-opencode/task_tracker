# shellcheck shell=bash
# Task 1: entry point.

test_cli_version() {
  assert_eq "$("$TASK" --version)" "task 0.2.0"
  assert_eq "$("$TASK" -v)" "task 0.2.0"
}

test_cli_help_lists_commands() {
  local out
  out="$("$TASK" --help)"
  assert_contains "$out" "task new <title>"
  assert_contains "$out" "task project import-memory"
  assert_contains "$out" "<id>: T-0083, t-83 or 83"
  assert_eq "$("$TASK" help)" "$out"
  assert_eq "$("$TASK" -h)" "$out"
}

test_cli_unknown_command() {
  local out rc=0
  out="$("$TASK" frobnicate 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" "task: unknown command: frobnicate (see 'task --help')"
  rc=0
  out="$("$TASK" 'Bad;cmd' 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown command"
}

test_cli_guessed_set_subcommand_points_to_task_set() {
  local out rc=0
  out="$("$TASK" set-url T-0084 https://example.invalid/mr/1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown command: set-url"
  assert_contains "$out" "task set <id> url <value>"
  assert_contains "$out" "keys: title project source session spec plan pr result"
  assert_no_file "$AGENT_TASKS_HOME"
}

test_cli_subcommand_help_prints_its_usage() {
  local out rc=0
  out="$("$TASK" new --help)" || rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" "task new <title>"
  assert_not_contains "$out" "task ls"
  assert_contains "$("$TASK" project -h)" "task project add"
  assert_no_file "$AGENT_TASKS_HOME"
  rc=0; out="$("$TASK" frobnicate --help 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown command: frobnicate"
}

test_cli_unknown_command_does_not_create_store() {
  local out
  out="$("$TASK" frobnicate 2>&1)" || true
  assert_contains "$out" "unknown command: frobnicate"
  assert_no_file "$AGENT_TASKS_HOME"
}

test_cli_no_arguments_prints_usage_to_stderr() {
  local out err rc=0
  out="$("$TASK" 2>/dev/null)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" ""
  err="$("$TASK" 2>&1 >/dev/null)" || true
  assert_contains "$err" "usage: task <command>"
}

test_cli_works_through_symlink() {
  ln -s "$TASK" "$TMP/bin/task"
  assert_eq "$(task --version)" "task 0.2.0"
}
