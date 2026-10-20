# shellcheck shell=bash
# Task 6: session binding. `opencode` is a stub in $TMP/bin that logs its arguments.

stub_opencode() {   # stub_opencode <get-response-json>
  OC_LOG="$TMP/opencode.log"
  export OC_LOG
  printf '%s\n' "$1" > "$TMP/oc-get.json"
  cat > "$TMP/bin/opencode" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$OC_LOG"
if [ "$1 $2" = "api get" ]; then
  [ -s "$OC_GET" ] || exit 1
  cat "$OC_GET"
  [ -z "${OC_FAIL_GET:-}" ] || exit 1
elif [ "$1 $2" = "api patch" ]; then
  [ -z "${OC_FAIL_PATCH:-}" ] || exit 1
  echo '{}'
fi
EOF
  chmod +x "$TMP/bin/opencode"
  export OC_GET="$TMP/oc-get.json"
}

test_session_bind_success() {
  stub_opencode '{"data":{"id":"ses_abc1","metadata":{"keep":"me","n":1}}}'
  "$TASK" new "Bindable" >/dev/null
  local out f
  out="$("$TASK" bind 1 --session ses_abc1)"
  assert_eq "$out" "T-0001: bound to ses_abc1"
  f="$(task_path_of T-0001)"
  assert_contains "$(cat "$f")" "session: ses_abc1"
  assert_contains "$(tail -n 1 "$f")" "agent: bound session ses_abc1"
  assert_eq "$(last_subject)" "tasks(work): T-0001 edit"
  assert_contains "$(cat "$OC_LOG")" "api get /api/session/ses_abc1"
  assert_contains "$(cat "$OC_LOG")" 'api patch /api/session/ses_abc1 --data {"metadata":{"keep":"me","n":1,"agent_tasks":{"id":"T-0001"}}}'
}

test_session_bind_without_existing_metadata() {
  stub_opencode '{"data":{"id":"ses_abc1"}}'
  "$TASK" new "Bindable" >/dev/null
  "$TASK" bind T-0001 --session ses_abc1 >/dev/null
  assert_contains "$(cat "$OC_LOG")" '--data {"metadata":{"agent_tasks":{"id":"T-0001"}}}'
}

test_session_bind_unknown_session_leaves_task_unchanged() {
  stub_opencode ''
  "$TASK" new "Bindable" >/dev/null
  local before out rc=0
  before="$(cat "$(task_path_of T-0001)")"
  out="$("$TASK" bind 1 --session ses_missing 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "session ses_missing not found (is OpenCode running?)"
  assert_eq "$(cat "$(task_path_of T-0001)")" "$before"
  case "$(cat "$OC_LOG")" in *"api patch"*) fail "patched an unknown session" ;; esac
}

test_session_bind_wrong_id_in_response() {
  stub_opencode '{"data":{"id":"ses_other"}}'
  "$TASK" new "Bindable" >/dev/null
  local out rc=0
  out="$("$TASK" bind 1 --session ses_abc1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "not found"
}

test_session_bind_refuses_session_of_another_task() {
  stub_opencode '{"data":{"id":"ses_abc1"}}'
  "$TASK" new "First" >/dev/null
  "$TASK" new "Second" >/dev/null
  "$TASK" bind 1 --session ses_abc1 >/dev/null
  : > "$OC_LOG"
  local out rc=0
  out="$("$TASK" bind 2 --session ses_abc1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "session ses_abc1 is already bound to T-0001"
  case "$(cat "$OC_LOG")" in *"api patch"*) fail "patched despite conflict" ;; esac
  assert_not_contains "$(cat "$(task_path_of T-0002)")" "session:"
}

test_session_bind_again_to_same_task_is_allowed() {
  stub_opencode '{"data":{"id":"ses_abc1"}}'
  "$TASK" new "First" >/dev/null
  "$TASK" bind 1 --session ses_abc1 >/dev/null
  assert_eq "$("$TASK" bind 1 --session ses_abc1)" "T-0001: bound to ses_abc1"
  assert_eq "$(grep -c '^session:' "$(task_path_of T-0001)")" 1
}

test_session_bind_patch_failure_leaves_task_unchanged() {
  stub_opencode '{"data":{"id":"ses_abc1"}}'
  "$TASK" new "First" >/dev/null
  local before out rc=0
  before="$(cat "$(task_path_of T-0001)")"
  out="$(OC_FAIL_PATCH=1 "$TASK" bind 1 --session ses_abc1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "left unchanged"
  assert_eq "$(cat "$(task_path_of T-0001)")" "$before"
}

test_session_bind_rejects_bad_input() {
  stub_opencode '{"data":{"id":"ses_abc1"}}'
  "$TASK" new "First" >/dev/null
  local out rc=0
  out="$("$TASK" bind 1 --session nonsense 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid session id"
  rc=0; out="$("$TASK" bind 1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: task bind"
  rc=0; out="$("$TASK" bind 9 --session ses_abc1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "no task T-0009"
  assert_eq "$(grep -c 'api patch' "$OC_LOG" || true)" 0
}

test_session_find() {
  stub_opencode '{"data":{"id":"ses_abc1"}}'
  "$TASK" new "First" >/dev/null
  "$TASK" new "Second" >/dev/null
  "$TASK" bind 2 --session ses_abc1 >/dev/null
  assert_eq "$("$TASK" find --session ses_abc1)" "T-0002"
  local out rc=0
  out="$("$TASK" find --session ses_none)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" ""
  rc=0; "$TASK" find --session bad >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 1
  rc=0; "$TASK" find >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 1
}

test_session_find_with_empty_store() {
  local rc=0 out
  out="$("$TASK" find --session ses_abc1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" ""
}

test_session_bind_refuses_malformed_frontmatter() {
  "$TASK" new "Broken" >/dev/null
  local f before out rc=0
  f="$(task_path_of T-0001)"
  printf -- '---\nid: T-0001\ntitle: "Broken"\n\nsource: x\n\n## Log\n' > "$f"
  git -C "$AGENT_TASKS_HOME" add -A
  git -C "$AGENT_TASKS_HOME" commit -q -m broken
  before="$(cat "$f")"
  printf '#!/bin/sh\necho "{\\"data\\":{\\"id\\":\\"ses_abc\\"}}"\n' > "$TMP/bin/opencode"
  chmod +x "$TMP/bin/opencode"
  out="$("$TASK" bind 1 --session ses_abc 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "malformed frontmatter in work/00_backlog/T-0001-broken.md (run 'task doctor')"
  assert_eq "$(cat "$f")" "$before"
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
}
