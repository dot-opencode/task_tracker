# shellcheck shell=bash
# Project registry: <ws>/.projects/<name> holds the repository's absolute path.

valid_project() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }

project_path() {
  local f="$STORE/$1/.projects/$2" p=""
  if [ -f "$f" ]; then IFS= read -r p < "$f" || true; fi
  if [ -n "$p" ]; then printf '%s\n' "$p"; fi
  return 0
}

# Workspace holding project $1 (restricted to $2 when given).
project_ws() {
  local name="$1" only="${2:-}" ws found="" n=0
  valid_project "$name" || die "invalid project name '$name'"
  for ws in $(list_workspaces); do
    if [ -n "$only" ] && [ "$ws" != "$only" ]; then continue; fi
    if [ -f "$STORE/$ws/.projects/$name" ]; then
      found="$found $ws"
      n=$((n + 1))
    fi
  done
  found="${found# }"
  [ "$n" -gt 0 ] || die "unknown project '$name' (register it: task project add $name <path>)"
  [ "$n" -eq 1 ] || die "project '$name' is registered in workspaces: $found — pass --ws"
  printf '%s\n' "$found"
}

# Current directory, but a git worktree maps to the same place in its main checkout.
cwd_equivalent() {
  local here common parent prefix
  here="$(pwd -P)"
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
  case "$common" in
    */.git) ;;
    *) printf '%s\n' "$here"; return 0 ;;
  esac
  parent="$(cd -P "${common%/.git}" 2>/dev/null && pwd -P)" || { printf '%s\n' "$here"; return 0; }
  prefix="$(git rev-parse --show-prefix)"
  prefix="${prefix%/}"
  if [ -n "$prefix" ]; then printf '%s/%s\n' "$parent" "$prefix"; else printf '%s\n' "$parent"; fi
}

# "<ws> <name>" of the registered project with the longest path containing the cwd.
detect_project() {
  local only="${1:-}" here ws f p best="" best_len=0
  here="$(cwd_equivalent)"
  for ws in $(list_workspaces); do
    if [ -n "$only" ] && [ "$ws" != "$only" ]; then continue; fi
    for f in "$STORE/$ws/.projects"/*; do
      [ -f "$f" ] || continue
      p="$(project_path "$ws" "$(basename "$f")")"
      [ -n "$p" ] || continue
      if [ "$here" = "$p" ] || [ "${here#"$p"/}" != "$here" ]; then
        if [ "${#p}" -gt "$best_len" ]; then
          best_len="${#p}"
          best="$ws $(basename "$f")"
        fi
      fi
    done
  done
  if [ -n "$best" ]; then printf '%s\n' "$best"; fi
  return 0
}

# Writes the registry entry; prints added|updated|unchanged.
register_project() {
  local ws="$1" name="$2" path="$3" f old=""
  f="$STORE/$ws/.projects/$name"
  if [ -f "$f" ]; then
    IFS= read -r old < "$f" || true
    if [ "$old" = "$path" ]; then echo unchanged; return 0; fi
    printf '%s\n' "$path" > "$f" || die "cannot write $f"
    echo updated
    return 0
  fi
  mkdir -p "$STORE/$ws/.projects"
  printf '%s\n' "$path" > "$f" || die "cannot write $f"
  echo added
}

project_add() {
  local name="" path="" ws="" arg_n=0 res
  while [ $# -gt 0 ]; do
    case "$1" in
      --ws) need_value "$@"; ws="$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *)
        arg_n=$((arg_n + 1))
        if [ "$arg_n" -eq 1 ]; then name="$1"
        elif [ "$arg_n" -eq 2 ]; then path="$1"
        else die "usage: task project add [<name> [<path>]] [--ws W]"
        fi
        shift ;;
    esac
  done
  [ -n "$path" ] || path="."
  [ -d "$path" ] || die "not a directory: $path"
  path="$(cd -P "$path" && pwd -P)"
  [ -n "$name" ] || name="$(basename "$path")"
  valid_project "$name" || die "invalid project name '$name'"
  [ -n "$ws" ] || ws="$(config_get default_workspace work)"
  valid_ws "$ws" || die "invalid workspace '$ws'"
  lock_acquire
  ensure_workspace "$ws"
  res="$(register_project "$ws" "$name" "$path")" || exit 1
  case "$res" in
    added) echo "added project $name ($ws): $path" ;;
    updated) echo "updated project $name ($ws): $path" ;;
    *) echo "project $name ($ws) is already registered: $path" ;;
  esac
  store_commit || true
}

project_ls() {
  local ws="" w f n rows="" wsw=0 nw=0 p suffix
  while [ $# -gt 0 ]; do
    case "$1" in
      --ws) need_value "$@"; ws="$2"; shift 2 ;;
      *) die "usage: task project ls [--ws W]" ;;
    esac
  done
  if [ -n "$ws" ]; then valid_ws "$ws" || die "invalid workspace '$ws'"; require_workspace "$ws"; fi
  for w in $(list_workspaces); do
    if [ -n "$ws" ] && [ "$w" != "$ws" ]; then continue; fi
    for f in "$STORE/$w/.projects"/*; do
      [ -f "$f" ] || continue
      n="$(basename "$f")"
      rows="$rows$w $n"$'\n'
      if [ "${#w}" -gt "$wsw" ]; then wsw="${#w}"; fi
      if [ "${#n}" -gt "$nw" ]; then nw="${#n}"; fi
    done
  done
  if [ -z "$rows" ]; then echo "no projects"; return 0; fi
  while read -r w n; do
    p="$(project_path "$w" "$n")"
    suffix=""
    if [ ! -d "$p" ]; then suffix=" (missing)"; fi
    printf '%-*s  %-*s  %s%s\n' "$wsw" "$w" "$nw" "$n" "$p" "$suffix"
  done <<< "${rows%$'\n'}"
}

project_import_memory() {
  local ws="" mem d w name pf p canon imported=0 updated=0 unchanged=0 skipped=0 skipped_names="" res
  while [ $# -gt 0 ]; do
    case "$1" in
      --ws) need_value "$@"; ws="$2"; shift 2 ;;
      *) die "usage: task project import-memory [--ws W]" ;;
    esac
  done
  if [ -n "$ws" ]; then valid_ws "$ws" || die "invalid workspace '$ws'"; fi
  mem="${AGENT_MEMORY_HOME:-$HOME/.agent-memory}"
  [ -d "$mem" ] || die "no agent-memory store at $mem"
  lock_acquire
  for pf in "$mem"/*/projects/*/.project-path; do
    [ -f "$pf" ] || continue
    d="$(dirname "$pf")"
    name="$(basename "$d")"
    w="$(basename "$(dirname "$(dirname "$d")")")"
    if [ -n "$ws" ] && [ "$w" != "$ws" ]; then continue; fi
    valid_ws "$w" || continue
    p=""
    IFS= read -r p < "$pf" || true
    if ! valid_project "$name" || [ -z "$p" ] || [ ! -d "$p" ]; then
      skipped=$((skipped + 1))
      skipped_names="$skipped_names, $name"
      continue
    fi
    canon="$(cd -P "$p" && pwd -P)"
    ensure_workspace "$w"
    res="$(register_project "$w" "$name" "$canon")" || exit 1
    case "$res" in
      added) imported=$((imported + 1)) ;;
      updated) updated=$((updated + 1)) ;;
      *) unchanged=$((unchanged + 1)) ;;
    esac
  done
  echo "imported $imported, updated $updated, unchanged $unchanged, skipped $skipped"
  if [ "$skipped" -gt 0 ]; then echo "skipped (path missing): ${skipped_names#, }"; fi
  store_commit || true
}

cmd_project() {
  local sub="${1:-}"
  if [ $# -gt 0 ]; then shift; fi
  case "$sub" in
    add) project_add "$@" ;;
    ls) project_ls "$@" ;;
    import-memory) project_import_memory "$@" ;;
    *) die "usage: task project add|ls|import-memory" ;;
  esac
}
