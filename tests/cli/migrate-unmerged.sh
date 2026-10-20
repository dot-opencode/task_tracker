# shellcheck shell=bash
# scripts/migrate-unmerged.sh: 10_done → 11_done, recent pr/kept tasks → 10_unmerged.

MU="$ROOT/scripts/migrate-unmerged.sh"

# mu_task <folder> <id> <result> <log date> [<extra frontmatter line>]
mu_task() {
  local fo="$1" id="$2" res="$3" date="$4" extra="${5:-}" d="$AGENT_TASKS_HOME/work/$1"
  mkdir -p "$d"
  {
    printf -- '---\nid: %s\ntitle: "%s"\ncreated: 2026-01-01\n' "$id" "$id"
    if [ -n "$res" ]; then printf 'result: %s\n' "$res"; fi
    if [ -n "$extra" ]; then printf '%s\n' "$extra"; fi
    printf -- '---\n\n## Log\n- %s 10:00 task: result: %s\n' "$date" "${res:-none}"
  } > "$d/$id.md"
}

mu_store() {
  local s="$AGENT_TASKS_HOME" fo
  mkdir -p "$s"
  git -C "$s" init -q
  printf '.auto\n.lock/\n.lock.steal/\n.notify/\n*.tmp\n' > "$s/.gitignore"
  printf 'default_workspace = "work"\n' > "$s/config.toml"
  for fo in 00_backlog 10_done blocked postponed; do mkdir -p "$s/work/$fo"; done
  mu_task 10_done T-0001 pr 2026-09-28
  mu_task 10_done T-0002 kept 2026-09-30
  mu_task 10_done T-0003 pr 2026-06-01
  mu_task 10_done T-0004 merged 2026-09-30
  mu_task postponed T-0005 "" 2026-09-01 "postponed_from: 10_done"
  mu_task blocked T-0006 "" 2026-09-01 "blocked_from: 10_done"
  git -C "$s" add -A
  git -C "$s" commit -q -m "old"
}

mu_folder() { basename "$(dirname "$(task_path_of "$1")")"; }

test_migrate_unmerged_moves_and_maps() {
  mu_store
  local out s="$AGENT_TASKS_HOME" fo
  out="$(AGENT_TASKS_NOW="2026-10-02 00:00" "$MU" --dry-run)"
  assert_contains "$out" "T-0001: work/10_done → work/10_unmerged (result pr)"
  assert_eq "$(git -C "$s" status --porcelain)" ""
  out="$(AGENT_TASKS_NOW="2026-10-02 00:00" "$MU")"
  assert_contains "$out" "migrated:"
  assert_eq "$(mu_folder T-0001)" 10_unmerged
  assert_eq "$(mu_folder T-0002)" 10_unmerged
  assert_eq "$(mu_folder T-0003)" 11_done
  assert_eq "$(mu_folder T-0004)" 11_done
  assert_contains "$(tail -n 1 "$(task_path_of T-0001)")" "task: folder layout migration: 10_done → 10_unmerged (result pr)"
  assert_contains "$(cat "$(task_path_of T-0005)")" "postponed_from: 11_done"
  assert_contains "$(cat "$(task_path_of T-0006)")" "blocked_from: 11_done"
  [ ! -d "$s/work/10_done" ] || fail "10_done still exists"
  for fo in 10_unmerged 11_done archive; do [ -d "$s/work/$fo" ] || fail "missing $fo"; done
  assert_eq "$(last_subject)" "tasks: add unmerged stage"
  assert_eq "$(git -C "$s" status --porcelain)" ""
  # Idempotent.
  local head
  head="$(git -C "$s" rev-parse HEAD)"
  assert_contains "$("$MU")" "nothing to migrate"
  assert_eq "$(git -C "$s" rev-parse HEAD)" "$head"
}

test_migrate_unmerged_refuses_with_auto_or_dirty_store() {
  mu_store
  local out rc=0
  : > "$AGENT_TASKS_HOME/.auto"
  out="$("$MU" 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "automation is on"
  rm -f "$AGENT_TASKS_HOME/.auto"
  echo x > "$AGENT_TASKS_HOME/work/00_backlog/stray.md"
  rc=0; out="$("$MU" 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "uncommitted changes"
}
