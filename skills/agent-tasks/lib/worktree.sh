# shellcheck shell=bash
# Task worktrees: <repo>/.worktrees/<T-id>, removed when the task reaches 11_done.

# Repo path of the task's project; empty when the task has no registered project.
worktree_repo() {   # worktree_repo <task-file>
  local proj
  proj="$(fm_get "$1" project)"
  [ -n "$proj" ] || return 0
  project_path "$(ws_of_file "$1")" "$proj"
}

# Registered worktree: the directory exists and git recognises it.
worktree_alive() {   # worktree_alive <path>
  [ -e "$1/.git" ] && git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Cleans up the worktree of a task. Never fails: problems are logged.
# <result> decides about the branch (only `merged` deletes it, and only with -d).
# <force> = 1 removes a dirty worktree too.
worktree_cleanup() {   # worktree_cleanup <task-file> <result> [force]
  local file="$1" result="${2:-}" force="${3:-0}" wt repo branch="" out
  wt="$(fm_get "$file" worktree)"
  [ -n "$wt" ] || return 0
  repo="$(worktree_repo "$file")"
  if [ -z "$repo" ] || [ ! -d "$repo" ]; then
    log_append "$file" task "worktree kept: project repository not found for $wt"
    return 0
  fi
  if [ ! -d "$wt" ]; then
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    fm_unset "$file" worktree || true
    log_append "$file" task "worktree $wt already gone"
    return 0
  fi
  if [ "$force" -ne 1 ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    log_append "$file" task "worktree kept: uncommitted changes in $wt"
    return 0
  fi
  branch="$(git -C "$wt" symbolic-ref --short -q HEAD 2>/dev/null)" || branch=""
  if [ "$force" -eq 1 ]; then
    out="$(git -C "$repo" worktree remove --force "$wt" 2>&1)" || {
      log_append "$file" task "worktree kept: cannot remove $wt: ${out%%$'\n'*}"
      return 0
    }
  else
    out="$(git -C "$repo" worktree remove "$wt" 2>&1)" || {
      log_append "$file" task "worktree kept: cannot remove $wt: ${out%%$'\n'*}"
      return 0
    }
  fi
  fm_unset "$file" worktree || true
  log_append "$file" task "worktree removed: $wt"
  if [ "$result" = "merged" ] && [ -n "$branch" ]; then
    if ! git -C "$repo" branch -d "$branch" >/dev/null 2>&1; then
      log_append "$file" task "branch $branch kept (not merged locally)"
    fi
  fi
  return 0
}

cmd_worktree() {
  local id="" branch="" base="" remove=0 force=0 f tid repo wt slug b excl dir
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch) need_value "$@"; branch="$2"; shift 2 ;;
      --base) need_value "$@"; base="$2"; shift 2 ;;
      --remove) remove=1; shift ;;
      --force) force=1; shift ;;
      -*) die "unknown option: $1" ;;
      *)
        [ -z "$id" ] || die "usage: task worktree <id> [--branch B] [--base REF] | --remove [--force]"
        id="$1"; shift ;;
    esac
  done
  [ -n "$id" ] || die "usage: task worktree <id> [--branch B] [--base REF] | --remove [--force]"
  if [ "$remove" -eq 0 ] && [ "$force" -eq 1 ]; then die "--force only goes with --remove"; fi
  if [ "$remove" -eq 1 ] && { [ -n "$branch" ] || [ -n "$base" ]; }; then die "--remove does not take --branch or --base"; fi
  lock_acquire
  f="$(task_file "$id")"
  fm_require "$f"
  tid="$(id_of_file "$f")"
  wt="$(fm_get "$f" worktree)"

  if [ "$remove" -eq 1 ]; then
    [ -n "$wt" ] || { echo "$tid has no worktree"; return 0; }
    worktree_cleanup "$f" "" "$force"
    store_commit || true
    if [ -n "$(fm_get "$f" worktree)" ]; then
      echo "$tid: worktree kept (see the log; --force removes it anyway)"
    else
      echo "$tid: worktree removed"
    fi
    return 0
  fi

  [ -n "$(fm_get "$f" project)" ] || die "$tid has no project; run: task set $tid project <name>"
  repo="$(worktree_repo "$f")"
  [ -n "$repo" ] || die "project of $tid has no path (register it: task project add <name> <path>)"
  [ -d "$repo" ] || die "project path does not exist: $repo"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $repo"
  repo="$(cd -P "$repo" && pwd -P)"

  if [ -n "$wt" ] && worktree_alive "$wt"; then
    printf '%s\n' "$wt"
    return 0
  fi

  wt="$repo/.worktrees/$tid"
  if [ -e "$wt" ] && ! worktree_alive "$wt"; then die "$wt exists but is not a git worktree"; fi

  if [ ! -e "$wt" ]; then
    if ! git -C "$repo" check-ignore -q .worktrees 2>/dev/null; then
      excl="$(git -C "$repo" rev-parse --path-format=absolute --git-path info/exclude)" || die "cannot locate git exclude file"
      dir="$(dirname "$excl")"
      mkdir -p "$dir"
      if [ -s "$excl" ] && [ -n "$(tail -c 1 "$excl")" ]; then printf '\n' >> "$excl"; fi
      printf '.worktrees/\n' >> "$excl"
    fi
    if [ -z "$branch" ]; then
      b="$(basename "$f" .md)"
      slug="${b#"$tid"}"
      slug="${slug#-}"
      if [ -n "$slug" ]; then branch="task/$tid-$slug"; else branch="task/$tid"; fi
    fi
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$repo" worktree add -q "$wt" "$branch" >&2 || die "git worktree add failed"
    elif [ -n "$base" ]; then
      git -C "$repo" worktree add -q -b "$branch" "$wt" "$base" >&2 || die "git worktree add failed"
    else
      git -C "$repo" worktree add -q -b "$branch" "$wt" >&2 || die "git worktree add failed"
    fi
  else
    branch="$(git -C "$wt" symbolic-ref --short -q HEAD 2>/dev/null)" || branch="(detached)"
  fi
  fm_set "$f" worktree "$(fm_quote "$wt")" || die "cannot update $f"
  log_append "$f" task "worktree $wt (branch $branch)"
  store_commit || true
  printf '%s\n' "$wt"
}
