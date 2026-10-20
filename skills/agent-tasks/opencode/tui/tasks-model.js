// Pure helpers for the /tasks dialog: JSON -> grouped, ordered select options.
// Keep free of OpenCode and node-process APIs so `node --test` can exercise it.

// Same set as WAITING_FOLDERS in skills/agent-tasks/lib/core.sh (by status name).
export const WAITING_STATUSES = ["brainstorming", "spec_review", "plan_review", "finishing", "blocked"]
const WORKING_STATUSES = ["exploring", "planning", "implementing"]
const QUEUED_STATUSES = ["ready", "approved"]

export const GROUPS = ["Waiting for you", "Agent working", "Queued", "Not merged", "Backlog", "Done", "Postponed", "Other"]

export function groupOf(status) {
  if (WAITING_STATUSES.includes(status)) return "Waiting for you"
  if (WORKING_STATUSES.includes(status)) return "Agent working"
  if (QUEUED_STATUSES.includes(status)) return "Queued"
  if (status === "unmerged") return "Not merged"
  if (status === "backlog") return "Backlog"
  if (status === "done") return "Done"
  if (status === "postponed") return "Postponed"
  return "Other"
}

/** Parse `task ls --json` output. Throws a readable Error on bad input. */
export function parseTasks(text) {
  let data
  try {
    data = JSON.parse(text)
  } catch (error) {
    throw new Error(`task ls returned invalid JSON: ${error.message}`)
  }
  if (!Array.isArray(data)) throw new Error("task ls returned unexpected JSON (expected an array)")
  return data.filter((t) => t && typeof t.id === "string")
}

function idNumber(id) {
  const n = Number.parseInt(String(id).replace(/\D+/g, ""), 10)
  return Number.isFinite(n) ? n : Number.MAX_SAFE_INTEGER
}

export function truncate(text, max) {
  const s = String(text ?? "").replace(/\s+/g, " ").trim()
  return s.length > max ? `${s.slice(0, max - 1)}…` : s
}

export function formatTitle(task, max = 90) {
  return `${task.id}  ${task.status}  ${truncate(task.title, max)}`
}

/**
 * Merge task lists (later lists do not override earlier ones), drop archived,
 * optionally keep only waiting tasks; order by group, then id.
 */
export function selectTasks(lists, { waitingOnly = false } = {}) {
  const seen = new Set()
  const out = []
  for (const list of lists) {
    for (const task of list) {
      if (seen.has(task.id)) continue
      seen.add(task.id)
      if (task.status === "archive" || task.folder === "archive") continue
      if (waitingOnly && !WAITING_STATUSES.includes(task.status)) continue
      out.push(task)
    }
  }
  out.sort(
    (a, b) => GROUPS.indexOf(groupOf(a.status)) - GROUPS.indexOf(groupOf(b.status)) || idNumber(a.id) - idNumber(b.id),
  )
  return nestChildren(out)
}

/** Within each group, put a task right after its parent (when the parent is in the same group). Stable otherwise. */
export function nestChildren(sorted) {
  const ids = new Map(sorted.map((t) => [t.id, t]))
  const nested = (t) => typeof t.parent === "string" && t.parent !== t.id && ids.has(t.parent) && groupOf(ids.get(t.parent).status) === groupOf(t.status)
  const kids = new Map()
  for (const t of sorted) {
    if (!nested(t)) continue
    if (!kids.has(t.parent)) kids.set(t.parent, [])
    kids.get(t.parent).push(t)
  }
  const out = []
  const placed = new Set()
  const place = (t) => {
    if (placed.has(t.id)) return
    placed.add(t.id)
    out.push(t)
    for (const c of kids.get(t.id) ?? []) place(c)
  }
  for (const t of sorted) if (!nested(t)) place(t)
  for (const t of sorted) place(t) // cycles: keep everything visible
  return out
}

export function isNested(task, tasks) {
  const parent = typeof task.parent === "string" ? tasks.find((t) => t.id === task.parent) : null
  return Boolean(parent) && parent.id !== task.id && groupOf(parent.status) === groupOf(task.status)
}

/** " [done/total]" for a task with children; done counts loaded children in 11_done/archive. */
export function progressSuffix(task, tasks) {
  const children = Array.isArray(task.children) ? task.children : []
  if (children.length === 0) return ""
  const done = children.filter((id) => {
    const c = tasks.find((t) => t.id === id)
    return c && (c.folder === "11_done" || c.folder === "archive")
  }).length
  return ` [${done}/${children.length}]`
}

export function toOption(task, { multiWorkspace = false, titleMax = 90, tasks = [] } = {}) {
  const parts = [task.project, multiWorkspace ? task.workspace : null].filter(Boolean)
  const description = parts.join(" · ")
  const blocked = Array.isArray(task.blocked_by) ? task.blocked_by : []
  const prefix = isNested(task, tasks) ? "  ↳ " : ""
  const wait = blocked.length ? ` · waits ${blocked.join(", ")}` : ""
  return {
    title: `${prefix}${formatTitle(task, titleMax)}${progressSuffix(task, tasks)}${wait}`,
    value: task,
    ...(description ? { description } : {}),
    category: groupOf(task.status),
  }
}

export function buildOptions(tasks, { titleMax = 90 } = {}) {
  const multiWorkspace = new Set(tasks.map((t) => t.workspace).filter(Boolean)).size > 1
  return tasks.map((task) => toOption(task, { multiWorkspace, titleMax, tasks }))
}

/** Search by id/title/project/workspace/status; every whitespace-separated word must match. Keeps the display order. */
export function searchOptions(query, options) {
  const words = String(query ?? "").toLowerCase().split(/\s+/).filter(Boolean)
  if (words.length === 0) return options
  return options.filter((option) => {
    const t = option.value
    const hay = [t.id, t.status, t.title, t.project, t.workspace, ...(Array.isArray(t.blocked_by) ? t.blocked_by : [])].filter(Boolean).join(" ").toLowerCase()
    return words.every((w) => hay.includes(w))
  })
}

export function noSessionMessage(task) {
  return `${task.id} has no session yet (status ${task.status})`
}
