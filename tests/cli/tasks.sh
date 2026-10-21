# shellcheck shell=bash
# Task 4: creating and reading tasks.

mkproj() {   # mkproj <name> [ws]  — registers $TMP/code/<name>
  mkdir -p "$TMP/code/$1"
  "$TASK" project add "$1" "$TMP/code/$1" --ws "${2:-work}" >/dev/null
}

test_tasks_new_exact_content() {
  mkproj api
  local id f
  id="$("$TASK" new "Fix internal service URL: port drift (ABC-6719)" --project api --source https://y.example/issue/1 --body "Some body")"
  assert_eq "$id" "T-0001"
  f="$AGENT_TASKS_HOME/work/00_backlog/T-0001-fix-internal-service-url-port-drift-abc-6719.md"
  assert_file "$f"
  local head
  head="$(sed -n '1,9p' "$f")"
  assert_eq "$head" "$(printf -- '---\nid: T-0001\ntitle: "Fix internal service URL: port drift (ABC-6719)"\nproject: api\ncreated: %s\nsource: https://y.example/issue/1\n---\n\nSome body\n' "$(date +%Y-%m-%d)")"
  assert_eq "$(sed -n '10,11p' "$f")" "$(printf '\n## Log')"
  case "$(sed -n '12p' "$f")" in
    "- "[0-9][0-9][0-9][0-9]"-"[0-9][0-9]"-"[0-9][0-9]" "[0-9][0-9]":"[0-9][0-9]" task: created in 00_backlog") ;;
    *) fail "bad log line: $(sed -n '12p' "$f")" ;;
  esac
  assert_eq "$(wc -l < "$f" | tr -d ' ')" 12
  assert_eq "$(last_subject)" "tasks(work): T-0001 new"
  assert_eq "$("$TASK" ls --json | jq -r '.[0].source')" "https://y.example/issue/1"
}

test_tasks_new_without_body_layout() {
  "$TASK" new "Plain" >/dev/null
  local f
  f="$(task_path_of T-0001)"
  assert_eq "$(sed -n '1,7p' "$f")" "$(printf -- '---\nid: T-0001\ntitle: "Plain"\ncreated: %s\n---\n\n## Log' "$(date +%Y-%m-%d)")"
}

test_tasks_new_numbering_continues_after_max() {
  write_task_file 11_done T-0007 "Old one"
  write_task_file 00_backlog T-0003 "Other"
  assert_eq "$("$TASK" new "Next")" "T-0008"
  mkdir -p "$AGENT_TASKS_HOME/home/00_backlog"
  write_task_file 01_ready T-0020 "Twenty"
  assert_eq "$("$TASK" new "After")" "T-0021"
}

test_tasks_title_quoting_round_trip() {
  "$TASK" new 'He said "hi" \ back' >/dev/null
  local f
  f="$(task_path_of T-0001)"
  assert_contains "$(cat "$f")" 'title: "He said \"hi\" \\ back"'
  assert_eq "$("$TASK" ls --json | jq -r '.[0].title')" 'He said "hi" \ back'
}

# test_tasks_fm_quote_rules: Rust unit test frontmatter::tests::quote_rules
# test_tasks_slug_rules: Rust unit test cmd::tasks::tests::slug_rules

test_tasks_new_slug_variants() {
  "$TASK" new "Исправить дрейф" >/dev/null
  assert_file "$AGENT_TASKS_HOME/work/00_backlog/T-0001.md"
  "$TASK" new "Anything" --slug custom-name >/dev/null
  assert_file "$AGENT_TASKS_HOME/work/00_backlog/T-0002-custom-name.md"
  local out rc=0
  out="$("$TASK" new "X" --slug 'Bad Slug' 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid slug"
  rc=0
  out="$("$TASK" new "X" --slug "$(printf 'a%.0s' $(seq 1 51))" 2>&1)" || rc=$?
  assert_eq "$rc" 1
}

test_tasks_new_ready_and_project_fields() {
  mkproj api
  "$TASK" new "Go" --project api --ready >/dev/null
  local f
  f="$(task_path_of T-0001)"
  assert_contains "$f" "/work/01_ready/"
  assert_contains "$(cat "$f")" "project: api"
  assert_contains "$(cat "$f")" "task: created in 01_ready"
}

test_tasks_new_body_from_stdin() {
  printf 'line one\n\nline three\n\n\n' | "$TASK" new "Piped" --body - >/dev/null
  local f
  f="$(task_path_of T-0001)"
  assert_eq "$(sed -n '6,9p' "$f")" "$(printf '\nline one\n\nline three')"
  assert_eq "$(sed -n '10,11p' "$f")" "$(printf '\n## Log')"
}

test_tasks_new_rejects_bad_input() {
  local out rc=0
  out="$("$TASK" new $'two\nlines' 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "single line"
  rc=0; out="$("$TASK" new "   " 2>&1)" || rc=$?
  assert_eq "$rc" 1
  rc=0; out="$("$TASK" new 2>&1)" || rc=$?
  assert_eq "$rc" 1
  rc=0; out="$("$TASK" new "T" --body $'a\n## Log\nb' 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "## Log"
  rc=0; out="$("$TASK" new "T" --project 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "--project requires a value"
  assert_eq "$(find "$AGENT_TASKS_HOME/work/00_backlog" -type f | wc -l | tr -d ' ')" 0
}

test_tasks_new_unknown_and_ambiguous_project() {
  local out rc=0
  out="$("$TASK" new "T" --project ghost 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown project 'ghost' (register it: task project add ghost <path>)"
  mkproj dup work
  mkproj dup home
  rc=0; out="$("$TASK" new "T" --project dup 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "project 'dup' is registered in workspaces: home work — pass --ws"
  assert_eq "$("$TASK" new "T" --project dup --ws home)" "T-0001"
  assert_contains "$(task_path_of T-0001)" "/home/00_backlog/"
}

test_tasks_new_detects_project_from_cwd_and_subdir() {
  mkproj api home
  mkdir -p "$TMP/code/api/src/deep"
  cd "$TMP/code/api/src/deep" || return 1
  "$TASK" new "Detected" >/dev/null
  local f
  f="$(task_path_of T-0001)"
  assert_contains "$f" "/home/00_backlog/"
  assert_contains "$(cat "$f")" "project: api"
}

test_tasks_detect_prefers_longest_prefix_and_boundary() {
  mkproj api
  mkdir -p "$TMP/code/api/sub" "$TMP/code/api-extra"
  "$TASK" project add sub "$TMP/code/api/sub" >/dev/null
  cd "$TMP/code/api/sub" || return 1
  "$TASK" new "Inner" >/dev/null
  assert_contains "$(cat "$(task_path_of T-0001)")" "project: sub"
  cd "$TMP/code/api-extra" || return 1
  "$TASK" new "Outside" >/dev/null
  case "$(cat "$(task_path_of T-0002)")" in *"project:"*) fail "api-extra matched api" ;; esac
}

test_tasks_detect_from_git_worktree() {
  mkdir -p "$TMP/code/repo"
  git -C "$TMP/code/repo" init -q
  git -C "$TMP/code/repo" commit -q --allow-empty -m init
  mkdir -p "$TMP/code/repo/pkg"
  "$TASK" project add repo "$TMP/code/repo" >/dev/null
  git -C "$TMP/code/repo" worktree add -q "$TMP/wt" -b feature
  cd "$TMP/wt" || return 1
  "$TASK" new "From worktree" >/dev/null
  assert_contains "$(cat "$(task_path_of T-0001)")" "project: repo"
}

test_tasks_new_no_project_uses_default_workspace() {
  "$TASK" new "Loose" >/dev/null
  assert_contains "$(task_path_of T-0001)" "/work/00_backlog/"
  case "$(cat "$(task_path_of T-0001)")" in *"project:"*) fail "unexpected project" ;; esac
  mkdir -p "$AGENT_TASKS_HOME/side/00_backlog"
  "$TASK" new "Elsewhere" --ws side >/dev/null
  assert_contains "$(task_path_of T-0002)" "/side/00_backlog/"
}

test_tasks_parallel_new() {
  export AGENT_TASKS_LOCK_TIMEOUT=30
  "$TASK" backup >/dev/null
  local i
  for i in 1 2 3 4 5 6 7 8; do
    "$TASK" new "Parallel $i" >"$TMP/out.$i" 2>&1 &
  done
  wait
  local ids
  ids="$(cat "$TMP"/out.* | LC_ALL=C sort | tr '\n' ' ')"
  assert_eq "$ids" "T-0001 T-0002 T-0003 T-0004 T-0005 T-0006 T-0007 T-0008 "
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
  assert_no_file "$AGENT_TASKS_HOME/.lock"
}

test_tasks_parallel_first_use() {
  export AGENT_TASKS_LOCK_TIMEOUT=30
  local i
  for i in 1 2 3; do "$TASK" new "Fresh $i" >"$TMP/out.$i" 2>&1 & done
  wait
  assert_eq "$(cat "$TMP"/out.* | LC_ALL=C sort | tr '\n' ' ')" "T-0001 T-0002 T-0003 "
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
}

test_tasks_show_and_path() {
  "$TASK" new "Showable" --body "hello" >/dev/null
  local f
  f="$(task_path_of T-0001)"
  assert_eq "$("$TASK" path T-0001)" "$f"
  assert_eq "$("$TASK" show T-0001)" "$(cat "$f")"
}

test_tasks_id_forms_and_errors() {
  "$TASK" new "One" >/dev/null
  local f form out rc=0
  f="$(task_path_of T-0001)"
  for form in 1 t-1 T-0001 0001 T-1; do
    assert_eq "$("$TASK" path "$form")" "$f"
  done
  out="$("$TASK" path T-0099 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" "task: no task T-0099"
  rc=0; out="$("$TASK" path abc 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_eq "$out" "task: invalid task id 'abc'"
  rc=0; out="$("$TASK" path 0 2>&1)" || rc=$?
  assert_eq "$rc" 1
}

test_tasks_id_does_not_match_longer_numbers() {
  write_task_file 00_backlog T-0010 "Ten"
  local out rc=0
  out="$("$TASK" path T-0001 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "no task T-0001"
}

test_tasks_duplicate_id_reported() {
  write_task_file 00_backlog T-0001 "One"
  write_task_file 01_ready T-0001 "One again"
  local out rc=0
  out="$("$TASK" path 1 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "duplicate task id T-0001:"
  assert_contains "$out" "(run 'task doctor')"
}

test_tasks_ls_table_and_footer() {
  mkproj api
  "$TASK" new "Alpha" --project api >/dev/null
  "$TASK" new "Beta" >/dev/null
  write_task_file 09_finishing T-0010 "Finishing one"
  write_task_file 11_done T-0011 "Done one"
  write_task_file 11_done T-0012 "Done two"
  local out
  out="$("$TASK" ls)"
  assert_eq "$out" "$(printf 'ID      STATUS     PROJECT  TITLE\nT-0001  backlog    api      Alpha\nT-0002  backlog    -        Beta\nT-0010  finishing  -        Finishing one\nT-0011  done       -        Done one\nT-0012  done       -        Done two')"
}

test_tasks_ls_filters() {
  write_task_file 00_backlog T-0001 "Back"
  write_task_file 03_brainstorming T-0002 "Brain"
  write_task_file 04_spec_review T-0003 "Spec"
  write_task_file 11_done T-0004 "Fin"
  write_task_file blocked T-0005 "Blk"
  write_task_file 08_implementing T-0006 "Impl"
  local out
  out="$("$TASK" ls 11_done)"
  assert_eq "$out" "ID      STATUS  PROJECT  TITLE
T-0004  done    -        Fin"
  assert_not_contains "$out" "more"
  assert_eq "$("$TASK" ls spec_review)" "ID      STATUS       PROJECT  TITLE
T-0003  spec_review  -        Spec"
  assert_eq "$("$TASK" ls 3 | tail -n 1)" "T-0002  brainstorming  -        Brain"
  write_task_file 06_plan_review T-0007 "Plan"
  write_task_file 05_planning T-0008 "Planning"
  out="$("$TASK" ls --waiting)"
  assert_contains "$out" "T-0007  plan_review"
  assert_not_contains "$out" "T-0008"
  assert_eq "$("$TASK" ls plan_review | tail -n 1)" "T-0007  plan_review  -        Plan"
  assert_eq "$("$TASK" ls 5 | tail -n 1)" "T-0008  planning  -        Planning"
  assert_contains "$out" "T-0002  brainstorming"
  assert_contains "$out" "T-0003  spec_review"
  assert_contains "$out" "T-0005  blocked"
  assert_not_contains "$out" "T-0001"
  assert_not_contains "$out" "T-0006"
  assert_not_contains "$out" "T-0004"
  out="$("$TASK" ls --all)"
  assert_contains "$out" "T-0004"
  assert_not_contains "$out" "more"
  assert_eq "$("$TASK" ls 01_ready)" "no tasks"
  local rc=0
  out="$("$TASK" ls bogus 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown folder 'bogus'"
}

test_tasks_ls_ws_filter() {
  "$TASK" new "In work" >/dev/null
  mkdir -p "$AGENT_TASKS_HOME/side/00_backlog"
  "$TASK" new "In side" --ws side >/dev/null
  local out
  out="$("$TASK" ls --ws side)"
  assert_eq "$out" "ID      STATUS   PROJECT  TITLE
T-0002  backlog  -        In side"
  assert_not_contains "$out" "In work"
}

test_tasks_ls_ws_column_only_with_two_workspaces() {
  "$TASK" new "In work" >/dev/null
  assert_eq "$("$TASK" ls | head -n 1)" "ID      STATUS   PROJECT  TITLE"
  mkdir -p "$AGENT_TASKS_HOME/side/00_backlog"
  "$TASK" new "In side" --ws side >/dev/null
  # Workspaces list alphabetically, so side comes first.
  assert_eq "$("$TASK" ls)" "WS    ID      STATUS   PROJECT  TITLE
side  T-0002  backlog  -        In side
work  T-0001  backlog  -        In work"
  assert_eq "$("$TASK" ls --ws work | head -n 1)" "ID      STATUS   PROJECT  TITLE"
}

test_tasks_ls_json() {
  mkproj api
  "$TASK" new "Alpha" --project api >/dev/null
  mkdir -p "$AGENT_TASKS_HOME/side/00_backlog"
  "$TASK" new "Beta" --ws side >/dev/null
  write_task_file 11_done T-0003 "Done one"
  local out
  out="$("$TASK" ls --json)"
  # Done tasks are listed too; only the archive is hidden.
  assert_eq "$(jq length <<< "$out")" 3
  # Workspaces list alphabetically, so side comes before work.
  assert_eq "$(jq -r '.[] | select(.id == "T-0001") | [.id, .title, .project, .workspace, .folder, .created, .session] | map(tostring) | join("|")' <<< "$out")" \
    "T-0001|Alpha|api|work|00_backlog|$(date +%Y-%m-%d)|null"
  assert_eq "$(jq -r '.[] | select(.id == "T-0001") | .status' <<< "$out")" "backlog"
  assert_eq "$("$TASK" ls --json 11_done | jq -r '.[0].status')" "done"
  assert_eq "$(jq -r '.[] | select(.id == "T-0001") | .path' <<< "$out")" "$(task_path_of T-0001)"
  assert_eq "$(jq -r '.[] | select(.id == "T-0002") | .project' <<< "$out")" "null"
  assert_eq "$(jq -r '.[] | select(.id == "T-0002") | .workspace' <<< "$out")" "side"
  assert_eq "$("$TASK" ls --json 11_done | jq -r '.[0].id')" "T-0003"
  assert_eq "$("$TASK" ls --json 01_ready)" "[]"
}

test_tasks_ls_json_session() {
  write_task_file 00_backlog T-0001 "Has session"
  "$TASK" set 1 session ses_abc >/dev/null
  assert_eq "$("$TASK" ls --json | jq -r '.[0].session')" "ses_abc"
}

test_tasks_parallel_new_with_dead_pid_lock() {
  export AGENT_TASKS_LOCK_TIMEOUT=30
  "$TASK" backup >/dev/null
  local round i
  for round in 1 2 3; do
    rm -f "$TMP"/out.*
    mkdir "$AGENT_TASKS_HOME/.lock"
    echo 999999 > "$AGENT_TASKS_HOME/.lock/pid"
    for i in 1 2 3 4 5 6; do
      "$TASK" new "Round $round item $i" >"$TMP/out.$i" 2>&1 &
    done
    wait
  done
  local ids
  ids="$(git -C "$AGENT_TASKS_HOME" ls-files 'work/*/T-*.md' | sed 's/.*\/\(T-[0-9]*\).*/\1/' | LC_ALL=C sort | uniq -d)"
  assert_eq "$ids" ""
  assert_eq "$(find "$AGENT_TASKS_HOME/work" -name 'T-*.md' | wc -l | tr -d ' ')" 18
  assert_eq "$(git -C "$AGENT_TASKS_HOME" status --porcelain)" ""
}

test_tasks_new_dash_title_after_double_dash() {
  assert_eq "$("$TASK" new -- "-x")" "T-0001"
  assert_contains "$(cat "$(task_path_of T-0001)")" 'title: "-x"'
  "$TASK" new --ready -- "--weird" >/dev/null
  assert_contains "$(cat "$(task_path_of T-0002)")" 'title: "--weird"'
  local out rc=0
  out="$("$TASK" new "-x" 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown option"
}

test_tasks_new_rejects_section_headings_in_body() {
  local out rc=0 h
  for h in "## Log" "## Result"; do
    rc=0
    out="$("$TASK" new "T" --body "$(printf 'a\n%s\nb' "$h")" 2>&1)" || rc=$?
    assert_eq "$rc" 1
    assert_contains "$out" "body must not contain a '$h' line"
  done
  assert_eq "$(find "$AGENT_TASKS_HOME/work/00_backlog" -type f | wc -l | tr -d ' ')" 0
}

test_tasks_project_name_validated_everywhere() {
  local out rc=0
  out="$("$TASK" new "T" --project ../../config.toml 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid project name"
  rc=0
  out="$("$TASK" new "T" --ws ../x 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid workspace"
  rc=0
  out="$("$TASK" ls --ws ../x 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid workspace"
  rc=0
  out="$("$TASK" project add api "$TMP" --ws ../x 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid workspace"
  rc=0
  out="$("$TASK" project ls --ws ../x 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid workspace"
  rc=0
  out="$("$TASK" project import-memory --ws ../x 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid workspace"
}

test_tasks_new_rejects_unknown_workspace() {
  "$TASK" backup >/dev/null
  local out rc=0
  out="$("$TASK" new "Typo" --ws work2 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown workspace 'work2' (existing: work)"
  assert_no_file "$AGENT_TASKS_HOME/work2"
  rc=0; out="$("$TASK" ls --ws work2 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown workspace 'work2'"
  rc=0; out="$("$TASK" project ls --ws work2 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown workspace 'work2'"
  assert_no_file "$AGENT_TASKS_HOME/work2"
  # `project add --ws` is how a workspace is born; --project then implies it.
  mkdir -p "$TMP/code/p"
  "$TASK" project add p "$TMP/code/p" --ws work2 >/dev/null
  assert_eq "$("$TASK" new "Now fine" --ws work2)" "T-0001"
  assert_contains "$(task_path_of T-0001)" "/work2/00_backlog/"
}
