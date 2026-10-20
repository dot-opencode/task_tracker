# shellcheck shell=bash
# Read-only consistency checks of the store.

# Gregorian calendar validation of YYYY-MM-DD with integer arithmetic only.
valid_calendar_date() {
  local date="$1" year month day rest y d max
  case "$date" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  year="${date%%-*}"; rest="${date#*-}"; month="${rest%%-*}"; day="${rest#*-}"
  d=$((10#$day))
  case "$month" in
    01|03|05|07|08|10|12) max=31 ;;
    04|06|09|11) max=30 ;;
    02)
      y=$((10#$year))
      if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then max=29; else max=28; fi
      ;;
    *) return 1 ;;
  esac
  [ "$d" -ge 1 ] && [ "$d" -le "$max" ]
}

# Structure of one task file. Prints "P<TAB>problem", "F<TAB>key<TAB>value"
# for every known frontmatter key, or "S" when there is no frontmatter at all.
doctor_scan() {
  DOC_KEYS="id title project created source session spec plan pr blocked_from postponed_from result worktree legacy_id parent depends_on" awk '
    function unq(v,   out, i, c, n) {
      if (length(v) >= 2 && substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") {
        v = substr(v, 2, length(v) - 2); out = ""; n = length(v)
        for (i = 1; i <= n; i++) {
          c = substr(v, i, 1)
          if (c == "\\" && i < n) { i++; c = substr(v, i, 1) }
          out = out c
        }
        return out
      }
      return v
    }
    BEGIN {
      n = split(ENVIRON["DOC_KEYS"], arr, " ")
      for (i = 1; i <= n; i++) known[arr[i]] = 1
    }
    $0 == "## Log" { haslog = 1 }
    NR == 1 {
      if ($0 != "---") { print "P\tno frontmatter"; print "S"; state = 2; nofm = 1 } else state = 1
      next
    }
    state == 1 {
      if ($0 == "---") { state = 2; closed = 1; next }
      if ($0 ~ /^[a-z_][a-z_]*:/) {
        p = index($0, ":")
        after = substr($0, p + 1, 1)
        if (after != "" && after != " ") { print "P\tbad frontmatter line \047" $0 "\047"; next }
        k = substr($0, 1, p - 1)
        v = substr($0, p + 2)
        if (k in seen) print "P\tduplicate key \047" k "\047"
        seen[k] = 1
        if (!(k in known)) print "P\tunknown key \047" k "\047"
        else {
          # a tab would shift the columns of task_rows
          if (k == "title" && index(v, "\t") > 0) print "P\ttitle contains a tab"
          print "F\t" k "\t" unq(v)
        }
      } else {
        print "P\tbad frontmatter line \047" $0 "\047"
      }
    }
    END {
      if (!nofm && !closed) print "P\tfrontmatter not closed"
      if (!haslog) print "P\tno ## Log section"
    }
  ' "$1"
}

cmd_doctor() {
  [ $# -eq 0 ] || die "usage: task doctor"
  local problems="" count=0 ntasks=0 nproj=0 idlist="" f rel ws folder out tag a b skip
  local f_id f_title f_project f_created f_session f_result f_blocked f_postponed fid ws_p name p dups line
  add_problem() { problems="$problems$1: $2"$'\n'; count=$((count + 1)); }

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    ntasks=$((ntasks + 1))
    rel="${f#"$STORE"/}"
    ws="$(ws_of_file "$f")"
    folder="$(folder_of_file "$f")"
    fid="$(id_of_file "$f")"
    idlist="$idlist$fid"$'\t'"$rel"$'\n'
    f_id=""; f_title=""; f_project=""; f_created=""; f_session=""; f_result=""; f_blocked=""; f_postponed=""
    skip=0
    out="$(doctor_scan "$f")"
    while IFS=$'\t' read -r tag a b; do
      case "$tag" in
        P) add_problem "$rel" "$a" ;;
        S) skip=1 ;;
        F)
          case "$a" in
            id) f_id="$b" ;;
            title) f_title="$b" ;;
            project) f_project="$b" ;;
            created) f_created="$b" ;;
            session) f_session="$b" ;;
            result) f_result="$b" ;;
            blocked_from) f_blocked="$b" ;;
            postponed_from) f_postponed="$b" ;;
          esac ;;
      esac
    done <<< "$out"
    [ "$skip" -eq 0 ] || continue

    if [ "$f_id" != "$fid" ]; then add_problem "$rel" "id '$f_id' does not match file name"; fi
    if [ -z "$f_title" ]; then add_problem "$rel" "empty title"; fi
    if ! valid_calendar_date "$f_created"; then add_problem "$rel" "invalid created date '$f_created'"; fi
    if [ -n "$f_result" ] && [ "$f_result" != "subtasks" ] && ! valid_result "$f_result"; then add_problem "$rel" "invalid result '$f_result'"; fi
    if [ "$folder" = "10_unmerged" ]; then
      case "$f_result" in pr|kept) ;; *) add_problem "$rel" "in 10_unmerged with result '${f_result:-none}' (expected pr or kept)" ;; esac
    fi
    if [ -n "$f_project" ]; then
      if ! valid_project "$f_project"; then
        add_problem "$rel" "invalid project name '$f_project'"
      elif [ ! -f "$STORE/$ws/.projects/$f_project" ]; then
        add_problem "$rel" "unknown project '$f_project'"
      fi
    fi
    if [ -n "$f_session" ] && ! valid_session "$f_session"; then
      add_problem "$rel" "invalid session id '$f_session'"
    fi
    if [ "$folder" = "blocked" ] && [ -z "$f_blocked" ]; then add_problem "$rel" "in blocked without blocked_from"; fi
    if [ "$folder" != "blocked" ] && [ -n "$f_blocked" ]; then add_problem "$rel" "blocked_from outside blocked"; fi
    if [ -n "$f_blocked" ]; then
      case " $FOLDERS " in
        *" $f_blocked "*) if [ "$f_blocked" = "blocked" ]; then add_problem "$rel" "invalid blocked_from '$f_blocked'"; fi ;;
        *) add_problem "$rel" "invalid blocked_from '$f_blocked'" ;;
      esac
    fi
    if [ "$folder" = "postponed" ] && [ -z "$f_postponed" ]; then add_problem "$rel" "in postponed without postponed_from"; fi
    if [ "$folder" != "postponed" ] && [ -n "$f_postponed" ]; then add_problem "$rel" "postponed_from outside postponed"; fi
    if [ -n "$f_postponed" ]; then
      case " $FOLDERS " in
        *" $f_postponed "*) if [ "$f_postponed" = "postponed" ]; then add_problem "$rel" "invalid postponed_from '$f_postponed'"; fi ;;
        *) add_problem "$rel" "invalid postponed_from '$f_postponed'" ;;
      esac
    fi
    case "$folder" in
      02_exploring|05_planning|08_implementing)
        if [ -z "$f_session" ]; then add_problem "$rel" "in $folder without session"; fi ;;
    esac
  done <<< "$(all_task_files)"

  # Stable sort keeps folder order, so the first file of an id is the "also" one.
  dups="$(printf '%s' "$idlist" | LC_ALL=C sort -t $'\t' -k1,1 -s \
    | awk -F'\t' '$1 == prev { print $2 "\t" $1 "\t" first; next } { prev = $1; first = $2 }')"
  if [ -n "$dups" ]; then
    while IFS=$'\t' read -r rel a b; do
      add_problem "$rel" "duplicate id $a (also $b)"
    done <<< "$dups"
  fi

  for ws_p in $(list_workspaces); do
    for f in "$STORE/$ws_p/.projects"/*; do
      [ -f "$f" ] || continue
      nproj=$((nproj + 1))
      name="$(basename "$f")"
      p="$(project_path "$ws_p" "$name")"
      if [ ! -d "$p" ]; then add_problem "$ws_p/.projects/$name" "path does not exist: $p"; fi
    done
  done

  st_load
  while IFS=$'\t' read -r rel a; do
    [ -n "$rel" ] || continue
    add_problem "$rel" "$a"
  done <<< "$(st_problems)"

  p="$(config_get preset "")"
  if [ -n "$p" ] && ! preset_model_ref "$p" >/dev/null; then
    add_problem "config.toml" "preset '$p' not found in $(slim_config_file)"
  fi

  if [ "$count" -gt 0 ]; then
    printf '%s' "$problems"
    echo "$count problem(s)"
    return 1
  fi
  line="ok: $ntasks task"; if [ "$ntasks" -ne 1 ]; then line="${line}s"; fi
  line="$line, $nproj project"; if [ "$nproj" -ne 1 ]; then line="${line}s"; fi
  echo "$line"
}
