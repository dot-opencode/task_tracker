# shellcheck shell=bash
# Auto-commit of the store with messages built from the staged diff.

# 0 when path is <ws>/<folder>/T-NNNN[-slug].md; sets TP_WS, TP_ID, TP_FOLDER.
parse_task_path() {
  local path="$1" ws rest folder file f
  TP_WS=""; TP_ID=""; TP_FOLDER=""
  case "$path" in */*/*) ;; *) return 1 ;; esac
  ws="${path%%/*}"; rest="${path#*/}"
  folder="${rest%%/*}"; file="${rest#*/}"
  case "$file" in */*) return 1 ;; esac
  case "$file" in T-[0-9]*.md) ;; *) return 1 ;; esac
  for f in $FOLDERS; do
    if [ "$f" = "$folder" ]; then
      TP_WS="$ws"; TP_FOLDER="$folder"; TP_ID="$(id_of_file "$file")"
      return 0
    fi
  done
  return 1
}

# 0 when the staged change of a task file only appends log-like lines.
staged_log_only() {
  local path="$1" line inhunk=0
  while IFS= read -r line; do
    case "$line" in
      @@*) inhunk=1; continue ;;
    esac
    [ "$inhunk" -eq 1 ] || continue
    case "$line" in
      "+- "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" "*) ;;
      "+  "*|"+"|"+## Log") ;;
      "\\"*) ;;
      *) return 1 ;;
    esac
  done <<< "$(git -C "$STORE" diff --cached -U0 --no-color -- "$path")"
  return 0
}

# Git's rename detection (-M, 50%) misses short tasks whose body changes a lot
# (e.g. `done --summary`), reporting a delete and an add. Pair them by task id
# and turn each pair into a synthetic rename line.
pair_task_moves() {
  awk -F'\t' '
    function key(p,   n, a, fn) {
      n = split(p, a, "/")
      if (n != 3) return ""
      fn = a[3]
      if (!match(fn, /^T-[0-9]+/)) return ""
      return a[1] "/" substr(fn, 3, RLENGTH - 2) + 0
    }
    { line[NR] = $0; st[NR] = substr($1, 1, 1); p1[NR] = $2
      if (st[NR] == "D") { k = key($2); if (k != "") dk[NR] = k }
      if (st[NR] == "A") { k = key($2); if (k != "") ak[NR] = k } }
    END {
      for (i = 1; i <= NR; i++) {
        if (!(i in dk)) continue
        for (j = 1; j <= NR; j++) {
          if ((j in ak) && !(j in used) && ak[j] == dk[i]) { used[j] = 1; mate[i] = j; break }
        }
      }
      for (i = 1; i <= NR; i++) {
        if (i in used) continue
        if (i in mate) print "R\t" p1[i] "\t" p1[mate[i]]
        else print line[i]
      }
    }'
}

commit_message() {
  local status p1 p2 ws desc rel n=0 ids="" m=0 entries="" code
  local TP_WS TP_ID TP_FOLDER old_folder old_id verb
  while IFS=$'\t' read -r status p1 p2; do
    [ -n "$status" ] || continue
    code="${status:0:1}"
    ws=""
    if [ -d "$STORE/${p1%%/*}/00_backlog" ] && [ "${p1#*/}" != "$p1" ]; then ws="${p1%%/*}"; fi
    desc=""
    case "$code" in
      R)
        if parse_task_path "$p1" && old_id="$TP_ID" && old_folder="$TP_FOLDER" \
           && parse_task_path "$p2" && [ "$TP_ID" = "$old_id" ]; then
          if [ "$old_folder" = "$TP_FOLDER" ]; then
            desc="$TP_ID edit"
          else
            desc="$TP_ID $old_folder → $TP_FOLDER"
          fi
          ids="$ids $TP_ID"
          ws="$TP_WS"
        else
          desc="rename $p1 → $p2"
        fi
        ;;
      A|M|D)
        if parse_task_path "$p1"; then
          ids="$ids $TP_ID"
          ws="$TP_WS"
          case "$code" in
            A) desc="$TP_ID new" ;;
            D) desc="$TP_ID deleted" ;;
            *) if staged_log_only "$p1"; then desc="$TP_ID log"; else desc="$TP_ID edit"; fi ;;
          esac
        else
          rel="${p1#*/}"
          case "$rel" in
            .projects/*)
              verb="updated"
              if [ "$code" = "A" ]; then verb="added"; fi
              if [ "$code" = "D" ]; then verb="removed"; fi
              desc="project ${rel#.projects/} $verb"
              ;;
            *)
              case "$code" in
                A) desc="add $p1" ;;
                D) desc="delete $p1" ;;
                *) desc="update $p1" ;;
              esac
              ;;
          esac
        fi
        ;;
      *) desc="update $p1" ;;
    esac
    n=$((n + 1))
    entries="$entries$ws"$'\037'"$desc"$'\n'
  done <<< "$(git -C "$STORE" -c core.quotepath=false diff --cached --name-status -M | pair_task_moves)"

  if [ "$n" -eq 1 ]; then
    ws="${entries%%$'\037'*}"; desc="${entries#*$'\037'}"; desc="${desc%$'\n'}"
    if [ -n "$ws" ]; then printf 'tasks(%s): %s\n' "$ws" "$desc"; else printf 'tasks: %s\n' "$desc"; fi
    return 0
  fi
  m="$(printf '%s\n' "$ids" | tr ' ' '\n' | awk 'NF && !s[$0]++ { n++ } END { print n + 0 }')"
  if [ "$m" -eq 0 ]; then
    printf 'tasks: %s changes\n\n' "$n"
  elif [ "$m" -eq 1 ]; then
    printf 'tasks: %s changes in 1 task\n\n' "$n"
  else
    printf 'tasks: %s changes in %s tasks\n\n' "$n" "$m"
  fi
  while IFS=$'\037' read -r ws desc; do
    if [ -n "$ws" ] || [ -n "$desc" ]; then
      if [ -n "$ws" ]; then printf -- '- %s: %s\n' "$ws" "$desc"; else printf -- '- %s\n' "$desc"; fi
    fi
  done <<< "${entries%$'\n'}"
}

# Commits everything that changed, including manual edits. 1 = nothing to commit.
store_commit() {
  local msg rc=0
  git -C "$STORE" add -A || die "git add failed in $STORE"
  git -C "$STORE" diff --cached --quiet || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 1
  elif [ "$rc" -ne 1 ]; then
    die "git diff failed in $STORE (exit $rc)"
  fi
  msg="$(commit_message)"
  git -C "$STORE" commit -q -m "$msg" \
    || die "commit failed in $STORE — is git user.name / user.email configured?"
}

cmd_backup() {
  [ $# -eq 0 ] || die "usage: task backup"
  lock_acquire
  if store_commit; then echo "backed up"; else echo "nothing to back up"; fi
}
