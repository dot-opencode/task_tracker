# shellcheck shell=bash
# shellcheck disable=SC1010 # "done" is the CLI subcommand here, not the keyword
# Task 5: changing tasks.

new_task() {   # new_task <title> [args...]  — prints the id
  "$TASK" new "$@"
}

test_edit_mv_moves_logs_and_commits() {
  new_task "Movable" >/dev/null
  local out f
  out="$("$TASK" mv T-0001 01_ready)"
  assert_eq "$out" "T-0001: 00_backlog → 01_ready"
  f="$(task_path_of T-0001)"
  assert_contains "$f" "/work/01_ready/T-0001-movable.md"
  assert_no_file "$AGENT_TASKS_HOME/work/00_backlog/T-0001-movable.md"
  assert_contains "$(tail -n 1 "$f")" " task: 00_backlog → 01_ready"
  assert_eq "$(last_subject)" "tasks(work): T-0001 00_backlog → 01_ready"
}

test_edit_mv_short_names_and_reason() {
  new_task "Movable" >/dev/null
  "$TASK" mv 1 spec_review --reason "spec written" >/dev/null
  assert_contains "$(task_path_of T-0001)" "/04_spec_review/"
  assert_contains "$(tail -n 1 "$(task_path_of T-0001)")" "task: 00_backlog → 04_spec_review — spec written"
  "$TASK" mv t-1 3 >/dev/null
  assert_contains "$(task_path_of T-0001)" "/03_brainstorming/"
  "$TASK" mv 1 blocked --reason "waiting" >/dev/null
  assert_contains "$(task_path_of T-0001)" "/work/blocked/"
}

test_edit_mv_same_folder_is_noop() {
  new_task "Stay" >/dev/null
  local before out
  before="$(git -C "$AGENT_TASKS_HOME" rev-list --count HEAD)"
  out="$("$TASK" mv 1 backlog)"
  assert_eq "$out" "T-0001 is already in 00_backlog"
  assert_eq "$(git -C "$AGENT_TASKS_HOME" rev-list --count HEAD)" "$before"
}

test_edit_mv_unknown_folder() {
  new_task "X" >/dev/null
  local out rc=0
  out="$("$TASK" mv 1 nowhere 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown folder 'nowhere'"
  assert_contains "$out" "00_backlog"
  assert_contains "$out" "blocked"
}

test_edit_mv_blocked_from_in_and_out() {
  new_task "Blockable" >/dev/null
  "$TASK" mv 1 08_implementing >/dev/null
  "$TASK" mv 1 blocked >/dev/null
  assert_contains "$(cat "$(task_path_of T-0001)")" "blocked_from: 08_implementing"
  "$TASK" mv 1 08_implementing >/dev/null
  assert_not_contains "$(cat "$(task_path_of T-0001)")" "blocked_from"
}

test_edit_mv_refuses_existing_destination() {
  write_task_file 00_backlog T-0001 "Same name"
  write_task_file 01_ready T-0001 "Same name"
  local out rc=0
  out="$("$TASK" mv 1 01_ready 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "duplicate task id"
}

test_edit_log_line_and_output() {
  new_task "Logged" >/dev/null
  local out
  out="$("$TASK" log 1 "Decided to use X")"
  assert_eq "$out" "T-0001: logged"
  case "$(tail -n 1 "$(task_path_of T-0001)")" in
    "- "[0-9][0-9][0-9][0-9]"-"[0-9][0-9]"-"[0-9][0-9]" "[0-9][0-9]":"[0-9][0-9]" agent: Decided to use X") ;;
    *) fail "bad log line" ;;
  esac
  assert_eq "$(last_subject)" "tasks(work): T-0001 log"
}

test_edit_log_multiline_from_stdin_and_author() {
  new_task "Logged" >/dev/null
  printf 'first\nsecond\n\nfourth\n' | "$TASK" log 1 - --author human >/dev/null
  assert_eq "$(tail -n 4 "$(task_path_of T-0001)" | sed 's/^- [0-9-]* [0-9:]* //')" "$(printf 'human: first\n  second\n  \n  fourth')"
}

test_edit_log_rejects_bad_input() {
  new_task "Logged" >/dev/null
  local out rc=0
  out="$("$TASK" log 1 "   " 2>&1)" || rc=$?
  assert_eq "$rc" 1
  rc=0; out="$("$TASK" log 1 "x" --author "a:b" 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "':'"
  rc=0; out="$("$TASK" log 1 "x" --author "" 2>&1)" || rc=$?
  assert_eq "$rc" 1
  rc=0; out="$("$TASK" log 1 2>&1)" || rc=$?
  assert_eq "$rc" 1
}

test_edit_log_works_without_log_section() {
  write_task_file 00_backlog T-0001 "Bare"
  local f
  f="$(task_path_of T-0001)"
  printf -- '---\nid: T-0001\ntitle: "Bare"\ncreated: 2026-10-01\n---\n\nbody' > "$f"
  "$TASK" log 1 "note" >/dev/null
  assert_eq "$(sed -n '7,8p' "$f")" "$(printf 'body\n')"
  assert_contains "$(cat "$f")" "## Log"
  assert_contains "$(tail -n 1 "$f")" "agent: note"
}

test_edit_set_each_key() {
  mkdir -p "$TMP/code/api"
  "$TASK" project add api "$TMP/code/api" >/dev/null
  new_task "Settable" >/dev/null
  local out f
  f="$(task_path_of T-0001)"
  assert_eq "$("$TASK" set 1 title 'New "title"')" 'T-0001: title = New "title"'
  assert_contains "$(cat "$f")" 'title: "New \"title\""'
  "$TASK" set 1 project api >/dev/null
  "$TASK" set 1 source https://x.example/1 >/dev/null
  "$TASK" set 1 session ses_abc123 >/dev/null
  "$TASK" set 1 spec docs/superpowers/specs/a-design.md >/dev/null
  "$TASK" set 1 plan docs/superpowers/plans/a.md >/dev/null
  "$TASK" set 1 pr https://github.com/o/r/pull/1 >/dev/null
  "$TASK" set 1 result merged >/dev/null
  out="$(cat "$f")"
  assert_contains "$out" "project: api"
  assert_contains "$out" "source: https://x.example/1"
  assert_contains "$out" "session: ses_abc123"
  assert_contains "$out" "spec: docs/superpowers/specs/a-design.md"
  assert_contains "$out" "plan: docs/superpowers/plans/a.md"
  assert_contains "$out" "pr: https://github.com/o/r/pull/1"
  assert_contains "$out" "result: merged"
  # New keys must land inside the frontmatter, before the closing ---.
  assert_eq "$(awk '/^---$/ { n++ } n == 1 && /^result:/ { print "inside" }' "$f")" "inside"
  assert_eq "$(last_subject)" "tasks(work): T-0001 edit"
}

test_edit_set_replaces_existing_value_once() {
  new_task "Settable" >/dev/null
  "$TASK" set 1 source https://a.example >/dev/null
  "$TASK" set 1 source https://b.example >/dev/null
  assert_eq "$(grep -c '^source:' "$(task_path_of T-0001)")" 1
  assert_contains "$(cat "$(task_path_of T-0001)")" "source: https://b.example"
}

test_edit_set_rejects_bad_input() {
  new_task "Settable" >/dev/null
  local out rc=0
  out="$("$TASK" set 1 bogus x 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "cannot set 'bogus'"
  rc=0; out="$("$TASK" set 1 url https://example.invalid/mr/1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "pr (MR/PR)"
  rc=0; out="$("$TASK" set 1 source "  " 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "task unset"
  rc=0; out="$("$TASK" set 1 source $'a\nb' 2>&1)" || rc=$?
  assert_eq "$rc" 1
  rc=0; out="$("$TASK" set 1 project ghost 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown project 'ghost'"
  rc=0; out="$("$TASK" set 1 result won 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid result"
  rc=0; out="$("$TASK" set 1 session notasession 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid session id"
  rc=0; out="$("$TASK" set 1 id T-0009 2>&1)" || rc=$?
  assert_eq "$rc" 1
}

test_edit_unset() {
  new_task "Unsettable" --source https://a.example >/dev/null
  local out
  out="$("$TASK" unset 1 source)"
  assert_eq "$out" "T-0001: source removed"
  assert_not_contains "$(cat "$(task_path_of T-0001)")" "source:"
  local before
  before="$(git -C "$AGENT_TASKS_HOME" rev-list --count HEAD)"
  out="$("$TASK" unset 1 source)"
  assert_eq "$out" "T-0001 has no source"
  assert_eq "$(git -C "$AGENT_TASKS_HOME" rev-list --count HEAD)" "$before"
  local rc=0
  out="$("$TASK" unset 1 title 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "cannot unset 'title'"
}

test_edit_done_moves_and_records_result() {
  new_task "Finishing" >/dev/null
  "$TASK" mv 1 09_finishing >/dev/null
  local out f
  out="$("$TASK" done 1 --result pr)"
  assert_eq "$out" "T-0001: 09_finishing → 10_unmerged (result: pr)"
  f="$(task_path_of T-0001)"
  assert_contains "$f" "/10_unmerged/"
  assert_contains "$(cat "$f")" "result: pr"
  assert_contains "$(tail -n 1 "$f")" "task: 09_finishing → 10_unmerged — result: pr"
  assert_eq "$(last_subject)" "tasks(work): T-0001 09_finishing → 10_unmerged"
}

test_edit_done_results_route_by_kind() {
  local r want
  for r in pr:10_unmerged kept:10_unmerged merged:11_done discarded:11_done cancelled:11_done; do
    rm -rf "$AGENT_TASKS_HOME"
    new_task "R" >/dev/null
    "$TASK" done 1 --result "${r%%:*}" >/dev/null
    want="${r#*:}"
    assert_contains "$(task_path_of T-0001)" "/$want/"
  done
}

test_edit_merged_moves_unmerged_to_done() {
  new_task "M" >/dev/null
  "$TASK" done 1 --result pr >/dev/null
  local out f
  out="$("$TASK" merged 1 --summary "Landed.")"
  assert_eq "$out" "T-0001: 10_unmerged → 11_done (result: merged)"
  f="$(task_path_of T-0001)"
  assert_contains "$f" "/11_done/"
  assert_contains "$(cat "$f")" "result: merged"
  assert_contains "$(cat "$f")" "Landed."
  assert_contains "$(tail -n 1 "$f")" "task: 10_unmerged → 11_done — merged"
  local rc=0
  out="$("$TASK" merged 1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "only unmerged tasks"
}

test_edit_done_summary_before_log_and_appends() {
  new_task "Finishing" --body "Body text" >/dev/null
  local f
  "$TASK" done 1 --result merged --summary "Merged it." >/dev/null
  f="$(task_path_of T-0001)"
  local text
  text="$(cat "$f")"
  assert_contains "$text" "$(printf 'Body text\n\n## Result\n\nMerged it.\n\n## Log\n- ')"
  printf 'Second part\n' | "$TASK" done 1 --result merged --summary - >/dev/null
  text="$(cat "$f")"
  assert_contains "$text" "$(printf '## Result\n\nMerged it.\n\nSecond part\n\n## Log')"
  assert_eq "$(grep -c '^## Result' "$f")" 1
  assert_eq "$(grep -c '^result:' "$f")" 1
  assert_contains "$text" "task: result: merged"
}

test_edit_done_from_blocked_clears_blocked_from() {
  new_task "Blocked" >/dev/null
  "$TASK" mv 1 08_implementing >/dev/null
  "$TASK" mv 1 blocked >/dev/null
  "$TASK" done 1 --result cancelled >/dev/null
  assert_not_contains "$(cat "$(task_path_of T-0001)")" "blocked_from"
  assert_contains "$(task_path_of T-0001)" "/11_done/"
}

test_edit_done_rejects_bad_result() {
  new_task "X" >/dev/null
  local out rc=0
  out="$("$TASK" done 1 --result nope 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid result 'nope'"
  rc=0; out="$("$TASK" done 1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "--result"
  assert_contains "$(task_path_of T-0001)" "/00_backlog/"
}

test_edit_unknown_id_fails_without_commit() {
  "$TASK" backup >/dev/null
  local before out rc=0
  before="$(git -C "$AGENT_TASKS_HOME" rev-list --count HEAD)"
  out="$("$TASK" log 5 hi 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "no task T-0005"
  assert_eq "$(git -C "$AGENT_TASKS_HOME" rev-list --count HEAD)" "$before"
  assert_no_file "$AGENT_TASKS_HOME/.lock"
}

test_edit_commits_manual_changes_too() {
  new_task "Manual" >/dev/null
  write_task_file 00_backlog T-0009 "By hand"
  "$TASK" log 1 "note" >/dev/null
  assert_eq "$(last_subject)" "tasks: 2 changes in 2 tasks"
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
}

# Task file whose frontmatter is never closed; a body line looks like a key.
broken_task() {
  "$TASK" new "Broken" >/dev/null
  BROKEN="$(task_path_of T-0001)"
  printf -- '---\nid: T-0001\ntitle: "Broken"\ncreated: 2026-10-01\n\nsource: x\n\n## Log\n- 2026-10-01 09:00 task: created\n' > "$BROKEN"
  git -C "$AGENT_TASKS_HOME" add -A
  git -C "$AGENT_TASKS_HOME" commit -q -m broken
  BROKEN_BEFORE="$(cat "$BROKEN")"
  BROKEN_COMMITS="$(git -C "$AGENT_TASKS_HOME" rev-list --count HEAD)"
}

assert_refused_as_malformed() {   # <description> <command...>
  local what="$1" out rc=0
  shift
  out="$("$@" 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] || fail "$what: expected exit 1, got $rc ($out)"
  assert_contains "$out" "malformed frontmatter in work/00_backlog/T-0001-broken.md (run 'task doctor')"
  assert_eq "$(cat "$BROKEN")" "$BROKEN_BEFORE"
  assert_eq "$(git -C "$AGENT_TASKS_HOME" rev-list --count HEAD)" "$BROKEN_COMMITS"
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
}

test_edit_malformed_frontmatter_is_never_rewritten() {
  broken_task
  assert_refused_as_malformed mv "$TASK" mv 1 ready
  assert_refused_as_malformed log "$TASK" log 1 "note"
  assert_refused_as_malformed set "$TASK" set 1 pr "http://x"
  assert_refused_as_malformed unset "$TASK" unset 1 source
  assert_refused_as_malformed done "$TASK" done 1 --result pr --summary "s"
}

test_edit_malformed_first_line_is_refused() {
  "$TASK" new "Broken" >/dev/null
  local f
  f="$(task_path_of T-0001)"
  { printf 'oops\n'; cat "$f"; } > "$f.x" && mv "$f.x" "$f"
  git -C "$AGENT_TASKS_HOME" add -A; git -C "$AGENT_TASKS_HOME" commit -q -m broken
  local before out rc=0
  before="$(cat "$f")"
  out="$("$TASK" set 1 pr x 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "malformed frontmatter"
  assert_eq "$(cat "$f")" "$before"
}

test_edit_rewriters_fail_without_anchor() {
  load_lib frontmatter
  local f="$TMP/raw.md" rc=0
  printf -- '---\nid: T-0001\nsource: x\n\n## Log\n' > "$f"
  fm_set "$f" pr y || rc=$?
  assert_eq "$rc" 1
  rc=0; fm_unset "$f" source || rc=$?
  assert_eq "$rc" 1
  rc=0; result_append "$f" text || rc=$?
  assert_eq "$rc" 1
  assert_eq "$(cat "$f")" "$(printf -- '---\nid: T-0001\nsource: x\n\n## Log')"
  assert_eq "$(find "$TMP" -maxdepth 1 -name '*.tmp' | wc -l | tr -d ' ')" 0
}

test_edit_set_project_rejects_traversal() {
  "$TASK" new "Trav" >/dev/null
  local before out rc=0 v
  before="$(cat "$(task_path_of T-0001)")"
  for v in ../../config.toml ../work/.projects/x a/b; do
    rc=0
    out="$("$TASK" set 1 project "$v" 2>&1)" || rc=$?
    assert_eq "$rc" 1
    assert_contains "$out" "invalid project name '$v'"
  done
  assert_eq "$(cat "$(task_path_of T-0001)")" "$before"
}

test_edit_done_rejects_section_headings_in_summary() {
  "$TASK" new "Sum" >/dev/null
  local before out rc=0 h
  before="$(cat "$(task_path_of T-0001)")"
  for h in "## Log" "## Result"; do
    rc=0
    out="$("$TASK" done 1 --result pr --summary "$(printf 'x\n%s\ny' "$h")" 2>&1)" || rc=$?
    assert_eq "$rc" 1
    assert_contains "$out" "summary must not contain a '$h' line"
  done
  assert_eq "$(cat "$(task_path_of T-0001)")" "$before"
  assert_contains "$(task_path_of T-0001)" "/00_backlog/"
}

test_edit_done_summary_commit_names_the_move() {
  write_task_file 09_finishing T-0001 "Short"
  "$TASK" backup >/dev/null
  "$TASK" done 1 --result pr --summary "Everything is different now, new words only." >/dev/null
  assert_eq "$(last_subject)" "tasks(work): T-0001 09_finishing → 10_unmerged"
}

test_edit_log_and_set_accept_dash_values() {
  "$TASK" new "Dashes" >/dev/null
  "$TASK" log 1 -- "-x starts with a dash" >/dev/null
  assert_contains "$(tail -n 1 "$(task_path_of T-0001)")" "agent: -x starts with a dash"
  "$TASK" log 1 --author me -- "--also" >/dev/null
  assert_contains "$(tail -n 1 "$(task_path_of T-0001)")" "me: --also"
  assert_eq "$("$TASK" set 1 title -- "-new title")" "T-0001: title = -new title"
  assert_contains "$(cat "$(task_path_of T-0001)")" 'title: "-new title"'
  "$TASK" set 1 source -- "-weird" >/dev/null
  assert_contains "$(cat "$(task_path_of T-0001)")" 'source: "-weird"'
}

test_edit_done_failed_move_leaves_no_orphan() {
  # chmod cannot block a root user, so the failure cannot be provoked.
  if [ "$(id -u)" -eq 0 ]; then return 0; fi
  write_task_file 08_implementing T-0001 "Ro test"
  "$TASK" backup >/dev/null
  local out rc=0
  chmod a-w "$AGENT_TASKS_HOME/work/08_implementing"
  out="$("$TASK" done 1 --result pr 2>&1)" || rc=$?
  chmod u+w "$AGENT_TASKS_HOME/work/08_implementing"
  assert_eq "$rc" 1
  assert_contains "$out" "cannot move"
  assert_no_file "$AGENT_TASKS_HOME/work/11_done/T-0001-ro-test.md"
  out="$("$TASK" show 1)"
  assert_contains "$out" "id: T-0001"
}

test_edit_set_quotes_yaml_typed_scalars() {
  "$TASK" new "Typed" >/dev/null
  local f v
  f="$(task_path_of T-0001)"
  load_lib frontmatter
  for v in 123 2026-10-01 true null '~' No OFF 1.5 -7 12:30; do
    "$TASK" set 1 source "$v" >/dev/null
    assert_eq "$(grep '^source:' "$f")" "source: \"$v\""
    assert_eq "$(fm_get "$f" source)" "$v"
  done
  for v in https://x.example/a dev_env nullable 2026-10-01-x; do
    "$TASK" set 1 source "$v" >/dev/null
    assert_eq "$(grep '^source:' "$f")" "source: $v"
    assert_eq "$(fm_get "$f" source)" "$v"
  done
}

test_edit_mv_resolves_folder_names_and_numbers() {
  write_task_file 00_backlog T-0001 "Move me"
  local fo
  for fo in 1:01_ready 02:02_exploring 3:03_brainstorming 04:04_spec_review plan_review:06_plan_review \
            planning:05_planning 5:05_planning 7:07_approved approved:07_approved 8:08_implementing \
            09:09_finishing 10:10_unmerged unmerged:10_unmerged 11:11_done done:11_done blocked:blocked 0:00_backlog; do
    "$TASK" mv 1 "${fo%%:*}" >/dev/null
    assert_eq "$(basename "$(dirname "$(task_path_of T-0001)")")" "${fo#*:}"
  done
  local out rc=0
  out="$("$TASK" mv 1 12 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown folder '12'"
  rc=0; out="$("$TASK" mv 1 100 2>&1)" || rc=$?
  assert_eq "$rc" 1
}

test_unmerged_signals_ls_and_doctor() {
  new_task "U" >/dev/null
  "$TASK" set 1 session ses_u1 >/dev/null
  "$TASK" done 1 --result kept >/dev/null
  "$TASK" signal 1 turn-end --session ses_u1 >/dev/null 2>&1 || true
  "$TASK" signal 1 permission --session ses_u1 >/dev/null 2>&1 || true
  assert_contains "$(task_path_of T-0001)" "/10_unmerged/"
  assert_eq "$("$TASK" ls --json | jq -r '.[0].status')" unmerged
  assert_eq "$("$TASK" ls unmerged | grep -c T-0001)" 1
  "$TASK" doctor >/dev/null
  "$TASK" set 1 result merged >/dev/null
  local rc=0
  "$TASK" doctor >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 1
  local out
  rc=0; out="$("$TASK" archive 1 2>&1)" || rc=$?
  assert_eq "$rc" 1
}
