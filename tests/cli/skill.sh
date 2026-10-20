# shellcheck shell=bash
# SKILL.md is the protocol agents read; these checks keep it in step with the CLI.

SKILL_MD="$ROOT/skills/agent-tasks/SKILL.md"

test_skill_frontmatter() {
  assert_file "$SKILL_MD"
  assert_eq "$(head -1 "$SKILL_MD")" "---"
  grep -qx 'name: agent-tasks' "$SKILL_MD" || fail "SKILL.md has no 'name: agent-tasks'"
  grep -q '^description: .\{80,\}' "$SKILL_MD" || fail "SKILL.md description is missing or too short"
}

test_skill_mentions_only_real_commands() {
  local usage cmds cmd count=0
  assert_file "$SKILL_MD"
  usage="$("$TASK" --help)"
  # shellcheck disable=SC2016 # the backtick is literal: commands are written as inline code
  cmds="$(grep -o '`task [a-z][a-z-]*' "$SKILL_MD" | awk '{print $2}' | sort -u)"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    count=$((count + 1))
    assert_contains "$usage" "task $cmd "
  done <<EOF
$cmds
EOF
  [ "$count" -ge 8 ] || fail "SKILL.md mentions only $count commands"
}

test_skill_describes_every_folder() {
  local f
  assert_file "$SKILL_MD"
  for f in 00_backlog 01_ready 02_exploring 03_brainstorming 04_spec_review 07_approved \
           08_implementing 09_finishing 10_unmerged 11_done blocked; do
    grep -qF "| \`$f\` |" "$SKILL_MD" || fail "SKILL.md does not describe $f"
  done
}
