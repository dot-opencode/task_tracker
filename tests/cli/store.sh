# shellcheck shell=bash
# Task 2: store, lock, commits.

test_store_first_use_initialises() {
  "$TASK" backup >/dev/null
  local s="$AGENT_TASKS_HOME" f
  [ -d "$s/.git" ] || fail "no .git"
  assert_file "$s/.gitignore"
  assert_file "$s/config.toml"
  for f in 00_backlog 01_ready 02_exploring 03_brainstorming 04_spec_review 07_approved 08_implementing 09_finishing 11_done blocked postponed archive .projects; do
    [ -d "$s/work/$f" ] || fail "missing work/$f"
  done
  assert_eq "$(git -C "$s" rev-list --count HEAD)" 1
  assert_eq "$(last_subject)" "tasks: init store"
  assert_contains "$(cat "$s/.gitignore")" ".lock/"
  assert_contains "$(cat "$s/.gitignore")" "*.tmp"
  assert_contains "$(cat "$s/config.toml")" 'default_workspace = "work"'
  assert_contains "$(cat "$s/config.toml")" "stale_minutes = 30"
}

test_store_relative_home_is_made_absolute() {
  export AGENT_TASKS_HOME="rel-store"
  "$TASK" backup >/dev/null
  [ -d "$TMP/rel-store/.git" ] || fail "relative store not created under cwd"
}

test_store_recreates_missing_config() {
  "$TASK" backup >/dev/null
  rm "$AGENT_TASKS_HOME/config.toml" "$AGENT_TASKS_HOME/.gitignore"
  rmdir "$AGENT_TASKS_HOME/work/blocked"
  "$TASK" backup >/dev/null
  assert_file "$AGENT_TASKS_HOME/config.toml"
  assert_file "$AGENT_TASKS_HOME/.gitignore"
  [ -d "$AGENT_TASKS_HOME/work/blocked" ] || fail "folder not recreated"
}

test_store_backup_nothing() {
  assert_eq "$("$TASK" backup)" "nothing to back up"
}

test_store_backup_new_task() {
  "$TASK" backup >/dev/null
  write_task_file 00_backlog T-0001 "First thing"
  assert_eq "$("$TASK" backup)" "backed up"
  assert_eq "$(last_subject)" "tasks(work): T-0001 new"
  assert_eq "$("$TASK" backup)" "nothing to back up"
}

test_store_backup_move() {
  write_task_file 02_exploring T-0001 "First thing"
  "$TASK" backup >/dev/null
  mv "$AGENT_TASKS_HOME"/work/02_exploring/T-0001-*.md "$AGENT_TASKS_HOME/work/03_brainstorming/" 2>/dev/null \
    || { mkdir -p "$AGENT_TASKS_HOME/work/03_brainstorming"; mv "$AGENT_TASKS_HOME"/work/02_exploring/T-0001-*.md "$AGENT_TASKS_HOME/work/03_brainstorming/"; }
  "$TASK" backup >/dev/null
  assert_eq "$(last_subject)" "tasks(work): T-0001 02_exploring → 03_brainstorming"
}

test_store_backup_log_and_edit() {
  write_task_file 00_backlog T-0001 "First thing"
  "$TASK" backup >/dev/null
  local f
  f="$(task_path_of T-0001)"
  printf -- '- 2026-10-01 10:00 agent: noted\n  second line\n' >> "$f"
  "$TASK" backup >/dev/null
  assert_eq "$(last_subject)" "tasks(work): T-0001 log"
  printf 'extra body\n' >> "$f"
  "$TASK" backup >/dev/null
  assert_eq "$(last_subject)" "tasks(work): T-0001 edit"
}

test_store_backup_delete() {
  write_task_file 00_backlog T-0001 "First thing"
  "$TASK" backup >/dev/null
  rm "$(task_path_of T-0001)"
  "$TASK" backup >/dev/null
  assert_eq "$(last_subject)" "tasks(work): T-0001 deleted"
}

test_store_backup_several_changes() {
  "$TASK" backup >/dev/null
  write_task_file 00_backlog T-0001 "First thing"
  write_task_file 00_backlog T-0002 "Second thing"
  "$TASK" backup >/dev/null
  assert_eq "$(last_subject)" "tasks: 2 changes in 2 tasks"
  assert_contains "$(last_body)" "- work: T-0001 new"
  assert_contains "$(last_body)" "- work: T-0002 new"
}

test_store_backup_project_and_other_paths() {
  "$TASK" backup >/dev/null
  printf '/x\n' > "$AGENT_TASKS_HOME/work/.projects/api"
  "$TASK" backup >/dev/null
  assert_eq "$(last_subject)" "tasks(work): project api added"
  printf '/y\n' > "$AGENT_TASKS_HOME/work/.projects/api"
  "$TASK" backup >/dev/null
  assert_eq "$(last_subject)" "tasks(work): project api updated"
  printf 'x\n' > "$AGENT_TASKS_HOME/notes.txt"
  "$TASK" backup >/dev/null
  assert_eq "$(last_subject)" "tasks: add notes.txt"
}

test_store_backup_one_task_two_changes_counts_one_task() {
  "$TASK" backup >/dev/null
  write_task_file 00_backlog T-0001 "First thing"
  printf '/x\n' > "$AGENT_TASKS_HOME/work/.projects/api"
  "$TASK" backup >/dev/null
  assert_eq "$(last_subject)" "tasks: 2 changes in 1 task"
}

test_store_stale_lock_is_removed() {
  "$TASK" backup >/dev/null
  mkdir "$AGENT_TASKS_HOME/.lock"
  echo 999999 > "$AGENT_TASKS_HOME/.lock/pid"
  assert_eq "$("$TASK" backup)" "nothing to back up"
}

test_store_live_lock_times_out() {
  "$TASK" backup >/dev/null
  sleep 30 &
  local holder=$! out rc=0
  mkdir "$AGENT_TASKS_HOME/.lock"
  echo "$holder" > "$AGENT_TASKS_HOME/.lock/pid"
  out="$(AGENT_TASKS_LOCK_TIMEOUT=1 "$TASK" backup 2>&1)" || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  assert_eq "$rc" 1
  assert_contains "$out" "store is locked by pid $holder"
}

test_store_lock_released_after_command() {
  "$TASK" backup >/dev/null
  assert_no_file "$AGENT_TASKS_HOME/.lock"
  "$TASK" frobnicate >/dev/null 2>&1 || true
  assert_no_file "$AGENT_TASKS_HOME/.lock"
}

test_store_lock_released_on_failure() {
  "$TASK" backup >/dev/null
  git config --global --unset user.email
  git config --global user.useConfigOnly true
  write_task_file 00_backlog T-0001 "First thing"
  local out rc=0
  out="$("$TASK" backup 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "user.email"
  assert_no_file "$AGENT_TASKS_HOME/.lock"
}

test_store_config_get() {
  "$TASK" backup >/dev/null
  printf 'default_workspace = "home"   # comment\nmax_active = 5\n' > "$AGENT_TASKS_HOME/config.toml"
  "$TASK" backup >/dev/null
  [ -d "$AGENT_TASKS_HOME/home/00_backlog" ] || fail "default_workspace not honoured"
}

# Several waiters see the same dead holder at once. With a plain "rm -rf and
# retry" the second rm deletes the first waiter's fresh lock and two of them
# enter the critical section, so the read-modify-write below loses updates.
test_store_lock_stale_steal_is_exclusive() {
  export AGENT_TASKS_LOCK_TIMEOUT=30
  "$TASK" backup >/dev/null
  local round i ids
  for round in 1 2 3; do
    mkdir "$AGENT_TASKS_HOME/.lock"
    echo 999999 > "$AGENT_TASKS_HOME/.lock/pid"
    for i in 1 2 3 4 5 6 7 8; do
      "$TASK" new "Steal $round $i" >/dev/null 2>&1 &
    done
    wait
    assert_no_file "$AGENT_TASKS_HOME/.lock"
    assert_no_file "$AGENT_TASKS_HOME/.lock.steal"
  done
  # two holders in the critical section would hand out the same id twice
  ids="$(find "$AGENT_TASKS_HOME/work" -name 'T-*.md' | sed 's/.*\/\(T-[0-9]*\).*/\1/' | LC_ALL=C sort | uniq -d)"
  assert_eq "$ids" ""
  assert_eq "$(find "$AGENT_TASKS_HOME/work" -name 'T-*.md' | wc -l | tr -d ' ')" 24
}

test_store_lock_steal_dir_is_ignored_by_git() {
  "$TASK" backup >/dev/null
  assert_contains "$(cat "$AGENT_TASKS_HOME/.gitignore")" ".lock.steal/"
}

test_store_old_steal_dir_does_not_wedge() {
  "$TASK" backup >/dev/null
  mkdir "$AGENT_TASKS_HOME/.lock" "$AGENT_TASKS_HOME/.lock.steal"
  echo 999999 > "$AGENT_TASKS_HOME/.lock/pid"
  touch -t 202001010000 "$AGENT_TASKS_HOME/.lock.steal"
  assert_eq "$(AGENT_TASKS_LOCK_TIMEOUT=3 "$TASK" backup)" "nothing to back up"
  assert_no_file "$AGENT_TASKS_HOME/.lock.steal"
}

test_store_init_prints_no_branch_hint() {
  local out
  git config --global --unset init.defaultBranch
  out="$("$TASK" backup 2>&1)"
  assert_eq "$out" "nothing to back up"
}

test_store_backup_rename_with_rewritten_body() {
  write_task_file 09_finishing T-0001 "Short"
  "$TASK" backup >/dev/null
  local src dest
  src="$(task_path_of T-0001)"
  dest="$AGENT_TASKS_HOME/work/11_done/$(basename "$src")"
  printf -- '---\nid: T-0001\ntitle: "Short"\ncreated: 2026-10-01\nresult: pr\n---\n\n## Result\n\nCompletely different text here, nothing alike.\n\n## Log\n- 2026-10-02 10:00 task: done\n' > "$dest"
  rm "$src"
  "$TASK" backup >/dev/null
  assert_eq "$(last_subject)" "tasks(work): T-0001 09_finishing → 11_done"
}

test_store_backup_delete_add_same_folder_is_edit() {
  write_task_file 00_backlog T-0001 "Short"
  "$TASK" backup >/dev/null
  local f
  f="$(task_path_of T-0001)"
  rm "$f"
  printf -- '---\nid: T-0001\ntitle: "Short"\ncreated: 2026-10-01\n---\n\nTotally new body, quite unlike the old one.\nMore lines.\n\n## Log\n- 2026-10-02 10:00 x: y\n' > "$AGENT_TASKS_HOME/work/00_backlog/T-0001-other.md"
  "$TASK" backup >/dev/null
  assert_eq "$(last_subject)" "tasks(work): T-0001 edit"
}

test_store_backup_fails_loudly_when_git_add_fails() {
  "$TASK" backup >/dev/null
  touch "$AGENT_TASKS_HOME/.git/index.lock"
  printf 'x\n' > "$AGENT_TASKS_HOME/notes.txt"
  local out rc=0
  out="$("$TASK" backup 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "git add failed"
  assert_not_contains "$out" "nothing to back up"
}

test_store_commit_body_lists_entries_without_workspace() {
  "$TASK" backup >/dev/null
  printf 'x\n' > "$AGENT_TASKS_HOME/notes.txt"
  write_task_file 00_backlog T-0001 "One"
  "$TASK" backup >/dev/null
  local body
  body="$(git -C "$AGENT_TASKS_HOME" log -1 --format=%b)"
  assert_contains "$body" "- work: T-0001 new"
  assert_contains "$body" "- add notes.txt"
  assert_not_contains "$body" "- add notes.txt:"
}
