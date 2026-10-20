import { execFile } from "node:child_process"
import { readFile, realpath } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { registerAgentTasks } from "./agent-tasks-core.js"

const moduleDirectory = await realpath(dirname(fileURLToPath(import.meta.url)))
const taskCli = resolve(moduleDirectory, "../bin/task")
const bundledSkills = [{ id: "agent-tasks", path: resolve(moduleDirectory, "../SKILL.md") }]
const TIMEOUT_MS = 30_000

function runTask(args) {
  return new Promise((resolveResult, reject) => {
    execFile(taskCli, args, { encoding: "utf8", shell: false, timeout: TIMEOUT_MS }, (error, stdout, stderr) => {
      if (!error) return resolveResult({ code: 0, stdout, stderr })
      if (typeof error.code === "number") return resolveResult({ code: error.code, stdout, stderr })
      reject(error)
    })
  })
}

async function log(entry) {
  try {
    console.error("[agent-tasks]", entry)
  } catch {
    // Logging must not interrupt OpenCode hooks.
  }
}

// A plain V2 plugin object ({ id, setup }); importing @opencode/plugin would make
// the plugin unloadable when installed as a bare symlink with no node_modules.
export default {
  id: "agent-tasks",
  async setup(ctx) {
    const { stop } = await registerAgentTasks(ctx, { runTask, readFile, now: () => Date.now(), log, taskCli, skills: bundledSkills })
    return stop
  },
}
