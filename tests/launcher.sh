#!/usr/bin/env bash
# Standalone, offline tests for skills/agent-tasks/bin/task.
# Uses AGENT_TASKS_RELEASE_BASE_URL (test-only override) with file:// URLs.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LAUNCHER_SRC=$ROOT/skills/agent-tasks/bin/task

TMP=$(mktemp -d "${TMPDIR:-/tmp}/launcher-test.XXXXXX") && TMP=$(cd -P "$TMP" && pwd)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { # name, command...  (passes when the command succeeds)
  n=$1; shift
  if "$@"; then ok "$n"; else bad "$n"; fi
}
eq() { [ "$1" = "$2" ]; }

sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

# Fake release: tarball containing a `task` shell script.
REL=$TMP/releases
VERSION=9.9.9
TARGETS="aarch64-apple-darwin x86_64-apple-darwin x86_64-unknown-linux-musl aarch64-unknown-linux-musl"
mkdir -p "$REL/v$VERSION" "$TMP/pkg"
cat >"$TMP/pkg/task" <<'EOF'
#!/bin/sh
echo "fake-task args=$* self=${AGENT_TASKS_SELF:-}"
EOF
chmod +x "$TMP/pkg/task"
for t in $TARGETS; do
  tar -czf "$REL/v$VERSION/task-$t.tar.gz" -C "$TMP/pkg" task
done
GOOD_SHA=$(sha "$REL/v$VERSION/task-aarch64-apple-darwin.tar.gz")
# All tarballs are identical bytes content-wise but gzip headers may differ; hash each.
write_release() { # dir, good|bad
  {
    echo "version $VERSION"
    for t in $TARGETS; do
      if [ "$2" = good ]; then
        echo "sha256 $t $(sha "$REL/v$VERSION/task-$t.tar.gz")"
      else
        echo "sha256 $t 0000000000000000000000000000000000000000000000000000000000000000"
      fi
    done
  } >"$1/release.txt"
}
: "$GOOD_SHA"

new_install() { # name -> dir with launcher
  d=$TMP/$1
  mkdir -p "$d/bin"
  cp "$LAUNCHER_SRC" "$d/bin/task"
  chmod +x "$d/bin/task"
  echo "$d/bin"
}

export AGENT_TASKS_RELEASE_BASE_URL="file://$REL"
unset AGENT_TASKS_BIN

# --- 1. download + verify, then cache hit -----------------------------------
BIN1=$(new_install t1)
write_release "$BIN1" good
export XDG_CACHE_HOME=$TMP/cache1
out=$("$BIN1/task" hello world 2>"$TMP/err1"); rc=$?
if [ $rc -eq 0 ] && [ "$out" = "fake-task args=hello world self=$BIN1/task" ]; then ok "download+verify runs binary"; else bad "download+verify runs binary"; fi
cached=$(find "$XDG_CACHE_HOME/agent-tasks/$VERSION" -name task -type f | head -n1)
if [ -x "$cached" ]; then ok "binary cached"; else bad "binary cached"; fi
leftover=$(find "$XDG_CACHE_HOME" -name '.tmp.*' | wc -l | tr -d ' ')
if [ "$leftover" = 0 ]; then ok "no temp leftovers"; else bad "no temp leftovers"; fi

# Cache hit: break the base URL; must still work.
out=$(AGENT_TASKS_RELEASE_BASE_URL="file:///nonexistent" "$BIN1/task" again 2>"$TMP/err1b"); rc=$?
if [ $rc -eq 0 ] && [ "$out" = "fake-task args=again self=$BIN1/task" ]; then ok "cache hit needs no network"; else bad "cache hit needs no network"; fi

# --- 2. checksum mismatch refuses to run ------------------------------------
BIN2=$(new_install t2)
write_release "$BIN2" bad
export XDG_CACHE_HOME=$TMP/cache2
out=$("$BIN2/task" x 2>"$TMP/err2"); rc=$?
if [ $rc -eq 1 ]; then ok "mismatch exits 1"; else bad "mismatch exits 1"; fi
if [ -z "$out" ]; then ok "mismatch prints nothing from binary"; else bad "mismatch prints nothing from binary"; fi
if grep -q '^task: checksum mismatch' "$TMP/err2"; then ok "mismatch message on stderr"; else bad "mismatch message on stderr"; fi
nbin=$(find "$XDG_CACHE_HOME" -name task -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$nbin" = 0 ]; then ok "mismatch leaves no binary"; else bad "mismatch leaves no binary"; fi

# --- 3. AGENT_TASKS_BIN override -------------------------------------------
BIN3=$(new_install t3)
echo "garbage" >"$BIN3/release.txt"
export XDG_CACHE_HOME=$TMP/cache3
out=$(AGENT_TASKS_BIN="$TMP/pkg/task" "$BIN3/task" ov 2>&1); rc=$?
if [ $rc -eq 0 ] && [ "$out" = "fake-task args=ov self=$BIN3/task" ]; then ok "AGENT_TASKS_BIN override"; else bad "AGENT_TASKS_BIN override"; fi
if [ ! -e "$XDG_CACHE_HOME" ]; then ok "override does not touch cache"; else bad "override does not touch cache"; fi

# --- 4. symlinked invocation ------------------------------------------------
BIN4=$(new_install t4)
write_release "$BIN4" good
mkdir -p "$TMP/t4/link/deeper"
ln -s "$BIN4/task" "$TMP/t4/link/task"
ln -s ../task "$TMP/t4/link/deeper/task"
export XDG_CACHE_HOME=$TMP/cache4
out=$("$TMP/t4/link/task" viasym 2>/dev/null); rc=$?
if [ $rc -eq 0 ] && [ "$out" = "fake-task args=viasym self=$BIN4/task" ]; then ok "symlink finds release.txt, SELF is real path"; else bad "symlink finds release.txt, SELF is real path"; fi
out=$("$TMP/t4/link/deeper/task" relsym 2>/dev/null); rc=$?
if [ $rc -eq 0 ] && [ "$out" = "fake-task args=relsym self=$BIN4/task" ]; then ok "relative symlink chain"; else bad "relative symlink chain"; fi

# --- 5. missing release.txt ---------------------------------------------------
BIN5=$(new_install t5)
out=$("$BIN5/task" 2>"$TMP/err5"); rc=$?
if [ $rc -eq 1 ] && grep -q '^task: ' "$TMP/err5"; then ok "missing release.txt errors"; else bad "missing release.txt errors"; fi

# --- 6. skill root is exported for the binary ------------------------------
BIN6=$(new_install t6)
cat >"$TMP/pkg/root" <<'EOF2'
#!/bin/sh
echo "root=${AGENT_TASKS_ROOT:-}"
EOF2
chmod +x "$TMP/pkg/root"
out=$(AGENT_TASKS_BIN="$TMP/pkg/root" "$BIN6/task" 2>&1)
if [ "$out" = "root=$TMP/t6" ]; then ok "AGENT_TASKS_ROOT is the skill dir"; else bad "AGENT_TASKS_ROOT is the skill dir ($out)"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
