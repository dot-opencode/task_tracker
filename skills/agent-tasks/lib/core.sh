# shellcheck shell=bash
# Store location, configuration, ids and folder names.

STORE="${AGENT_TASKS_HOME:-$HOME/.agent-tasks}"
case "$STORE" in
  /*) ;;
  *) STORE="$(pwd -P)/$STORE" ;;
esac
if [ "$STORE" != "/" ]; then STORE="${STORE%/}"; fi

FOLDERS="00_backlog 01_ready 02_exploring 03_brainstorming 04_spec_review 05_planning 06_plan_review 07_approved 08_implementing 09_finishing 10_unmerged 11_done blocked postponed archive"
# shellcheck disable=SC2034 # read by the later libs (ls --waiting)
WAITING_FOLDERS="03_brainstorming 04_spec_review 06_plan_review 09_finishing blocked"
# Folders where an agent is at work (max_active, stale check, doctor).
# shellcheck disable=SC2034 # read by the later libs
AGENT_FOLDERS="02_exploring 05_planning 08_implementing"
RESULTS="pr merged kept discarded cancelled"

warn() { echo "task: $*" >&2; }

# Call as `need_value "$@"` with the option in $1: dies when its value is missing.
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then die "$1 requires a value"; fi
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

single_line() {
  case "$1" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  return 0
}

# `-` reads stdin. Command substitution strips trailing newlines of stdin;
# an argument gets the same treatment so both behave alike.
read_text_arg() {
  local text="$1"
  if [ "$text" = "-" ]; then text="$(cat)"; fi
  while [ "${text%$'\n'}" != "$text" ]; do text="${text%$'\n'}"; done
  printf '%s' "$text"
}

valid_ws() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; }
valid_session() { [[ "$1" =~ ^ses[A-Za-z0-9_-]+$ ]]; }
valid_result() { case " $RESULTS " in *" $1 "*) return 0 ;; esac; return 1; }

# Flat `key = value` lines; `#` starts a comment, double quotes are dropped.
config_get() {
  local key="$1" default="$2" val=""
  if [ -f "$STORE/config.toml" ]; then
    val="$(CFG_KEY="$key" awk '
      {
        line = $0
        sub(/#.*/, "", line)
        eq = index(line, "=")
        if (eq == 0) next
        k = substr(line, 1, eq - 1)
        v = substr(line, eq + 1)
        sub(/^[ \t]+/, "", k); sub(/[ \t]+$/, "", k)
        sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
        if (k == ENVIRON["CFG_KEY"]) { gsub(/"/, "", v); val = v }
      }
      END { print val }
    ' "$STORE/config.toml")"
  fi
  if [ -n "$val" ]; then printf '%s\n' "$val"; else printf '%s\n' "$default"; fi
}

default_config() {
  cat <<'EOF'
default_workspace = "work"
max_active = 2           # automation limit for 02_exploring + 05_planning + 08_implementing
agent = ""               # empty: OpenCode default agent
model = ""               # empty: OpenCode default model; explicit provider/model, wins over preset
preset = ""              # oh-my-opencode-slim preset for task sessions; empty: OpenCode default model
quiet_minutes = 3        # no question alert if the user answered in this session recently
stale_minutes = 30       # a session in 2 or 6 without activity counts as stopped
mr_check_minutes = 10    # check MRs/PRs of unmerged tasks at most this often; 0 disables
archive_after_days = 14  # done tasks move to archive after this many days (also those archived in ai_task_tracker, at once); 0 disables all automatic archiving
EOF
}

slim_config_file() { printf '%s\n' "${AGENT_TASKS_SLIM_CONFIG:-$HOME/.config/opencode/oh-my-opencode-slim.json}"; }

# Model of a slim preset for the configured agent (default orchestrator), as the
# OpenCode model ref JSON {providerID, id[, variant]}. Fails when it cannot be read.
preset_model_ref() {   # preset_model_ref <preset>
  local file agent
  file="$(slim_config_file)"
  agent="$(config_get agent "")"
  [ -n "$agent" ] || agent=orchestrator
  [ -f "$file" ] || return 1
  jq -ce --arg p "$1" --arg a "$agent" '
    .presets[$p][$a].model as $m
    | (if ($m | type) == "array" then $m[0] else $m end) as $e
    | (if ($e | type) == "string" then {raw: $e}
       elif ($e | type) == "object" and ($e.id | type) == "string" then {raw: $e.id, variant: $e.variant}
       else empty end) as $x
    | select($x.raw | test("^[^/]+/.+"))
    | {providerID: ($x.raw | split("/")[0]), id: ($x.raw | split("/")[1:] | join("/"))}
      + (if ($x.variant | type) == "string" and $x.variant != "" then {variant: $x.variant} else {} end)
  ' "$file" 2>/dev/null
}

# Effective model for task sessions. Sets MODEL_REF (JSON, empty = OpenCode default)
# and MODEL_LABEL. Returns 1 when a configured preset does not resolve.
# shellcheck disable=SC2034 # MODEL_REF/MODEL_LABEL are read by callers
resolve_task_model() {
  local model preset ref
  MODEL_REF=""; MODEL_LABEL="OpenCode default"
  model="$(config_get model "")"
  preset="$(config_get preset "")"
  if [ -n "$model" ]; then
    MODEL_REF="$(jq -cn --arg m "$model" '{providerID: ($m | split("/")[0]), id: ($m | split("/")[1:] | join("/"))}')"
    MODEL_LABEL="$model (from config model)"
    return 0
  fi
  [ -n "$preset" ] || return 0
  ref="$(preset_model_ref "$preset")" || return 1
  MODEL_REF="$ref"
  MODEL_LABEL="$(jq -r '.providerID + "/" + .id + (if .variant then " (" + .variant + ")" else "" end)' <<< "$ref") from preset $preset"
}

default_gitignore() {
  printf '%s\n' .auto .lock/ .lock.steal/ .notify/ .obsidian/ .DS_Store '*.tmp'
}

ensure_workspace() {
  local ws="$1" f
  for f in $FOLDERS .projects; do
    if [ ! -d "$STORE/$ws/$f" ]; then mkdir -p "$STORE/$ws/$f"; fi
  done
}

list_workspaces() {
  local d
  for d in "$STORE"/*/; do
    [ -d "${d}00_backlog" ] || continue
    basename "${d%/}"
  done
}

# A workspace is born with `task project add --ws W`; elsewhere a typo must not create one.
require_workspace() {
  local ws="$1" list
  if [ -d "$STORE/$ws/00_backlog" ]; then return 0; fi
  list="$(list_workspaces | tr '\n' ' ')"
  die "unknown workspace '$ws' (existing: ${list% })"
}

ensure_store() {
  local fresh=0 took_lock=0 ws
  mkdir -p "$STORE"
  if [ ! -d "$STORE/.git" ]; then
    if [ "$LOCK_HELD" -eq 0 ]; then took_lock=1; fi
    lock_acquire
    if [ ! -d "$STORE/.git" ]; then fresh=1; fi
  fi
  if [ ! -f "$STORE/.gitignore" ]; then default_gitignore > "$STORE/.gitignore"; fi
  if [ ! -f "$STORE/config.toml" ]; then default_config > "$STORE/config.toml"; fi
  ws="$(config_get default_workspace work)"
  valid_ws "$ws" || die "invalid default_workspace '$ws' in $STORE/config.toml"
  ensure_workspace "$ws"
  if [ "$fresh" -eq 1 ]; then
    # .git appears last: a concurrent command that sees it finds a complete store.
    git -C "$STORE" -c advice.defaultBranchName=false init -q
    git -C "$STORE" add -A
    git -C "$STORE" commit -q -m "tasks: init store" \
      || die "commit failed in $STORE — is git user.name / user.email configured?"
  fi
  if [ "$took_lock" -eq 1 ]; then lock_release; fi
}

# T-0083, t-83, 83 and 0083 all name the same task.
normalize_id() {
  local raw="$1" n
  case "$raw" in
    T-*|t-*) n="${raw#??}" ;;
    *) n="$raw" ;;
  esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#n}" -le 9 ] || return 1
  n=$((10#$n))
  [ "$n" -gt 0 ] || return 1
  printf 'T-%04d\n' "$n"
}

id_of_file() {
  local b r
  b="$(basename "$1")"
  r="${b#T-}"
  printf 'T-%s\n' "${r%%[!0-9]*}"
}

ws_of_file() {
  local rel="${1#"$STORE"/}"
  printf '%s\n' "${rel%%/*}"
}

folder_of_file() {
  local rel="${1#"$STORE"/}"
  rel="${rel#*/}"
  printf '%s\n' "${rel%%/*}"
}

all_task_files() {
  local ws fo f
  for ws in $(list_workspaces); do
    for fo in $FOLDERS; do
      for f in "$STORE/$ws/$fo"/T-[0-9]*.md; do
        [ -e "$f" ] || continue
        printf '%s\n' "$f"
      done
    done
  done
}

task_file() {
  local id f b found="" other="" n=0
  id="$(normalize_id "$1")" || die "invalid task id '$1'"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in
      "$id.md"|"$id"-*.md)
        n=$((n + 1))
        if [ "$n" -eq 1 ]; then found="$f"; else other="$f"; fi
        ;;
    esac
  done <<< "$(all_task_files)"
  [ "$n" -gt 0 ] || die "no task $id"
  [ "$n" -eq 1 ] || die "duplicate task id $id: $found and $other (run 'task doctor')"
  printf '%s\n' "$found"
}

# Highest number in the whole store plus one; there is no separate counter.
next_id() {
  local max=0 f n
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n="$(id_of_file "$f")"
    n=$((10#${n#T-}))
    if [ "$n" -gt "$max" ]; then max="$n"; fi
  done <<< "$(all_task_files)"
  printf '%s\n' "$((max + 1))"
}

# Folder name without the numeric prefix: 00_backlog -> backlog, blocked -> blocked.
folder_status() { printf '%s\n' "${1#[0-9][0-9]_}"; }

# Exact name, number (3 or 03) or status name (spec_review, blocked).
resolve_folder() {
  local x="$1" f num xn=""
  case "$x" in ''|*[!0-9]*) ;; *) if [ "${#x}" -le 3 ]; then xn=$((10#$x)); fi ;; esac
  for f in $FOLDERS; do
    if [ "$x" = "$f" ] || [ "$x" = "$(folder_status "$f")" ]; then
      printf '%s\n' "$f"
      return 0
    fi
    num="${f%%_*}"
    case "$num" in
      [0-9][0-9]) if [ -n "$xn" ] && [ "$xn" -eq $((10#$num)) ]; then printf '%s\n' "$f"; return 0; fi ;;
    esac
  done
  return 1
}
