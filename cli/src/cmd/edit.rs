//! Changing tasks: move, log, set/unset, done, merged (lib/edit.sh).

use crate::commit::store_commit;
use crate::core::*;
use crate::frontmatter::*;
use crate::lock::lock_acquire;
use crate::subtasks::*;
use std::fs;
use std::path::Path;

/// Moves the file, keeps blocked_from in step, logs the move; returns the new
/// path. A move into 11_done cleans up the task's worktree; `result` (default:
/// the task's result field) decides about its branch.
pub fn move_task(file: &str, folder: &str, author: &str, reason: &str, result: &str) -> String {
    let from = folder_of_file(file);
    let mut blocked_prev = String::new();
    if from == "blocked" {
        blocked_prev = fm_get(file, "blocked_from");
    }
    if from == folder {
        return file.to_string();
    }
    let ws = ws_of_file(file);
    let dest = format!("{}/{}/{}/{}", store(), ws, folder, basename(file));
    if Path::new(&dest).exists() {
        die(format!("cannot move: {dest} already exists"));
    }
    let _ = fs::create_dir_all(format!("{}/{}/{}", store(), ws, folder));
    if fs::rename(file, &dest).is_err() {
        die(format!("cannot move {file} to {dest}"));
    }
    let upd = |r: Result<(), ()>| {
        if r.is_err() {
            die(format!("cannot update {dest}"));
        }
    };
    if folder == "blocked" {
        upd(fm_set(&dest, "blocked_from", &from));
    }
    if from == "blocked" {
        upd(fm_unset(&dest, "blocked_from"));
    }
    if folder == "postponed" {
        // From blocked the stage itself is remembered, so resume returns there.
        let pfrom = if from == "blocked" && !blocked_prev.is_empty() {
            blocked_prev.clone()
        } else {
            from.clone()
        };
        upd(fm_set(&dest, "postponed_from", &pfrom));
    }
    if from == "postponed" {
        upd(fm_unset(&dest, "postponed_from"));
    }
    let mut msg = format!("{from} → {folder}");
    if !reason.is_empty() {
        msg.push_str(&format!(" — {reason}"));
    }
    log_append(&dest, author, &msg);
    if folder == "11_done" {
        let res = if result.is_empty() {
            fm_get(&dest, "result")
        } else {
            result.to_string()
        };
        crate::cmd::worktree::worktree_cleanup(&dest, &res, false);
    }
    // The last open subtask finished: the parent closes too (recursively, through move_task).
    if folder == "11_done" || folder == "archive" {
        st_autoclose(&dest);
    }
    dest
}

pub fn cmd_mv(args: &[String]) -> i32 {
    const USAGE: &str = "usage: task mv <id> <folder> [--reason TEXT] [--force]";
    let (mut id, mut fol, mut reason, mut force) =
        (String::new(), String::new(), String::new(), false);
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--reason" => {
                reason = trim(need_value(args, i)).to_string();
                i += 2;
            }
            "--force" => {
                force = true;
                i += 1;
            }
            _ if a.starts_with('-') => die(format!("unknown option: {a}")),
            _ => {
                if id.is_empty() {
                    id = a.to_string();
                } else if fol.is_empty() {
                    fol = a.to_string();
                } else {
                    die(USAGE);
                }
                i += 1;
            }
        }
    }
    if id.is_empty() || fol.is_empty() {
        die(USAGE);
    }
    let folder = resolve_folder(&fol).unwrap_or_else(|| {
        die(format!(
            "unknown folder '{}' (folders: {})",
            fol,
            folders_str()
        ))
    });
    if !single_line(&reason) {
        die("reason must be a single line");
    }
    lock_acquire();
    let f = task_file(&id);
    fm_require(&f);
    let tid = normalize_id(&id).unwrap();
    let from = folder_of_file(&f);
    if from == folder {
        println!("{tid} is already in {folder}");
        return 0;
    }
    if !force && st_parent_wait_folder(folder) {
        st_guard_open(&tid);
    }
    move_task(&f, folder, "task", &reason, "");
    store_commit();
    println!("{tid}: {from} → {folder}");
    0
}

pub fn cmd_log(args: &[String]) -> i32 {
    const USAGE: &str = "usage: task log <id> <message|-> [--author A]";
    let (mut id, mut msg, mut have_msg) = (String::new(), String::new(), false);
    let mut author = "agent".to_string();
    let mut opts = true;
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        if opts && a == "--" {
            opts = false;
            i += 1;
            continue;
        }
        if opts && a == "--author" {
            author = need_value(args, i).to_string();
            i += 2;
            continue;
        }
        if id.is_empty() {
            id = a.to_string();
        } else if !have_msg {
            msg = a.to_string();
            have_msg = true;
        } else {
            die(USAGE);
        }
        i += 1;
    }
    if id.is_empty() || !have_msg {
        die(USAGE);
    }
    let msg = read_text_arg(&msg);
    if trim(&msg).is_empty() {
        die("log message is empty");
    }
    if !single_line(&author) {
        die("author must be a single line");
    }
    if author.is_empty() {
        die("author is empty");
    }
    if author.contains(':') {
        die("author must not contain ':'");
    }
    lock_acquire();
    let f = task_file(&id);
    fm_require(&f);
    log_append(&f, &author, &msg);
    store_commit();
    println!("{}: logged", normalize_id(&id).unwrap());
    0
}

pub fn cmd_set(args: &[String]) -> i32 {
    let mut a: Vec<String> = args.to_vec();
    // `--` may precede the arguments or the value, so a value can start with '-'.
    if a.first().map(|s| s.as_str()) == Some("--") {
        a.remove(0);
    }
    if a.len() == 4 && a[2] == "--" {
        a = vec![a[0].clone(), a[1].clone(), a[3].clone()];
    }
    if a.len() != 3 {
        die("usage: task set <id> <key> <value>");
    }
    let (id, key) = (a[0].clone(), a[1].clone());
    if !matches!(
        key.as_str(),
        "title"
            | "project"
            | "source"
            | "session"
            | "spec"
            | "plan"
            | "pr"
            | "result"
            | "parent"
            | "depends_on"
    ) {
        die(format!(
            "cannot set '{key}' (keys: title project source session spec plan pr result parent depends_on); links go to source (ticket), pr (MR/PR), spec or plan (docs)"
        ));
    }
    let mut val = trim(&a[2]).to_string();
    if val.is_empty() {
        die(format!(
            "empty value for {key} (use 'task unset {id} {key}' to remove it)"
        ));
    }
    if !single_line(&val) {
        die("value must be a single line");
    }
    match key.as_str() {
        "project" => {
            if !valid_project(&val) {
                die(format!("invalid project name '{val}'"));
            }
        }
        "session" => {
            if !valid_session(&val) {
                die(format!("invalid session id '{val}'"));
            }
        }
        "result" if !valid_result(&val) => {
            die(format!(
                "invalid result '{val}' (one of: {})",
                results_str()
            ));
        }
        _ => {}
    }
    lock_acquire();
    let f = task_file(&id);
    fm_require(&f);
    let tid = normalize_id(&id).unwrap();
    if key == "project" {
        let ws = ws_of_file(&f);
        if !Path::new(&format!("{}/{}/.projects/{}", store(), ws, val)).is_file() {
            die(format!(
                "unknown project '{val}' in workspace {ws} (register it: task project add {val} <path>)"
            ));
        }
    }
    let fail = |r: Result<(), ()>| {
        if r.is_err() {
            die(format!("cannot update {f}"));
        }
    };
    match key.as_str() {
        "parent" => {
            val = normalize_id(&val).unwrap_or_else(|| die(format!("invalid task id '{val}'")));
            st_validate_parent(&tid, &f, &val);
            fail(fm_set(&f, "parent", &val));
        }
        "depends_on" => {
            let ids = st_parse_ids(&val);
            if ids.is_empty() {
                die("empty value for depends_on");
            }
            st_validate_depends(&tid, &ids);
            val = ids.join(" ");
            fail(fm_set(&f, "depends_on", &val));
        }
        "title" => fail(fm_set(&f, "title", &fm_quote_always(&val))),
        _ => fail(fm_set(&f, &key, &fm_quote(&val))),
    }
    store_commit();
    println!("{tid}: {key} = {val}");
    0
}

pub fn cmd_unset(args: &[String]) -> i32 {
    if args.len() != 2 {
        die("usage: task unset <id> <key>");
    }
    let (id, key) = (&args[0], &args[1]);
    if !matches!(
        key.as_str(),
        "project"
            | "source"
            | "session"
            | "spec"
            | "plan"
            | "pr"
            | "result"
            | "worktree"
            | "parent"
            | "depends_on"
    ) {
        die(format!(
            "cannot unset '{key}' (keys: project source session spec plan pr result worktree parent depends_on)"
        ));
    }
    lock_acquire();
    let f = task_file(id);
    fm_require(&f);
    let tid = normalize_id(id).unwrap();
    if fm_get(&f, key).is_empty() {
        println!("{tid} has no {key}");
        return 0;
    }
    if fm_unset(&f, key).is_err() {
        die(format!("cannot update {f}"));
    }
    store_commit();
    println!("{tid}: {key} removed");
    0
}

pub fn cmd_done(args: &[String]) -> i32 {
    const USAGE: &str = "usage: task done <id> --result R [--summary TEXT|-] [--force]";
    let (mut id, mut result, mut summary) = (String::new(), String::new(), String::new());
    let (mut have_summary, mut force) = (false, false);
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--result" => {
                result = need_value(args, i).to_string();
                i += 2;
            }
            "--summary" => {
                summary = need_value(args, i).to_string();
                have_summary = true;
                i += 2;
            }
            "--force" => {
                force = true;
                i += 1;
            }
            _ if a.starts_with('-') => die(format!("unknown option: {a}")),
            _ => {
                if !id.is_empty() {
                    die(USAGE);
                }
                id = a.to_string();
                i += 1;
            }
        }
    }
    if id.is_empty() {
        die(USAGE);
    }
    if result.is_empty() {
        die(format!("task done requires --result ({})", results_str()));
    }
    if !valid_result(&result) {
        die(format!(
            "invalid result '{result}' (one of: {})",
            results_str()
        ));
    }
    if have_summary {
        summary = read_text_arg(&summary);
        reject_sections("summary", &summary);
    }
    lock_acquire();
    let mut f = task_file(&id);
    fm_require(&f);
    let tid = normalize_id(&id).unwrap();
    let from = folder_of_file(&f);
    let dest = if result == "pr" || result == "kept" {
        "10_unmerged"
    } else {
        "11_done"
    };
    if !force {
        st_guard_open(&tid);
    }
    if from == dest {
        log_append(&f, "task", &format!("result: {result}"));
    } else {
        f = move_task(&f, dest, "task", &format!("result: {result}"), &result);
    }
    if fm_set(&f, "result", &result).is_err() {
        die(format!("cannot update {f}"));
    }
    if !summary.is_empty() && result_append(&f, &summary).is_err() {
        die(format!("cannot update {f}"));
    }
    store_commit();
    println!("{tid}: {from} → {dest} (result: {result})");
    0
}

pub fn cmd_merged(args: &[String]) -> i32 {
    const USAGE: &str = "usage: task merged <id> [--summary TEXT|-] [--force]";
    let (mut id, mut summary) = (String::new(), String::new());
    let (mut have_summary, mut force) = (false, false);
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--summary" => {
                summary = need_value(args, i).to_string();
                have_summary = true;
                i += 2;
            }
            "--force" => {
                force = true;
                i += 1;
            }
            _ if a.starts_with('-') => die(format!("unknown option: {a}")),
            _ => {
                if !id.is_empty() {
                    die(USAGE);
                }
                id = a.to_string();
                i += 1;
            }
        }
    }
    if id.is_empty() {
        die(USAGE);
    }
    if have_summary {
        summary = read_text_arg(&summary);
        reject_sections("summary", &summary);
    }
    lock_acquire();
    let f = task_file(&id);
    fm_require(&f);
    let tid = normalize_id(&id).unwrap();
    let from = folder_of_file(&f);
    if from != "10_unmerged" {
        die(format!(
            "{tid} is in {from}; only unmerged tasks can be marked merged"
        ));
    }
    if !force {
        st_guard_open(&tid);
    }
    let f = move_task(&f, "11_done", "task", "merged", "merged");
    if fm_set(&f, "result", "merged").is_err() {
        die(format!("cannot update {f}"));
    }
    if !summary.is_empty() && result_append(&f, &summary).is_err() {
        die(format!("cannot update {f}"));
    }
    store_commit();
    println!("{tid}: 10_unmerged → 11_done (result: merged)");
    0
}
