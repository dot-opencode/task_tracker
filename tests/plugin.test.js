// Run: node --test tests/plugin.test.js
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

import {
  artifactFor, contextText, createState, findPrUrl, gateMessage, LIMIT, parseTask, questionText, registerAgentTasks, RULES,
} from "../skills/agent-tasks/opencode/agent-tasks-core.js"

const DIR = "/repo/app"
const STORE = "/store/work"
const TASK_TEXT = `---
id: T-0083
title: "Fix \\"port\\" drift"
project: crm
created: 2026-10-01
session: ses_root
spec: docs/superpowers/specs/2026-10-01-port-drift-design.md
---

The internal service URL drifts.

## Log
- 2026-10-01 09:12 task: 01_ready → 02_exploring
`

// Test-side adapter: registerAgentTasks returns {stop, idle}; keep `stop()` + `stop.idle()` ergonomics.
async function reg(ctx, deps) {
  const { stop, idle } = await registerAgentTasks(ctx, deps)
  return Object.assign(() => stop(), { idle })
}

function deferredEvents() {
  const queue = []
  let signal
  return {
    push(event) { queue.push(event) },
    aborted() { return signal?.aborted === true },
    async *subscribe({ signal: subscriptionSignal }) {
      signal = subscriptionSignal
      while (!signal.aborted) {
        const event = queue.shift()
        if (event) yield event
        else await new Promise((resolve) => setImmediate(resolve))
      }
    },
  }
}

async function tick(n = 30) {
  for (let i = 0; i < n; i += 1) await new Promise((resolve) => setImmediate(resolve))
}

// sessions: { id: { parentID?, metadata?, directory? } }
function contextFor({ sessions, events, folder = "03_brainstorming", taskText = TASK_TEXT, runTask } = {}) {
  const hooks = new Map(); const tools = []; const calls = []; const logs = []; const gets = []
  const state = { folder, clock: 1_000_000 }
  const ctx = {
    hooks, tools,
    session: {
      hook: async (name, callback) => hooks.set(name, callback),
      get: async ({ sessionID }) => {
        gets.push(sessionID)
        const s = sessions[sessionID]
        if (!s) throw new Error(`session ${sessionID} not found`)
        return { id: sessionID, parentID: s.parentID ?? null, metadata: s.metadata ?? null, location: { directory: s.directory ?? DIR } }
      },
    },
    tool: {
      hook: async (name, callback) => hooks.set(`tool:${name}`, callback),
      transform: async (fn) => fn({ add: (tool) => tools.push(tool) }),
    },
    event: { subscribe: ({ signal }) => events.subscribe({ signal }) },
  }
  const deps = {
    state: createState(),
    now: () => state.clock,
    log: async (entry) => logs.push(entry),
    readFile: async (path) => {
      if (path !== `${STORE}/${state.folder}/T-0083-fix.md`) throw Object.assign(new Error("ENOENT"), { code: "ENOENT" })
      return taskText
    },
    runTask: runTask ?? (async (args) => {
      calls.push(args)
      if (args[0] === "path") return { code: 0, stdout: `${STORE}/${state.folder}/T-0083-fix.md\n`, stderr: "" }
      if (args[0] === "bind") return { code: 0, stdout: `T-0083: bound to ${args[3]}\n`, stderr: "" }
      return { code: 0, stdout: "", stderr: "" }
    }),
  }
  return { ctx, deps, calls, logs, gets, state }
}

const BOUND = { ses_root: { metadata: { agent_tasks: { id: "T-0083" } } } }

async function setup(t, options = {}) {
  const events = deferredEvents()
  const env = contextFor({ sessions: BOUND, events, ...options })
  const stop = await reg(env.ctx, env.deps)
  t.after(stop)
  const hook = (name) => env.ctx.hooks.get(name)
  const signals = () => env.calls.filter((c) => c[0] === "signal")
  return { ...env, events, stop, hook, signals }
}

const sig = (name, text) => (text === undefined
  ? ["signal", "T-0083", name, "--session", "ses_root"]
  : ["signal", "T-0083", name, "--session", "ses_root", "--text", text])

// ---------------------------------------------------------------- hooks → signals

test("prompt hook sends input with the first prompt line", async (t) => {
  const e = await setup(t)
  await e.hook("prompt")({ sessionID: "ses_root", messageID: "msg_1", prompt: { text: "  \nlet's go\nmore" }, metadata: {}, delivery: "immediate" })
  await e.stop.idle()
  assert.deepEqual(e.signals(), [sig("input", "let's go")])
})

test("dedupe: the same hook or event delivered by N setup instances signals once", async (t) => {
  const events = deferredEvents()
  const env = contextFor({ sessions: BOUND, events })
  const stops = []
  const hookSets = []
  for (let i = 0; i < 3; i += 1) {
    const hooks = new Map()
    const ctx = { ...env.ctx, hooks, session: { ...env.ctx.session, hook: async (n, cb) => hooks.set(n, cb) },
      tool: { ...env.ctx.tool, hook: async (n, cb) => hooks.set(`tool:${n}`, cb) } }
    stops.push(await reg(ctx, env.deps))
    hookSets.push(hooks)
  }
  t.after(() => stops.forEach((s) => s()))
  const prompt = { sessionID: "ses_root", messageID: "msg_1", prompt: { text: "hi" } }
  const question = { tool: "question", sessionID: "ses_root", id: "call_1", input: { questions: [{ question: "Q?", options: [] }] } }
  for (const hooks of hookSets) {
    await hooks.get("prompt")({ ...prompt })
    await hooks.get("tool:execute.before")({ ...question })
  }
  // The event stream is shared, so every subscriber sees the same event object.
  for (let i = 0; i < 3; i += 1) {
    // each subscription consumes from the shared queue; push one copy per subscriber
    events.push({ id: "evt_1", type: "session.execution.succeeded", data: { sessionID: "ses_root" } })
  }
  await tick()
  await stops[0].idle()
  assert.deepEqual(env.calls.filter((c) => c[0] === "signal"), [sig("input", "hi"), sig("question", "Q?"), sig("turn-end")])
})

test("dedupe without ids falls back to a short window", async (t) => {
  const e = await setup(t)
  await e.hook("prompt")({ sessionID: "ses_root", prompt: { text: "a" } })
  await e.hook("prompt")({ sessionID: "ses_root", prompt: { text: "a" } })
  await e.stop.idle()
  assert.equal(e.signals().length, 1)
})

test("question execute.before sends question with the first question and option labels", async (t) => {
  const e = await setup(t)
  await e.hook("tool:execute.before")({
    tool: "question", sessionID: "ses_root", agent: "build", messageID: "m1", id: "call_q",
    input: { questions: [
      { question: "Which license?", header: "License", options: [{ label: "MIT", description: "x" }, { label: "Apache-2.0", description: "y" }] },
      { question: "Second?", header: "S", options: [{ label: "no" }] },
    ] },
  })
  await e.stop.idle()
  assert.deepEqual(e.signals(), [sig("question", "Which license? — MIT / Apache-2.0")])
})

test("execute.after: question → answered, finishing skill → finishing, errors and other tools ignored", async (t) => {
  const e = await setup(t)
  const after = e.hook("tool:execute.after")
  await after({ tool: "question", sessionID: "ses_root", id: "c1", input: {}, status: "completed", result: { output: { answers: [["MIT"]] } } })
  await after({ tool: "question", sessionID: "ses_root", id: "c2", input: {}, status: "error", error: new Error("dismissed") })
  await after({ tool: "skill", sessionID: "ses_root", id: "c3", input: { id: "finishing-a-development-branch" }, status: "completed", result: { output: {} } })
  await after({ tool: "skill", sessionID: "ses_root", id: "c4", input: { id: "brainstorming" }, status: "completed", result: {} })
  await after({ tool: "read", sessionID: "ses_root", id: "c5", input: { path: "/x" }, status: "completed", result: {} })
  await e.stop.idle()
  assert.deepEqual(e.signals(), [sig("answered"), sig("finishing")])
})

test("events map to turn-end, error, permission and answered; others ignored", async (t) => {
  const e = await setup(t)
  const push = (type, data, id) => e.events.push({ id, type, data: { sessionID: "ses_root", ...data } })
  push("session.execution.succeeded", {}, "e1")
  push("session.execution.failed", { error: { message: "provider exploded\nstack" } }, "e2")
  push("session.execution.interrupted", { reason: "user" }, "e3")
  push("session.execution.interrupted", { reason: "superseded" }, "e4")
  push("session.execution.interrupted", { reason: "shutdown" }, "e5")
  push("session.execution.interrupted", { reason: "inactivity" }, "e5b")
  push("permission.asked", { id: "per_1", action: "external_directory", resources: ["/tmp/x", "/tmp/y"] }, "e6")
  push("permission.replied", { id: "per_1", reply: "once" }, "e7")
  push("form.replied", { id: "frm_1", answer: { q0: "MIT" } }, "e8")
  push("session.viewed", {}, "e9")
  e.events.push({ type: "form.created", data: { form: { id: "frm", sessionID: "ses_root" } } })
  await tick()
  await e.stop.idle()
  assert.deepEqual(e.signals(), [
    sig("turn-end"),
    sig("error", "provider exploded"),
    sig("error", "interrupted: shutdown"),
    sig("error", "interrupted: inactivity"),
    sig("permission", "external_directory /tmp/x, /tmp/y"),
    sig("answered"),
  ])
})

// ---------------------------------------------------------------- binding lookup

test("unbound session → no runTask calls and no context", async (t) => {
  const events = deferredEvents()
  const env = contextFor({ sessions: { ses_free: {} }, events })
  const stop = await reg(env.ctx, env.deps)
  t.after(stop)
  await env.ctx.hooks.get("prompt")({ sessionID: "ses_free", messageID: "m", prompt: { text: "x" } })
  await env.ctx.hooks.get("tool:execute.before")({ tool: "skill", sessionID: "ses_free", id: "c", input: { id: "writing-plans" } })
  await env.ctx.hooks.get("tool:execute.after")({ tool: "write", sessionID: "ses_free", id: "w", input: { path: `${DIR}/docs/superpowers/specs/a-design.md` }, status: "completed" })
  const ev = { sessionID: "ses_free", system: [] }
  await env.ctx.hooks.get("context")(ev)
  events.push({ id: "e", type: "session.execution.succeeded", data: { sessionID: "ses_free" } })
  events.push({ id: "e2", type: "session.execution.succeeded", data: { sessionID: "ses_missing" } })
  await tick()
  await stop.idle()
  assert.deepEqual(env.calls, [])
  assert.deepEqual(ev.system, [])
})

test("child sessions resolve to the root of the parentID chain; only question/permission/answered count", async (t) => {
  const events = deferredEvents()
  const sessions = { ...BOUND, ses_mid: { parentID: "ses_root" }, ses_leaf: { parentID: "ses_mid", metadata: { other: 1 } } }
  const env = contextFor({ sessions, events })
  const stop = await reg(env.ctx, env.deps)
  t.after(stop)
  await env.ctx.hooks.get("tool:execute.before")({ tool: "question", sessionID: "ses_leaf", id: "q1", input: { questions: [{ question: "Q?" }] } })
  await env.ctx.hooks.get("prompt")({ sessionID: "ses_leaf", messageID: "m1", prompt: { text: "sub prompt" } })
  events.push({ id: "e1", type: "session.execution.succeeded", data: { sessionID: "ses_leaf" } })
  events.push({ id: "e2", type: "permission.asked", data: { sessionID: "ses_leaf", action: "bash", resources: ["rm"] } })
  await tick()
  await stop.idle()
  assert.deepEqual(env.calls.filter((c) => c[0] === "signal"), [sig("question", "Q?"), sig("permission", "bash rm")])
  // cached: the chain was walked once
  assert.deepEqual(env.gets, ["ses_leaf", "ses_mid", "ses_root"])
})

test("chains deeper than 5 hops are treated as unbound", async (t) => {
  const events = deferredEvents()
  const sessions = { ...BOUND }
  let parent = "ses_root"
  for (let i = 1; i <= 6; i += 1) { sessions[`ses_c${i}`] = { parentID: parent }; parent = `ses_c${i}` }
  const env = contextFor({ sessions, events })
  const stop = await reg(env.ctx, env.deps)
  t.after(stop)
  await env.ctx.hooks.get("tool:execute.before")({ tool: "question", sessionID: "ses_c5", id: "a", input: { questions: [{ question: "ok" }] } })
  await env.ctx.hooks.get("tool:execute.before")({ tool: "question", sessionID: "ses_c6", id: "b", input: { questions: [{ question: "deep" }] } })
  await stop.idle()
  assert.deepEqual(env.calls, [sig("question", "ok")])
})

// ---------------------------------------------------------------- skill gate

test("skill gate rejects writing-plans before planning with the exact message", async (t) => {
  const e = await setup(t, { folder: "03_brainstorming" })
  const expected = "agent-tasks: writing-plans is not allowed while T-0083 is in 03_brainstorming. " +
    "If the user approved the spec, run `task approve T-0083` first."
  assert.equal(gateMessage("writing-plans", "T-0083", "03_brainstorming"), expected)
  await assert.rejects(
    e.hook("tool:execute.before")({ tool: "skill", sessionID: "ses_root", id: "c1", input: { id: "writing-plans" } }),
    (error) => error instanceof Error && error.message === expected,
  )
  assert.deepEqual(e.calls, [["path", "T-0083"]])
})

test("skill gate message for implementation skills asks for plan approval", () => {
  assert.equal(
    gateMessage("subagent-driven-development", "T-0083", "06_plan_review"),
    "agent-tasks: subagent-driven-development is not allowed while T-0083 is in 06_plan_review. " +
      "If the user approved the plan, run `task approve T-0083` first (use --now if they asked to start immediately).",
  )
})

test("skill gate rejects in every hook instance for the same call", async (t) => {
  const e = await setup(t, { folder: "07_approved" })
  const ev = { tool: "skill", sessionID: "ses_root", id: "c1", input: { id: "subagent-driven-development" } }
  await assert.rejects(e.hook("tool:execute.before")({ ...ev }), /subagent-driven-development is not allowed while T-0083 is in 07_approved/)
  await assert.rejects(e.hook("tool:execute.before")({ ...ev }), /is not allowed/)
  assert.equal(e.calls.length, 1)
})

test("skill gate: writing-plans only in 05/06, implementation skills only in 08/09", async (t) => {
  const open = {
    "writing-plans": ["05_planning", "06_plan_review"],
    "executing-plans": ["08_implementing", "09_finishing", "10_unmerged"],
    "subagent-driven-development": ["08_implementing", "09_finishing", "10_unmerged"],
  }
  const all = ["02_exploring", "03_brainstorming", "04_spec_review", "05_planning", "06_plan_review", "07_approved",
    "08_implementing", "09_finishing", "10_unmerged", "blocked", "postponed"]
  for (const [skill, folders] of Object.entries(open)) {
    for (const folder of all) {
      const e = await setup(t, { folder })
      const call = e.hook("tool:execute.before")({ tool: "skill", sessionID: "ses_root", id: `c-${skill}-${folder}`, input: { id: skill } })
      if (folders.includes(folder)) await call
      else await assert.rejects(call, new RegExp(`${skill} is not allowed while T-0083 is in ${folder}`))
    }
  }
  const e = await setup(t)
  await e.hook("tool:execute.before")({ tool: "skill", sessionID: "ses_root", id: "c", input: { id: "brainstorming" } })
  assert.deepEqual(e.calls, [])
})

test("skill gate fails open when task path fails", async (t) => {
  const e = await setup(t, { runTask: async () => ({ code: 1, stdout: "", stderr: "task: no task T-0083" }) })
  await e.hook("tool:execute.before")({ tool: "skill", sessionID: "ses_root", id: "c", input: { id: "writing-plans" } })
  assert.equal(e.logs[0].message, "task exited nonzero")
})

// ---------------------------------------------------------------- spec / plan / pr

test("write/edit of spec and plan files → task set with relative or absolute paths", async (t) => {
  const e = await setup(t)
  const after = e.hook("tool:execute.after")
  const done = (tool, id, path) => after({ tool, sessionID: "ses_root", id, input: { path }, status: "completed", result: {} })
  await done("write", "w1", `${DIR}/docs/superpowers/specs/2026-10-02-x-design.md`)
  await done("edit", "w2", "/elsewhere/wt/docs/superpowers/plans/2026-10-02-x.md")
  await done("write", "w3", "docs/superpowers/specs/2026-10-02-y-design.md")
  await done("write", "w4", `${DIR}/docs/superpowers/specs/notes.md`)
  await done("write", "w5", `${DIR}/docs/superpowers/plans/sub/x.md`)
  await done("edit", "w6", `${DIR}/docs/superpowers/specs/2026-10-02-y-design.md`) // same value: no repeat
  await e.stop.idle()
  assert.deepEqual(e.calls, [
    ["set", "T-0083", "spec", "docs/superpowers/specs/2026-10-02-x-design.md"],
    ["set", "T-0083", "plan", "/elsewhere/wt/docs/superpowers/plans/2026-10-02-x.md"],
    ["set", "T-0083", "spec", "docs/superpowers/specs/2026-10-02-y-design.md"],
  ])
  assert.deepEqual(artifactFor("/a/docs/superpowers/plans/p.md", "/a"), { key: "plan", value: "docs/superpowers/plans/p.md" })
  assert.equal(artifactFor("/a/docs/superpowers/specs/x.md", "/a"), undefined)
})

test("gh pr create output → task set pr <url>", async (t) => {
  const e = await setup(t)
  const after = e.hook("tool:execute.after")
  await after({ tool: "shell", sessionID: "ses_root", id: "s1", input: { command: "git push && gh pr create --fill" }, status: "completed",
    result: { output: { stdout: "Creating pull request\nhttps://github.com/org/repo/pull/42\n" }, content: [], metadata: {} } })
  await after({ tool: "bash", sessionID: "ses_root", id: "s2", input: { command: "gh pr view" }, status: "completed",
    result: { output: "https://github.com/org/repo/pull/43" } })
  await after({ tool: "bash", sessionID: "ses_root", id: "s3", input: { command: "gh pr create" }, status: "completed", result: { output: "error" } })
  await e.stop.idle()
  assert.deepEqual(e.calls, [["set", "T-0083", "pr", "https://github.com/org/repo/pull/42"]])
  assert.equal(findPrUrl({ content: [{ type: "text", text: "see https://github.com/a/b/pull/7." }] }), "https://github.com/a/b/pull/7")
})

// ---------------------------------------------------------------- context

test("context and compaction hooks inject one <agent-tasks> block with id, folder, rules and body", async (t) => {
  const e = await setup(t, { folder: "04_spec_review" })
  for (const name of ["context", "compaction"]) {
    const ev = { sessionID: "ses_root", system: [{ type: "text", text: "base" }] }
    await e.hook(name)(ev)
    await e.hook(name)(ev)
    const blocks = ev.system.filter((p) => p.type === "text" && p.text.includes("<agent-tasks>"))
    assert.equal(blocks.length, 1)
    const text = blocks[0].text
    assert.match(text, /^<agent-tasks>\nTask T-0083: "Fix "port" drift" — folder 04_spec_review, project crm/)
    assert.match(text, /spec: docs\/superpowers\/specs\/2026-10-01-port-drift-design\.md/)
    assert.match(text, /task approve T-0083/)
    assert.match(text, /question tool/)
    assert.match(text, /Never edit task files directly/)
    assert.match(text, /The internal service URL drifts\./)
    assert.doesNotMatch(text, /## Log|01_ready → 02_exploring/)
    assert.match(text, /<\/agent-tasks>$/)
  }
})

test("context re-reads the folder on every hook", async (t) => {
  const e = await setup(t, { folder: "03_brainstorming" })
  const a = { sessionID: "ses_root", system: [] }
  await e.hook("context")(a)
  e.state.folder = "08_implementing"
  const b = { sessionID: "ses_root", system: [] }
  await e.hook("context")(b)
  assert.match(a.system[0].text, /folder 03_brainstorming/)
  assert.match(b.system[0].text, /folder 08_implementing/)
  assert.match(b.system[0].text, /Implement the approved plan in a worktree/)
})

test("contextText truncates to the limit and keeps the closing tag", () => {
  const text = contextText({ id: "T-0001", title: "t", folder: "08_implementing", project: "p", body: "x".repeat(10_000) })
  assert.ok(text.length <= LIMIT, `length ${text.length}`)
  assert.equal(LIMIT, 4000)
  assert.match(text, /description truncated; run `task show T-0001`/)
  assert.match(text, /^<agent-tasks>\nTask T-0001/)
  assert.match(text, /<\/agent-tasks>$/)
  assert.match(text, /Rules:/)
})

test("folders 00, 01, 10 carry only the common rule; every working folder has rules", () => {
  for (const folder of ["00_backlog", "01_ready", "11_done"]) {
    const text = contextText({ id: "T-0001", title: "t", folder, body: "b" })
    assert.equal(text.match(/^- /gm).length, 1)
  }
  for (const folder of ["02_exploring", "03_brainstorming", "04_spec_review", "05_planning", "06_plan_review", "07_approved", "08_implementing", "09_finishing", "10_unmerged", "blocked", "postponed"]) {
    assert.equal(typeof RULES[folder], "function", folder)
  }
  const postponed = contextText({ id: "T-0007", title: "t", folder: "postponed" })
  assert.match(postponed, /postponed by the user.*Do not work on it unless the user asks.*`task resume T-0007`/s)
  assert.match(contextText({ id: "T-1", title: "t", folder: "07_approved" }), /task approve T-1 --now/)
  assert.match(contextText({ id: "T-1", title: "t", folder: "06_plan_review" }), /task approve T-1.*deferred.*worker.*start/s)
  assert.match(contextText({ id: "T-1", title: "t", folder: "05_planning" }), /writing-plans.*docs\/superpowers\/plans\/.*Do not implement/s)
  for (const folder of ["05_planning", "06_plan_review"]) {
    assert.match(contextText({ id: "T-1", title: "t", folder }), /`task approve T-1`/, folder)
  }
  const review = contextText({ id: "T-1", title: "t", folder: "06_plan_review" })
  assert.match(review, /ALWAYS run `task approve T-1` at once.*automation is on or off.*only records the approval.*07_approved.*without `--now`/s)
  assert.match(contextText({ id: "T-1", title: "t", folder: "09_finishing" }), /task done T-1 --result/)
})

test("parseTask reads quoted titles and stops the body at ## Result / ## Log", () => {
  const { fields, body } = parseTask(TASK_TEXT)
  assert.equal(fields.title, 'Fix "port" drift')
  assert.equal(fields.session, "ses_root")
  assert.equal(body, "The internal service URL drifts.")
  assert.equal(questionText({ questions: [] }), "")
})

// ---------------------------------------------------------------- task_bind and robustness

test("task_bind tool runs task bind for the current session", async (t) => {
  const e = await setup(t)
  assert.equal(e.ctx.tools.length, 1)
  const tool = e.ctx.tools[0]
  assert.equal(tool.name, "task_bind")
  assert.deepEqual(tool.input.required, ["id"])
  const result = await tool.execute({ id: "83" }, { sessionID: "ses_new" })
  assert.deepEqual(e.calls, [["bind", "83", "--session", "ses_new"]])
  assert.deepEqual(result, { content: "T-0083: bound to ses_new" })
  const failing = await setup(t, { runTask: async () => ({ code: 1, stdout: "", stderr: "task: invalid task id 'x'" }) })
  assert.deepEqual(await failing.ctx.tools[0].execute({ id: "x" }, { sessionID: "ses_new" }), { content: "task bind failed: task: invalid task id 'x'" })
})

test("rpc: registered with the plugin; signals that move a task and recorded fields emit changed", async (t) => {
  const emitted = []
  let registered
  const runTask = async (args) => {
    if (args[0] === "signal" && args[2] === "turn-end") return { code: 0, stdout: "T-0083: 03_brainstorming → 04_spec_review\n", stderr: "" }
    return { code: 0, stdout: "T-0083: input noted\n", stderr: "" }
  }
  const events = deferredEvents()
  const env = contextFor({ sessions: BOUND, events, runTask })
  const ctx = { ...env.ctx, rpc: { register: async (def) => { registered = def; return { events: { emit: async (...a) => emitted.push(a) } } } } }
  const stop = await reg(ctx, env.deps)
  t.after(stop)
  assert.equal(registered.id, "agent-tasks")
  await ctx.hooks.get("prompt")({ sessionID: "ses_root", messageID: "m_rpc", prompt: { text: "hi" } })
  events.push({ id: "e_rpc", type: "session.execution.succeeded", data: { sessionID: "ses_root" } })
  await ctx.hooks.get("tool:execute.after")({ tool: "write", sessionID: "ses_root", id: "w_rpc", input: { path: `${DIR}/docs/superpowers/plans/p.md` }, status: "completed" })
  await tick()
  await stop.idle()
  // `input noted` does not move the task, so only the turn-end signal and the plan field emit.
  assert.deepEqual(emitted.map(([name, data]) => `${name}:${data.action}:${data.id}`).sort(), ["changed:set:T-0083", "changed:signal:T-0083"])
})

test("runTask failures and session lookup errors are logged, never thrown", async (t) => {
  const events = deferredEvents()
  const env = contextFor({ sessions: BOUND, events, runTask: async () => { throw new Error("spawn ENOENT") } })
  env.deps.log = async () => { throw new Error("logger broken") }
  const stop = await reg(env.ctx, env.deps)
  t.after(stop)
  await env.ctx.hooks.get("prompt")({ sessionID: "ses_root", messageID: "m", prompt: { text: "x" } })
  await env.ctx.hooks.get("prompt")({ sessionID: "ses_gone", messageID: "m", prompt: { text: "x" } })
  await env.ctx.hooks.get("tool:execute.before")({ tool: "skill", sessionID: "ses_root", id: "c", input: { id: "writing-plans" } })
  const ev = { sessionID: "ses_root", system: [] }
  await env.ctx.hooks.get("context")(ev)
  events.push({ type: "session.execution.succeeded" })
  events.push(null)
  await tick()
  await stop.idle()
  assert.deepEqual(ev.system, [])
})

test("cleanup aborts the event subscription", async () => {
  const events = deferredEvents()
  const env = contextFor({ sessions: BOUND, events })
  const stop = await reg(env.ctx, env.deps)
  await tick(2)
  stop()
  await tick(2)
  assert.equal(events.aborted(), true)
})

test("entrypoint is a dependency-free V2 plugin object", async () => {
  const url = new URL("../skills/agent-tasks/opencode/agent-tasks.js", import.meta.url)
  const siblings = ["agent-tasks-core.js", "agent-tasks-rpc.js", "rpc.js"].map((f) => new URL(`../skills/agent-tasks/opencode/${f}`, import.meta.url))
  for (const file of [url, ...siblings]) {
    const source = await readFile(file, "utf8")
    for (const [, specifier] of source.matchAll(/^import\s.*?from\s+["']([^"']+)["']/gm)) {
      assert.ok(specifier.startsWith("node:") || specifier.startsWith("./"), `non-bundled import: ${specifier}`)
    }
    assert.doesNotMatch(source, /from\s+["']@opencode|import\(["']@opencode/)
  }
  const { default: plugin } = await import(url)
  assert.equal(plugin.id, "agent-tasks")
  assert.equal(typeof plugin.setup, "function")
})

// ---------------------------------------------------------------- review fixes

test("C1: automated kickoff prompts are not user input", async (t) => {
  const e = await setup(t)
  await e.hook("prompt")({ sessionID: "ses_root", messageID: "m_auto", prompt: { text: "You are working on task" },
    metadata: { agent_tasks: { automated: true } }, delivery: "queue" })
  await e.hook("prompt")({ sessionID: "ses_root", messageID: "m_user", prompt: { text: "hello" }, metadata: {}, delivery: "immediate" })
  await e.stop.idle()
  assert.deepEqual(e.signals(), [sig("input", "hello")])
})

// Probe shape: no top-level id, data = {sessionID}, N copies within ~3 ms (one per setup instance).
async function burst(t, type, data) {
  const e = await setup(t)
  for (let i = 0; i < 7; i += 1) {
    e.events.push({ type, data: { sessionID: "ses_root", ...data } })
    e.state.clock += i % 2 // copies spread over ~3 ms
  }
  await tick()
  await e.stop.idle()
  return e
}

test("I4: 7 id-less execution.succeeded copies within a few ms → one turn-end", async (t) => {
  const e = await burst(t, "session.execution.succeeded", {})
  assert.deepEqual(e.signals(), [sig("turn-end")])
})

test("I4: 7 id-less execution.failed copies → one error", async (t) => {
  const e = await burst(t, "session.execution.failed", { error: { message: "boom" } })
  assert.deepEqual(e.signals(), [sig("error", "boom")])
})

test("I4: the dedupe window does not swallow a turn-end repeated 2.5 s later", async (t) => {
  const e = await setup(t)
  e.events.push({ type: "session.execution.succeeded", data: { sessionID: "ses_root" } })
  await tick()
  e.state.clock += 2500
  e.events.push({ type: "session.execution.succeeded", data: { sessionID: "ses_root" } })
  await tick()
  await e.stop.idle()
  assert.deepEqual(e.signals(), [sig("turn-end"), sig("turn-end")])
})

test("I5: child sessions record spec/plan/pr relative to their own directory but still send no turn-end", async (t) => {
  const events = deferredEvents()
  const sessions = { ...BOUND, ses_sub: { parentID: "ses_root", directory: "/repo/wt" } }
  const env = contextFor({ sessions, events })
  const stop = await reg(env.ctx, env.deps)
  t.after(stop)
  const after = env.ctx.hooks.get("tool:execute.after")
  await after({ tool: "write", sessionID: "ses_sub", id: "w1", input: { path: "/repo/wt/docs/superpowers/specs/2026-10-02-z-design.md" }, status: "completed", result: {} })
  await after({ tool: "edit", sessionID: "ses_sub", id: "w2", input: { path: `${DIR}/docs/superpowers/plans/2026-10-02-z.md` }, status: "completed", result: {} })
  await after({ tool: "shell", sessionID: "ses_sub", id: "s1", input: { command: "gh pr create --fill" }, status: "completed",
    result: { output: { exit: 0, output: "https://github.com/org/repo/pull/9\n" } } })
  await after({ tool: "skill", sessionID: "ses_sub", id: "k1", input: { id: "finishing-a-development-branch" }, status: "completed", result: {} })
  events.push({ type: "session.execution.succeeded", data: { sessionID: "ses_sub" } })
  await tick()
  await stop.idle()
  assert.deepEqual(env.calls, [
    ["set", "T-0083", "spec", "docs/superpowers/specs/2026-10-02-z-design.md"],
    ["set", "T-0083", "plan", `${DIR}/docs/superpowers/plans/2026-10-02-z.md`],
    ["set", "T-0083", "pr", "https://github.com/org/repo/pull/9"],
  ])
})

test("M9: an event stream that ends on its own is resubscribed after a delay", async (t) => {
  let subscriptions = 0
  const events = {
    async *subscribe({ signal }) {
      subscriptions += 1
      if (subscriptions === 1) return // ends without abort
      yield { type: "session.execution.succeeded", data: { sessionID: "ses_root" } }
      while (!signal.aborted) await new Promise((resolve) => setImmediate(resolve))
    },
  }
  const env = contextFor({ sessions: BOUND, events })
  env.deps.resubscribeMs = 5
  const stop = await reg(env.ctx, env.deps)
  t.after(stop)
  for (let i = 0; i < 50 && env.calls.length === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 2))
  await stop.idle()
  assert.equal(subscriptions, 2)
  assert.deepEqual(env.calls, [sig("turn-end")])
})

test("M9: gives up after 20 consecutive empty ends and logs", async (t) => {
  let subscriptions = 0
  const events = { async *subscribe() { subscriptions += 1 } }
  const env = contextFor({ sessions: BOUND, events })
  env.deps.resubscribeMs = 0
  const stop = await reg(env.ctx, env.deps)
  t.after(stop)
  for (let i = 0; i < 200 && !env.logs.length; i += 1) await new Promise((resolve) => setTimeout(resolve, 1))
  assert.equal(subscriptions, 20)
  assert.equal(env.logs[0].message, "event subscription keeps ending; giving up")
})

test("M10: the plugin's setup returns a plain cleanup function", async () => {
  const { default: plugin } = await import("../skills/agent-tasks/opencode/agent-tasks.js")
  const env = contextFor({ sessions: BOUND, events: deferredEvents() })
  const stop = await plugin.setup(env.ctx)
  assert.equal(typeof stop, "function")
  assert.equal(stop.idle, undefined)
  stop()
})
