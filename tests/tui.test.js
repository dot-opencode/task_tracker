// Run: node --test tests/tui.test.js
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

import { createTasksPlugin, runTask } from "../skills/agent-tasks/opencode/tui/tui.js"
import {
  buildOptions, formatTitle, groupOf, noSessionMessage, parseTasks, searchOptions, selectTasks, WAITING_STATUSES,
} from "../skills/agent-tasks/opencode/tui/tasks-model.js"

const T = (id, status, extra = {}) => ({
  id, title: `Title ${id}`, project: "api", workspace: "work", folder: "x", status, session: null, ...extra,
})
const SAMPLE = [
  T("T-0010", "backlog"), T("T-0104", "plan_review", { session: "ses_1", title: "ABC-6240: long" }),
  T("T-0003", "implementing"), T("T-0005", "ready"), T("T-0002", "done"), T("T-0001", "blocked"),
  T("T-0099", "archive", { folder: "archive" }),
]

test("waiting statuses match WAITING_FOLDERS in core.rs", async () => {
  const core = await readFile(new URL("../cli/src/core.rs", import.meta.url), "utf8")
  const folders = [...core.match(/WAITING_FOLDERS: \[&str; \d+\] = \[([^\]]*)\]/)[1].matchAll(/"([^"]+)"/g)].map((m) => m[1])
  const statuses = folders.map((f) => f.replace(/^\d+_/, ""))
  assert.deepEqual([...statuses].sort(), [...WAITING_STATUSES].sort())
})

test("groupOf", () => {
  assert.equal(groupOf("exploring"), "Agent working")
  assert.equal(groupOf("approved"), "Queued")
  assert.equal(groupOf("backlog"), "Backlog")
  assert.equal(groupOf("done"), "Done")
  assert.equal(groupOf("unmerged"), "Not merged")
  assert.equal(groupOf("spec_review"), "Waiting for you")
})

test("parseTasks validates input", () => {
  assert.equal(parseTasks(JSON.stringify(SAMPLE)).length, SAMPLE.length)
  assert.throws(() => parseTasks("nope"), /invalid JSON/)
  assert.throws(() => parseTasks("{}"), /expected an array/)
})

test("selectTasks orders by group then id, drops archive, merges without duplicates", () => {
  const ids = selectTasks([SAMPLE, [T("T-0104", "plan_review"), T("T-0200", "postponed")]]).map((t) => t.id)
  assert.deepEqual(ids, ["T-0001", "T-0104", "T-0003", "T-0005", "T-0010", "T-0002", "T-0200"])
  assert.deepEqual(selectTasks([SAMPLE], { waitingOnly: true }).map((t) => t.id), ["T-0001", "T-0104"])
})

test("buildOptions formats title, description and category", () => {
  const [first, second] = buildOptions(selectTasks([SAMPLE]))
  assert.equal(first.category, "Waiting for you")
  assert.equal(second.title, "T-0104  plan_review  ABC-6240: long")
  assert.equal(second.description, "api")
  const multi = buildOptions([T("T-1", "ready"), T("T-2", "ready", { workspace: "home" })])
  assert.equal(multi[1].description, "api · home")
})

test("searchOptions matches id, title and project; all words", () => {
  const options = buildOptions(selectTasks([SAMPLE, [T("T-0300", "ready", { project: "crm", title: "Fix port" })]]))
  assert.deepEqual(searchOptions("t-0300", options).map((o) => o.value.id), ["T-0300"])
  assert.deepEqual(searchOptions("crm port", options).map((o) => o.value.id), ["T-0300"])
  assert.equal(searchOptions("", options).length, options.length)
  assert.equal(searchOptions("zzz", options).length, 0)
})

test("subtasks: nested after parent within a group, progress and waits suffix, search, old CLI output", () => {
  const list = [
    T("T-0010", "ready", { children: ["T-0012", "T-0013", "T-0014"] }),
    T("T-0011", "ready"),
    T("T-0012", "ready", { parent: "T-0010", blocked_by: ["T-0084"], depends_on: ["T-0084"] }),
    T("T-0013", "done", { folder: "11_done", parent: "T-0010" }),
    T("T-0020", "backlog", { parent: "T-0010" }),
  ]
  const tasks = selectTasks([list])
  assert.deepEqual(tasks.map((t) => t.id), ["T-0010", "T-0012", "T-0011", "T-0020", "T-0013"])
  const options = buildOptions(tasks)
  assert.equal(options[0].title, "T-0010  ready  Title T-0010 [1/3]")
  assert.equal(options[1].title, "  ↳ T-0012  ready  Title T-0012 · waits T-0084")
  assert.equal(options[3].title, "T-0020  backlog  Title T-0020")
  assert.equal(options[4].title, "T-0013  done  Title T-0013")
  assert.deepEqual(searchOptions("t-0084", options).map((o) => o.value.id), ["T-0012"])
  assert.deepEqual(searchOptions("title t-0012", options).map((o) => o.value.id), ["T-0012"])
  const old = buildOptions(selectTasks([SAMPLE]))
  assert.ok(old.every((o) => !o.title.includes("↳") && !o.title.includes("waits") && !o.title.includes("[")))
})

test("runTask falls back to the bundled CLI on ENOENT and reports CLI errors", async () => {
  const calls = []
  const out = await runTask(["ls"], {
    fallback: "/fb/task",
    run: async (file) => {
      calls.push(file)
      if (file === "task") throw Object.assign(new Error("x"), { code: "ENOENT" })
      return { code: 0, stdout: "[]", stderr: "" }
    },
  })
  assert.equal(out, "[]")
  assert.deepEqual(calls, ["task", "/fb/task"])
  await assert.rejects(runTask(["ls"], { run: async () => ({ code: 1, stdout: "", stderr: "boom\n" }) }), /boom/)
})

function fakeContext() {
  const log = { toasts: [], navigated: [], synced: [], layers: [], dialogs: [], dialogSet: [] }
  const context = {
    renderer: { width: 200 },
    keymap: { layer: (f) => log.layers.push(f()) },
    ui: {
      toast: { show: (t) => log.toasts.push(t) },
      router: { navigate: (r) => log.navigated.push(r) },
      dialog: {
        select: (o) => new Promise((res) => log.dialogs.push({ o, res })),
        set: (o) => log.dialogSet.push(o),
      },
    },
    data: { session: { sync: async (id) => log.synced.push(id) } },
  }
  return { context, log }
}
const tick = () => new Promise((r) => setTimeout(r, 5))

test("setup registers /tasks; selecting a task with a session navigates", async () => {
  const calls = []
  const run = async (args) => {
    calls.push(args.join(" "))
    return JSON.stringify(SAMPLE)
  }
  const plugin = createTasksPlugin({ run })
  assert.equal(plugin.id, "agent-tasks.tui")
  const { context, log } = fakeContext()
  plugin.setup(context)
  const [layer] = log.layers
  const cmd = layer.commands[0]
  assert.equal(cmd.slash.name, "tasks")
  assert.equal(cmd.title, "Tasks")
  assert.equal(cmd.group, "agent-tasks")
  assert.equal(cmd.palette, true)
  assert.ok(cmd.bind)
  assert.deepEqual(layer.bindings, [cmd.id])

  cmd.run()
  await tick()
  assert.deepEqual(calls, ["ls --json"])
  const { o, res } = log.dialogs[0]
  assert.equal(o.options[0].category, "Waiting for you")
  assert.equal(o.actions.length, 2)
  // The dialog asks for the widest size and titles use the terminal width.
  assert.deepEqual(log.dialogSet, [{ size: "xlarge" }])
  assert.equal(formatTitle({ id: "T-1", status: "x", title: "a".repeat(140) }, 150).endsWith("…"), false)
  res(o.options.find((x) => x.value.id === "T-0104").value)
  await tick()
  assert.deepEqual(log.synced, ["ses_1"])
  assert.deepEqual(log.navigated, [{ type: "session", sessionID: "ses_1" }])
})

test("task without session toasts; CLI failure toasts; actions reopen with filters", async () => {
  const calls = []
  const run = async (args) => {
    calls.push(args.join(" "))
    return JSON.stringify(args[1] === "postponed" ? [T("T-0200", "postponed")] : SAMPLE)
  }
  const { context, log } = fakeContext()
  createTasksPlugin({ run }).setup(context)
  const cmd = log.layers[0].commands[0]
  cmd.run()
  await tick()
  const first = log.dialogs[0]
  first.o.actions[1].onTrigger() // include postponed
  await tick()
  assert.ok(calls.includes("ls postponed --json"))
  const second = log.dialogs[1]
  assert.ok(second.o.options.some((x) => x.value.id === "T-0200"))
  first.res(undefined) // superseded dialog resolves undefined: must be ignored
  second.o.actions[0].onTrigger() // waiting only
  await tick()
  const third = log.dialogs[2]
  assert.ok(third.o.options.every((x) => x.category === "Waiting for you"))
  third.res(third.o.options.find((x) => x.value.id === "T-0001").value)
  await tick()
  assert.equal(log.toasts.at(-1).message, noSessionMessage(T("T-0001", "blocked")))
  assert.equal(log.navigated.length, 0)

  const bad = fakeContext()
  createTasksPlugin({ run: async () => { throw new Error("task: store missing") } }).setup(bad.context)
  bad.log.layers[0].commands[0].run()
  await tick()
  assert.equal(bad.log.toasts[0].variant, "error")
  assert.match(bad.log.toasts[0].message, /store missing/)
  assert.equal(bad.log.dialogs.length, 0)
})
