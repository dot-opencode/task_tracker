# Changelog

## Unreleased

- CLI rewritten in Rust (`cli/`, binary `task`).
- `bin/task` is now a launcher that downloads the prebuilt binary pinned in `bin/release.txt` from GitHub Releases (sha256-verified, cached under `~/.cache/agent-tasks/`). `AGENT_TASKS_BIN` runs a local build instead.
- Install as an OpenCode package plugin: `opencode plugin add github:dot-opencode/task_tracker#release`. The plugin registers the bundled `agent-tasks` skill and tells the agent the absolute path of the `task` CLI. The package also ships the `/tasks` TUI plugin (`./tui` export), so no `cli.json` entry is needed; root `index.js`/`tui.js` serve local-path loading.
- `task install-opencode` is deprecated in favour of the package plugin.
- CI (fmt, clippy, tests on Linux and macOS, launcher, plugin) and a tag-driven release workflow with prebuilt macOS and Linux (musl) binaries. MIT license.
- Release build is size-optimised (`opt-level = "z"`, LTO, stripped, `panic = "abort"`).
- Version 0.3.0.
- Removed the Bash libs and the `migrate-folders` / `migrate-unmerged` scripts.

## 0.2.0 — 2026-10-20

First tagged release.

- File-based task store with a `task` CLI: new, show, ls, mv, set, done, log, logs, doctor.
- Project registry and OpenCode session binding (`task bind`).
- Stages: planning, plan review, approval (waits in `07_approved` unless `--now`), `10_unmerged`, done, postponed and archive with auto-archiving.
- Automation: `task signal`, `task approve`, worker runs, notifications, MR auto-check and `task merged`.
- `task worktree`: git worktrees in `<repo>/.worktrees`, removed when the task reaches `11_done`.
- Subtasks: `--parent` and `--depends`; a parent closes itself when all its subtasks are done.
- OpenCode plugin: automation, the `/tasks` TUI dialog, and an RPC for web frontends and userscripts.
- Task sessions take their model from an oh-my-opencode-slim preset.
