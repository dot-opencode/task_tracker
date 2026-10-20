# shellcheck shell=bash
# Archive: done tasks leave the view after archive_after_days.

# ar_done <id> <created> [<log line>...] — a task in 11_done with the given log lines.
ar_done() {
  local id="$1" created="$2" f
  shift 2
  if [ ! -d "$AGENT_TASKS_HOME/.git" ]; then "$TASK" ls >/dev/null; fi
  write_task_file 11_done "$id" "Task $id"
  f="$(task_path_of "$id")"
  sed -i.bak "s/^created: .*/created: $created/" "$f"; rm -f "$f.bak"
  # Drop the default log line; the given ones replace it.
  grep -v '^- 2026-10-01 09:00 task: created' "$f" > "$f.tmp"; mv "$f.tmp" "$f"
  local l
  for l in "$@"; do printf -- '- %s\n' "$l" >> "$f"; done
  git -C "$AGENT_TASKS_HOME" add -A
  git -C "$AGENT_TASKS_HOME" commit -q -m "test: $id"
}

ar_folder() { basename "$(dirname "$(task_path_of "$1")")"; }
ar_commits() { git -C "$AGENT_TASKS_HOME" rev-list --count HEAD; }

test_archive_age_uses_last_real_entry() {
  # Import line is fresh, the real entry is old: archives.
  ar_done T-0001 2026-01-01 "2026-01-05 10:00 task: result: pr" "2026-10-01 12:00 task: imported from ai_task_tracker (status done)"
  # Migration line is fresh, real entry old.
  ar_done T-0002 2026-01-01 "2026-01-05 10:00 task: result: pr" "2026-10-01 12:00 task: folder layout migration: 8_done → 11_done"
  # A recent real entry wins over the old ones.
  ar_done T-0003 2026-01-01 "2026-01-05 10:00 task: result: pr" "2026-10-01 12:00 task: reopened note"
  local out
  out="$(AGENT_TASKS_NOW="2026-10-02 00:00" "$TASK" archive --due)"
  assert_eq "$out" "archived 2 task(s)"
  assert_eq "$(ar_folder T-0001)" archive
  assert_eq "$(ar_folder T-0002)" archive
  assert_eq "$(ar_folder T-0003)" 11_done
}

test_archive_age_falls_back_to_created() {
  ar_done T-0001 2026-01-01 "2026-10-01 12:00 task: imported from ai_task_tracker (status done)"
  ar_done T-0002 2026-09-30
  AGENT_TASKS_NOW="2026-10-02 00:00" "$TASK" archive --due >/dev/null
  assert_eq "$(ar_folder T-0001)" archive
  assert_eq "$(ar_folder T-0002)" 11_done
}

test_archive_threshold_boundary() {
  ar_done T-0001 2026-09-01 "2026-09-18 10:00 task: result: pr"   # 13 days at now
  ar_done T-0002 2026-09-01 "2026-09-17 10:00 task: result: pr"   # 14 days at now
  AGENT_TASKS_NOW="2026-10-01 10:00" "$TASK" archive --due >/dev/null
  assert_eq "$(ar_folder T-0001)" 11_done
  assert_eq "$(ar_folder T-0002)" archive
  assert_contains "$(cat "$(task_path_of T-0002)")" "task: 11_done → archive — archived after 14 days in done"
}

test_archive_after_days_config() {
  ar_done T-0001 2026-01-01 "2026-01-05 10:00 task: result: pr"
  printf 'archive_after_days = 0\n' >> "$AGENT_TASKS_HOME/config.toml"
  git -C "$AGENT_TASKS_HOME" add -A; git -C "$AGENT_TASKS_HOME" commit -q -m cfg
  local n; n="$(ar_commits)"
  assert_eq "$("$TASK" archive --due)" "nothing to archive"
  assert_eq "$(ar_folder T-0001)" 11_done
  sed -i.bak 's/^archive_after_days = 0/archive_after_days = 400/' "$AGENT_TASKS_HOME/config.toml"; rm -f "$AGENT_TASKS_HOME/config.toml.bak"
  assert_eq "$("$TASK" archive --due)" "nothing to archive"
  sed -i.bak 's/^archive_after_days = 400/archive_after_days = 1/' "$AGENT_TASKS_HOME/config.toml"; rm -f "$AGENT_TASKS_HOME/config.toml.bak"
  assert_eq "$("$TASK" archive --due)" "archived 1 task(s)"
}

test_archive_default_config_has_key_and_default_applies() {
  "$TASK" ls >/dev/null
  assert_contains "$(cat "$AGENT_TASKS_HOME/config.toml")" "archive_after_days = 14"
  ar_done T-0001 2026-01-01 "2026-01-05 10:00 task: result: pr"
  grep -v archive_after_days "$AGENT_TASKS_HOME/config.toml" > "$TMP/c"; cp "$TMP/c" "$AGENT_TASKS_HOME/config.toml"
  assert_eq "$("$TASK" archive --due)" "archived 1 task(s)"
}

test_archive_commit_messages() {
  ar_done T-0001 2026-01-01 "2026-01-05 10:00 task: result: pr"
  "$TASK" archive --due >/dev/null
  assert_eq "$(last_subject)" "tasks(work): T-0001 11_done → archive"
  ar_done T-0002 2026-01-01 "2026-01-05 10:00 task: result: pr"
  ar_done T-0003 2026-01-01 "2026-01-05 10:00 task: result: pr"
  local n; n="$(ar_commits)"
  assert_eq "$("$TASK" archive --due)" "archived 2 task(s)"
  assert_eq "$(ar_commits)" "$((n + 1))"
  assert_eq "$(last_subject)" "tasks: 2 changes in 2 tasks"
}

test_archive_due_is_silent_and_commitless_when_nothing_due() {
  ar_done T-0001 2026-10-01
  local n out; n="$(ar_commits)"
  out="$("$TASK" archive --due)"
  assert_eq "$out" "nothing to archive"
  assert_eq "$(ar_commits)" "$n"
  assert_no_file "$AGENT_TASKS_HOME/.lock"
}

test_ls_triggers_archive_and_json_stays_pure() {
  ar_done T-0001 2026-01-01 "2026-01-05 10:00 task: result: pr"
  local out err
  out="$("$TASK" ls --json 2>"$TMP/err")"
  err="$(cat "$TMP/err")"
  assert_eq "$err" "archived 1 task(s)"
  assert_eq "$(printf '%s' "$out" | jq length)" 0
  assert_eq "$(ar_folder T-0001)" archive
  ar_done T-0002 2026-01-01 "2026-01-05 10:00 task: result: pr"
  out="$("$TASK" ls 2>"$TMP/err")"
  assert_contains "$(cat "$TMP/err")" "archived 1 task(s)"
  assert_not_contains "$out" "archived"
  assert_eq "$(ar_folder T-0002)" archive
}

test_run_once_archives_without_auto() {
  at_stubs
  ar_done T-0001 2026-01-01 "2026-01-05 10:00 task: result: pr"
  local out
  out="$("$TASK" run --once 2>&1)"
  assert_contains "$out" "archived 1 task(s)"
  assert_eq "$(ar_folder T-0001)" archive
  assert_eq "$(cat "$TMP/opencode.log")" ""
}

test_run_once_archives_with_auto() {
  at_stubs
  ar_done T-0001 2026-01-01 "2026-01-05 10:00 task: result: pr"
  at_auto_on
  "$TASK" run --once >/dev/null 2>&1 || true
  assert_eq "$(ar_folder T-0001)" archive
}

test_archive_and_unarchive_commands() {
  ar_done T-0001 2026-10-01 "2026-10-01 10:00 task: result: pr"
  write_task_file 01_ready T-0002 "Ready one"
  git -C "$AGENT_TASKS_HOME" add -A; git -C "$AGENT_TASKS_HOME" commit -q -m "test: T-0002"
  assert_eq "$("$TASK" archive 1)" "T-0001: 11_done → archive"
  assert_eq "$(ar_folder T-0001)" archive
  assert_eq "$(last_subject)" "tasks(work): T-0001 11_done → archive"
  local out
  out="$("$TASK" archive 2 2>&1)" && fail "archive of a ready task succeeded"
  assert_eq "$out" "task: T-0002 is in 01_ready; only done tasks can be archived"
  out="$("$TASK" unarchive 2 2>&1)" && fail "unarchive of a ready task succeeded"
  assert_contains "$out" "T-0002 is in 01_ready"
  assert_eq "$("$TASK" unarchive 1)" "T-0001: archive → 11_done"
  assert_eq "$(ar_folder T-0001)" 11_done
  assert_contains "$(cat "$(task_path_of T-0001)")" "archive → 11_done — unarchived"
}

test_unarchive_restarts_done_age() {
  ar_done T-0001 2026-01-01 "2026-01-05 10:00 task: result: pr"
  "$TASK" archive --due >/dev/null
  assert_eq "$(ar_folder T-0001)" archive
  AGENT_TASKS_NOW="2026-10-01 10:00" "$TASK" unarchive T-0001 >/dev/null
  # `unarchived` is logged with the real clock; compare at that moment.
  local day; day="$(date +%Y-%m-%d)"
  assert_eq "$(AGENT_TASKS_NOW="$day 23:59" "$TASK" archive --due)" "nothing to archive"
  assert_eq "$(ar_folder T-0001)" 11_done
}

test_ls_views_exclude_and_include_archive() {
  ar_done T-0001 2026-10-01 "2026-10-01 10:00 task: result: pr"
  ar_done T-0002 2026-10-01 "2026-10-01 10:00 task: result: pr"
  write_task_file 01_ready T-0003 "Ready one"
  "$TASK" archive 2 >/dev/null
  local out
  out="$("$TASK" ls)"
  assert_contains "$out" "T-0003"
  assert_contains "$out" "T-0001"
  assert_not_contains "$out" "T-0002"
  assert_not_contains "$out" "more (task ls done)"
  assert_contains "$out" "archive: 1 (task ls archive)"
  out="$("$TASK" ls "done")"
  assert_contains "$out" "T-0001"
  assert_not_contains "$out" "T-0002"
  out="$("$TASK" ls archive)"
  assert_contains "$out" "T-0002"
  assert_contains "$out" "archive"
  assert_not_contains "$out" "T-0001"
  assert_contains "$("$TASK" ls --all)" "T-0002"
  assert_eq "$("$TASK" ls --json --all | jq -r '.[] | select(.id == "T-0002") | .status')" archive
  "$TASK" unarchive 2 >/dev/null
  "$TASK" archive 1 >/dev/null
  "$TASK" archive 2 >/dev/null
  assert_not_contains "$("$TASK" ls)" "11_done:"
}

test_doctor_ok_with_archived_tasks() {
  ar_done T-0001 2026-10-01 "2026-10-01 10:00 task: result: pr"
  "$TASK" archive 1 >/dev/null
  "$TASK" doctor >/dev/null || fail "doctor failed: $("$TASK" doctor 2>&1)"
}

test_ensure_workspace_creates_archive() {
  "$TASK" ls >/dev/null
  [ -d "$AGENT_TASKS_HOME/work/archive" ] || fail "no work/archive"
  rmdir "$AGENT_TASKS_HOME/work/archive"
  "$TASK" ls >/dev/null
  [ -d "$AGENT_TASKS_HOME/work/archive" ] || fail "archive not recreated"
  assert_eq "$("$TASK" mv 1 archive 2>&1 | head -1)" "task: no task T-0001"
}

test_archive_import_marked_archived_goes_at_once() {
  ar_done T-0001 2026-10-01 "2026-10-01 18:20 task: imported from ai_task_tracker (status DONE, archived)" "2026-10-01 20:00 task: note"
  ar_done T-0002 2026-10-01 "2026-10-01 18:20 task: imported from ai_task_tracker (status DONE)" "2026-10-01 20:00 task: note"
  ar_done T-0003 2026-10-01 "2026-10-01 18:20 task: imported from ai_task_tracker (status DONE, archived, tags: BLOCKED)"
  ar_done T-0004 2026-10-01 "2026-10-01 18:20 task: imported from ai_task_tracker (status DONE, tags: BLOCKED)"
  ar_done T-0005 2026-10-01 "2026-10-01 18:20 task: imported from ai_task_tracker (status TO_DO, archived)"
  assert_eq "$("$TASK" archive --due)" "archived 3 task(s)"
  assert_eq "$(ar_folder T-0001)" archive
  assert_eq "$(ar_folder T-0002)" 11_done
  assert_eq "$(ar_folder T-0003)" archive
  assert_eq "$(ar_folder T-0004)" 11_done
  assert_eq "$(ar_folder T-0005)" archive
  assert_contains "$(cat "$(task_path_of T-0001)")" "archived (already archived in ai_task_tracker)"
}

test_archive_zero_days_disables_import_rule_too() {
  ar_done T-0001 2026-10-01 "2026-10-01 18:20 task: imported from ai_task_tracker (status DONE, archived)"
  printf 'archive_after_days = 0\n' >> "$AGENT_TASKS_HOME/config.toml"
  assert_eq "$("$TASK" archive --due)" "nothing to archive"
  assert_eq "$(ar_folder T-0001)" 11_done
}
