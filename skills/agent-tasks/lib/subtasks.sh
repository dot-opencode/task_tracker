# shellcheck shell=bash
# Subtasks (`parent`) and dependencies (`depends_on`).
#
# st_load scans every task file once into ST_INDEX, one line per task:
#   id <TAB> folder <TAB> parent <TAB> depends_on (space-separated) <TAB> workspace <TAB> path relative to the store
# The helpers below read that index; call st_load again after files moved.

ST_INDEX=""

st_load() {
  local f
  local -a files=()
  ST_INDEX=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    files+=("$f")
  done <<< "$(all_task_files)"
  [ "${#files[@]}" -gt 0 ] || return 0
  ST_INDEX="$(awk -v store="$STORE/" '
    function nid(s,   t) {
      t = s
      gsub(/^["[:space:]]+/, "", t); gsub(/["[:space:]]+$/, "", t)
      if (t ~ /^[Tt]-[0-9]+$/) t = substr(t, 3)
      if (t ~ /^[0-9]+$/) return sprintf("T-%04d", t + 0)
      return t
    }
    function ids(s,   a, n, i, out) {
      gsub(/,/, " ", s)
      n = split(s, a, " "); out = ""
      for (i = 1; i <= n; i++) out = out (out == "" ? "" : " ") nid(a[i])
      return out
    }
    function flush() {
      if (cur != "") print id "\t" fol "\t" parent "\t" deps "\t" ws "\t" rel
    }
    FNR == 1 {
      flush(); cur = FILENAME
      n = split(FILENAME, p, "/"); fol = p[n - 1]; ws = p[n - 2]
      b = p[n]; sub(/^T-/, "", b); match(b, /^[0-9]+/)
      id = nid("T-" substr(b, 1, RLENGTH)); parent = ""; deps = ""
      rel = FILENAME; if (index(rel, store) == 1) rel = substr(rel, length(store) + 1)
      state = ($0 == "---") ? 1 : 0
      next
    }
    state == 1 {
      if ($0 == "---") { state = 2; next }
      if (index($0, "parent: ") == 1) parent = nid(substr($0, 9))
      else if (index($0, "depends_on: ") == 1) deps = ids(substr($0, 13))
    }
    END { flush() }
  ' "${files[@]}")"
}

# Normalized unique ids, one per line, from a comma/space separated list.
st_parse_ids() {
  local raw="${1//,/ }" t n out=""
  for t in $raw; do
    n="$(normalize_id "$t")" || die "invalid task id '$t'"
    case " $out " in *" $n "*) continue ;; esac
    out="$out $n"
  done
  for n in $out; do printf '%s\n' "$n"; done
}

st_folder() { awk -F'\t' -v id="$1" '$1 == id { print $2; exit }' <<< "$ST_INDEX"; }
st_parent_of() { awk -F'\t' -v id="$1" '$1 == id { print $3; exit }' <<< "$ST_INDEX"; }
st_deps_of() { awk -F'\t' -v id="$1" '$1 == id { print $4; exit }' <<< "$ST_INDEX"; }
st_children() { awk -F'\t' -v id="$1" '$3 == id { print $1 }' <<< "$ST_INDEX"; }

# Children that are not yet in 11_done/archive.
st_open_children() {
  awk -F'\t' -v id="$1" '$3 == id && $2 != "11_done" && $2 != "archive" { print $1 }' <<< "$ST_INDEX"
}

# depends_on ids whose task is not in 10_unmerged/11_done/archive (a missing task blocks).
st_blocked_by() {
  awk -F'\t' -v id="$1" '
    { fol[$1] = $2; if ($1 == id) deps = $4 }
    END {
      n = split(deps, d, " ")
      for (i = 1; i <= n; i++) {
        f = fol[d[i]]
        if (f != "10_unmerged" && f != "11_done" && f != "archive") print d[i]
      }
    }' <<< "$ST_INDEX"
}

# 0 when the folder is one a parent may not enter while subtasks are open.
st_parent_wait_folder() { case "$1" in 09_finishing|10_unmerged|11_done) return 0 ;; esac; return 1; }

# Open children of <id> on one line ("T-0084 T-0085"); empty when none.
st_open_list() {
  st_load
  st_open_children "$1" | tr '\n' ' ' | sed 's/ $//'
}

# Dies when the task has open subtasks.
st_guard_open() {   # st_guard_open <id>
  local open
  open="$(st_open_list "$1")"
  [ -z "$open" ] || die "$1 has open subtasks: $open (use --force)"
}

# 0 when from can reach target through depends_on edges.
st_depends_reach() {   # st_depends_reach <from> <target>
  local stack="$1" seen=" " n
  while [ -n "$stack" ]; do
    n="${stack%% *}"
    if [ "$stack" = "$n" ]; then stack=""; else stack="${stack#* }"; fi
    stack="$(trim "$stack")"
    [ -n "$n" ] || continue
    [ "$n" != "$2" ] || return 0
    case "$seen" in *" $n "*) continue ;; esac
    seen="$seen$n "
    stack="$(trim "$stack $(st_deps_of "$n")")"
  done
  return 1
}

st_validate_parent() {   # st_validate_parent <id> <file> <parent-id>
  local id="$1" f="$2" p="$3" pf x steps=0
  [ "$p" != "$id" ] || die "$id cannot be its own parent"
  pf="$(task_file "$p")"
  [ "$(ws_of_file "$pf")" = "$(ws_of_file "$f")" ] || die "parent $p is in another workspace"
  st_load
  x="$p"
  while [ -n "$x" ] && [ "$steps" -le 10000 ]; do
    [ "$x" != "$id" ] || die "parent cycle: $p is below $id"
    x="$(st_parent_of "$x")"
    steps=$((steps + 1))
  done
}

st_validate_depends() {   # st_validate_depends <id> <ids, one per line>
  local id="$1" d
  st_load
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ "$d" != "$id" ] || die "$id cannot depend on itself"
    task_file "$d" >/dev/null
    if st_depends_reach "$d" "$id"; then die "dependency cycle: $d already depends on $id"; fi
  done <<< "$2"
}

# Closes the parent <id> when every child is in 11_done/archive. Needs the lock.
# Returns 1 when it did not close anything.
st_try_close() {
  local id="$1" folder kids pf list
  st_load
  folder="$(st_folder "$id")"
  case "$folder" in ''|postponed|11_done|archive) return 1 ;; esac
  kids="$(st_children "$id")"
  [ -n "$kids" ] || return 1
  [ -z "$(st_open_children "$id")" ] || return 1
  pf="$(task_file "$id")"
  list="$(printf '%s' "$kids" | tr '\n' ' ' | sed 's/ $//; s/ /, /g')"
  move_task "$pf" 11_done task "all subtasks done" subtasks
  pf="$(task_file "$id")"
  fm_set "$pf" result subtasks || die "cannot update $pf"
  result_append "$pf" "All subtasks done: $list" || die "cannot update $pf"
}

# A task just landed in 11_done or archive: close its parent when that was the last open child.
st_autoclose() {   # st_autoclose <file>
  local parent
  st_load
  parent="$(st_parent_of "$(id_of_file "$1")")"
  [ -n "$parent" ] || return 0
  st_try_close "$parent" || true
}

# Parents (one id per line) that should be closed: all children done, parent still open.
st_closable() {
  awk -F'\t' '
    { fol[$1] = $2; if ($3 != "") { tot[$3]++; if ($2 == "11_done" || $2 == "archive") dn[$3]++ } }
    END {
      for (id in tot)
        if (id in fol && tot[id] == dn[id] && fol[id] != "postponed" && fol[id] != "11_done" && fol[id] != "archive") print id
    }' <<< "$ST_INDEX" | LC_ALL=C sort
}

# Problems found in parent/depends_on links, as "<rel path><TAB><message>".
st_problems() {
  awk -F'\t' '
    function dfs(node, target,   a, n, i) {
      if (node == target) return 1
      if (node in vis) return 0
      vis[node] = 1
      n = split(dep[node], a, " ")
      for (i = 1; i <= n; i++) if (dfs(a[i], target)) return 1
      return 0
    }
    { fol[$1] = $2; par[$1] = $3; dep[$1] = $4; ws[$1] = $5; rel[$1] = $6; ids[++cnt] = $1 }
    END {
      for (k = 1; k <= cnt; k++) {
        id = ids[k]; p = par[id]
        if (p != "") {
          if (p == id) print rel[id] "\tparent is the task itself"
          else if (!(p in fol)) print rel[id] "\tparent " p " does not exist"
          else {
            if (ws[p] != ws[id]) print rel[id] "\tparent " p " is in another workspace"
            x = p; steps = 0
            while (x != "" && steps <= cnt) {
              if (x == id) { print rel[id] "\tparent cycle through " p; break }
              x = par[x]; steps++
            }
          }
        }
        nd = split(dep[id], d, " ")
        for (j = 1; j <= nd; j++) {
          if (d[j] == id) { print rel[id] "\tdepends_on itself"; continue }
          if (!(d[j] in fol)) { print rel[id] "\tdepends_on " d[j] " does not exist"; continue }
          split("", vis)
          # reach id from the dependency (starting at its own deps)
          if (dfs(d[j], id)) print rel[id] "\tdependency cycle through " d[j]
        }
      }
    }' <<< "$ST_INDEX"
}

# Closes every parent whose children are all done (hand-moved files). Cheap and
# lock-free when nothing is due; commits once otherwise.
st_sweep() {
  local took=0 id n=0 list
  st_load
  [ -n "$(st_closable)" ] || return 0
  if [ "$LOCK_HELD" -eq 0 ]; then took=1; fi
  lock_acquire
  while :; do
    st_load
    list="$(st_closable)"
    [ -n "$list" ] || break
    id="${list%%$'\n'*}"
    st_try_close "$id" || break
    n=$((n + 1))
  done
  if [ "$n" -gt 0 ]; then store_commit || true; echo "closed $n parent task(s): all subtasks done"; fi
  if [ "$took" -eq 1 ]; then lock_release; fi
}

# Eligible start candidates: oldest task of the folders without blocked_by.
oldest_unblocked_in() {   # oldest_unblocked_in <folder>...
  local f id
  st_load
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    id="$(id_of_file "$f")"
    if [ -z "$(st_blocked_by "$id")" ]; then printf '%s\n' "$f"; return 0; fi
  done <<< "$(oldest_tasks_in "$@")"
  return 0
}
