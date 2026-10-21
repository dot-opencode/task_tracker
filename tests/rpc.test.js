// Run: node --test tests/rpc.test.js
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

import { parseProjects, registerRpc, rpcHandlers } from "../skills/agent-tasks/opencode/agent-tasks-rpc.js"
import { AgentTasksRpc } from "../skills/agent-tasks/opencode/rpc.js"

const context = { signal: new AbortController().signal, error: (type, message, data) => ({ type, message, data }) }

function env(outputs = {}) {
  const calls = []
  const events = []
  const handlers = rpcHandlers({
    run: async (args) => {
      calls.push(args)
      return outputs[args[0]] ?? { code: 0, stdout: "", stderr: "" }
    },
    readFile: async (path) => {
      assert.equal(path, "/store/work/06_plan_review/T-0083-x.md")
      return "---\nid: T-0083\ntitle: \"X\"\n---\n\nBody\n\n## Log\n- a\n"
    },
    changed: async (event) => events.push(event),
  })
  return { handlers, calls, events }
}

test("every method in the contract has a handler and a JSON schema", () => {
  const { handlers } = env()
  assert.deepEqual(Object.keys(handlers).sort(), Object.keys(AgentTasksRpc.methods).sort())
  for (const [name, m] of Object.entries(AgentTasksRpc.methods)) {
    assert.equal(m.input.type, "object", name)
    assert.equal(m.output.type, "object", name)
    assert.ok(!Object.keys(m.errors).some((e) => e.startsWith("rpc.")), name)
  }
  assert.equal(AgentTasksRpc.events.changed.schema.type, "object")
})

test("list maps filters to task ls --json and parses the result", async () => {
  const e = env({ ls: { code: 0, stdout: '[{"id":"T-0001"}]', stderr: "" } })
  assert.deepEqual(await e.handlers.list({}, context), { tasks: [{ id: "T-0001" }] })
  await e.handlers.list({ folder: "ready", workspace: "work" }, context)
  await e.handlers.list({ waiting: true }, context)
  await e.handlers.list({ all: true }, context)
  assert.deepEqual(e.calls, [
    ["ls", "--json"], ["ls", "--json", "ready", "--ws", "work"], ["ls", "--json", "--waiting"], ["ls", "--json", "--all"],
  ])
  assert.deepEqual(e.events, [])
})

test("show reads the task file and splits fields and body", async () => {
  const e = env({ path: { code: 0, stdout: "/store/work/06_plan_review/T-0083-x.md\n", stderr: "" } })
  const out = await e.handlers.show({ id: "83" }, context)
  assert.equal(out.id, "T-0083")
  assert.equal(out.folder, "06_plan_review")
  assert.equal(out.status, "plan_review")
  assert.deepEqual(out.fields, { id: "T-0083", title: "X" })
  assert.equal(out.body, "Body")
  assert.match(out.markdown, /## Log/)
})

test("mutations pass values after -- or as option values and emit changed", async () => {
  const e = env({ new: { code: 0, stdout: "T-0200\n", stderr: "" } })
  assert.deepEqual(await e.handlers.create({ title: "-weird title", project: "api", body: "b", ready: true }, context), { id: "T-0200" })
  await e.handlers.log({ id: "T-0001", message: "--not-a-flag" }, context)
  await e.handlers.set({ id: "1", key: "pr", value: "-x" }, context)
  await e.handlers.move({ id: "1", folder: "ready", reason: "go" }, context)
  await e.handlers.done({ id: "1", result: "pr", summary: "ok" }, context)
  await e.handlers.setAuto({ enabled: true, duration: "3h" }, context)
  await e.handlers.setAuto({ enabled: false }, context)
  await e.handlers.removeWorktree({ id: "1", force: true }, context)
  assert.deepEqual(e.calls, [
    ["new", "--project", "api", "--body", "b", "--ready", "--", "-weird title"],
    ["log", "T-0001", "--", "--not-a-flag"],
    ["set", "--", "1", "pr", "-x"],
    ["mv", "1", "ready", "--reason", "go"],
    ["done", "1", "--result", "pr", "--summary", "ok"],
    ["auto", "on", "3h"],
    ["auto", "off"],
    ["worktree", "1", "--remove", "--force"],
  ])
  assert.deepEqual(e.events.map((x) => x.action), ["create", "log", "set", "move", "done", "auto", "auto", "worktree-remove"])
  assert.deepEqual(e.events[0], { action: "create", id: "T-0200" })
})

test("subtasks: parent/depends/force map to CLI flags", async () => {
  const e = env({ new: { code: 0, stdout: "T-0201\n", stderr: "" } })
  await e.handlers.create({ title: "Sub", parent: "T-0200", dependsOn: ["T-0084", "85"] }, context)
  await e.handlers.list({ parent: "T-0200" }, context)
  await e.handlers.set({ id: "1", key: "parent", value: "T-0200" }, context)
  await e.handlers.set({ id: "1", key: "depends_on", value: ["T-0084", "T-0085"] }, context)
  await e.handlers.set({ id: "1", key: "depends_on", value: "T-0084 T-0085" }, context)
  await e.handlers.unset({ id: "1", key: "parent" }, context)
  await e.handlers.unset({ id: "1", key: "depends_on" }, context)
  await e.handlers.move({ id: "1", folder: "done", force: true }, context)
  await e.handlers.done({ id: "1", result: "pr", force: true }, context)
  await e.handlers.merged({ id: "1", force: true }, context)
  await e.handlers.merged({ id: "1" }, context)
  assert.deepEqual(e.calls, [
    ["new", "--parent", "T-0200", "--depends", "T-0084,85", "--", "Sub"],
    ["ls", "--json", "--parent", "T-0200"],
    ["set", "--", "1", "parent", "T-0200"],
    ["set", "--", "1", "depends_on", "T-0084 T-0085"],
    ["set", "--", "1", "depends_on", "T-0084 T-0085"],
    ["unset", "1", "parent"],
    ["unset", "1", "depends_on"],
    ["mv", "1", "done", "--force"],
    ["done", "1", "--result", "pr", "--force"],
    ["merged", "1", "--force"],
    ["merged", "1"],
  ])
  const bad = env()
  assert.equal((await bad.handlers.create({ title: "t", parent: "--x" }, context)).data.field, "parent")
  assert.equal((await bad.handlers.create({ title: "t", dependsOn: ["1", "-x"] }, context)).data.field, "dependsOn")
  assert.equal((await bad.handlers.set({ id: "1", key: "depends_on", value: ["-x"] }, context)).data.field, "value")
  assert.equal((await bad.handlers.set({ id: "1", key: "parent", value: "nope" }, context)).data.field, "value")
  assert.deepEqual(bad.calls, [])
  const props = AgentTasksRpc.methods.list.output.properties.tasks.items.properties
  for (const k of ["source", "parent", "depends_on", "blocked_by", "children"]) assert.ok(props[k], k)
})

test("approve reports start or deferred", async () => {
  const start = env({ approve: { code: 0, stdout: "start\n", stderr: "" } })
  assert.deepEqual(await start.handlers.approve({ id: "1", now: true }, context), { result: "start", text: "start" })
  assert.deepEqual(start.calls, [["approve", "1", "--now"]])
  const deferred = env({ approve: { code: 0, stdout: "deferred\n", stderr: "" } })
  assert.equal((await deferred.handlers.approve({ id: "1" }, context)).result, "deferred")
})

test("a nonzero exit becomes task_failed with the CLI message and emits nothing", async () => {
  const e = env({ mv: { code: 1, stdout: "", stderr: "task: no task T-0009\n" } })
  assert.deepEqual(await e.handlers.move({ id: "9", folder: "ready" }, context), {
    type: "task_failed", message: "no task T-0009", data: { code: 1, stderr: "task: no task T-0009", stdout: "" },
  })
  assert.deepEqual(e.events, [])
})

test("formats are checked in the handlers: option-like values are rejected before the CLI runs", async () => {
  const e = env()
  assert.deepEqual(await e.handlers.move({ id: "--x", folder: "ready" }, context), { type: "invalid_input", message: "invalid id", data: { field: "id" } })
  assert.equal((await e.handlers.create({ title: "t", project: "-p" }, context)).data.field, "project")
  assert.equal((await e.handlers.worktree({ id: "1", branch: "--orphan" }, context)).data.field, "branch")
  assert.equal((await e.handlers.setAuto({ enabled: true, duration: "soon" }, context)).data.field, "duration")
  assert.deepEqual(e.calls, [])
})

test("schemas avoid `pattern`, which OpenCode rejects in RPC schemas", () => {
  assert.doesNotMatch(JSON.stringify(AgentTasksRpc), /"pattern"/)
})

test("parseProjects reads task project ls columns", () => {
  assert.deepEqual(parseProjects("work  api   /w/api\nhome  memo  /p/memo (missing)\n"), [
    { workspace: "work", name: "api", path: "/w/api", missing: false },
    { workspace: "home", name: "memo", path: "/p/memo", missing: true },
  ])
  assert.deepEqual(parseProjects("no projects\n"), [])
})

test("registerRpc registers the contract and emits changed; no-op without ctx.rpc", async () => {
  const emitted = []
  let registered
  const ctx = { rpc: { register: async (def, handlers) => { registered = { def, handlers }; return { events: { emit: async (...a) => emitted.push(a) } } } } }
  const changed = await registerRpc(ctx, { runTask: async () => ({ code: 0, stdout: "", stderr: "" }), readFile: async () => "", log: async () => {} })
  assert.equal(registered.def, AgentTasksRpc)
  await registered.handlers.resume({ id: "1" }, context)
  await changed({ action: "signal", id: "T-0001" })
  assert.deepEqual(emitted, [["changed", { action: "resume", id: "T-0001" }], ["changed", { action: "signal", id: "T-0001" }]])
  const noop = await registerRpc({}, {})
  await noop({ action: "x" })
})

test("rpc.js is plain data with no imports (browsers and userscripts load it as is)", async () => {
  const source = await readFile(new URL("../skills/agent-tasks/opencode/rpc.js", import.meta.url), "utf8")
  assert.doesNotMatch(source, /^import\s/m)
})
