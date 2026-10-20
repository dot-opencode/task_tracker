//! Postponed: a task the user set aside (lib/postpone.sh).

use crate::cmd::edit::move_task;
use crate::commit::store_commit;
use crate::core::*;
use crate::frontmatter::*;
use crate::lock::lock_acquire;

pub fn cmd_postpone(args: &[String]) -> i32 {
    const USAGE: &str = "usage: task postpone <id> [--reason TEXT]";
    let (mut id, mut reason) = (String::new(), String::new());
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        if a == "--reason" {
            reason = trim(need_value(args, i)).to_string();
            i += 2;
        } else if a.starts_with('-') {
            die(format!("unknown option: {a}"));
        } else {
            if !id.is_empty() {
                die(USAGE);
            }
            id = a.to_string();
            i += 1;
        }
    }
    if id.is_empty() {
        die(USAGE);
    }
    if !single_line(&reason) {
        die("reason must be a single line");
    }
    lock_acquire();
    let f = task_file(&id);
    fm_require(&f);
    let tid = normalize_id(&id).unwrap();
    let from = folder_of_file(&f);
    match from.as_str() {
        "10_unmerged" | "11_done" | "archive" => die(format!(
            "{tid} is in {from}; done/archived tasks cannot be postponed"
        )),
        "postponed" => die(format!("{tid} is already postponed")),
        _ => {}
    }
    let ses = fm_get(&f, "session");
    let f = move_task(&f, "postponed", "task", "", "");
    let target = fm_get(&f, "postponed_from");
    let mut msg = "postponed".to_string();
    if !reason.is_empty() {
        msg = format!("postponed — {reason}");
    }
    log_append(&f, "task", &msg);
    store_commit();
    println!("{tid}: {from} → postponed (from {target})");
    if matches!(from.as_str(), "02_exploring" | "05_planning" | "08_implementing") && !ses.is_empty()
    {
        eprintln!("warning: session {ses} may still be running; stop it in OpenCode (task open {tid})");
    }
    0
}

pub fn cmd_resume(args: &[String]) -> i32 {
    if args.len() != 1 {
        die("usage: task resume <id>");
    }
    lock_acquire();
    let f = task_file(&args[0]);
    fm_require(&f);
    let tid = normalize_id(&args[0]).unwrap();
    let from = folder_of_file(&f);
    if from != "postponed" {
        die(format!("{tid} is in {from}; not postponed"));
    }
    let raw = fm_get(&f, "postponed_from");
    let mut target = resolve_folder(&raw).unwrap_or("");
    if matches!(
        target,
        "" | "postponed" | "blocked" | "archive" | "11_done" | "10_unmerged"
    ) {
        target = "00_backlog";
    }
    match target {
        "02_exploring" | "05_planning" | "08_implementing" => {
            // No agent runs there any more: wait for the user in blocked.
            let m = move_task(&f, "blocked", "task", "", "");
            if fm_set(&m, "blocked_from", target).is_err() {
                die(format!("cannot update {m}"));
            }
            log_append(&m, "task", "resumed; open the session to continue");
            store_commit();
            println!("{tid}: postponed → blocked (from {target}); continue with: task open {tid}");
        }
        _ => {
            let m = move_task(&f, target, "task", "", "");
            log_append(&m, "task", "resumed");
            store_commit();
            println!("{tid}: postponed → {target}");
        }
    }
    0
}
