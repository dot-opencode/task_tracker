# shellcheck shell=bash
# mrcheck: MR/PR state auto-check of 10_unmerged tasks.

mr_setup() {
  export AGENT_TASKS_MRCHECK=1
  "$TASK" ls >/dev/null
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/glab" <<'STUB'
#!/usr/bin/env bash
echo "glab $*" >> "$TMP/cli.log"
case "$*" in
  *merge_requests/1) echo '{"state":"merged"}' ;;
  *merge_requests/2) echo '{"state":"closed"}' ;;
  *merge_requests/3) echo '{"state":"opened"}' ;;
  *) exit 1 ;;
esac
STUB
  cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$TMP/cli.log"
case "$*" in
  *pull/9*) echo '{"state":"MERGED"}' ;;
  *) echo '{"state":"OPEN"}' ;;
esac
STUB
  chmod +x "$TMP/bin/glab" "$TMP/bin/gh"
  export TMP
}

mr_unmerged() {   # mr_unmerged <id> <pr url>
  write_task_file 10_unmerged "$1" "MR task $1"
  "$TASK" set "$1" pr "$2" >/dev/null
  "$TASK" set "$1" result pr >/dev/null
}

test_mrcheck_moves_merged_and_notes_closed() {
  mr_setup
  mr_unmerged T-0001 "https://gitlab.com/grp/sub/proj/-/merge_requests/1"
  mr_unmerged T-0002 "https://gitlab.com/grp/proj/-/merge_requests/2"
  mr_unmerged T-0003 "https://gitlab.example.org/grp/proj/-/merge_requests/3"
  mr_unmerged T-0004 "https://github.com/o/r/pull/9"
  local out
  out="$("$TASK" check-mrs)"
  assert_contains "$out" "T-0001: merged"
  assert_eq "$(basename "$(dirname "$(task_path_of T-0001)")")" 11_done
  assert_contains "$(cat "$(task_path_of T-0001)")" "result: merged"
  assert_contains "$(cat "$(task_path_of T-0001)")" "MR merged (auto-check)"
  assert_eq "$(basename "$(dirname "$(task_path_of T-0004)")")" 11_done
  assert_eq "$(basename "$(dirname "$(task_path_of T-0003)")")" 10_unmerged
  assert_eq "$(basename "$(dirname "$(task_path_of T-0002)")")" 10_unmerged
  assert_contains "$(cat "$(task_path_of T-0002)")" "MR closed without merge"
  assert_contains "$(cat "$TMP/cli.log")" "glab api projects/grp%2Fsub%2Fproj/merge_requests/1"
  assert_contains "$(cat "$TMP/cli.log")" "gh pr view https://github.com/o/r/pull/9 --json state"
  # closed is logged once.
  "$TASK" check-mrs >/dev/null
  assert_eq "$(grep -c 'MR closed without merge' "$(task_path_of T-0002)")" 1
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
}

test_mrcheck_due_runs_at_most_every_ten_minutes() {
  mr_setup
  mr_unmerged T-0001 "https://gitlab.com/g/p/-/merge_requests/3"
  rm -f "$AGENT_TASKS_HOME/.notify/mrcheck.last"
  "$TASK" ls >/dev/null 2>&1
  "$TASK" ls >/dev/null 2>&1
  assert_eq "$(grep -c '^glab' "$TMP/cli.log")" 1
  AGENT_TASKS_MRCHECK=0 "$TASK" ls >/dev/null 2>&1
  rm -f "$AGENT_TASKS_HOME/.notify/mrcheck.last"
  AGENT_TASKS_MRCHECK=0 "$TASK" ls >/dev/null 2>&1
  assert_eq "$(grep -c '^glab' "$TMP/cli.log")" 1
}

test_mrcheck_ls_json_stdout_stays_clean_and_missing_tool_is_silent() {
  mr_setup
  mr_unmerged T-0001 "https://gitlab.com/g/p/-/merge_requests/1"
  rm -f "$TMP/bin/glab"
  local out err
  out="$(PATH="/usr/bin:/bin:$(dirname "$(command -v jq)")" "$TASK" ls --json 2>"$TMP/err")"
  err="$(cat "$TMP/err")"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].status')" unmerged
  assert_eq "$err" ""
  rm -f "$AGENT_TASKS_HOME/.notify/mrcheck.last"
  out="$("$TASK" ls --json 2>/dev/null)" || true
}
