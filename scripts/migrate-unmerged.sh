#!/usr/bin/env bash
# One-off store migration: adds the 10_unmerged stage and renames 10_done → 11_done.
#
#   migrate-unmerged.sh [--dry-run]
#
# Per workspace: 10_done → 11_done; tasks with result pr/kept whose last real
# log entry is at most 14 days old go to 10_unmerged instead. blocked_from and
# postponed_from values 10_done become 11_done. Idempotent.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB="$HERE/../skills/agent-tasks/lib"

die() { echo "migrate-unmerged: $*" >&2; exit 1; }

# shellcheck source=/dev/null # path computed at run time
. "$LIB/core.sh"
# shellcheck source=/dev/null
. "$LIB/lock.sh"
# shellcheck source=/dev/null
. "$LIB/frontmatter.sh"
# shellcheck source=/dev/null
. "$LIB/archive.sh"

COMMIT_MSG="tasks: add unmerged stage"
RECENT_DAYS=14

workspaces() {
  local d
  for d in "$STORE"/*/; do
    [ -d "${d}00_backlog" ] || continue
    basename "${d%/}"
  done
}

# Tab-separated plan lines: kind, workspace, file, from, to, result.
#   move — the file leaves 10_done for `to`
#   from — blocked_from/postponed_from `10_done` is rewritten (field in `from`)
build_plan() {
  local ws f old due res to
  for ws in $(workspaces); do
    if [ -d "$STORE/$ws/10_done" ]; then
      due="$(archive_due_files "$RECENT_DAYS" 10_done | cut -f1)"
      for f in "$STORE/$ws/10_done"/T-[0-9]*.md; do
        [ -e "$f" ] || continue
        res="$(fm_get "$f" result)"
        to=11_done
        case "$res" in
          pr|kept) if ! printf '%s\n' "$due" | grep -qxF "$f"; then to=10_unmerged; fi ;;
        esac
        printf 'move\t%s\t%s\t10_done\t%s\t%s\n' "$ws" "$f" "$to" "$res"
      done
    fi
    for old in blocked postponed; do
      for f in "$STORE/$ws/$old"/T-[0-9]*.md; do
        [ -e "$f" ] || continue
        if [ "$old" = blocked ]; then res="$(fm_get "$f" blocked_from)"; else res="$(fm_get "$f" postponed_from)"; fi
        [ "$res" = "10_done" ] || continue
        printf 'field\t%s\t%s\t%s_from\t11_done\t\n' "$ws" "$f" "$old"
      done
    done
  done
}

print_plan() {   # print_plan <plan>
  local kind ws f from to res
  while IFS=$'\t' read -r kind ws f from to res; do
    [ -n "$kind" ] || continue
    if [ "$kind" = "move" ]; then
      echo "  $(id_of_file "$f"): $ws/$from → $ws/$to${res:+ (result $res)}"
    else
      echo "  $(id_of_file "$f"): $from 10_done → $to"
    fi
  done <<< "$1"
}

main() {
  local dry=0 plan kind ws f from to res dest
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      *) die "usage: migrate-unmerged.sh [--dry-run]" ;;
    esac
  done
  [ -d "$STORE/.git" ] || die "$STORE is not a task store (no .git)"
  if [ -e "$STORE/.auto" ]; then
    die "automation is on ($STORE/.auto exists); run 'task auto off' first"
  fi
  if [ -n "$(git -C "$STORE" status --porcelain)" ]; then
    die "the store has uncommitted changes; run 'task backup' (or commit) first"
  fi

  plan="$(build_plan)"
  if [ -z "$plan" ] && ! compgen -G "$STORE/*/10_done" >/dev/null; then
    echo "nothing to migrate: the store already has 10_unmerged/11_done"
    return 0
  fi
  if [ "$dry" -eq 1 ]; then
    echo "dry run — nothing is changed:"
    print_plan "$plan"
    return 0
  fi

  lock_acquire
  plan="$(build_plan)"
  for ws in $(workspaces); do
    for to in $FOLDERS; do mkdir -p "$STORE/$ws/$to"; done
  done
  while IFS=$'\t' read -r kind ws f from to res; do
    [ -n "$kind" ] || continue
    if [ "$kind" = "move" ]; then
      dest="$STORE/$ws/$to/$(basename "$f")"
      [ ! -e "$dest" ] || die "cannot move: $dest already exists"
      mv "$f" "$dest"
      if [ "$to" = "10_unmerged" ]; then
        log_append "$dest" task "folder layout migration: 10_done → 10_unmerged (result $res)"
      fi
    else
      fm_set "$f" "$from" "$to" || die "cannot update $f"
    fi
  done <<< "$plan"
  for ws in $(workspaces); do
    if [ -d "$STORE/$ws/10_done" ]; then
      rmdir "$STORE/$ws/10_done" 2>/dev/null || echo "migrate-unmerged: $STORE/$ws/10_done is not empty; left in place" >&2
    fi
  done

  git -C "$STORE" add -A
  if ! git -C "$STORE" diff --cached --quiet; then
    git -C "$STORE" commit -q -m "$COMMIT_MSG" \
      || die "commit failed in $STORE — is git user.name / user.email configured?"
  fi
  echo "migrated:"
  print_plan "$plan"
}

main "$@"
