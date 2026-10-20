//! Spec approval (→ planning) and plan approval (→ 07_approved for the worker,
//! or implementing with --now) (lib/approve.sh).

use crate::cmd::edit::move_task;
use crate::cmd::run::run_send_implement;
use crate::commit::store_commit;
use crate::core::*;
use crate::frontmatter::*;
use crate::lock::{lock_acquire, lock_release};

pub fn cmd_approve(args: &[String]) -> i32 {
    const USAGE: &str = "usage: task approve <id> [--now]";
    const ALLOWED: &str = "03_brainstorming, 04_spec_review (spec), 05_planning (plan recorded), 06_plan_review (plan), 07_approved with --now";
    let mut id = String::new();
    let mut now = false;
    for a in args {
        if a == "--now" {
            now = true;
        } else if a.starts_with('-') {
            die(format!("unknown option: {a}"));
        } else {
            if !id.is_empty() {
                die(USAGE);
            }
            id = a.clone();
        }
    }
    if id.is_empty() {
        die(USAGE);
    }
    let tid = normalize_id(&id).unwrap_or_else(|| die(format!("invalid task id '{id}'")));
    lock_acquire();
    let f = task_file(&tid);
    fm_require(&f);
    let folder = folder_of_file(&f);
    match folder.as_str() {
        "03_brainstorming" | "04_spec_review" => {
            // Spec approved: the agent goes on with writing-plans in its own session.
            move_task(
                &f,
                "05_planning",
                "task",
                "spec approved — planning starts now",
                "",
            );
            store_commit();
            println!("start");
            return 0;
        }
        "05_planning" => {
            // The plan review was answered while the task is still in planning (signals race).
            if fm_get(&f, "plan").is_empty() {
                die(format!("{tid} has no plan recorded yet"));
            }
        }
        "06_plan_review" => {}
        "07_approved" => {
            if !now {
                die(format!(
                    "{tid} is in {folder}; approve applies to {ALLOWED}"
                ));
            }
        }
        _ => die(format!(
            "{tid} is in {folder}; approve applies to {ALLOWED}"
        )),
    }
    if now {
        let moved = move_task(
            &f,
            "08_implementing",
            "task",
            "plan approved — implementation starts now",
            "",
        );
        store_commit();
        println!("start");
        // From 06 the agent is in its own turn and goes on with the implementation.
        // A task waiting in 07 has an idle session: it needs the kickoff prompt.
        if folder == "07_approved" {
            approve_kickoff(&tid, &moved);
        }
    } else {
        // The worker (task run --once) starts it when automation is on and a slot is free.
        move_task(
            &f,
            "07_approved",
            "task",
            "plan approved — waiting for the worker",
            "",
        );
        store_commit();
        println!("deferred");
    }
    0
}

/// Sends the implementation prompt to the session of a task that left 07_approved.
fn approve_kickoff(tid: &str, f: &str) {
    let session = fm_get(f, "session");
    if session.is_empty() {
        println!("{tid} has no session; start the implementation in the session yourself");
        return;
    }
    if !valid_session(&session) {
        die(format!("{tid} has an invalid session field"));
    }
    lock_release();
    if run_send_implement(tid, &session) {
        println!("sent the implementation prompt to session {session}");
    } else {
        warn(format!(
            "could not send the implementation prompt to session {session}; start the implementation in the session yourself"
        ));
    }
}
