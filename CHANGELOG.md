# Changelog

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
