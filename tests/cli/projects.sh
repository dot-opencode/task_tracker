# shellcheck shell=bash
# Task 3: project registry.

project_json_eq() {
  node -e 'const a=require("node:assert/strict"); a.deepEqual(JSON.parse(process.argv[1]),JSON.parse(process.argv[2]))' "$1" "$2"
}

test_projects_show_legacy_json() {
  mkdir -p "$TMP/code"
  "$TASK" project add api "$TMP/code" >/dev/null
  project_json_eq "$("$TASK" project show api --ws work --json)" \
    "{\"workspace\":\"work\",\"name\":\"api\",\"path\":\"$TMP/code\",\"settings\":null}"
}

test_projects_configure_file_and_registry_format() {
  mkdir -p "$TMP/code"
  "$TASK" project add api "$TMP/code" >/dev/null
  local settings='{"version":1,"environment":{"cwd":"repo","start":"touch SHOULD_NOT_EXIST","stop":"stop","readiness":"ready"},"task_code":{"attach":"attach","verify_version":"version"},"tests":[{"name":"backend","cwd":"repo","command":"test"}],"application":{"url":"http://localhost","login":"instructions","test_data":"fixtures"},"browser":{"navigation":"home","checks":"save"}}'
  printf '%s\n' "$settings" > "$TMP/settings.json"
  "$TASK" project configure api --file "$TMP/settings.json" >/dev/null
  project_json_eq "$("$TASK" project show api --json)" \
    "{\"workspace\":\"work\",\"name\":\"api\",\"path\":\"$TMP/code\",\"settings\":$settings}"
  node -e 'const fs=require("node:fs"),a=require("node:assert/strict"); const [path,...json]=fs.readFileSync(process.argv[1],"utf8").split("\n"); a.equal(path,process.argv[2]); a.deepEqual(JSON.parse(json.join("\n")),JSON.parse(process.argv[3]))' \
    "$AGENT_TASKS_HOME/work/.projects/api" "$TMP/code" "$settings"
  assert_no_file "$TMP/SHOULD_NOT_EXIST"
  assert_contains "$("$TASK" project ls)" "$TMP/code"
  assert_not_contains "$("$TASK" project ls)" "version"
}

test_projects_configure_partial_stdin_and_clear() {
  mkdir -p "$TMP/code"
  "$TASK" project add api "$TMP/code" >/dev/null
  local settings
  for settings in '{"version":1}' '{"version":1,"environment":{"start":"serve"}}' '{"version":1,"tests":[{"name":"unit","cwd":"repo","command":"test"}]}' '{}'; do
    printf '%s' "$settings" | "$TASK" project configure api --ws work --file - >/dev/null
    project_json_eq "$("$TASK" project show api --json)" \
      "{\"workspace\":\"work\",\"name\":\"api\",\"path\":\"$TMP/code\",\"settings\":$settings}"
  done
  "$TASK" project configure api --clear >/dev/null
  assert_eq "$(cat "$AGENT_TASKS_HOME/work/.projects/api")" "$TMP/code"
  project_json_eq "$("$TASK" project show api --json)" \
    "{\"workspace\":\"work\",\"name\":\"api\",\"path\":\"$TMP/code\",\"settings\":null}"
  "$TASK" project configure api --clear >/dev/null
}

test_projects_configure_rejects_invalid_without_writes() {
  mkdir -p "$TMP/code"
  "$TASK" project add api "$TMP/code" >/dev/null
  printf '{"version":1,"browser":{"checks":"keep"}}' | "$TASK" project configure api --file - >/dev/null
  local before subject settings rc out
  before="$(cat "$AGENT_TASKS_HOME/work/.projects/api")"
  subject="$(git -C "$AGENT_TASKS_HOME" rev-parse HEAD)"
  for settings in 'not-json' 'null' '[]' '{"browser":{}}' '{"version":2}' '{"version":"1"}' '{"version":1.0}' '{"version":true}' '{"version":1,"unknown":1}' '{"version":1,"environment":null}' '{"version":1,"environment":{"start":1}}' '{"version":1,"environment":{"secret":"x"}}' '{"version":1,"task_code":[]}' '{"version":1,"task_code":{"attach":false}}' '{"version":1,"application":{"url":[]}}' '{"version":1,"browser":{"checks":{}}}' '{"version":1,"tests":{}}' '{"version":1,"tests":["test"]}' '{"version":1,"tests":[{"name":"unit","cwd":"repo"}]}' '{"version":1,"tests":[{"name":"unit","command":"test"}]}' '{"version":1,"tests":[{"command":"test"}]}' '{"version":1,"tests":[{"name":"unit","command":"test","extra":1}]}' '{"version":1,"tests":[{"name":"unit","command":false}]}'; do
    rc=0
    out="$(printf '%s' "$settings" | "$TASK" project configure api --file - 2>&1)" || rc=$?
    assert_eq "$rc" 1
    assert_contains "$out" "settings"
    assert_eq "$(cat "$AGENT_TASKS_HOME/work/.projects/api")" "$before"
    assert_eq "$(git -C "$AGENT_TASKS_HOME" rev-parse HEAD)" "$subject"
  done
}

test_projects_settings_unknown_and_invalid_options() {
  local rc out args
  for args in 'show absent --json' 'configure absent --clear' 'configure absent --file -'; do
    rc=0
    out="$(printf '{"version":1}' | "$TASK" project $args 2>&1)" || rc=$?
    assert_eq "$rc" 1
    assert_contains "$out" "unknown project"
  done
  mkdir -p "$TMP/code"
  "$TASK" project add api "$TMP/code" >/dev/null
  local before="$(cat "$AGENT_TASKS_HOME/work/.projects/api")"
  for args in 'configure api' 'configure api --clear --file -' 'configure api --file' 'configure api --file /nonexistent-settings-file' 'show api --json --ws ../bad' 'configure api --clear --ws ../bad'; do
    rc=0
    out="$("$TASK" project $args 2>&1)" || rc=$?
    assert_eq "$rc" 1
    assert_eq "$(cat "$AGENT_TASKS_HOME/work/.projects/api")" "$before"
  done
}

test_projects_settings_workspace_isolation_and_ambiguity() {
  mkdir -p "$TMP/code"
  "$TASK" project add api "$TMP/code" --ws work >/dev/null
  "$TASK" project add api "$TMP/code" --ws side >/dev/null
  local args rc out
  for args in 'show api --json' 'configure api --clear' 'configure api --file -'; do
    rc=0
    out="$(printf '{"version":1}' | "$TASK" project $args 2>&1)" || rc=$?
    assert_eq "$rc" 1
    assert_contains "$out" "pass --ws"
  done
  printf '{"version":1,"browser":{"checks":"work only"}}' | "$TASK" project configure api --ws work --file - >/dev/null
  project_json_eq "$("$TASK" project show api --ws side --json)" \
    "{\"workspace\":\"side\",\"name\":\"api\",\"path\":\"$TMP/code\",\"settings\":null}"
  assert_contains "$("$TASK" project show api --ws work --json)" 'work only'
  "$TASK" project configure api --ws side --clear >/dev/null
  assert_contains "$("$TASK" project show api --ws work --json)" 'work only'
}

test_projects_settings_preserved_on_path_update_and_import() {
  mkdir -p "$TMP/a" "$TMP/b"
  "$TASK" project add api "$TMP/a" >/dev/null
  printf '{"version":1,"browser":{"checks":"preserve"}}' | "$TASK" project configure api --file - >/dev/null
  "$TASK" project add api "$TMP/b" >/dev/null
  assert_contains "$("$TASK" project show api --json)" 'preserve'
  assert_eq "$("$TASK" project add api "$TMP/b")" "project api (work) is already registered: $TMP/b"
  export AGENT_MEMORY_HOME="$TMP/mem"
  mem_project work api "$TMP/a"
  "$TASK" project import-memory >/dev/null
  project_json_eq "$("$TASK" project show api --json)" \
    "{\"workspace\":\"work\",\"name\":\"api\",\"path\":\"$TMP/a\",\"settings\":{\"version\":1,\"browser\":{\"checks\":\"preserve\"}}}"
}

test_projects_show_rejects_malformed_stored_settings() {
  mkdir -p "$TMP/code"
  "$TASK" project add api "$TMP/code" >/dev/null
  local settings rc out
  for settings in '{broken' '{"version":2}' '{"version":1,"browser":{"typo":"x"}}'; do
    printf '%s\n%s\n' "$TMP/code" "$settings" > "$AGENT_TASKS_HOME/work/.projects/api"
    rc=0
    out="$("$TASK" project show api --json 2>&1)" || rc=$?
    assert_eq "$rc" 1
    assert_contains "$out" "settings"
  done
  "$TASK" project configure api --clear >/dev/null
  assert_eq "$(cat "$AGENT_TASKS_HOME/work/.projects/api")" "$TMP/code"
}

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
