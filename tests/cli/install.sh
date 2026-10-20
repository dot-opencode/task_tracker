# shellcheck shell=bash
# Installing the OpenCode plugin. The plugin file itself is covered by
# tests/plugin.test.js; these tests use a copy of the CLI with a placeholder plugin.

# Copies bin/ (the launcher) into a fake package ($TMP/repo/skills/agent-tasks;
# AGENT_TASKS_BIN from tests/run.sh points at the real build) with a stand-in
# opencode/agent-tasks.js.
at_pkg() {
  AT_PKG="$TMP/repo/skills/agent-tasks"
  mkdir -p "$AT_PKG/opencode"
  cp -R "$ROOT/skills/agent-tasks/bin" "$AT_PKG/"
  printf 'export default { id: "agent-tasks", setup() {} }\n' > "$AT_PKG/opencode/agent-tasks.js"
  AT_PKG_TASK="$AT_PKG/bin/task"
}

test_install_opencode_symlinks_plugin() {
  at_pkg
  local out dest
  dest="$HOME/.config/opencode/plugins/agent-tasks.js"
  out="$("$AT_PKG_TASK" install-opencode)"
  assert_eq "$out" "installed OpenCode plugin: $dest (run 'opencode reload' or restart OpenCode)"
  [ -L "$dest" ] || fail "not a symlink: $dest"
  assert_eq "$(readlink "$dest")" "$AT_PKG/opencode/agent-tasks.js"
  assert_eq "$("$AT_PKG_TASK" install-opencode)" "OpenCode plugin already installed: $dest"
  assert_eq "$(readlink "$dest")" "$AT_PKG/opencode/agent-tasks.js"
}

test_install_opencode_honours_xdg_and_replaces_stale_link() {
  at_pkg
  local dest
  export XDG_CONFIG_HOME="$TMP/xdg"
  dest="$XDG_CONFIG_HOME/opencode/plugins/agent-tasks.js"
  mkdir -p "$(dirname "$dest")"
  ln -s "$TMP/old/agent-tasks.js" "$dest"
  assert_contains "$("$AT_PKG_TASK" install-opencode)" "installed OpenCode plugin: $dest"
  assert_eq "$(readlink "$dest")" "$AT_PKG/opencode/agent-tasks.js"
  assert_no_file "$HOME/.config/opencode"
}

test_install_opencode_through_cli_symlink() {
  at_pkg
  ln -s "$AT_PKG_TASK" "$TMP/bin/task"
  task install-opencode >/dev/null
  assert_eq "$(readlink "$HOME/.config/opencode/plugins/agent-tasks.js")" "$AT_PKG/opencode/agent-tasks.js"
}

test_install_opencode_refuses_regular_file() {
  at_pkg
  local dest out rc=0
  dest="$HOME/.config/opencode/plugins/agent-tasks.js"
  mkdir -p "$(dirname "$dest")"
  echo "mine" > "$dest"
  out="$("$AT_PKG_TASK" install-opencode 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" "task: refusing to overwrite non-symlink: $dest"
  assert_eq "$(cat "$dest")" "mine"
}

test_install_opencode_errors() {
  at_pkg
  local out rc=0
  out="$("$AT_PKG_TASK" install-opencode now 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: task install-opencode"
  rm "$AT_PKG/opencode/agent-tasks.js"
  rc=0; out="$("$AT_PKG_TASK" install-opencode 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" "task: OpenCode plugin not found at $AT_PKG/opencode/agent-tasks.js"
  assert_no_file "$HOME/.config/opencode/plugins/agent-tasks.js"
}

test_install_help_lists_automation_commands() {
  local out c
  out="$("$TASK" --help)"
  assert_contains "$out" "automation:"
  for c in "task signal <id> <signal> --session <session-id> [--text TEXT]" "task approve <id> [--now]" \
           "task auto [on [DURATION] | off]" "task run --once" "task open <id>" "task next" "task install-opencode"; do
    assert_contains "$out" "  $c"
  done
  # install-opencode moved from "store:" to "automation:".
  assert_contains "${out#*automation:}" "task install-opencode"
  assert_not_contains "${out%%automation:*}" "install-opencode"
  # Every listed command exists (wrong arguments give its usage, not "unknown command").
  for c in signal approve auto run open next install-opencode; do
    out="$("$TASK" "$c" --bogus-arg x y z 2>&1)" || true
    assert_not_contains "$out" "unknown command"
  done
}
