---
name: agent-tasks
description: Read and update the user's file-based task tracker (~/.agent-tasks) through the `task` CLI — find and read tasks, create one, log progress and decisions, record links and the outcome. Use when the user mentions a task id such as T-0083, asks to create or track a task, or the current work belongs to a tracked task.
---

# Agent Tasks

The user tracks work as Markdown files in `~/.agent-tasks/` (`$AGENT_TASKS_HOME` overrides it), a git
repository. One task is one file, `<workspace>/<folder>/T-0083-<slug>.md`. Its status is the folder
it is in:

| Folder | Status |
|---|---|
| `00_backlog` | recorded, not started |
| `01_ready` | queued to start |
| `02_exploring` | an agent studies the task and prepares questions |
| `03_brainstorming` | the user answers questions and approves the design |
| `04_spec_review` | the user reviews the written spec |
| `05_planning` | spec approved; an agent writes the implementation plan |
| `06_plan_review` | the user reviews the plan |
| `07_approved` | plan approved; implementation waits for the worker |
| `08_implementing` | an agent implements the plan |
| `09_finishing` | the user chooses how to finish: merge, PR, keep or discard |
| `10_unmerged` | finished (result `pr` or `kept`) but not merged yet; checked automatically for merged MRs |
| `11_done` | finished; the outcome is in `result` |
| `blocked` | stopped until the user acts |
| `postponed` | set aside by the user; hidden from `task ls`; `task resume` returns it to its stage |
| `archive` | finished long ago; hidden from `task ls` |

Done tasks are archived automatically after `archive_after_days` days (config, default 14; 0 disables).
Automated task sessions take their model from the oh-my-opencode-slim preset named by `preset` in config (`model` overrides it; both empty: OpenCode default).
Agents do not archive tasks themselves unless asked (`task archive <id>`, `task unarchive <id>`).
Agents postpone or resume tasks only when the user asks (`task postpone <id> [--reason TEXT]`, `task resume <id>`).

## The `task` CLI

Use `task` from PATH if installed; otherwise call the script that ships with this skill,
`<this skill's directory>/bin/task`. If `task` is not on PATH (plugin install), use the absolute path
given in the `<agent-tasks-cli>` block wherever this skill says `task`. `task --help` lists every command. Ids can be written
`T-0083`, `t-83` or `83`.

Every read and change goes through the CLI. **Never edit, write or move task files yourself** — no
edit/write tools, no `mv`, no `sed`. A task file moves between folders, so a path you saw earlier may
already be stale, and a direct write can leave a duplicate. The CLI finds the file wherever it is,
keeps the format and commits the store.

| Goal | Command |
|---|---|
| see open tasks, or only those waiting for the user | `task ls`, `task ls --waiting` |
| read a task | `task show T-0083` |
| create a task | `task new "Title" --project <name>` |
| record progress, a decision or a finding | `task log T-0083 "message" --author <your model id>` |
| record a link | `task set T-0083 pr <url>`, `task set T-0083 spec <path>`, `task set T-0083 plan <path>` |
| create the task's worktree | `task worktree T-0083 [--branch B] [--base REF]` (prints the path) |
| record the outcome | `task done T-0083 --result <result> --summary "..."` |
| list projects | `task project ls` |
| bind this OpenCode session to a task | `task bind T-0083 --session <your session id>` |

Worktrees: `task worktree <id>` creates `<repo>/.worktrees/<T-id>` (the task needs a project) and prints its path.
Work only there and do not create worktrees elsewhere ($TMPDIR, sibling directories of the repo, `.claude/worktrees`, `.slim/worktrees`).
`task worktree` adds `.worktrees/` to `.git/info/exclude` itself; never add it to the tracked `.gitignore`.
The worktree is removed when the task reaches 11_done;
a dirty one is kept and logged. A `merged` branch is deleted with `git branch -d`; other branches are kept.
`task worktree <id> --remove [--force]` removes it by hand; never pass `--force` on uncommitted changes without asking the user.

Multi-line text: pass `-` and write the text to stdin, for example
`task log T-0083 - --author <id> <<'EOF'` ... `EOF`; `task new` takes `--body -`.

## Creating tasks

Create a task when the user asks for one, or after they agree to your suggestion; don't create
tasks for trivial one-off requests. `--project` is a name from `task project ls`; inside a
registered project's directory it is detected automatically. Put the essentials in the body: goal,
context, links (`--source <url>` for a ticket). A new task starts in `00_backlog`; the user decides
when to start it.

## Subtasks

Split big work into subtasks: `task new "Title" --parent T-0083 [--depends T-0084,T-0085]` (the
project and workspace come from the parent unless given). `task set <id> parent <id>` /
`task unset <id> parent` and `task set <id> depends_on "T-0084 T-0085"` / `task unset <id> depends_on`
change the links; self links, cycles and a parent in another workspace are refused.

- A parent cannot enter `09_finishing`, `10_unmerged` or `11_done` (`task mv`, `task done`,
  `task merged`) while a subtask is not in `11_done`/`archive`: it dies with "has open subtasks"
  unless `--force`. A session's `finishing` signal does not fail; the parent stays and the log says
  "waiting for subtasks".
- When the last subtask lands in `11_done`/`archive`, the parent moves to `11_done` by itself
  (`result: subtasks`), recursively; postponed parents are left alone.
- The worker does not start a `01_ready`/`07_approved` task while one of its `depends_on` tasks is not
  in `10_unmerged`/`11_done`/`archive` (`task ls` shows `(waits T-0084)`). Manual moves and
  `task approve --now` are not gated.
- `task ls --parent T-0083` lists the subtasks; `task ls --json` has `source`, `parent`, `depends_on`,
  `blocked_by`, `children`; `task show` appends the subtask list.

## Logging

When you work on a task, log what a reader will need later: decisions and why, findings, blockers,
the spec and plan paths, the PR link. Skip routine steps.

- `--author` is your model identifier (for example `claude-opus-5-5`), not a generic `agent` or
  `assistant`. It must be a single token without `:` (`claude-opus-5-5`, not `openai:gpt-5`).
- The message states what happened or what is needed next. Good: "Root cause: the env files
  hard-code port 8001; switched to service discovery, tests green." Bad: "Did the work.",
  "Called task log."
- Never write secrets (tokens, passwords, URLs with credentials): the store is a git repository.

## Status changes

Don't move tasks between folders on your own. Two exceptions:

- the user asks you to: `task mv T-0083 <folder>`;
- the user has chosen how to finish the work: record it with `task done`. Results: `pr` (a pull
  request was opened), `merged`, `kept` (the branch stays as it is), `discarded`, `cancelled` (the
  task is dropped). `pr` and `kept` put the task in `10_unmerged`; when it is merged run
  `task merged T-0083` (merged MRs are also detected automatically; `task check-mrs` checks now).

## Sessions

If you are working in an OpenCode session that belongs to a task, bind it once with
`task bind T-0083 --session <your session id>`, so later tooling can find the task by session
(`task find --session <id>`).

## Automation (OpenCode plugin)

When the OpenCode plugin is installed, it moves a bound task between
folders from the session's signals: a question, the end of a turn, a permission request, an error.
**Don't move the task yourself** while the plugin is active; its rules for the current folder are
injected into your context.

- Ask the user questions only with the question tool: one at a time, with options and your
  recommendation.
- When the user approves the spec, run `task approve T-0083`; it prints `start` and the task moves to
  `05_planning`: continue with writing-plans, save the plan under `docs/superpowers/plans/`, then end
  the turn asking the user to review the plan. Do not implement before the plan is approved.
- When the user approves the plan, run `task approve T-0083` (`--now` only if they explicitly ask
  to start now) and act on what it prints:
  - `start` — implement the plan with subagent-driven-development;
  - `deferred` — end the turn, telling the user that the worker starts the implementation in this
    session when automation is on and a slot is free (`task approve T-0083 --now` starts it right away).
- writing-plans is refused until the spec is approved (`05_planning`, `06_plan_review`);
  implementation skills are refused until the plan is approved (`08_implementing`, `09_finishing`, `10_unmerged`).
- When the user has chosen how to finish, carry it out and record it with `task done`.

The user controls the active period with `task auto on 3h` / `task auto off` and opens the session
of a waiting task with `task open T-0083`; `task run --once` and `task signal` are called by launchd
and the plugin, not by you.
