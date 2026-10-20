#!/usr/bin/env bash
# One-off store migration: stage-1 folders (0_backlog … 8_done) to the
# two-digit layout with the planning stages (00_backlog … 11_done).
#
#   migrate-folders.sh [--dry-run]
#
# 0_backlog→00_backlog 1_ready→01_ready 2_exploring→02_exploring
# 3_brainstorming→03_brainstorming 4_spec_review→04_spec_review
# 5_approved→07_approved 6_implementing→05_planning (no `plan` field) or
# 08_implementing (`plan` set) 7_finishing→09_finishing 8_done→11_done.
# `blocked_from:` values follow the same mapping. Idempotent.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB="$HERE/../skills/agent-tasks/lib"

die() { echo "migrate-folders: $*" >&2; exit 1; }

# shellcheck source=/dev/null # path computed at run time
. "$LIB/core.sh"
# shellcheck source=/dev/null
. "$LIB/lock.sh"
# shellcheck source=/dev/null
. "$LIB/frontmatter.sh"

OLD_FOLDERS="0_backlog 1_ready 2_exploring 3_brainstorming 4_spec_review 5_approved 6_implementing 7_finishing 8_done"
NEW_FOLDERS="$FOLDERS"
COMMIT_MSG="tasks: migrate to two-digit folders with planning stages"

# new_folder <old folder> <file>: the new folder for a task, empty when unknown.
new_folder() {
  case "$1" in
    0_backlog) echo 00_backlog ;;
    1_ready) echo 01_ready ;;
    2_exploring) echo 02_exploring ;;
    3_brainstorming) echo 03_brainstorming ;;
    4_spec_review) echo 04_spec_review ;;
    5_approved) echo 07_approved ;;
    6_implementing)
      if [ -n "$(fm_get "$2" plan)" ]; then echo 08_implementing; else echo 05_planning; fi ;;
    7_finishing) echo 09_finishing ;;
    8_done) echo 11_done ;;
    *) echo "" ;;
  esac
}

workspaces() {
  local d
  for d in "$STORE"/*/; do
    [ -d "${d}0_backlog" ] || [ -d "${d}00_backlog" ] || continue
    basename "${d%/}"
  done
}

# Old folders still present (empty ones count: they are removed).
old_dirs() {
  local ws old
  for ws in $(workspaces); do
    for old in $OLD_FOLDERS; do
      if [ -d "$STORE/$ws/$old" ]; then echo "$ws/$old"; fi
    done
  done
}

# Tab-separated plan lines: kind, workspace, file, old, new.
#   move    — the file goes to another folder
#   blocked — the file stays in blocked; blocked_from changes
build_plan() {
  local ws old f new from to
  for ws in $(workspaces); do
    for old in $OLD_FOLDERS; do
      for f in "$STORE/$ws/$old"/T-[0-9]*.md; do
        [ -e "$f" ] || continue
        new="$(new_folder "$old" "$f")"
        printf 'move\t%s\t%s\t%s\t%s\n' "$ws" "$f" "$old" "$new"
      done
    done
    for f in "$STORE/$ws/blocked"/T-[0-9]*.md; do
      [ -e "$f" ] || continue
      from="$(fm_get "$f" blocked_from)"
      to="$(new_folder "$from" "$f")"
      [ -n "$to" ] || continue
      printf 'blocked\t%s\t%s\t%s\t%s\n' "$ws" "$f" "$from" "$to"
    done
  done
}

print_plan() {   # print_plan <plan>
  local kind ws f old new
  while IFS=$'\t' read -r kind ws f old new; do
    [ -n "$kind" ] || continue
    if [ "$kind" = "move" ]; then
      echo "  $(id_of_file "$f"): $ws/$old → $ws/$new"
    else
      echo "  $(id_of_file "$f"): $ws/blocked blocked_from $old → $new"
    fi
  done <<< "$1"
}

print_summary() {   # print_summary <plan>
  local old new n
  echo "summary:"
  for old in $OLD_FOLDERS; do
    for new in $NEW_FOLDERS; do
      n="$(printf '%s\n' "$1" | awk -F'\t' -v o="$old" -v nw="$new" '$1 == "move" && $4 == o && $5 == nw { c++ } END { print c + 0 }')"
      if [ "$n" -gt 0 ]; then printf '  %-16s → %-16s %s\n' "$old" "$new" "$n"; fi
    done
  done
  n="$(printf '%s\n' "$1" | awk -F'\t' '$1 == "blocked" { c++ } END { print c + 0 }')"
  if [ "$n" -gt 0 ]; then printf '  %-16s   %-16s %s\n' "blocked_from" "(rewritten)" "$n"; fi
}

main() {
  local dry=0 plan kind ws f old new dest ndir
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      *) die "usage: migrate-folders.sh [--dry-run]" ;;
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
  if [ -z "$plan" ] && [ -z "$(old_dirs)" ]; then
    echo "nothing to migrate: the store already uses the new folders"
    return 0
  fi
  if [ "$dry" -eq 1 ]; then
    echo "dry run — nothing is changed:"
    print_plan "$plan"
    print_summary "$plan"
    return 0
  fi

  lock_acquire
  # The tree may have changed while waiting for the lock.
  plan="$(build_plan)"
  for ws in $(workspaces); do
    for new in $NEW_FOLDERS; do
      mkdir -p "$STORE/$ws/$new"
    done
  done

  while IFS=$'\t' read -r kind ws f old new; do
    [ -n "$kind" ] || continue
    if [ "$kind" = "move" ]; then
      [ -n "$new" ] || die "no target folder for $f"
      dest="$STORE/$ws/$new/$(basename "$f")"
      [ ! -e "$dest" ] || die "cannot move: $dest already exists"
      mv "$f" "$dest"
      case "$new" in
        05_planning|08_implementing)
          if [ "$old" = "6_implementing" ]; then
            log_append "$dest" task "folder layout migration: $old → $new"
          fi ;;
      esac
    else
      fm_set "$f" blocked_from "$new" || die "cannot update $f"
    fi
  done <<< "$plan"

  for ws in $(workspaces); do
    for old in $OLD_FOLDERS; do
      ndir="$STORE/$ws/$old"
      if [ -d "$ndir" ]; then
        rmdir "$ndir" 2>/dev/null || echo "migrate-folders: $ndir is not empty; left in place" >&2
      fi
    done
  done

  git -C "$STORE" add -A
  if ! git -C "$STORE" diff --cached --quiet; then
    git -C "$STORE" commit -q -m "$COMMIT_MSG" \
      || die "commit failed in $STORE — is git user.name / user.email configured?"
  fi
  echo "migrated:"
  print_summary "$plan"
}

main "$@"
