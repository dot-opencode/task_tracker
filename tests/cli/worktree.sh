# shellcheck shell=bash
# task worktree: creation, cleanup on 11_done, manual removal.

wt_setup() {   # creates repo + task T-0001 with project repo
  mkdir -p "$TMP/code/repo"
  git -C "$TMP/code/repo" init -q
  git -C "$TMP/code/repo" commit -q --allow-empty -m init
  "$TASK" project add repo "$TMP/code/repo" >/dev/null
  "$TASK" new "Fix thing" --project repo >/dev/null
  REPO="$TMP/code/repo"
  WT="$REPO/.worktrees/T-0001"
}

wt_has_branch() { git -C "$REPO" show-ref --verify --quiet "refs/heads/$1"; }

test_worktree_create() {
  wt_setup
  local out f
  out="$("$TASK" worktree 1)"
  assert_eq "$out" "$WT"
  [ -d "$WT" ] || fail "no worktree dir"
  assert_contains "$(cat "$REPO/.git/info/exclude")" ".worktrees/"
  assert_eq "$(git -C "$REPO" status --porcelain)" ""
  f="$(task_path_of T-0001)"
  assert_contains "$(cat "$f")" "worktree: $WT"
  assert_contains "$(cat "$f")" "(branch task/T-0001-fix-thing)"
  wt_has_branch task/T-0001-fix-thing || fail "no branch"
  assert_eq "$("$TASK" worktree 1)" "$WT"
  assert_eq "$(grep -c 'worktree .*(branch' "$f")" "1"
  assert_eq "$(grep -c '^.worktrees/$' "$REPO/.git/info/exclude")" "1"
}

test_worktree_existing_branch_and_custom() {
  wt_setup
  git -C "$REPO" branch task/T-0001-fix-thing
  "$TASK" worktree 1 >/dev/null
  assert_eq "$(git -C "$WT" symbolic-ref --short HEAD)" "task/T-0001-fix-thing"
  "$TASK" new "Other" --project repo >/dev/null
  "$TASK" worktree 2 --branch feat/x --base HEAD >/dev/null
  assert_eq "$(git -C "$REPO/.worktrees/T-0002" symbolic-ref --short HEAD)" "feat/x"
}

test_worktree_no_project() {
  "$TASK" new "Loose" >/dev/null
  local out rc=0
  out="$("$TASK" worktree 1 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "expected failure"
  assert_contains "$out" "task set T-0001 project"
}

test_worktree_done_merged_removes() {
  wt_setup
  "$TASK" worktree 1 >/dev/null
  "$TASK" done 1 --result merged >/dev/null
  assert_no_file "$WT"
  wt_has_branch task/T-0001-fix-thing && fail "branch should be deleted"
  case "$(cat "$(task_path_of T-0001)")" in *"worktree: "*) fail "field kept" ;; esac
  assert_contains "$(cat "$(task_path_of T-0001)")" "worktree removed"
}

test_worktree_done_discarded_keeps_branch() {
  wt_setup
  "$TASK" worktree 1 >/dev/null
  "$TASK" done 1 --result discarded >/dev/null
  assert_no_file "$WT"
  wt_has_branch task/T-0001-fix-thing || fail "branch should stay"
}

test_worktree_unmerged_branch_kept_on_merged() {
  wt_setup
  "$TASK" worktree 1 >/dev/null
  echo x > "$WT/f"; git -C "$WT" add f; git -C "$WT" commit -q -m work
  "$TASK" done 1 --result merged >/dev/null
  assert_no_file "$WT"
  wt_has_branch task/T-0001-fix-thing || fail "unmerged branch must stay"
  assert_contains "$(cat "$(task_path_of T-0001)")" "kept (not merged locally)"
}

test_worktree_dirty_kept() {
  wt_setup
  "$TASK" worktree 1 >/dev/null
  echo x > "$WT/dirty"
  "$TASK" done 1 --result discarded >/dev/null
  [ -d "$WT" ] || fail "dirty worktree removed"
  assert_contains "$(cat "$(task_path_of T-0001)")" "worktree kept: uncommitted changes in $WT"
  assert_contains "$(task_path_of T-0001)" "/11_done/"
}

test_worktree_pr_then_merged() {
  wt_setup
  "$TASK" worktree 1 >/dev/null
  "$TASK" done 1 --result pr >/dev/null
  assert_contains "$(task_path_of T-0001)" "/10_unmerged/"
  [ -d "$WT" ] || fail "worktree removed too early"
  "$TASK" merged 1 >/dev/null
  assert_no_file "$WT"
  wt_has_branch task/T-0001-fix-thing && fail "branch should be deleted"
  return 0
}

test_worktree_mv_done_and_missing_dir() {
  wt_setup
  "$TASK" worktree 1 >/dev/null
  rm -rf "$WT"
  "$TASK" mv 1 11_done >/dev/null
  case "$(cat "$(task_path_of T-0001)")" in *"worktree: "*) fail "field kept" ;; esac
  assert_eq "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')" "1"
}

test_worktree_remove() {
  wt_setup
  "$TASK" worktree 1 >/dev/null
  echo x > "$WT/dirty"
  "$TASK" worktree 1 --remove >/dev/null
  [ -d "$WT" ] || fail "dirty removed without --force"
  "$TASK" worktree 1 --remove --force >/dev/null
  assert_no_file "$WT"
  case "$(cat "$(task_path_of T-0001)")" in *"worktree: "*) fail "field kept" ;; esac
  wt_has_branch task/T-0001-fix-thing || fail "branch should stay"
}
