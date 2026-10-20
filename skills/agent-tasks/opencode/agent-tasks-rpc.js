// RPC handlers: each method maps to one `task` CLI call through run(args); never a shell.
import { folderOfPath, parseTask } from "./agent-tasks-core.js"
import { AgentTasksRpc, PATTERNS } from "./rpc.js"

const text = (result) => String(result.stdout ?? "").trim()
const status = (folder) => folder.replace(/^\d\d_/, "")

// Input fields whose format the schema cannot express (see PATTERNS in rpc.js).
const FIELD_PATTERNS = {
  id: PATTERNS.id, workspace: PATTERNS.workspace, folder: PATTERNS.folder, sessionID: PATTERNS.session,
  duration: PATTERNS.duration, project: PATTERNS.name, slug: PATTERNS.name, author: PATTERNS.name,
  branch: PATTERNS.name, base: PATTERNS.name, parent: PATTERNS.id,
}

// `83`, `t-83`, `T-0083` → `T-0083`, as the CLI prints it.
export const normalizeId = (id) => `T-${String(Number(String(id).replace(/^[Tt]-/, ""))).padStart(4, "0")}`

export function invalidField(input) {
  if (input?.dependsOn !== undefined && (!Array.isArray(input.dependsOn) || !input.dependsOn.every((id) => PATTERNS.id.test(String(id))))) return "dependsOn"
  if (input?.key === "parent" && input.value !== undefined && (typeof input.value !== "string" || !PATTERNS.id.test(input.value))) return "value"
  if (input?.key === "depends_on" && input.value !== undefined) {
    const ids = Array.isArray(input.value) ? input.value : typeof input.value === "string" ? input.value.split(/\s+/).filter(Boolean) : null
    if (!ids?.length || !ids.every((id) => PATTERNS.id.test(String(id)))) return "value"
  } else if (Array.isArray(input?.value)) return "value"
  return Object.keys(FIELD_PATTERNS).find((field) => input?.[field] !== undefined && !FIELD_PATTERNS[field].test(String(input[field])))
}

function failure(context, args, result) {
  const stderr = String(result.stderr ?? "").trim()
  const stdout = text(result)
  return context.error("task_failed", stderr.replace(/^task: /, "") || stdout || `task ${args[0]} exited with ${result.code}`, {
    code: result.code, stderr, stdout,
  })
}

// `task project ls` prints aligned columns: workspace, name, path[ (missing)].
export function parseProjects(stdout) {
  return String(stdout).split("\n").map((line) => line.match(/^(\S+)\s+(\S+)\s+(.*?)( \(missing\))?$/)).filter(Boolean)
    .map(([, workspace, name, path, missing]) => ({ workspace, name, path, missing: Boolean(missing) }))
}

// deps: { run(args) → {code, stdout, stderr}, readFile(path, "utf8"), changed(event) }
export function rpcHandlers({ run, readFile, changed }) {
  // Runs the CLI and maps a nonzero exit to the declared task_failed error.
  const call = async (args, context, onOk) => {
    const result = await run(args)
    if (result.code !== 0) return failure(context, args, result)
    return onOk(result)
  }
  // Mutations report their stdout and announce the change.
  const mutate = (action, build) => async (input, context) => {
    const args = build(input)
    return call(args, context, async (result) => {
      await changed({ action, ...(input.id ? { id: normalizeId(input.id) } : {}) })
      return { text: text(result) }
    })
  }
  const opt = (args, flag, value) => {
    if (value !== undefined && value !== "") args.push(flag, String(value))
    return args
  }

  const forced = (args, input) => (input.force ? [...args, "--force"] : args)

  const handlers = {
    list: (input, context) => {
      const args = ["ls", "--json"]
      if (input.folder) args.push(input.folder)
      else if (input.waiting) args.push("--waiting")
      else if (input.all) args.push("--all")
      opt(args, "--ws", input.workspace)
      opt(args, "--parent", input.parent)
      return call(args, context, (result) => ({ tasks: JSON.parse(result.stdout || "[]") }))
    },
    show: (input, context) => call(["path", input.id], context, async (result) => {
      const path = text(result)
      const markdown = await readFile(path, "utf8")
      const { fields, body } = parseTask(markdown)
      const folder = folderOfPath(path)
      return { id: fields.id || input.id, folder, status: status(folder), path, fields, body, markdown }
    }),
    logs: (input, context) => {
      const args = ["logs"]
      if (input.id) args.push(input.id)
      opt(args, "-n", input.lines)
      return call(args, context, (result) => ({ text: String(result.stdout ?? "") }))
    },
    create: async (input, context) => {
      const args = ["new"]
      opt(args, "--project", input.project)
      opt(args, "--ws", input.workspace)
      opt(args, "--source", input.source)
      opt(args, "--slug", input.slug)
      opt(args, "--body", input.body)
      opt(args, "--parent", input.parent)
      if (input.dependsOn?.length) args.push("--depends", input.dependsOn.join(","))
      if (input.ready) args.push("--ready")
      args.push("--", input.title)
      return call(args, context, async (result) => {
        const id = text(result).split("\n").pop()
        await changed({ action: "create", id })
        return { id }
      })
    },
    move: mutate("move", (i) => forced(opt(["mv", i.id, i.folder], "--reason", i.reason), i)),
    log: mutate("log", (i) => [...opt(["log", i.id], "--author", i.author), "--", i.message]),
    set: mutate("set", (i) => ["set", "--", i.id, i.key, Array.isArray(i.value) ? i.value.join(" ") : i.value]),
    unset: mutate("unset", (i) => ["unset", i.id, i.key]),
    done: mutate("done", (i) => forced(opt(["done", i.id, "--result", i.result], "--summary", i.summary), i)),
    merged: mutate("merged", (i) => forced(opt(["merged", i.id], "--summary", i.summary), i)),
    approve: (input, context) => call(input.now ? ["approve", input.id, "--now"] : ["approve", input.id], context, async (result) => {
      const out = text(result)
      await changed({ action: "approve", id: normalizeId(input.id) })
      return { result: out.split("\n").includes("start") ? "start" : "deferred", text: out }
    }),
    postpone: mutate("postpone", (i) => opt(["postpone", i.id], "--reason", i.reason)),
    resume: mutate("resume", (i) => ["resume", i.id]),
    archive: mutate("archive", (i) => ["archive", i.id]),
    unarchive: mutate("unarchive", (i) => ["unarchive", i.id]),
    bind: mutate("bind", (i) => ["bind", i.id, "--session", i.sessionID]),
    worktree: (input, context) => {
      const args = opt(opt(["worktree", input.id], "--branch", input.branch), "--base", input.base)
      return call(args, context, async (result) => {
        await changed({ action: "worktree", id: normalizeId(input.id) })
        return { directory: text(result).split("\n").pop() }
      })
    },
    removeWorktree: mutate("worktree-remove", (i) => (i.force ? ["worktree", i.id, "--remove", "--force"] : ["worktree", i.id, "--remove"])),
    projects: (input, context) => call(opt(["project", "ls"], "--ws", input.workspace), context,
      (result) => ({ projects: parseProjects(result.stdout) })),
    autoStatus: (input, context) => call(["auto"], context, (result) => ({ text: text(result) })),
    setAuto: mutate("auto", (i) => (!i.enabled ? ["auto", "off"] : i.duration ? ["auto", "on", i.duration] : ["auto", "on"])),
  }
  return Object.fromEntries(Object.entries(handlers).map(([name, handler]) => [name, (input = {}, context) => {
    const field = invalidField(input)
    if (field) return Promise.resolve(context.error("invalid_input", `invalid ${field}`, { field }))
    return handler(input, context)
  }]))
}

// Registers the RPC when the host supports it; returns emit(event) for `changed`.
// deps: { runTask, readFile, log(message, extra) }
export async function registerRpc(ctx, deps) {
  if (typeof ctx.rpc?.register !== "function") return async () => {}
  let registration
  const changed = async (event) => {
    try {
      await registration?.events.emit("changed", event)
    } catch (error) {
      await deps.log("could not emit rpc event", { error: String(error) })
    }
  }
  registration = await ctx.rpc.register(AgentTasksRpc, rpcHandlers({ run: deps.runTask, readFile: deps.readFile, changed }))
  return changed
}
