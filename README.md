# agent-tasks

A file-based task tracker for one developer's coding agents. No servers or databases — markdown
files, folders, git, and one Rust CLI. Same conventions as
[agent-memory](https://github.com/kurbezz/memory).

A task is a markdown file in `~/.agent-tasks/<workspace>/<folder>/T-0083-<slug>.md`; its status is the
folder it sits in, so Finder, Zed or Obsidian work as a board. The store is a git repository: every
change made through the CLI is committed. Agents learn the protocol from the
[`agent-tasks` skill](skills/agent-tasks/SKILL.md) and change tasks only through the `task` CLI.

Folders: `00_backlog`, `01_ready`, `02_exploring`, `03_brainstorming`, `04_spec_review`, `05_planning`,
`06_plan_review`, `07_approved`, `08_implementing`, `09_finishing`, `10_unmerged` (finished, not merged yet), `11_done`, `blocked`, plus `postponed` (set aside) and `archive` for old done tasks — the stages of the
[superpowers](https://github.com/obra/superpowers) workflow.

## Install

### OpenCode package plugin (recommended)

```bash
opencode plugin add github:dot-opencode/task_tracker#release
```

The `release` branch moves only after a GitHub Release (and its pinned checksums) is published, so you get
updates on releases only. Check and update with:

```bash
opencode plugin check      # is there a newer release?
opencode plugin update     # fetch it; then restart OpenCode
```

The plugin registers the bundled `agent-tasks` skill. If a skill with the same name is already installed
(for example via `npx skills`), that one wins. It also tells the agent the absolute path of the `task` CLI, so
nothing needs to be on `PATH` for the agent.

For your own shell, symlink the launcher. The package path changes on update, so use the path the plugin shows
the agent:

```bash
ln -s <path-to-package>/skills/agent-tasks/bin/task ~/.local/bin/task
task project import-memory    # register the projects agent-memory knows
```

`bin/task` is a small launcher. On first run it downloads the prebuilt binary pinned in `bin/release.txt` from
GitHub Releases, checks its sha256 and caches it under `~/.cache/agent-tasks/` (`$XDG_CACHE_HOME` if set).
Prebuilt binaries exist for macOS (arm64, x86_64) and Linux (x86_64, aarch64; static musl). Offline or on
another platform, build it yourself and point the launcher at it:

```bash
cargo install --git https://github.com/dot-opencode/task_tracker agent-tasks
export AGENT_TASKS_BIN="$HOME/.cargo/bin/task"
```

### From a checkout (development)

```bash
cd ~/work/task_tracker && cargo build --release
export AGENT_TASKS_BIN="$PWD/target/release/task"
ln -s ~/work/task_tracker/skills/agent-tasks ~/.agents/skills/agent-tasks
ln -s ../../.agents/skills/agent-tasks ~/.claude/skills/agent-tasks   # Claude Code
ln -s ~/work/task_tracker/skills/agent-tasks/bin/task ~/.local/bin/task
```

`task install-opencode` (symlinks the plugin into `~/.config/opencode/plugins`) still works but is
**deprecated**: prefer `opencode plugin add`.

The store is created on first use at `~/.agent-tasks` (override with `AGENT_TASKS_HOME`).

## Use

```bash
task new "Fix port drift" --project crm --source https://tracker.example/issue/ABC-1
task ls                       # all tasks except the archive, with their status; --waiting: tasks that need you
task show T-0001
task postpone 1 --reason "later"  # hidden from task ls (task ls postponed); task resume 1 returns it to its stage
task archive 1                # done tasks archive themselves after archive_after_days (14); task ls archive, task unarchive 1
task mv 1 ready               # folders by name or number
task log 1 "Root cause: hard-coded port"
task logs -f                  # follow the automation worker log
task logs T-0001 -f           # follow a task's log, even as it moves between folders
task set 1 pr https://github.com/org/repo/pull/7
task done 1 --result pr --summary "Fixed and covered by tests"
task worktree 1               # git worktree in <repo>/.worktrees/T-0001; removed when the task reaches 11_done
task new "Part" --parent 1 --depends 2   # subtask; waits for T-0002 in the worker
task ls --parent 1             # subtasks; the parent closes itself when all are done (--force overrides the parent wait)
task project add api ~/work/api
task doctor                   # check the store
```

For OpenCode session signals, install the plugin (see Install). Automation is off until you explicitly run `task auto on 3h`; turn it off with `task auto off`. Open a waiting session with `task open T-0001` or `task next`. The plugin handles task status changes from session signals.

The package exposes both `./server` and `./tui` entries, so `opencode plugin add` also enables the TUI plugin; from a checkout, point `plugins` at the repository root (`<dir>/index.js` is the server, `<dir>/tui.js` the CLI plugin). In the TUI, `/tasks` (or the command palette, or `<leader>k`) opens a searchable task list grouped by "Waiting for you", "Agent working", "Queued", "Backlog", "Done"; Enter opens the task's session. In the dialog `alt+w` toggles waiting-only and `alt+p` includes postponed tasks. It runs `task ls --json` (`task` from PATH, else the bundled `bin/task`).

`task --help` lists every command. Hand edits and moves are fine; the next command commits them.

### HTTP API (RPC)

The plugin registers the OpenCode RPC `agent-tasks`, so a custom frontend or a userscript on the OpenCode web UI can
manage tasks: `POST /api/rpc/agent-tasks/<method>` with `{"input": {...}}` returns `{"output": ...}`. The contract
(methods, input/output schemas, events) is [`opencode/rpc.js`](skills/agent-tasks/opencode/rpc.js), plain data that
can be imported as is or passed to `client.rpc(AgentTasksRpc)` from `@opencode/client`.

Methods: `list` (`folder` | `waiting` | `all`, `workspace`), `show`, `logs`, `create`, `move`, `log`, `set`, `unset`,
`done`, `merged`, `approve`, `postpone`, `resume`, `archive`, `unarchive`, `bind`, `worktree`, `removeWorktree`,
`projects`, `autoStatus`, `setAuto`. Each one runs the matching `task` command. Failures come back as
`{"_tag": "RpcError", "type": "task_failed" | "invalid_input", "message": ...}`.

The event `rpc.agent-tasks.changed` (`{id, action}`, on `GET /api/event`) fires after every change made through the
plugin: RPC calls, session signals that move a task, recorded spec/plan/pr. Hand edits and CLI runs outside the plugin
do not fire it, so refetch on focus as well.

```js
// In the OpenCode web UI (same origin, signed in via `opencode pair`):
const call = async (method, input = {}) => {
  const res = await fetch(`/api/rpc/agent-tasks/${method}`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ input }),
  })
  const body = await res.json()
  if (!res.ok) throw body
  return body.output
}
const { tasks } = await call("list", { waiting: true })
await call("move", { id: "T-0083", folder: "ready", reason: "from the browser" })
```

A frontend served from another origin needs `opencode service set cors <origin>` and the server password (HTTP Basic,
user `opencode`). The address comes from `opencode service status`.

Task sessions use the OpenCode default model unless `config.toml` sets `preset` (an oh-my-opencode-slim preset, e.g. `preset = "claude"`) or `model` (explicit `provider/model`, wins over `preset`).

## Layout

```
~/.agent-tasks/              git repository
  config.toml
  <workspace>/               work, home, ...
    00_backlog/ … 10_unmerged/ 11_done/ blocked/ postponed/ archive/
    .projects/<name>         one line: absolute path of the project's repository
```

## Tests

```bash
cargo test                    # Rust unit tests
cargo build --release && bash tests/run.sh   # CLI via the launcher + AGENT_TASKS_BIN (SKIP_CARGO_BUILD=1 skips the build)
bash tests/launcher.sh        # launcher download/verify/cache, offline
TZ=UTC node --test tests/*.test.js     # plugin, RPC and TUI
```

