# shellcheck shell=bash
# Spec approval (→ planning) and plan approval (→ 07_approved for the worker, or implementing with --now).

cmd_approve() {
  local usage="usage: task approve <id> [--now]"
  local allowed="03_brainstorming, 04_spec_review (spec), 05_planning (plan recorded), 06_plan_review (plan), 07_approved with --now"
  local id="" now=0 tid f folder
  while [ $# -gt 0 ]; do
    case "$1" in
      --now) now=1; shift ;;
      -*) die "unknown option: $1" ;;
      *) [ -z "$id" ] || die "$usage"; id="$1"; shift ;;
    esac
  done
  [ -n "$id" ] || die "$usage"
  tid="$(normalize_id "$id")" || die "invalid task id '$id'"
  lock_acquire
  f="$(task_file "$tid")"
  fm_require "$f"
  folder="$(folder_of_file "$f")"
  case "$folder" in
    03_brainstorming|04_spec_review)
      # Spec approved: the agent goes on with writing-plans in its own session.
      move_task "$f" 05_planning task "spec approved — planning starts now"
      store_commit || true
      echo start
      return 0 ;;
    05_planning)
      # The plan review was answered while the task is still in planning (signals race).
      [ -n "$(fm_get "$f" plan)" ] || die "$tid has no plan recorded yet" ;;
    06_plan_review) ;;
    07_approved) [ "$now" -eq 1 ] || die "$tid is in $folder; approve applies to $allowed" ;;
    *) die "$tid is in $folder; approve applies to $allowed" ;;
  esac
  if [ "$now" -eq 1 ]; then
    move_task "$f" 08_implementing task "plan approved — implementation starts now"
    store_commit || true
    echo start
    # From 06 the agent is in its own turn and goes on with the implementation.
    # A task waiting in 07 has an idle session: it needs the kickoff prompt.
    if [ "$folder" = "07_approved" ]; then approve_kickoff "$tid" "$MOVED_TO"; fi
  else
    # The worker (task run --once) starts it when automation is on and a slot is free.
    move_task "$f" 07_approved task "plan approved — waiting for the worker"
    store_commit || true
    echo deferred
  fi
}

# Sends the implementation prompt (lib/run.sh) to the session of a task that
# left 07_approved; without lib/run.sh or a session, prints what to do instead.
approve_kickoff() {   # approve_kickoff <id> <file>
  local tid="$1" f="$2" session
  session="$(fm_get "$f" session)"
  if [ -z "$session" ]; then
    echo "$tid has no session; start the implementation in the session yourself"
    return 0
  fi
  valid_session "$session" || die "$tid has an invalid session field"
  if ! declare -F run_send_implement >/dev/null; then
    echo "start the implementation in the session yourself"
    return 0
  fi
  lock_release
  if run_send_implement "$tid" "$session"; then
    echo "sent the implementation prompt to session $session"
  else
    warn "could not send the implementation prompt to session $session; start the implementation in the session yourself"
  fi
}
