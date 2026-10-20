// agent-tasks OpenCode plugin logic. Pure helpers plus registerAgentTasks(ctx, deps).
// All CLI calls go through deps.runTask(args) so tests never spawn bin/task.
import { readFileSync, unwatchFile, watchFile } from "node:fs"
import { homedir } from "node:os"
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path"

import { normalizeId, registerRpc } from "./agent-tasks-rpc.js"

export const LIMIT = 4000
const OPEN = "<agent-tasks>"
const CLOSE = "</agent-tasks>"
const CLI_OPEN = "<agent-tasks-cli>"
const CLI_CLOSE = "</agent-tasks-cli>"
const HANDLED_MAX = 2000
const BINDING_TTL_MS = 30_000
const MAX_HOPS = 5
const WINDOW_MS = 2000
const RESUBSCRIBE_MS = 1000
const MAX_EMPTY_ENDS = 20
const STORE_POLL_MS = 2000
const STORE_DEBOUNCE_MS = 300

// Mirrors cli/src/core.rs store(): $AGENT_TASKS_HOME (non-empty) else $HOME/.agent-tasks.
function defaultStoreDir() {
  const env = process.env.AGENT_TASKS_HOME
  if (env) return resolve(env)
  return join(process.env.HOME || homedir(), ".agent-tasks")
}

// Default watcher: stat-polls `file` (works when it appears later); returns an unwatch function.
function watchStatFile(file, intervalMs, onChange) {
  const listener = (cur, prev) => {
    if (cur.mtimeMs !== prev.mtimeMs || cur.size !== prev.size) onChange()
  }
  watchFile(file, { interval: intervalMs, persistent: false }, listener)
  return () => unwatchFile(file, listener)
}

// Watches the store git log and emits changed({action:"store"}) debounced. Returns stop().
function startStoreWatcher({ deps, changed, log }) {
  const dir = deps.storeDir ?? defaultStoreDir()
  const pollMs = deps.storePollMs ?? STORE_POLL_MS
  const debounceMs = deps.storeDebounceMs ?? STORE_DEBOUNCE_MS
  const watch = deps.watchStore ?? watchStatFile
  let timer
  let stopped = false
  const fire = () => {
    timer = undefined
    if (stopped) return
    Promise.resolve(changed({ action: "store" })).catch((error) => log("store change emit failed", { error: String(error) }))
  }
  const onChange = () => {
    if (stopped) return
    if (timer) clearTimeout(timer)
    timer = setTimeout(fire, debounceMs)
  }
  const unwatchers = []
  for (const file of [join(dir, ".git", "logs", "HEAD")]) {
    try {
      unwatchers.push(watch(file, pollMs, onChange))
    } catch (error) {
      Promise.resolve(log("could not watch store file", { file, error: String(error) })).catch(() => {})
    }
  }
  return () => {
    stopped = true
    if (timer) clearTimeout(timer)
    timer = undefined
    for (const unwatch of unwatchers) {
      try {
        unwatch?.()
      } catch {
        // Cleanup must not throw.
      }
    }
  }
}

export const GATED_SKILLS = new Set(["writing-plans", "executing-plans", "subagent-driven-development"])
// Where each gated skill may run: planning needs the spec approved, implementation the plan approved.
const GATE_FOLDERS = {
  "writing-plans": new Set(["05_planning", "06_plan_review"]),
  "executing-plans": new Set(["08_implementing", "09_finishing", "10_unmerged"]),
  "subagent-driven-development": new Set(["08_implementing", "09_finishing", "10_unmerged"]),
}
const SPEC_RE = /docs\/superpowers\/specs\/[^/]+-design\.md$/
const PLAN_RE = /docs\/superpowers\/plans\/[^/]+\.md$/
const GH_PR_RE = /\bgh pr create\b/
const PR_URL_RE = /https:\/\/github\.com\/[^\s/]+\/[^\s/]+\/pull\/\d+/
// Signals a child (background subagent) session may send on behalf of its root.
const CHILD_SIGNALS = new Set(["question", "permission", "answered"])

const APPROVE_SPEC = (id) =>
  `When the user approves the spec, run \`task approve ${id}\`; it prints \`start\` and the task moves to planning: ` +
  "continue with writing-plans in this session."
const BRAINSTORM = (id) =>
  "Follow superpowers brainstorming. Ask questions only with the question tool: one at a time, with options " +
  `and your recommendation. Do not offer the visual companion. ${APPROVE_SPEC(id)}`

export const RULES = {
  "02_exploring": BRAINSTORM,
  "03_brainstorming": BRAINSTORM,
  "04_spec_review": BRAINSTORM,
  "05_planning": (id) =>
    "The spec is approved. Write the implementation plan with writing-plans and save it to " +
    "docs/superpowers/plans/ (writing it there records it on the task). Then ask the user to review the plan " +
    "(the question tool is fine) and end the turn. Do not implement. When the user approves the plan, " +
    `run \`task approve ${id}\` at once (see 06_plan_review).`,
  "06_plan_review": (id) =>
    "The user reviews the plan. When they approve it (also by answering your review question, also " +
    `\"approve, no implementation\"), ALWAYS run \`task approve ${id}\` at once, before anything else, ` +
    "whether automation is on or off. Approve only records the approval (→ 07_approved); it does not " +
    "implement, and nothing is implemented without `--now` (add it only if the user explicitly asks to start " +
    "now). If it prints `deferred`, end the turn saying the plan is approved and the implementation starts " +
    `only via the worker (when automation is on) or \`task approve ${id} --now\`; if it prints \`start\`, ` +
    "implement with subagent-driven-development.",
  "07_approved": (id) =>
    "The plan is approved; the worker starts the implementation when automation is on and a slot is free. " +
    `Do not implement unless the user asks to start now: then run \`task approve ${id} --now\`.`,
  "08_implementing": (id) =>
    "Implement the approved plan in a worktree (no need to ask for consent) with subagent-driven-development " +
    "(no need to ask how to execute), and finally finishing-a-development-branch. " +
    `Create the worktree with \`task worktree ${id}\` (add \`--branch <name>\` if the project has its own branch naming); ` +
    "it prints the path. Work only in that path. Never create worktrees elsewhere " +
    "(not in $TMPDIR, sibling directories, .claude/worktrees or .slim/worktrees).",
  "09_finishing": (id) =>
    "After the user chooses (merge, PR, keep or discard), carry it out and run " +
    `\`task done ${id} --result pr|merged|kept|discarded\` (pr and kept move the task to unmerged automatically). ` +
    "The worktree is removed automatically when the task reaches 11_done; do not remove it by hand.",
  "10_unmerged": (id) =>
    "The work is finished but not merged yet (result pr or kept). If the user says it is merged, run " +
    `\`task merged ${id}\`; for follow-up fixes to the MR keep working in this session without changing the status.`,
  blocked: () =>
    "The task is blocked: the session stopped and is waiting for the user. Answer them, then continue " +
    "under the rules of the stage the task came from (blocked_from).",
  postponed: (id) =>
    "This task is postponed by the user. Do not work on it unless the user asks; " +
    `to bring it back run \`task resume ${id}\`.`,
}
const COMMON_RULE = (id) => `Never edit task files directly; record notes and decisions with \`task log ${id} "…"\`.`

// ---------------------------------------------------------------- pure helpers

export function createState() {
  return {
    handled: new Set(), recent: new Map(), gates: new Map(), inflight: new Map(), lastSet: new Map(), bindings: new Map(),
  }
}

function trimSet(set, max = HANDLED_MAX) {
  while (set.size > max) set.delete(set.values().next().value)
}
function trimMap(map, max = HANDLED_MAX) {
  while (map.size > max) map.delete(map.keys().next().value)
}

// True the first time `key` is seen in this process. Payloads without an id use
// `fallback` instead, deduped within WINDOW_MS (the N setup instances deliver
// the same hook/event back to back).
export function claim(state, key, fallback, at = Date.now()) {
  if (key == null) {
    if (fallback == null) return true
    const last = state.recent.get(fallback)
    if (last !== undefined && at - last < WINDOW_MS) return false
    state.recent.delete(fallback)
    state.recent.set(fallback, at)
    trimMap(state.recent)
    return true
  }
  if (state.handled.has(key)) return false
  state.handled.add(key)
  trimSet(state.handled)
  return true
}

function unquote(raw) {
  if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
    return raw.slice(1, -1).replace(/\\(.)/g, "$1")
  }
  return raw
}

// Fixed task format: `---`, `key: value` lines, `---`, body, optional `## Result`, `## Log`.
export function parseTask(text) {
  const lines = String(text).split("\n")
  const fields = {}
  if (lines[0] !== "---") return { fields, body: String(text).trim() }
  let i = 1
  for (; i < lines.length && lines[i] !== "---"; i += 1) {
    const at = lines[i].indexOf(": ")
    if (at > 0) fields[lines[i].slice(0, at)] = unquote(lines[i].slice(at + 2))
  }
  const body = []
  for (i += 1; i < lines.length; i += 1) {
    if (lines[i] === "## Log" || lines[i] === "## Result") break
    body.push(lines[i])
  }
  return { fields, body: body.join("\n").trim() }
}

export function folderOfPath(path) {
  return basename(dirname(String(path).trim()))
}

export function contextText({ id, title, folder, project, spec, plan, body, blocked_from: blockedFrom }) {
  const head = [`Task ${id}: "${title ?? ""}" — folder ${folder}${project ? `, project ${project}` : ""}` +
    (folder === "blocked" && blockedFrom ? ` (blocked from ${blockedFrom})` : "")]
  if (spec) head.push(`spec: ${spec}`)
  if (plan) head.push(`plan: ${plan}`)
  const rule = RULES[folder]
  const rules = [rule ? rule(id) : null, COMMON_RULE(id)].filter(Boolean).map((r) => `- ${r}`).join("\n")
  const top = `${OPEN}\n${head.join("\n")}\n\nRules:\n${rules}\n`
  const text = body ? `${top}\nDescription:\n${body}\n${CLOSE}` : `${top}${CLOSE}`
  if (text.length <= LIMIT) return text
  const notice = `\n[agent-tasks: description truncated; run \`task show ${id}\`]\n${CLOSE}`
  const room = LIMIT - notice.length
  if (top.length + "\nDescription:\n".length >= room) return `${text.slice(0, room)}${notice}`
  return `${`${top}\nDescription:\n${body}`.slice(0, room)}${notice}`
}

function firstLine(text, max = 300) {
  const line = String(text ?? "").split("\n").find((l) => l.trim()) ?? ""
  return line.trim().slice(0, max)
}

export function questionText(input) {
  const q = input?.questions?.[0]
  if (!q) return ""
  const labels = (q.options ?? []).map((o) => o?.label).filter(Boolean)
  const question = String(q.question ?? "").replace(/\s+/g, " ").trim()
  return labels.length ? `${question} — ${labels.join(" / ")}` : question
}

export function promptText(prompt) {
  if (typeof prompt === "string") return firstLine(prompt)
  if (prompt && typeof prompt.text === "string") return firstLine(prompt.text)
  const parts = Array.isArray(prompt) ? prompt : prompt?.parts
  if (Array.isArray(parts)) return firstLine(parts.filter((p) => p?.type === "text").map((p) => p.text).join("\n"))
  return ""
}

function asText(value) {
  if (value == null) return ""
  if (typeof value === "string") return value
  if (Array.isArray(value)) return value.map(asText).join(" ")
  if (typeof value === "object") return value.message ? String(value.message) : safeJSON(value)
  return String(value)
}
function safeJSON(value) {
  try { return JSON.stringify(value) } catch { return String(value) }
}

export function permissionText(data) {
  const resources = Array.isArray(data?.resources) ? data.resources.map(asText).join(", ") : asText(data?.resources)
  return [asText(data?.action), resources].filter(Boolean).join(" ")
}

function collectStrings(value, out = [], depth = 0) {
  if (depth > 6 || value == null) return out
  if (typeof value === "string") out.push(value)
  else if (Array.isArray(value)) for (const v of value) collectStrings(v, out, depth + 1)
  else if (typeof value === "object") for (const v of Object.values(value)) collectStrings(v, out, depth + 1)
  return out
}

export function findPrUrl(result) {
  for (const s of collectStrings(result)) {
    const m = s.match(PR_URL_RE)
    if (m) return m[0]
  }
  return undefined
}

// spec/plan path as stored in the task: relative to the session directory when inside it.
export function artifactFor(path, directory) {
  if (typeof path !== "string" || !path) return undefined
  const abs = isAbsolute(path) || !directory ? path : resolve(directory, path)
  const key = SPEC_RE.test(abs) ? "spec" : PLAN_RE.test(abs) ? "plan" : undefined
  if (!key) return undefined
  let value = abs
  if (directory && isAbsolute(abs)) {
    const rel = relative(directory, abs)
    if (rel && !rel.startsWith("..") && !isAbsolute(rel)) value = rel
  }
  return { key, value }
}

export function gateMessage(skill, id, folder) {
  const approval = skill === "writing-plans"
    ? `If the user approved the spec, run \`task approve ${id}\` first.`
    : `If the user approved the plan, run \`task approve ${id}\` first (use --now if they asked to start immediately).`
  return `agent-tasks: ${skill} is not allowed while ${id} is in ${folder}. ${approval}`
}

// ---------------------------------------------------------------- runtime

function parseSkill(raw) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(raw)
  let description = ""
  if (match) {
    for (const line of match[1].split(/\r?\n/)) {
      const kv = /^description:\s*(.+)$/.exec(line)
      if (kv) description = kv[1].trim().replace(/^['"]|['"]$/g, "")
    }
  }
  return { description, body: (match ? raw.slice(match[0].length) : raw).trim() }
}

// Register bundled skills in-process. A skill with the same id provided elsewhere
// (npx skills, user copy) wins. Never throws.
async function registerSkills(ctx, skills, logger) {
  try {
    if (!Array.isArray(skills) || skills.length === 0 || typeof ctx.skill?.transform !== "function") return undefined
    const loaded = []
    for (const { id, path } of skills) {
      try {
        const parsed = parseSkill(readFileSync(path, "utf8").replace(/^\uFEFF/, ""))
        loaded.push({ id, name: id, description: parsed.description, path, content: parsed.body })
      } catch (error) {
        await logger("could not read bundled skill", { error: String(error), skill: id })
      }
    }
    if (loaded.length === 0) return undefined
    return await ctx.skill.transform((editor) => {
      try {
        if (typeof editor?.add !== "function") return
        for (const info of loaded) {
          if (typeof editor.get === "function" && editor.get(info.id)) continue
          try {
            editor.add(info)
          } catch (error) {
            void logger("bundled skill registration failed", { error: String(error), skill: info.id })
          }
        }
      } catch (error) {
        void logger("bundled skill registration failed", { error: String(error) })
      }
    })
  } catch (error) {
    await logger("bundled skill registration failed", { error: String(error) })
    return undefined
  }
}

const sharedState = createState()

export async function registerAgentTasks(ctx, deps) {
  const state = deps.state ?? sharedState
  const now = deps.now ?? (() => Date.now())
  const controller = new AbortController()
  const bindings = state.bindings
  const queues = new Map()
  const pending = new Set()

  async function log(message, extra) {
    try {
      await deps.log({ service: "agent-tasks", level: "error", message, ...extra })
    } catch {
      // Logging must not interrupt an OpenCode conversation.
    }
  }

  async function run(args) {
    try {
      const result = await deps.runTask(args)
      if (result.code !== 0) await log("task exited nonzero", { args, code: result.code, stderr: String(result.stderr ?? "") })
      return result
    } catch (error) {
      await log("could not run task", { args, error: String(error) })
      return { code: -1, stdout: "", stderr: String(error) }
    }
  }

  async function lookup(sessionID) {
    const first = await ctx.session.get({ sessionID })
    const directory = first?.location?.directory
    let session = first
    let rootID = sessionID
    for (let hops = 0; session?.parentID && hops < MAX_HOPS; hops += 1) {
      rootID = session.parentID
      session = await ctx.session.get({ sessionID: rootID })
    }
    if (session?.parentID) return null // chain deeper than MAX_HOPS: refuse to guess
    const id = session?.metadata?.agent_tasks?.id
    if (typeof id !== "string" || !id) return null
    return { id, sessionID, rootID, directory, child: rootID !== sessionID }
  }

  // Binding of a session (via the root of its parentID chain), cached briefly so
  // the N hook instances and successive hooks of one turn share one lookup.
  function sessionFor(sessionID) {
    if (typeof sessionID !== "string" || !sessionID) return Promise.resolve(null)
    const hit = bindings.get(sessionID)
    if (hit && now() - hit.at < BINDING_TTL_MS) return hit.promise
    const promise = lookup(sessionID).catch(async (error) => {
      bindings.delete(sessionID)
      await log("could not resolve session binding", { sessionID, error: String(error) })
      return null
    })
    bindings.set(sessionID, { at: now(), promise })
    trimMap(bindings)
    return promise
  }

  // Fire and forget, serialised per task so the CLI sees signals in hook order.
  function enqueue(id, args, onDone) {
    const previous = queues.get(id) ?? Promise.resolve()
    const next = previous.then(() => run(args)).then((result) => onDone?.(result))
    queues.set(id, next)
    pending.add(next)
    void next.finally(() => {
      pending.delete(next)
      if (queues.get(id) === next) queues.delete(id)
    })
  }

  // Set once the RPC is registered; announces task changes to RPC subscribers.
  let changed = async () => {}
  let rpcRegistered = false

  async function signal(sessionID, name, text) {
    const binding = await sessionFor(sessionID)
    if (!binding) return
    if (binding.child && !CHILD_SIGNALS.has(name)) return
    const args = ["signal", binding.id, name, "--session", binding.rootID]
    if (text) args.push("--text", text)
    enqueue(binding.id, args, (result) => {
      // `task signal` prints `<id>: <from> → <to>` only when the task moved.
      if (result.code === 0 && String(result.stdout ?? "").includes("→")) return changed({ action: "signal", id: binding.id })
    })
  }

  function setField(binding, key, value) {
    const memo = `${binding.id}:${key}`
    if (state.lastSet.get(memo) === value) return
    state.lastSet.set(memo, value)
    trimMap(state.lastSet)
    enqueue(binding.id, ["set", binding.id, key, value], (result) => {
      if (result.code !== 0 && state.lastSet.get(memo) === value) state.lastSet.delete(memo)
      if (result.code === 0) return changed({ action: "set", id: binding.id })
    })
  }

  async function currentPath(id) {
    const result = await run(["path", id])
    const path = result.code === 0 ? String(result.stdout ?? "").trim() : ""
    return path || undefined
  }

  async function gateFor(skill, sessionID) {
    try {
      const binding = await sessionFor(sessionID)
      if (!binding) return undefined
      const path = await currentPath(binding.id)
      if (!path) return undefined
      const folder = folderOfPath(path)
      return GATE_FOLDERS[skill]?.has(folder) ? undefined : gateMessage(skill, binding.id, folder)
    } catch (error) {
      await log("skill gate failed open", { sessionID, error: String(error) })
      return undefined
    }
  }

  async function loadContext(sessionID) {
    const binding = await sessionFor(sessionID)
    if (!binding || binding.child) return undefined
    let path = await currentPath(binding.id)
    if (!path) return undefined
    let content
    try {
      content = await deps.readFile(path, "utf8")
    } catch {
      path = await currentPath(binding.id) // moved between `task path` and the read
      if (!path) return undefined
      content = await deps.readFile(path, "utf8")
    }
    const { fields, body } = parseTask(content)
    return contextText({ ...fields, id: fields.id || binding.id, folder: folderOfPath(path), body })
  }

  const hasBlock = (parts) => parts.some((p) => p?.type === "text" && typeof p.text === "string" && p.text.includes(OPEN))

  // Tells the agent where the CLI is when it is not on PATH (package install).
  const hasCliBlock = (parts) => parts.some((p) => p?.type === "text" && typeof p.text === "string" && p.text.includes(CLI_OPEN))
  function injectCliPath(ev) {
    if (!deps.taskCli || !Array.isArray(ev?.system) || hasCliBlock(ev.system)) return
    ev.system.push({ type: "text", text: `${CLI_OPEN}\nThe \`task\` CLI may not be on PATH; run it as \`${deps.taskCli}\` wherever the agent-tasks skill says \`task\`.\n${CLI_CLOSE}` })
  }

  async function inject(ev) {
    try {
      injectCliPath(ev)
      if (!Array.isArray(ev?.system) || hasBlock(ev.system)) return
      const key = `context:${ev.sessionID}`
      let promise = state.inflight.get(key)
      if (!promise) {
        promise = loadContext(ev.sessionID).finally(() => state.inflight.delete(key))
        state.inflight.set(key, promise)
      }
      const text = await promise
      if (text && !hasBlock(ev.system)) ev.system.push({ type: "text", text })
    } catch (error) {
      await log("could not build task context", { sessionID: ev?.sessionID, error: String(error) })
    }
  }

  async function onPrompt(ev) {
    try {
      const key = ev?.messageID ? `prompt:${ev.sessionID}:${ev.messageID}` : null
      if (!claim(state, key, `prompt:${ev?.sessionID}`, now())) return
      // Kickoff prompts posted by `task run` carry this marker; they are not user activity.
      if (ev?.metadata?.agent_tasks?.automated === true) return
      await signal(ev.sessionID, "input", promptText(ev.prompt))
    } catch (error) {
      await log("prompt hook failed", { error: String(error) })
    }
  }

  async function onBefore(ev) {
    let gate
    try {
      const callID = ev?.id ?? ev?.callID
      const key = callID ? `before:${ev.sessionID}:${callID}` : null
      if (ev?.tool === "skill" && GATED_SKILLS.has(ev.input?.id)) {
        // Every hook instance awaits the same decision so each one rejects.
        gate = key ? state.gates.get(key) : undefined
        if (!gate) {
          gate = gateFor(ev.input.id, ev.sessionID)
          if (key) { state.gates.set(key, gate); trimMap(state.gates) }
        }
      }
      if (ev?.tool === "question" && claim(state, key, `before:${ev.sessionID}:question:${safeJSON(ev.input)}`, now())) {
        await signal(ev.sessionID, "question", questionText(ev.input))
      }
    } catch (error) {
      await log("execute.before hook failed", { error: String(error) })
    }
    const message = gate ? await gate : undefined
    if (message) throw new Error(message)
  }

  async function onAfter(ev) {
    try {
      if (ev?.status !== "completed") return
      const callID = ev.id ?? ev.callID
      const key = callID ? `after:${ev.sessionID}:${callID}` : null
      if (!claim(state, key, `after:${ev.sessionID}:${ev.tool}:${safeJSON(ev.input)}`, now())) return
      const input = ev.input ?? {}
      switch (ev.tool) {
        case "question":
          return await signal(ev.sessionID, "answered")
        case "skill":
          if (input.id === "finishing-a-development-branch") await signal(ev.sessionID, "finishing")
          return
        case "write":
        case "edit": {
          // Artifacts are not signals: child sessions (subagents) record them too,
          // relative to the child's own directory.
          const binding = await sessionFor(ev.sessionID)
          if (!binding) return
          const found = artifactFor(input.path ?? input.filePath, binding.directory)
          if (found) setField(binding, found.key, found.value)
          return
        }
        case "shell":
        case "bash": {
          if (typeof input.command !== "string" || !GH_PR_RE.test(input.command)) return
          const url = findPrUrl(ev.result)
          if (!url) return
          const binding = await sessionFor(ev.sessionID)
          if (binding) setField(binding, "pr", url)
          return
        }
        default:
      }
    } catch (error) {
      await log("execute.after hook failed", { error: String(error) })
    }
  }

  async function onEvent(event) {
    const data = event?.data ?? {}
    const sessionID = data.sessionID
    if (!sessionID) return
    let name
    let text
    switch (event.type) {
      case "session.execution.succeeded": name = "turn-end"; break
      // Shapes per @opencode/schema 2.0.7: failed → data.error.{type,message};
      // interrupted → data.reason ∈ {user, shutdown, superseded, inactivity}.
      case "session.execution.failed": name = "error"; text = firstLine(asText(data.error ?? data.message) || "execution failed"); break
      case "session.execution.interrupted":
        if (data.reason !== "shutdown" && data.reason !== "inactivity") return
        name = "error"; text = `interrupted: ${data.reason}`; break
      case "permission.asked": name = "permission"; text = permissionText(data); break
      case "permission.replied": name = "answered"; break
      default: return // form.replied: the question tool's execute.after covers it
    }
    // Probe: execution.* events carry no id at all (event = {type, data:{sessionID}}) and arrive
    // as N copies within ~3 ms, so they are deduped by the WINDOW_MS fallback in claim().
    const id = event.id ?? data.id ?? data.executionID ?? data.messageID
    if (!claim(state, id != null ? `event:${event.type}:${sessionID}:${id}` : null, `event:${event.type}:${sessionID}`, now())) return
    await signal(sessionID, name, text)
  }

  function bindTool() {
    return {
      name: "task_bind",
      description: "Bind the current OpenCode session to an agent-tasks task (runs `task bind <id> --session <this session>`). " +
        "Use it when the user asks to work on an existing task in this session.",
      input: { type: "object", properties: { id: { type: "string", minLength: 1 } }, required: ["id"], additionalProperties: false },
      async execute(input, context) {
        const sessionID = context?.sessionID
        const result = await run(["bind", String(input?.id ?? ""), "--session", String(sessionID ?? "")])
        bindings.delete(sessionID)
        if (result.code === 0) await changed({ action: "bind", id: normalizeId(input.id) })
        const out = String(result.stdout ?? "").trim()
        const err = String(result.stderr ?? "").trim()
        return { content: result.code === 0 ? out || `bound ${input.id} to ${sessionID}` : `task bind failed: ${err || out || `exit ${result.code}`}` }
      },
    }
  }

  const skillRegistration = await registerSkills(ctx, deps.skills, log)
  await ctx.session.hook("prompt", onPrompt)
  await ctx.session.hook("context", inject)
  await ctx.session.hook("compaction", inject)
  await ctx.tool.hook("execute.before", onBefore)
  await ctx.tool.hook("execute.after", onAfter)
  await ctx.tool.transform((editor) => editor.add(bindTool()))
  try {
    // RPC callers get CLI errors back as task_failed, so nonzero exits are not logged here.
    const runQuiet = (args) => deps.runTask(args).catch((error) => ({ code: -1, stdout: "", stderr: String(error) }))
    changed = await registerRpc(ctx, { runTask: runQuiet, readFile: deps.readFile, log })
    rpcRegistered = typeof ctx.rpc?.register === "function"
  } catch (error) {
    await log("could not register rpc", { error: String(error) })
  }
  // Other CLI runs (worker, check-mrs, terminal) commit to the store repo; announce those too.
  let stopStoreWatch = () => {}
  if (rpcRegistered) {
    try {
      stopStoreWatch = startStoreWatcher({ deps, changed, log })
    } catch (error) {
      await log("could not watch store", { error: String(error) })
    }
  }
  const resubscribeMs = deps.resubscribeMs ?? RESUBSCRIBE_MS
  const sleep = (ms) => new Promise((resolveSleep) => {
    if (controller.signal.aborted) return resolveSleep()
    const timer = setTimeout(done, ms)
    function done() { clearTimeout(timer); controller.signal.removeEventListener("abort", done); resolveSleep() }
    controller.signal.addEventListener("abort", done)
  })

  // The stream may end without our abort (service hiccup): resubscribe after a delay,
  // giving up after MAX_EMPTY_ENDS consecutive ends that delivered no event.
  void (async () => {
    let emptyEnds = 0
    while (!controller.signal.aborted) {
      let delivered = false
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          delivered = true
          emptyEnds = 0
          if (!event || typeof event.type !== "string") continue
          try {
            await onEvent(event)
          } catch (error) {
            await log("event handling failed", { type: event.type, error: String(error) })
          }
        }
      } catch (error) {
        if (controller.signal.aborted) return
        await log("event subscription failed", { error: String(error) })
      }
      if (controller.signal.aborted) return
      if (!delivered) emptyEnds += 1
      if (emptyEnds >= MAX_EMPTY_ENDS) {
        await log("event subscription keeps ending; giving up", { attempts: emptyEnds })
        return
      }
      await sleep(resubscribeMs)
    }
  })().catch((error) => log("could not subscribe to OpenCode events", { error: String(error) }))

  // `stop` is the plugin cleanup; `idle` waits for queued CLI calls (tests only).
  return {
    stop: () => {
      controller.abort()
      try {
        stopStoreWatch()
      } catch {
        // Cleanup must not throw.
      }
      try {
        skillRegistration?.dispose?.()
      } catch {
        // Cleanup must not throw.
      }
    },
    idle: async () => {
      while (pending.size) await Promise.allSettled([...pending])
    },
  }
}
