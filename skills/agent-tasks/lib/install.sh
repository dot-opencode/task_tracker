# shellcheck shell=bash
# Installing the OpenCode plugin as a symlink into the global plugins directory.

cmd_install_opencode() {
  [ $# -eq 0 ] || die "usage: task install-opencode"
  local source config_dir destination current
  source="$TASK_ROOT/opencode/agent-tasks.js"
  [ -f "$source" ] || die "OpenCode plugin not found at $source"
  config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins"
  destination="$config_dir/agent-tasks.js"
  mkdir -p "$config_dir"
  if [ -L "$destination" ]; then
    current="$(canonical_path "$destination" 2>/dev/null)" || current=""   # dangling link: replace it
    if [ "$current" = "$source" ]; then
      echo "OpenCode plugin already installed: $destination"
      return 0
    fi
    rm "$destination"
  elif [ -e "$destination" ]; then
    die "refusing to overwrite non-symlink: $destination"
  fi
  ln -s "$source" "$destination"
  echo "installed OpenCode plugin: $destination (run 'opencode reload' or restart OpenCode)"
}
