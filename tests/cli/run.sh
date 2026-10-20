# shellcheck shell=bash
# Stage 2, task 5: the automation tick. opencode is the at_stubs stub; requests
# land in $TMP/opencode.log, --data payloads in $TMP/opencode.data.

at_auto_on() { printf 'until=0\nsince=%s\n' "$(date +%s)" > "$AGENT_TASKS_HOME/.auto"; }

# A registered project "crm" at $TMP/proj.
at_project() {
  mkdir -p "$TMP/proj" "$AGENT_TASKS_HOME/work/.projects"
  printf '%s\n' "$TMP/proj" > "$AGENT_TASKS_HOME/work/.projects/crm"
  git -C "$AGENT_TASKS_HOME" add -A
  git -C "$AGENT_TASKS_HOME" commit -q -m "test: project"
}

at_age() {   # at_age <id> <minutes> — sets the task file's mtime back
  touch -t "$(minutes_ago "$2")" "$(task_path_of "$1")"
}

test_run_without_auto_does_nothing() {
  at_stubs
  at_task 01_ready T-0001 "Queued" project crm
  local out before
  before="$(at_commits)"
  out="$("$TASK" run --once 2>&1)"
  assert_eq "$out" ""
  assert_eq "$(cat "$TMP/opencode.log")" ""
  assert_eq "$(at_folder T-0001)" 01_ready
  assert_eq "$(at_commits)" "$before"
}

test_run_expired_turns_automation_off() {
  at_stubs
  at_task 01_ready T-0001 "Queued" project crm
  printf 'until=%s\nsince=1\n' "$(($(date +%s) - 5))" > "$AGENT_TASKS_HOME/.auto"
  mkdir -p "$HOME/Library/LaunchAgents"
  : > "$HOME/Library/LaunchAgents/agent-tasks.run.plist"
  local out
  out="$("$TASK" run --once)"
  assert_eq "$out" "[agent-tasks] automation off (the active period ended)"
  assert_no_file "$AGENT_TASKS_HOME/.auto"
  assert_no_file "$HOME/Library/LaunchAgents/agent-tasks.run.plist"
  assert_contains "$(cat "$TMP/launchctl.log")" "bootout gui/$(id -u)/agent-tasks.run"
  assert_eq "$(at_folder T-0001)" 01_ready
  assert_eq "$(cat "$TMP/opencode.log")" ""
}

test_run_without_auto_unloads_stray_job() {
  at_stubs
  "$TASK" ls >/dev/null
  mkdir -p "$HOME/Library/LaunchAgents"
  : > "$HOME/Library/LaunchAgents/agent-tasks.run.plist"
  : > "$TMP/launchctl.loaded"
  assert_eq "$("$TASK" run --once 2>&1)" ""
  assert_no_file "$HOME/Library/LaunchAgents/agent-tasks.run.plist"
  assert_eq "$(cat "$TMP/launchctl.log")" "bootout gui/$(id -u)/agent-tasks.run"
  assert_eq "$(cat "$TMP/opencode.log")" ""
}

test_run_skips_invalid_session_fields() {
  at_stubs
  at_task 02_exploring T-0001 "Bad" session '"ses_x; echo pwned"'
  at_task 07_approved T-0002 "Bad too" session '"ses_y; echo pwned"'
  at_age T-0001 90
  at_auto_on
  local out err
  err="$("$TASK" run --once 2>&1 >/dev/null)"
  assert_contains "$err" "T-0001 has an invalid session field; skipped"
  assert_eq "$(at_folder T-0001)" 02_exploring
  assert_eq "$(at_folder T-0002)" blocked
  assert_contains "$(tail -n 1 "$(task_path_of T-0002)")" "T-0002 has an invalid session field"
  out="$(cat "$TMP/opencode.log")"
  assert_not_contains "$out" "pwned"
  assert_not_contains "$out" "prompt"
}

test_signal_input_right_after_run_start_does_not_quiet() {
  at_stubs
  "$TASK" ls >/dev/null
  at_project
  at_task 01_ready T-0001 "Kickoff" project crm
  at_auto_on
  "$TASK" run --once >/dev/null
  # The plugin reports the kickoff prompt as input, then the agent asks.
  "$TASK" signal 1 input --session ses_test1 --text "You are working on task T-0001" >/dev/null
  assert_no_file "$AGENT_TASKS_HOME/.notify/T-0001.last-user"
  assert_no_file "$AGENT_TASKS_HOME/.notify/T-0001.auto-prompt"
  "$TASK" signal 1 question --session ses_test1 --text "First question?" >/dev/null
  at_wait_for "$TMP/alerter.log" "--message=First question?"
  # The next input is the user's own.
  "$TASK" signal 1 input --session ses_test1 --text "answer" >/dev/null
  assert_file "$AGENT_TASKS_HOME/.notify/T-0001.last-user"
  at_reap_alerters
}

test_approve_now_from_approved_sends_implementation_prompt() {
  at_stubs
  at_task 07_approved T-0001 "Waiting" session ses_a1
  local out
  out="$("$TASK" approve 1 --now)"
  assert_eq "$out" "start
sent the implementation prompt to session ses_a1"
  assert_eq "$(at_folder T-0001)" 08_implementing
  assert_contains "$(cat "$TMP/opencode.log")" "api post /api/session/ses_a1/prompt --data"
  assert_eq "$(jq -c .skills "$TMP/opencode.data")" '[{"id":"subagent-driven-development"}]'
  assert_eq "$(jq -c .metadata "$TMP/opencode.data")" '{"agent_tasks":{"automated":true}}'
  assert_file "$AGENT_TASKS_HOME/.notify/T-0001.auto-prompt"
  # From 06 the agent continues in its own turn: no prompt.
  : > "$TMP/opencode.log"
  at_task 06_plan_review T-0002 "Reviewing" session ses_b1
  assert_eq "$("$TASK" approve 2 --now)" "start"
  assert_eq "$(cat "$TMP/opencode.log")" ""
  # A failed prompt is a warning; the task stays in 08.
  at_task 07_approved T-0003 "Offline" session ses_c1
  : > "$TMP/oc-fail-prompt"
  local err
  err="$("$TASK" approve 3 --now 2>&1 >/dev/null)"
  assert_contains "$err" "could not send the implementation prompt to session ses_c1"
  assert_eq "$(at_folder T-0003)" 08_implementing
}

test_run_commits_manual_edits() {
  at_stubs
  at_task 00_backlog T-0001 "Edited"
  at_auto_on
  printf 'manual note\n' >> "$(task_path_of T-0001)"
  "$TASK" run --once >/dev/null
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
  assert_eq "$(last_subject)" "tasks(work): T-0001 edit"
}

test_run_starts_ready_task() {
  at_stubs
  "$TASK" ls >/dev/null
  at_project
  at_task 01_ready T-0001 "Fix port drift" project crm
  at_auto_on
  local out f
  out="$("$TASK" run --once)"
  assert_eq "$out" "[agent-tasks] T-0001: 01_ready → 02_exploring (session ses_test1)"
  f="$(task_path_of T-0001)"
  assert_contains "$f" "/work/02_exploring/"
  assert_contains "$(cat "$f")" "session: ses_test1"
  assert_contains "$(tail -n 1 "$f")" "task: 01_ready → 02_exploring — started session ses_test1"
  assert_eq "$(sed -n 1p "$TMP/opencode.log")" "api get /api/session/active"
  assert_contains "$(sed -n 2p "$TMP/opencode.log")" "api post /api/session --data"
  assert_contains "$(sed -n 3p "$TMP/opencode.log")" "api post /api/session/ses_test1/prompt --data"
  assert_file "$AGENT_TASKS_HOME/.notify/T-0001.auto-prompt"
  assert_eq "$(sed -n 1p "$TMP/opencode.data" | jq -c .)" \
    "{\"location\":{\"directory\":\"$TMP/proj\"},\"title\":\"T-0001: Fix port drift\",\"metadata\":{\"agent_tasks\":{\"id\":\"T-0001\"}}}"
  local p
  p="$(sed -n 2p "$TMP/opencode.data")"
  assert_eq "$(jq -c .skills <<< "$p")" '[{"id":"brainstorming"}]'
  assert_eq "$(jq -r .delivery <<< "$p")" queue
  assert_eq "$(jq -c .files <<< "$p")" "[{\"uri\":\"file://$f\",\"name\":\"T-0001.md\"}]"
  assert_eq "$(jq -c .metadata <<< "$p")" '{"agent_tasks":{"automated":true}}'
  assert_eq "$(jq -c 'keys' <<< "$p")" '["delivery","files","metadata","skills","text"]'
  assert_eq "$(jq -r .text <<< "$p")" "You are working on task T-0001 (attached). Explore the codebase yourself first. Then ask the user your first question with the question tool: one question, with options and your recommendation. Do not start implementing."
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
  assert_eq "$(last_subject)" "tasks(work): T-0001 01_ready → 02_exploring"
}

test_run_passes_agent_and_model() {
  at_stubs
  "$TASK" ls >/dev/null
  at_project
  printf 'agent = "build"\nmodel = "anthropic/claude-x/beta"\n' >> "$AGENT_TASKS_HOME/config.toml"
  at_task 01_ready T-0001 "Configured" project crm
  at_auto_on
  "$TASK" run --once >/dev/null
  local p
  p="$(sed -n 1p "$TMP/opencode.data")"
  assert_eq "$(jq -r .agent <<< "$p")" build
  assert_eq "$(jq -c .model <<< "$p")" '{"providerID":"anthropic","id":"claude-x/beta"}'
}

test_run_continues_approved_before_ready() {
  at_stubs
  "$TASK" ls >/dev/null
  at_project
  at_task 01_ready T-0001 "Ready" project crm
  at_task 07_approved T-0002 "Approved" session ses_b1
  at_task 08_implementing T-0003 "Busy" session ses_c1
  echo '{"data":{"ses_c1":{"type":"running"}}}' > "$TMP/active.json"
  at_auto_on
  local out p
  out="$("$TASK" run --once)"
  assert_eq "$out" "[agent-tasks] T-0002: 07_approved → 08_implementing (session ses_b1)"
  assert_eq "$(at_folder T-0002)" 08_implementing
  assert_eq "$(at_folder T-0001)" 01_ready
  assert_contains "$(tail -n 1 "$(task_path_of T-0002)")" "07_approved → 08_implementing — implementation starts (active period)"
  assert_contains "$(cat "$TMP/opencode.log")" "api post /api/session/ses_b1/prompt --data"
  p="$(cat "$TMP/opencode.data")"
  assert_eq "$(jq -c . <<< "$p")" '{"text":"The implementation plan was approved. Implement it with subagent-driven-development, following the plan.","skills":[{"id":"subagent-driven-development"}],"delivery":"queue","metadata":{"agent_tasks":{"automated":true}}}'
  assert_file "$AGENT_TASKS_HOME/.notify/T-0002.auto-prompt"
  assert_eq "$(jq -r .text <<< "$p")" "The implementation plan was approved. Implement it with subagent-driven-development, following the plan."
  assert_eq "$(jq -c .skills <<< "$p")" '[{"id":"subagent-driven-development"}]'
  assert_eq "$(jq -r .delivery <<< "$p")" queue
}

test_run_fills_free_slots_oldest_first() {
  at_stubs
  "$TASK" ls >/dev/null
  at_project
  printf 'max_active = 3\n' >> "$AGENT_TASKS_HOME/config.toml"
  at_task 01_ready T-0001 "First" project crm
  sleep 1
  at_task 01_ready T-0002 "Second" project crm
  at_task 01_ready T-0003 "Third" project crm
  sleep 1
  touch "$(task_path_of T-0001)"   # ctime moves: T-0001 is now the newest
  at_task 07_approved T-0004 "Approved" session ses_d1
  at_auto_on
  local out
  out="$("$TASK" run --once)"
  assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "[agent-tasks] T-0004: 07_approved → 08_implementing (session ses_d1)"
  assert_contains "$(printf '%s\n' "$out" | sed -n 2p)" "[agent-tasks] T-0002: 01_ready → 02_exploring"
  assert_contains "$(printf '%s\n' "$out" | sed -n 3p)" "[agent-tasks] T-0003: 01_ready → 02_exploring"
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 3
  assert_eq "$(at_folder T-0001)" 01_ready
}

test_run_blocks_on_project_problems() {
  at_stubs
  "$TASK" ls >/dev/null
  at_task 01_ready T-0001 "Unregistered" project ghost
  at_task 01_ready T-0002 "No project"
  mkdir -p "$AGENT_TASKS_HOME/work/.projects"
  printf '%s\n' "$TMP/nowhere" > "$AGENT_TASKS_HOME/work/.projects/gone"
  at_task 01_ready T-0003 "Missing dir" project gone
  at_auto_on
  local out
  out="$("$TASK" run --once)"
  assert_contains "$out" "[agent-tasks] T-0001: 01_ready → blocked — project ghost is not registered"
  assert_contains "$out" "[agent-tasks] T-0002: 01_ready → blocked — task has no project"
  assert_contains "$out" "[agent-tasks] T-0003: 01_ready → blocked — project directory missing: $TMP/nowhere"
  assert_contains "$(tail -n 1 "$(task_path_of T-0001)")" "01_ready → blocked — project ghost is not registered"
  assert_contains "$(cat "$(task_path_of T-0001)")" "blocked_from: 01_ready"
  assert_eq "$(grep -c 'api post' "$TMP/opencode.log" || true)" 0
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
}

test_run_blocks_when_opencode_requests_fail() {
  at_stubs
  "$TASK" ls >/dev/null
  at_project
  at_task 01_ready T-0001 "Create fails" project crm
  at_auto_on
  : > "$TMP/oc-fail-create"
  assert_eq "$("$TASK" run --once)" "[agent-tasks] T-0001: 01_ready → blocked — could not create an OpenCode session"
  assert_not_contains "$(cat "$(task_path_of T-0001)")" "session:"
  rm "$TMP/oc-fail-create"
  "$TASK" mv 1 ready >/dev/null
  : > "$TMP/oc-fail-prompt"
  assert_eq "$("$TASK" run --once)" "[agent-tasks] T-0001: 02_exploring → blocked — could not send the first prompt to session ses_test1"
  assert_contains "$(cat "$(task_path_of T-0001)")" "session: ses_test1"
  assert_contains "$(cat "$(task_path_of T-0001)")" "blocked_from: 02_exploring"
  at_task 07_approved T-0002 "Prompt fails" session ses_b1
  assert_eq "$("$TASK" run --once)" "[agent-tasks] T-0002: 08_implementing → blocked — could not send the implementation prompt to session ses_b1"
}

test_run_restart_logs_previous_session() {
  at_stubs
  "$TASK" ls >/dev/null
  at_project
  at_task 01_ready T-0001 "Restart" project crm session ses_old1
  at_auto_on
  "$TASK" run --once >/dev/null
  assert_contains "$(cat "$(task_path_of T-0001)")" "task: restart: previous session ses_old1"
  assert_contains "$(cat "$(task_path_of T-0001)")" "session: ses_test1"
  assert_eq "$(grep -c '^session:' "$(task_path_of T-0001)")" 1
}

test_run_signals_stalled_sessions() {
  at_stubs
  at_task 02_exploring T-0001 "Stale" session ses_a1
  at_task 08_implementing T-0002 "Running" session ses_b1
  at_task 08_implementing T-0003 "Recent" session ses_c1
  at_task 02_exploring T-0004 "Child runs" session ses_d1
  echo '{"data":{"ses_b1":{"type":"running"},"ses_kid":{"type":"running"}}}' > "$TMP/active.json"
  # Only ses_d1 has the running child; the stub answers the same list for every parent.
  echo '{"data":[{"id":"ses_kid","parentID":"ses_d1"}]}' > "$TMP/children.json"
  at_age T-0001 31; at_age T-0002 120; at_age T-0004 60
  at_auto_on
  local out
  out="$("$TASK" run --once)"
  assert_contains "$out" "[agent-tasks] T-0001: no activity for 30 min"
  assert_contains "$out" "[agent-tasks] T-0001: 02_exploring → blocked"
  assert_not_contains "$out" "T-0002"
  assert_not_contains "$out" "T-0003"
  assert_not_contains "$out" "T-0004"
  assert_eq "$(at_folder T-0001)" blocked
  assert_contains "$(tail -n 1 "$(task_path_of T-0001)")" "02_exploring → blocked — stalled — no activity for 30 min"
  assert_eq "$(at_folder T-0002)" 08_implementing
  assert_eq "$(at_folder T-0003)" 08_implementing
  assert_eq "$(at_folder T-0004)" 02_exploring
}

test_run_without_opencode_service_skips_stale_check() {
  at_stubs
  at_task 02_exploring T-0001 "Stale" session ses_a1
  at_age T-0001 90
  at_auto_on
  : > "$TMP/oc-fail-active"
  local err
  err="$("$TASK" run --once 2>&1 >/dev/null)"
  assert_contains "$err" "[agent-tasks] cannot list active sessions"
  assert_eq "$(at_folder T-0001)" 02_exploring
}

test_run_rejects_bad_arguments() {
  local out rc=0
  out="$("$TASK" run 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: task run --once"
  rc=0; out="$("$TASK" run --twice 2>&1)" || rc=$?
  assert_eq "$rc" 1
}

test_run_kickoff_uri_encodes_store_path() {
  # A store path with a space must still produce a valid file:// URI.
  export AGENT_TASKS_HOME="$TMP/store with space"
  at_stubs
  "$TASK" ls >/dev/null
  at_project
  at_task 01_ready T-0001 "Spaced" project crm
  at_auto_on
  "$TASK" run --once >/dev/null
  local p
  p="$(sed -n 2p "$TMP/opencode.data")"
  assert_eq "$(jq -r '.files[0].uri' <<< "$p")" "file://$TMP/store%20with%20space/work/02_exploring/T-0001-spaced.md"
}
