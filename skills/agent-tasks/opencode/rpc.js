// RPC contract of the agent-tasks OpenCode plugin: `POST /api/rpc/agent-tasks/<method>` with
// `{"input": {...}}`, or `client.rpc(AgentTasksRpc)` from @opencode/client.
// Plain data with no imports, so browsers, userscripts and other plugins can import it as is.

// OpenCode rejects `pattern` in RPC schemas; the handlers check formats (PATTERNS below).
const ID = { type: "string", minLength: 1 }
const WORKSPACE = { type: "string", minLength: 1 }
const FOLDER = { type: "string", minLength: 1 }
const LINE = { type: "string", minLength: 1 }
const NAME = { type: "string", minLength: 1 }

export const PATTERNS = {
  id: /^([Tt]-)?[0-9]{1,9}$/,
  workspace: /^[a-z0-9][a-z0-9_-]*$/,
  folder: /^[A-Za-z0-9_]+$/,
  // Values that must not be mistaken for CLI or git options.
  name: /^[^-\s]\S*$/,
  session: /^ses[A-Za-z0-9_-]+$/,
  duration: /^[0-9]+[smhd]([0-9]+[smhd])*$/,
}
const NULLABLE = { anyOf: [{ type: "string" }, { type: "null" }] }

export const SET_KEYS = ["title", "project", "source", "session", "spec", "plan", "pr", "result", "parent", "depends_on"]
export const UNSET_KEYS = ["project", "source", "session", "spec", "plan", "pr", "result", "worktree", "parent", "depends_on"]
export const RESULTS = ["pr", "merged", "kept", "discarded", "cancelled"]

const object = (properties, required = []) => ({ type: "object", properties, required, additionalProperties: false })
const TEXT = object({ text: { type: "string" } }, ["text"])
const ERRORS = {
  invalid_input: object({ field: { type: "string" } }, ["field"]),
  task_failed: object({ code: { type: "integer" }, stderr: { type: "string" }, stdout: { type: "string" } }, ["code", "stderr", "stdout"]),
}
const method = (input, output = TEXT) => ({ input, output, errors: ERRORS })

const TASK = object({
  id: { type: "string" },
  title: { type: "string" },
  project: NULLABLE,
  workspace: { type: "string" },
  folder: { type: "string" },
  status: { type: "string" },
  created: { type: "string" },
  session: NULLABLE,
  path: { type: "string" },
  parent: NULLABLE,
  depends_on: { type: "array", items: { type: "string" } },
  blocked_by: { type: "array", items: { type: "string" } },
  children: { type: "array", items: { type: "string" } },
}, ["id", "title", "project", "workspace", "folder", "status", "created", "session", "path"])

export const AgentTasksRpc = {
  id: "agent-tasks",
  methods: {
    list: method(
      object({ folder: FOLDER, waiting: { type: "boolean" }, all: { type: "boolean" }, workspace: WORKSPACE, parent: ID }),
      object({ tasks: { type: "array", items: TASK } }, ["tasks"]),
    ),
    show: method(
      object({ id: ID }, ["id"]),
      object({
        id: { type: "string" },
        folder: { type: "string" },
        status: { type: "string" },
        path: { type: "string" },
        fields: { type: "object", additionalProperties: { type: "string" } },
        body: { type: "string" },
        markdown: { type: "string" },
      }, ["id", "folder", "status", "path", "fields", "body", "markdown"]),
    ),
    logs: method(object({ id: ID, lines: { type: "integer", minimum: 1, maximum: 10000 } })),
    create: method(
      object({
        title: LINE, project: NAME, workspace: WORKSPACE, source: LINE, slug: NAME, body: { type: "string" },
        ready: { type: "boolean" }, parent: ID, dependsOn: { type: "array", items: ID },
      }, ["title"]),
      object({ id: { type: "string" } }, ["id"]),
    ),
    move: method(object({ id: ID, folder: FOLDER, reason: LINE, force: { type: "boolean" } }, ["id", "folder"])),
    log: method(object({ id: ID, message: LINE, author: NAME }, ["id", "message"])),
    set: method(object({ id: ID, key: { type: "string", enum: SET_KEYS }, value: { anyOf: [LINE, { type: "array", items: ID }] } }, ["id", "key", "value"])),
    unset: method(object({ id: ID, key: { type: "string", enum: UNSET_KEYS } }, ["id", "key"])),
    done: method(object({ id: ID, result: { type: "string", enum: RESULTS }, summary: { type: "string" }, force: { type: "boolean" } }, ["id", "result"])),
    merged: method(object({ id: ID, summary: { type: "string" }, force: { type: "boolean" } }, ["id"])),
    approve: method(
      object({ id: ID, now: { type: "boolean" } }, ["id"]),
      object({ result: { type: "string", enum: ["start", "deferred"] }, text: { type: "string" } }, ["result", "text"]),
    ),
    postpone: method(object({ id: ID, reason: LINE }, ["id"])),
    resume: method(object({ id: ID }, ["id"])),
    archive: method(object({ id: ID }, ["id"])),
    unarchive: method(object({ id: ID }, ["id"])),
    bind: method(object({ id: ID, sessionID: { type: "string", minLength: 1 } }, ["id", "sessionID"])),
    worktree: method(
      object({ id: ID, branch: NAME, base: NAME }, ["id"]),
      object({ directory: { type: "string" } }, ["directory"]),
    ),
    removeWorktree: method(object({ id: ID, force: { type: "boolean" } }, ["id"])),
    projects: method(
      object({ workspace: WORKSPACE }),
      object({
        projects: {
          type: "array",
          items: object({
            workspace: { type: "string" }, name: { type: "string" }, path: { type: "string" }, missing: { type: "boolean" },
          }, ["workspace", "name", "path", "missing"]),
        },
      }, ["projects"]),
    ),
    autoStatus: method(object({})),
    setAuto: method(object({ enabled: { type: "boolean" }, duration: { type: "string", minLength: 1 } }, ["enabled"])),
  },
  events: {
    // A task changed through this plugin (an RPC call or a session signal). Hand edits and other
    // CLI runs do not emit it; refetch with `list`/`show`.
    changed: { schema: object({ id: { type: "string" }, action: { type: "string" } }, ["action"]) },
  },
}
