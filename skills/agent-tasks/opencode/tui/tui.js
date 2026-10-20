// OpenCode V2 CLI/TUI plugin: /tasks dialog to browse agent-tasks and open their sessions.
// Plain V2 plugin object (no @opencode/plugin import) so it loads from a bare directory path
// without node_modules. OpenCode resolves `<dir>/tui` for local-path plugins.
import { execFile } from "node:child_process"
import { realpathSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { buildOptions, noSessionMessage, parseTasks, searchOptions, selectTasks } from "./tasks-model.js"

const TIMEOUT_MS = 30_000
const COMMAND_ID = "agent-tasks.tasks"

function moduleDirectory() {
  const dir = dirname(fileURLToPath(import.meta.url))
  try {
    return realpathSync(dir)
  } catch {
    return dir
  }
}

function exec(file, args) {
  return new Promise((resolveResult, reject) => {
    execFile(file, args, { encoding: "utf8", shell: false, timeout: TIMEOUT_MS, maxBuffer: 16 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (!error) return resolveResult({ code: 0, stdout, stderr })
      if (typeof error.code === "number") return resolveResult({ code: error.code, stdout, stderr })
      reject(error)
    })
  })
}

/** Run the task CLI: `task` from PATH, falling back to <repo>/skills/agent-tasks/bin/task. */
export async function runTask(args, { run = exec, fallback = resolve(moduleDirectory(), "../../bin/task") } = {}) {
  let result
  try {
    result = await run("task", args)
  } catch (error) {
    if (error?.code !== "ENOENT") throw error
    result = await run(fallback, args)
  }
  if (result.code !== 0) throw new Error((result.stderr || result.stdout || `task exited with ${result.code}`).trim())
  return result.stdout
}

async function loadTasks(run, { waitingOnly, includePostponed }) {
  const lists = [parseTasks(await run(["ls", "--json"]))]
  if (includePostponed && !waitingOnly) lists.push(parseTasks(await run(["ls", "postponed", "--json"])))
  return selectTasks(lists, { waitingOnly })
}

export function createTasksPlugin({ run = runTask } = {}) {
  return {
    id: "agent-tasks.tui",
    setup(context) {
      const toast = (message, variant = "info") => context.ui.toast.show({ title: "agent-tasks", message, variant })
      let generation = 0

      async function openSession(task) {
        if (!task.session) return toast(noSessionMessage(task), "warning")
        try {
          await context.data.session.sync(task.session)
        } catch {
          // Best effort: navigating still loads the session.
        }
        try {
          context.ui.router.navigate({ type: "session", sessionID: task.session })
        } catch (error) {
          toast(`Cannot open ${task.session}: ${error?.message ?? error}`, "error")
        }
      }

      async function show(state) {
        const mine = ++generation
        let tasks
        try {
          tasks = await loadTasks(run, state)
        } catch (error) {
          return toast(error?.message ?? String(error), "error")
        }
        if (mine !== generation) return
        const reopen = (patch) => void show({ ...state, ...patch })
        const flags = [state.waitingOnly ? "waiting only" : null, state.includePostponed ? "+postponed" : null].filter(Boolean)
        // Wide dialog: titles get the room the terminal has (the dialog keeps a margin and the project column).
        const titleMax = Math.max(40, (context.renderer?.width ?? 120) - 50)
        // A new dialog resolves the previous promise with undefined; `generation` tells that apart from a real pick.
        const pending = context.ui.dialog.select({
          title: flags.length ? `Tasks (${flags.join(", ")})` : "Tasks",
          placeholder: "Search by id, title, project",
          options: buildOptions(tasks, { titleMax }),
          search: searchOptions,
          actions: [
            {
              bind: "alt+w",
              title: state.waitingOnly ? "all tasks" : "waiting only",
              selection: "none",
              onTrigger: () => reopen({ waitingOnly: !state.waitingOnly }),
            },
            {
              bind: "alt+p",
              title: state.includePostponed ? "hide postponed" : "show postponed",
              selection: "none",
              onTrigger: () => reopen({ includePostponed: !state.includePostponed }),
            },
          ],
        })
        try {
          context.ui.dialog.set({ size: "xlarge" })
        } catch {
          // Older hosts without dialog.set keep the default size.
        }
        const picked = await pending
        if (mine !== generation || !picked) return
        await openSession(picked)
      }

      context.keymap.layer(() => ({
        mode: "global",
        commands: [
          {
            id: COMMAND_ID,
            title: "Tasks",
            group: "agent-tasks",
            bind: "<leader>k",
            palette: true,
            slash: { name: "tasks" },
            run: () => show({ waitingOnly: false, includePostponed: false }),
          },
        ],
        bindings: [COMMAND_ID],
      }))
    },
  }
}

export default createTasksPlugin()
