# shellcheck shell=bash
# Task 3: project registry.

test_projects_add_explicit_path() {
  mkdir -p "$TMP/code/api"
  local out
  out="$("$TASK" project add api "$TMP/code/api")"
  assert_eq "$out" "added project api (work): $TMP/code/api"
  assert_eq "$(cat "$AGENT_TASKS_HOME/work/.projects/api")" "$TMP/code/api"
  assert_eq "$(last_subject)" "tasks(work): project api added"
}

test_projects_add_canonicalises_path() {
  mkdir -p "$TMP/code/api"
  ln -s "$TMP/code/api" "$TMP/link"
  "$TASK" project add api "$TMP/link" >/dev/null
  assert_eq "$(cat "$AGENT_TASKS_HOME/work/.projects/api")" "$TMP/code/api"
}

test_projects_add_defaults_to_cwd() {
  mkdir -p "$TMP/code/my-svc"
  cd "$TMP/code/my-svc" || return 1
  local out
  out="$("$TASK" project add)"
  assert_eq "$out" "added project my-svc (work): $TMP/code/my-svc"
  mkdir sub
  cd sub || return 1
  out="$("$TASK" project add named)"
  assert_eq "$out" "added project named (work): $TMP/code/my-svc/sub"
}

test_projects_add_update_and_unchanged() {
  mkdir -p "$TMP/a" "$TMP/b"
  "$TASK" project add api "$TMP/a" >/dev/null
  assert_eq "$("$TASK" project add api "$TMP/a")" "project api (work) is already registered: $TMP/a"
  assert_eq "$("$TASK" project add api "$TMP/b")" "updated project api (work): $TMP/b"
  assert_eq "$(last_subject)" "tasks(work): project api updated"
}

test_projects_add_rejects_bad_input() {
  local out rc=0
  out="$("$TASK" project add api "$TMP/missing" 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "not a directory"
  mkdir -p "$TMP/d"
  rc=0
  out="$("$TASK" project add 'bad name' "$TMP/d" 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid project name"
  rc=0
  out="$("$TASK" project add -x 2>&1)" || rc=$?
  assert_eq "$rc" 1
  rc=0
  out="$("$TASK" project bogus 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: task project"
}

test_projects_add_uses_default_workspace_from_config() {
  "$TASK" backup >/dev/null
  printf 'default_workspace = "home"\n' > "$AGENT_TASKS_HOME/config.toml"
  "$TASK" backup >/dev/null
  mkdir -p "$TMP/d"
  assert_eq "$("$TASK" project add d "$TMP/d")" "added project d (home): $TMP/d"
  assert_file "$AGENT_TASKS_HOME/home/.projects/d"
  assert_eq "$(last_subject)" "tasks(home): project d added"
}

test_projects_add_ws_flag() {
  mkdir -p "$TMP/d"
  "$TASK" project add d "$TMP/d" --ws side >/dev/null
  assert_file "$AGENT_TASKS_HOME/side/.projects/d"
  [ -d "$AGENT_TASKS_HOME/side/00_backlog" ] || fail "workspace not created"
}

test_projects_ls() {
  local out
  assert_eq "$("$TASK" project ls)" "no projects"
  mkdir -p "$TMP/a" "$TMP/long-name-dir"
  "$TASK" project add a "$TMP/a" >/dev/null
  "$TASK" project add long-name "$TMP/long-name-dir" >/dev/null
  "$TASK" project add other "$TMP/a" --ws home >/dev/null
  rmdir "$TMP/long-name-dir"
  out="$("$TASK" project ls)"
  assert_contains "$out" "home  other      $TMP/a"
  assert_contains "$out" "work  a          $TMP/a"
  assert_contains "$out" "work  long-name  $TMP/long-name-dir (missing)"
  out="$("$TASK" project ls --ws home)"
  assert_not_contains "$out" "long-name"
}

mem_project() {   # mem_project <ws> <name> <path>
  mkdir -p "$TMP/mem/$1/projects/$2"
  printf '%s\n' "$3" > "$TMP/mem/$1/projects/$2/.project-path"
}

test_projects_import_memory() {
  export AGENT_MEMORY_HOME="$TMP/mem"
  mkdir -p "$TMP/code/a" "$TMP/code/b" "$TMP/code/c"
  mem_project work a "$TMP/code/a"
  mem_project work b "$TMP/code/b"
  mem_project work gone "$TMP/code/gone"
  mem_project home c "$TMP/code/c"
  local out
  out="$("$TASK" project import-memory)"
  assert_contains "$out" "imported 3, updated 0, unchanged 0, skipped 1"
  assert_contains "$out" "skipped (path missing): gone"
  assert_file "$AGENT_TASKS_HOME/work/.projects/a"
  assert_file "$AGENT_TASKS_HOME/home/.projects/c"
  assert_no_file "$AGENT_TASKS_HOME/work/.projects/gone"
  assert_eq "$(last_subject)" "tasks: 3 changes"
  out="$("$TASK" project import-memory)"
  assert_contains "$out" "imported 0, updated 0, unchanged 3, skipped 1"
}

test_projects_import_memory_updates_and_filters() {
  export AGENT_MEMORY_HOME="$TMP/mem"
  mkdir -p "$TMP/code/a" "$TMP/code/a2" "$TMP/code/c"
  mem_project work a "$TMP/code/a"
  mem_project home c "$TMP/code/c"
  "$TASK" project import-memory --ws work >/dev/null
  assert_no_file "$AGENT_TASKS_HOME/home/.projects/c"
  mem_project work a "$TMP/code/a2"
  local out
  out="$("$TASK" project import-memory --ws work)"
  assert_contains "$out" "imported 0, updated 1, unchanged 0, skipped 0"
  assert_not_contains "$out" "skipped (path"
}

test_projects_import_memory_without_store() {
  export AGENT_MEMORY_HOME="$TMP/nope"
  local out rc=0
  out="$("$TASK" project import-memory 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "no agent-memory store at $TMP/nope"
}

test_projects_import_memory_defaults_to_home_dir() {
  mkdir -p "$HOME/.agent-memory" 
  local out
  out="$("$TASK" project import-memory)"
  assert_contains "$out" "imported 0"
}
