# shellcheck shell=bash
# scripts/migrate-folders.sh: stage-1 folders → two-digit folders with planning stages.

MIGRATE="$ROOT/scripts/migrate-folders.sh"

# A committed store in the OLD layout, built by hand (the CLI only knows the new one).
mf_old_store() {
  local s="$AGENT_TASKS_HOME" fo
  mkdir -p "$s"
  git -C "$s" init -q
  printf '.auto\n.lock/\n.lock.steal/\n.notify/\n*.tmp\n' > "$s/.gitignore"
  printf 'default_workspace = "work"\n' > "$s/config.toml"
  for fo in 0_backlog 1_ready 2_exploring 3_brainstorming 4_spec_review 5_approved 6_implementing 7_finishing 8_done blocked; do
    mkdir -p "$s/work/$fo"
  done
  write_task_file 0_backlog T-0001 "Backlog one"
  write_task_file 1_ready T-0002 "Ready one"
  write_task_file 2_exploring T-0003 "Exploring one"
  write_task_file 3_brainstorming T-0004 "Brainstorming one"
  write_task_file 4_spec_review T-0005 "Spec one"
  write_task_file 5_approved T-0006 "Approved one"
  write_task_file 6_implementing T-0007 "No plan yet"
  write_task_file 6_implementing T-0008 "Has a plan"
  mf_add_field "$(task_path_of T-0008)" "plan: docs/superpowers/plans/x.md"
  write_task_file 7_finishing T-0009 "Finishing one"
  write_task_file 8_done T-0010 "Done one"
  write_task_file blocked T-0011 "Blocked from impl, no plan"
  mf_add_field "$(task_path_of T-0011)" "blocked_from: 6_implementing"
  write_task_file blocked T-0012 "Blocked from impl, plan"
  mf_add_field "$(task_path_of T-0012)" "plan: docs/superpowers/plans/y.md"
  mf_add_field "$(task_path_of T-0012)" "blocked_from: 6_implementing"
  write_task_file blocked T-0013 "Blocked from approved"
  mf_add_field "$(task_path_of T-0013)" "blocked_from: 5_approved"
  write_task_file blocked T-0014 "Blocked from brainstorming"
  mf_add_field "$(task_path_of T-0014)" "blocked_from: 3_brainstorming"
  git -C "$s" add -A
  git -C "$s" commit -q -m "old layout"
}

# Adds a frontmatter line right before the closing `---`.
mf_add_field() {   # mf_add_field <file> <line>
  MF_LINE="$2" awk 'NR > 1 && $0 == "---" && !d { print ENVIRON["MF_LINE"]; d = 1 } { print }' "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

mf_folder_of() { basename "$(dirname "$(task_path_of "$1")")"; }

test_migrate_folders_dry_run_changes_nothing() {
  mf_old_store
  local before out
  before="$(git -C "$AGENT_TASKS_HOME" rev-parse HEAD)"
  out="$("$MIGRATE" --dry-run)"
  assert_contains "$out" "dry run"
  assert_contains "$out" "T-0007: work/6_implementing → work/05_planning"
  assert_contains "$out" "T-0008: work/6_implementing → work/08_implementing"
  assert_contains "$out" "T-0006: work/5_approved → work/07_approved"
  assert_contains "$out" "T-0011: work/blocked blocked_from 6_implementing → 05_planning"
  assert_eq "$(git -C "$AGENT_TASKS_HOME" rev-parse HEAD)" "$before"
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
  [ -d "$AGENT_TASKS_HOME/work/6_implementing" ] || fail "old folder removed by --dry-run"
  [ ! -d "$AGENT_TASKS_HOME/work/05_planning" ] || fail "new folder created by --dry-run"
}

test_migrate_folders_moves_and_maps() {
  mf_old_store
  local out s="$AGENT_TASKS_HOME"
  out="$("$MIGRATE")"
  assert_contains "$out" "migrated:"
  assert_eq "$(mf_folder_of T-0001)" 00_backlog
  assert_eq "$(mf_folder_of T-0002)" 01_ready
  assert_eq "$(mf_folder_of T-0003)" 02_exploring
  assert_eq "$(mf_folder_of T-0004)" 03_brainstorming
  assert_eq "$(mf_folder_of T-0005)" 04_spec_review
  assert_eq "$(mf_folder_of T-0006)" 07_approved
  assert_eq "$(mf_folder_of T-0007)" 05_planning
  assert_eq "$(mf_folder_of T-0008)" 08_implementing
  assert_eq "$(mf_folder_of T-0009)" 09_finishing
  assert_eq "$(mf_folder_of T-0010)" 11_done
  assert_eq "$(mf_folder_of T-0011)" blocked
  # blocked_from follows the same mapping, including the plan rule.
  assert_contains "$(cat "$(task_path_of T-0011)")" "blocked_from: 05_planning"
  assert_contains "$(cat "$(task_path_of T-0012)")" "blocked_from: 08_implementing"
  assert_contains "$(cat "$(task_path_of T-0013)")" "blocked_from: 07_approved"
  assert_contains "$(cat "$(task_path_of T-0014)")" "blocked_from: 03_brainstorming"
  # One log line for tasks that came from 6_implementing, none for the others.
  assert_contains "$(tail -n 1 "$(task_path_of T-0007)")" "task: folder layout migration: 6_implementing → 05_planning"
  assert_contains "$(tail -n 1 "$(task_path_of T-0008)")" "task: folder layout migration: 6_implementing → 08_implementing"
  assert_contains "$(tail -n 1 "$(task_path_of T-0006)")" "task: created in 5_approved"
  # Old folders are gone, every new one exists, one commit, store clean.
  local fo
  for fo in 0_backlog 1_ready 2_exploring 3_brainstorming 4_spec_review 5_approved 6_implementing 7_finishing 8_done; do
    [ ! -d "$s/work/$fo" ] || fail "old folder $fo still exists"
  done
  for fo in $FOLDERS_NEW; do
    [ -d "$s/work/$fo" ] || fail "missing new folder $fo"
  done
  assert_eq "$(git -C "$s" rev-list --count HEAD)" 2
  assert_eq "$(last_subject)" "tasks: migrate to two-digit folders with planning stages"
  assert_eq "$(git -C "$s" status --porcelain)" ""
  # git sees the moves as renames.
  assert_contains "$(git -C "$s" show --name-status -M --format= HEAD | grep T-0001)" "R"
  # The summary counts per folder.
  assert_contains "$out" "6_implementing   → 05_planning      1"
  assert_contains "$out" "6_implementing   → 08_implementing  1"
  # The migrated store works with the CLI.
  assert_eq "$("$TASK" ls --json | jq length)" 14
  assert_eq "$("$TASK" doctor 2>&1 | tail -n 1 | grep -c 'without session' || true)" 0
}

FOLDERS_NEW="00_backlog 01_ready 02_exploring 03_brainstorming 04_spec_review 05_planning 06_plan_review 07_approved 08_implementing 09_finishing 10_unmerged 11_done blocked postponed archive"

test_migrate_folders_is_idempotent() {
  mf_old_store
  "$MIGRATE" >/dev/null
  local head out
  head="$(git -C "$AGENT_TASKS_HOME" rev-parse HEAD)"
  out="$("$MIGRATE")"
  assert_contains "$out" "nothing to migrate"
  assert_eq "$(git -C "$AGENT_TASKS_HOME" rev-parse HEAD)" "$head"
  out="$("$MIGRATE" --dry-run)"
  assert_contains "$out" "nothing to migrate"
}

test_migrate_folders_refuses_with_auto_or_dirty_store() {
  mf_old_store
  local out rc=0 s="$AGENT_TASKS_HOME"
  printf 'until=9999999999\nsince=1\n' > "$s/.auto"
  out="$("$MIGRATE" 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "task auto off"
  [ -d "$s/work/6_implementing" ] || fail "store changed despite .auto"
  rm -f "$s/.auto"
  echo "edit" >> "$(task_path_of T-0001)"
  rc=0; out="$("$MIGRATE" 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "uncommitted changes"
  assert_eq "$(mf_folder_of T-0001)" 0_backlog
  rc=0; out="$("$MIGRATE" --bogus 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: migrate-folders.sh [--dry-run]"
}
