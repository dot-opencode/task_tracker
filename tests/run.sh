#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC2034 # used by the sourced tests/cli/*.sh
TASK="$ROOT/skills/agent-tasks/bin/task"
PASS=0; FAIL=0

# The skill's bin/task is a shim around target/release/task: build it once.
if [ -z "${SKIP_CARGO_BUILD:-}" ]; then
  (cd "$ROOT" && cargo build --release --quiet) || { echo "cargo build --release failed"; exit 1; }
fi
FILTER="${1:-}"

setup() {
  set -e
  TMP="$(mktemp -d)"
  TMP="$(cd -P "$TMP" && pwd -P)"
  export AGENT_TASKS_HOME="$TMP/store"
  export HOME="$TMP/home"                 # isolates global git config too
  unset XDG_CONFIG_HOME AGENT_MEMORY_HOME AGENT_TASKS_LOCK_TIMEOUT
  export GIT_CONFIG_NOSYSTEM=1
  # Fixed "now" for archiving: fixtures dated 2026-10-01 must not age into archive.
  export AGENT_TASKS_NOW="2026-10-02 00:00"
  # MR auto-check is off except in its own tests.
  export AGENT_TASKS_MRCHECK=0
  mkdir -p "$HOME" "$TMP/bin"
  export PATH="$TMP/bin:$PATH"
  git config --global user.email "test@example.com"
  git config --global user.name "Test"
  git config --global init.defaultBranch main
  # Every commit forks a detached `git maintenance run --auto`; it must not
  # outlive the test and race the trap's `rm -rf "$TMP"`.
  git config --global gc.auto 0
  cd "$TMP"
}

fail() { echo "  assertion failed: $*"; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "no '$2' in: $1" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "unexpected '$2' in: $1" ;; *) ;; esac; }
assert_file() { [ -f "$1" ] || fail "missing file: $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "unexpected file: $1"; }

# Sources a lib into the test shell; a missing file fails the test explicitly.
load_lib() {
  local f="$ROOT/skills/agent-tasks/lib/$1.sh"
  [ -f "$f" ] || fail "missing lib: $1.sh"
  # shellcheck source=/dev/null # lib chosen by name
  . "$f"
}

last_subject() { git -C "$AGENT_TASKS_HOME" log -1 --format=%s; }
last_body() { git -C "$AGENT_TASKS_HOME" log -1 --format=%b; }

# Path of a task found by id, without using the CLI under test.
task_path_of() {
  local f
  for f in "$AGENT_TASKS_HOME"/*/*/"$1".md "$AGENT_TASKS_HOME"/*/*/"$1"-*.md; do
    if [ -e "$f" ]; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

# Minimal valid task file, written by hand so store tests do not need `task new`.
write_task_file() {   # write_task_file <folder> <id> <title>
  local folder="$1" id="$2" title="$3" slug dir file
  # shellcheck disable=SC2018,SC2019 # ASCII-only on purpose (LC_ALL=C)
  slug="$(printf '%s' "$title" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
  dir="$AGENT_TASKS_HOME/work/$folder"
  mkdir -p "$dir"
  file="$dir/$id-$slug.md"
  printf -- '---\nid: %s\ntitle: "%s"\ncreated: 2026-10-01\n---\n\nBody of %s.\n\n## Log\n- 2026-10-01 09:00 task: created in %s\n' \
    "$id" "$title" "$id" "$folder" > "$file"
}

run_test() {
  case "$1" in *"$FILTER"*) ;; *) return 0 ;; esac
  (
    setup
    trap 'cd /; rm -rf "$TMP"' EXIT
    "$1"
  )
  local rc=$?
  if [ "$rc" -eq 0 ]; then PASS=$((PASS+1)); echo "ok - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi
}

for f in "$ROOT"/tests/cli/*.sh; do
  [ -e "$f" ] || continue
  # shellcheck source=/dev/null # test files are found by glob
  . "$f"
done

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do run_test "$t"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
