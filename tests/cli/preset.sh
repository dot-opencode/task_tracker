# shellcheck shell=bash
# Slim preset → task session model. Uses at_stubs/at_project/at_auto_on from run.sh.

pr_slim() {   # pr_slim <json> — writes the slim config and points the CLI at it
  printf '%s\n' "$1" > "$TMP/slim.json"
  export AGENT_TASKS_SLIM_CONFIG="$TMP/slim.json"
}

pr_start() {   # pr_start <config lines> — one ready task, one tick; echoes the session payload
  at_stubs
  "$TASK" ls >/dev/null
  at_project
  printf '%s\n' "$1" >> "$AGENT_TASKS_HOME/config.toml"
  at_task 01_ready T-0001 "Preset" project crm
  at_auto_on
  "$TASK" run --once >/dev/null
  sed -n 1p "$TMP/opencode.data" 2>/dev/null || true
}

test_preset_array_form() {
  pr_slim '{"presets":{"claude":{"orchestrator":{"model":[{"id":"cpa-gui/claude-opus-5-5","variant":"high"},{"id":"x/y"}]}}}}'
  local p
  p="$(pr_start 'preset = "claude"')"
  assert_eq "$(jq -c .model <<< "$p")" '{"providerID":"cpa-gui","id":"claude-opus-5-5","variant":"high"}'
  assert_eq "$(at_folder T-0001)" 02_exploring
}

test_preset_object_form() {
  pr_slim '{"presets":{"claude":{"orchestrator":{"model":{"id":"a/b/c","variant":"low"}}}}}'
  assert_eq "$(jq -c .model <<< "$(pr_start 'preset = "claude"')")" '{"providerID":"a","id":"b/c","variant":"low"}'
}

test_preset_string_form_has_no_variant() {
  pr_slim '{"presets":{"claude":{"orchestrator":{"model":"a/b"}}}}'
  assert_eq "$(jq -c .model <<< "$(pr_start 'preset = "claude"')")" '{"providerID":"a","id":"b"}'
}

test_preset_uses_configured_agent() {
  pr_slim '{"presets":{"claude":{"orchestrator":{"model":"a/orch"},"build":{"model":[{"id":"a/bld","variant":"max"}]}}}}'
  local p
  p="$(pr_start $'agent = "build"\npreset = "claude"')"
  assert_eq "$(jq -r .agent <<< "$p")" build
  assert_eq "$(jq -c .model <<< "$p")" '{"providerID":"a","id":"bld","variant":"max"}'
}

test_preset_model_override_wins() {
  pr_slim '{"presets":{"claude":{"orchestrator":{"model":"a/b"}}}}'
  assert_eq "$(jq -c .model <<< "$(pr_start $'preset = "claude"\nmodel = "x/y"')")" '{"providerID":"x","id":"y"}'
}

test_preset_missing_blocks_task() {
  pr_slim '{"presets":{"other":{}}}'
  pr_start 'preset = "claude"' >/dev/null
  assert_eq "$(at_folder T-0001)" blocked
  assert_contains "$(tail -n 1 "$(task_path_of T-0001)")" "preset 'claude' not found in $TMP/slim.json"
  assert_not_contains "$(cat "$TMP/opencode.log")" "POST"
}

test_preset_missing_file_blocks_task() {
  export AGENT_TASKS_SLIM_CONFIG="$TMP/nope.json"
  pr_start 'preset = "claude"' >/dev/null
  assert_eq "$(at_folder T-0001)" blocked
  assert_contains "$(tail -n 1 "$(task_path_of T-0001)")" "preset 'claude' not found in $TMP/nope.json"
}

test_preset_doctor_check() {
  at_stubs
  pr_slim '{"presets":{"claude":{"orchestrator":{"model":"a/b"}}}}'
  "$TASK" ls >/dev/null
  printf 'preset = "claude"\n' >> "$AGENT_TASKS_HOME/config.toml"
  assert_eq "$("$TASK" doctor)" "ok: 0 tasks, 0 projects"
  printf 'preset = "nope"\n' >> "$AGENT_TASKS_HOME/config.toml"
  local out rc=0
  out="$("$TASK" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "config.toml: preset 'nope' not found in $TMP/slim.json"
}

test_preset_auto_status_line() {
  at_stubs
  "$TASK" ls >/dev/null
  assert_contains "$("$TASK" auto)" "model: OpenCode default"
  pr_slim '{"presets":{"claude":{"orchestrator":{"model":[{"id":"cpa-gui/claude-opus-5-5","variant":"high"}]}}}}'
  printf 'preset = "claude"\n' >> "$AGENT_TASKS_HOME/config.toml"
  assert_contains "$("$TASK" auto)" "model: cpa-gui/claude-opus-5-5 (high) from preset claude"
}
