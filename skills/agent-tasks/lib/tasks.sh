# shellcheck shell=bash
# Creating and reading tasks.

# ASCII words of the title joined by '-', at most 50 characters.
slugify() {
  local words w out=""
  # shellcheck disable=SC2018,SC2019 # ASCII-only on purpose (LC_ALL=C)
  words="$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z0-9' ' ')"
  for w in $words; do
    if [ -z "$out" ]; then
      out="${w:0:50}"
    elif [ $((${#out} + 1 + ${#w})) -le 50 ]; then
      out="$out-$w"
    else
      break
    fi
  done
  printf '%s\n' "$out"
}

valid_slug() { [ "${#1}" -le 50 ] && [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }

cmd_new() {
  local title="" project="" ws_opt="" source="" slug="" body="" have_body=0 ready=0
  local parent="" depends="" pf pid
  local ws det folder id n slug_part tmp dest dir opts=1 d
  while [ $# -gt 0 ]; do
    if [ "$opts" -eq 1 ] && [ "$1" = "--" ]; then opts=0; shift; continue; fi
    case "$1" in
      -?*) if [ "$opts" -eq 0 ]; then
          [ -z "$title" ] || die "usage: task new <title> [options] (quote the title)"
          title="$1"; shift; continue
        fi ;;
    esac
    case "$1" in
      --project) need_value "$@"; project="$2"; shift 2 ;;
      --ws) need_value "$@"; ws_opt="$2"; shift 2 ;;
      --source) need_value "$@"; source="$2"; shift 2 ;;
      --slug) need_value "$@"; slug="$2"; shift 2 ;;
      --body) need_value "$@"; body="$2"; have_body=1; shift 2 ;;
      --ready) ready=1; shift ;;
      --parent) need_value "$@"; parent="$2"; shift 2 ;;
      --depends) need_value "$@"; depends="$depends $2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *)
        [ -z "$title" ] || die "usage: task new <title> [options] (quote the title)"
        title="$1"; shift ;;
    esac
  done
  title="$(trim "$title")"
  [ -n "$title" ] || die "usage: task new <title> [--project P] [--ws W] [--source URL] [--slug S] [--body TEXT|-] [--ready] [--parent ID] [--depends ID,...]"
  single_line "$title" || die "title must be a single line"
  if [ -n "$ws_opt" ]; then valid_ws "$ws_opt" || die "invalid workspace '$ws_opt'"; fi
  # A registered project implies its workspace; without one --ws must name an existing workspace.
  if [ -n "$ws_opt" ] && [ -z "$project" ]; then require_workspace "$ws_opt"; fi
  if [ -n "$source" ]; then single_line "$source" || die "source must be a single line"; fi
  if [ "$have_body" -eq 1 ]; then
    body="$(read_text_arg "$body")"
    reject_sections body "$body"
  fi
  if [ -n "$slug" ]; then
    valid_slug "$slug" || die "invalid slug '$slug' (lowercase letters, digits, hyphens; at most 50 characters)"
  else
    slug="$(slugify "$title")"
  fi

  pid=""
  if [ -n "$parent" ]; then
    pid="$(normalize_id "$parent")" || die "invalid task id '$parent'"
    pf="$(task_file "$pid")"
  fi
  if [ -n "$project" ]; then
    valid_project "$project" || die "invalid project name '$project'"
    ws="$(project_ws "$project" "$ws_opt")"
  elif [ -n "$pid" ]; then
    ws="$(ws_of_file "$pf")"
    if [ -n "$ws_opt" ] && [ "$ws_opt" != "$ws" ]; then die "parent $pid is in workspace $ws, not $ws_opt"; fi
    project="$(fm_get "$pf" project)"
  else
    det="$(detect_project "$ws_opt")"
    if [ -n "$det" ]; then
      ws="${det%% *}"; project="${det#* }"
    else
      ws="$ws_opt"
      if [ -z "$ws" ]; then ws="$(config_get default_workspace work)"; fi
    fi
  fi
  if [ -n "$pid" ] && [ "$ws" != "$(ws_of_file "$pf")" ]; then die "parent $pid is in another workspace"; fi
  depends="$(st_parse_ids "$depends" | tr '\n' ' ')"
  depends="$(trim "$depends")"
  for d in $depends; do task_file "$d" >/dev/null; done
  folder="00_backlog"
  if [ "$ready" -eq 1 ]; then folder="01_ready"; fi

  lock_acquire
  ensure_workspace "$ws"
  n="$(next_id)"
  id="$(printf 'T-%04d' "$n")"
  slug_part=""
  if [ -n "$slug" ]; then slug_part="-$slug"; fi
  dir="$STORE/$ws/$folder"
  tmp="$dir/.$id.$$.tmp"
  dest="$dir/$id$slug_part.md"
  {
    printf -- '---\nid: %s\ntitle: %s\n' "$id" "$(fm_quote_always "$title")"
    if [ -n "$project" ]; then printf 'project: %s\n' "$(fm_quote "$project")"; fi
    printf 'created: %s\n' "$(date +%Y-%m-%d)"
    if [ -n "$source" ]; then printf 'source: %s\n' "$(fm_quote "$source")"; fi
    if [ -n "$pid" ]; then printf 'parent: %s\n' "$pid"; fi
    if [ -n "$depends" ]; then printf 'depends_on: %s\n' "$depends"; fi
    printf -- '---\n\n'
    if [ -n "$body" ]; then printf '%s\n' "$body"; fi
  } > "$tmp"
  log_append "$tmp" task "created in $folder"
  mv "$tmp" "$dest"
  store_commit || true
  echo "$id"
}

cmd_show() {
  [ $# -eq 1 ] || die "usage: task show <id>"
  local f
  local kids k kf
  f="$(task_file "$1")"
  cat "$f"
  st_load
  kids="$(st_children "$(id_of_file "$f")")"
  if [ -n "$kids" ]; then
    echo
    echo "## Subtasks"
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      kf="$(task_file "$k")"
      echo "subtasks: $k $(folder_of_file "$kf") $(fm_get "$kf" title)"
    done <<< "$kids"
  fi
}

cmd_path() {
  [ $# -eq 1 ] || die "usage: task path <id>"
  local f
  f="$(task_file "$1")"
  printf '%s\n' "$f"
}

cmd_ls() {
  local mode="default" folder="" ws="" json=0 parent="" f rel w rest fo keep arch_n=0 post_n=0 row recs="" rows tid
  while [ $# -gt 0 ]; do
    case "$1" in
      --waiting) mode="waiting"; shift ;;
      --all) mode="all"; shift ;;
      --json) json=1; shift ;;
      --ws) need_value "$@"; ws="$2"; shift 2 ;;
      --parent) need_value "$@"; parent="$(normalize_id "$2")" || die "invalid task id '$2'"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *)
        [ -z "$folder" ] || die "usage: task ls [<folder>|--waiting|--all] [--ws W] [--parent ID] [--json]"
        folder="$(resolve_folder "$1")" || die "unknown folder '$1' (folders: $FOLDERS)"
        mode="folder"; shift ;;
    esac
  done

  if [ -n "$ws" ]; then valid_ws "$ws" || die "invalid workspace '$ws'"; require_workspace "$ws"; fi
  if declare -F archive_due >/dev/null; then archive_due >&2; fi
  if declare -F mr_check_due >/dev/null; then mr_check_due >&2 || true; fi
  st_load
  if [ -n "$parent" ]; then task_file "$parent" >/dev/null; fi
  set --
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -n "$parent" ] && [ "$(st_parent_of "$(id_of_file "$f")")" != "$parent" ]; then continue; fi
    rel="${f#"$STORE"/}"; w="${rel%%/*}"; rest="${rel#*/}"; fo="${rest%%/*}"
    if [ -n "$ws" ] && [ "$w" != "$ws" ]; then continue; fi
    keep=0
    case "$mode" in
      all) keep=1 ;;
      folder) if [ "$fo" = "$folder" ]; then keep=1; fi ;;
      waiting) case " $WAITING_FOLDERS " in *" $fo "*) keep=1 ;; esac ;;
      *)
        # Everything that is not archived, done included.
        if [ "$fo" = "archive" ]; then arch_n=$((arch_n + 1))
        elif [ "$fo" = "postponed" ]; then post_n=$((post_n + 1))
        else keep=1; fi ;;
    esac
    if [ "$keep" -eq 1 ]; then set -- "$@" "$f"; fi
  done <<< "$(all_task_files)"

  rows=""
  if [ $# -gt 0 ]; then rows="$(task_rows "$@")"; fi
  if [ -n "$rows" ]; then
    while IFS= read -r row; do
      split_row "$row"
      tid="$(id_of_file "$R_PATH")"
      rel="${R_PATH#"$STORE"/}"; w="${rel%%/*}"; rest="${rel#*/}"; fo="${rest%%/*}"
      recs="$recs$w"$'\t'"$fo"$'\t'"$(id_of_file "$R_PATH")"$'\t'"$R_TITLE"$'\t'"$R_PROJECT"$'\t'"$R_CREATED"$'\t'"$R_SESSION"$'\t'"$R_PATH"$'\t'"$(folder_status "$fo")"$'\t'"$(st_parent_of "$tid")"$'\t'"$(st_deps_of "$tid")"$'\t'"$(st_blocked_by "$tid" | tr '\n' ' ')"$'\t'"$(st_children "$tid" | tr '\n' ' ')"$'\t'"$(st_done_count "$tid")"$'\n'
    done <<< "$rows"
  fi

  if [ "$json" -eq 1 ]; then
    printf '%s' "$recs" | jq -R -s '
      split("\n") | map(select(length > 0)) | map(split("\t")) | map({
        id: .[2], title: .[3],
        project: (if .[4] == "" then null else .[4] end),
        workspace: .[0], folder: .[1], status: .[8], created: .[5],
        session: (if .[6] == "" then null else .[6] end),
        path: .[7],
        parent: (if .[9] == "" then null else .[9] end),
        depends_on: (.[10] | split(" ") | map(select(length > 0))),
        blocked_by: (.[11] | split(" ") | map(select(length > 0))),
        children: (.[12] | split(" ") | map(select(length > 0))) })'
    return 0
  fi
  if [ -z "$recs" ]; then
    echo "no tasks"
  else
    printf '%s' "$recs" | awk -F'\t' '
      function cell(s, w) { return sprintf("%-" w "s", s) "  " }
      function emit(i, depth,   k, c) {
        if (seen[i]) return
        seen[i] = 1; m++; ord[m] = i; dep[i] = depth
        for (k = 1; k <= nk[i]; k++) emit(kid[i, k], depth + 1)
      }
      { n++; ws[n] = $1; id[n] = $3; st[n] = $9; pr[n] = ($5 == "" ? "-" : $5)
        idx[$3] = n; par[n] = $10; blk[n] = $12; chl[n] = $13; dn[n] = $14
        if (n > 1 && $1 != ws[1]) multi = 1
        ti[n] = $4 }
      END {
        for (i = 1; i <= n; i++)
          if (par[i] != "" && (par[i] in idx) && idx[par[i]] != i) { p = idx[par[i]]; kid[p, ++nk[p]] = i }
        for (i = 1; i <= n; i++)
          if (!(par[i] != "" && (par[i] in idx) && idx[par[i]] != i)) emit(i, 0)
        for (i = 1; i <= n; i++) emit(i, 0)
        for (j = 1; j <= n; j++) {
          i = ord[j]
          if (dep[i] > 0) ti[i] = "↳ " ti[i]
          nc = split(chl[i], tmp, " ")
          if (nc > 0) ti[i] = ti[i] " [" dn[i] "/" nc "]"
          if (blk[i] != "") { sub(/ +$/, "", blk[i]); ti[i] = ti[i] " (waits " blk[i] ")" }
          if (length(ws[i]) > ww) ww = length(ws[i])
          if (length(id[i]) > wi) wi = length(id[i])
          if (length(st[i]) > ws_w) ws_w = length(st[i])
          if (length(pr[i]) > wp) wp = length(pr[i])
        }
        if (ww < 2) ww = 2
        if (wi < 2) wi = 2
        if (ws_w < 6) ws_w = 6
        if (wp < 7) wp = 7
        head = (multi ? cell("WS", ww) : "") cell("ID", wi) cell("STATUS", ws_w) cell("PROJECT", wp) "TITLE"
        print head
        for (j = 1; j <= n; j++) {
          i = ord[j]
          print (multi ? cell(ws[i], ww) : "") cell(id[i], wi) cell(st[i], ws_w) cell(pr[i], wp) ti[i]
        }
      }'
  fi
  if [ "$mode" = "default" ] && [ "$post_n" -gt 0 ]; then
    echo "postponed: $post_n (task ls postponed)"
  fi
  if [ "$mode" = "default" ] && [ "$arch_n" -gt 0 ]; then
    echo "archive: $arch_n (task ls archive)"
  fi
}

# Number of children of <id> in 11_done or archive.
st_done_count() {
  awk -F'\t' -v id="$1" '$3 == id && ($2 == "11_done" || $2 == "archive") { n++ } END { print n + 0 }' <<< "$ST_INDEX"
}
