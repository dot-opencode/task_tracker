//! Session signals from the OpenCode plugin: the transition table (lib/signal.sh).

use crate::cmd::edit::move_task;
use crate::cmd::open::{notify_clear, notify_task};
use crate::cmd::run::api_get;
use crate::commit::store_commit;
use crate::core::*;
use crate::frontmatter::*;
use crate::lock::lock_acquire;
use crate::subtasks::{st_load, st_parent_wait_folder};
use serde_json::Value;
use std::fs;
use std::path::Path;

pub const SIGNALS: &str = "question turn-end input answered permission error stalled finishing";

/// Number of task files in the given folders across all workspaces.
pub fn count_tasks_in(folders: &[&str]) -> usize {
    let mut n = 0;
    for ws in list_workspaces() {
        for fo in folders {
            n += task_files_in(&format!("{}/{}/{}", store(), ws, fo)).len();
        }
    }
    n
}

/// Agents at work: tasks in 02_exploring, 05_planning and 08_implementing.
pub fn active_count() -> usize {
    count_tasks_in(&AGENT_FOLDERS)
}

/// Path of the least recently touched task in the folders.
pub fn oldest_task_in(with_session: bool, folders: &[&str]) -> Option<String> {
    oldest_tasks_in(with_session, folders).into_iter().next()
}

pub fn max_active() -> u64 {
    let n = config_get("max_active", "2");
    if n.is_empty() || !n.bytes().all(|b| b.is_ascii_digit()) {
        return 2;
    }
    n.parse().unwrap_or(u64::MAX)
}

/// The user acted in the task's session (quiet rule of notify_task).
pub fn record_user_activity(id: &str) {
    let d = format!("{}/.notify", store());
    let _ = fs::create_dir_all(&d);
    let _ = fs::write(format!("{d}/{id}.last-user"), format!("{}\n", epoch_now()));
}

/// True when a child session of `s` is running. `active` is the
/// /api/session/active answer (fetched when empty). Any failure counts as
/// "no running children", with a warning.
pub fn session_has_running_children(s: &str, active: &str) -> bool {
    if !crate::cmd::session::on_path("opencode") {
        warn(format!(
            "opencode not found; child sessions of {s} not checked"
        ));
        return false;
    }
    let active = if active.is_empty() {
        match api_get("/api/session/active") {
            Some(a) => a,
            None => {
                warn(format!(
                    "cannot list active sessions; child sessions of {s} not checked"
                ));
                return false;
            }
        }
    } else {
        active.to_string()
    };
    let Some(kids) = api_get(&format!("/api/session?parentID={s}")) else {
        warn(format!("cannot list child sessions of {s}; assuming none"));
        return false;
    };
    match children_running(s, &active, &kids) {
        Some(b) => b,
        None => {
            warn(format!(
                "unexpected answer when listing child sessions of {s}; assuming none"
            ));
            false
        }
    }
}

/// The jq filter of session_has_running_children; None = jq failed (exit 5).
pub fn children_running(s: &str, active: &str, kids: &str) -> Option<bool> {
    let a: Value = serde_json::from_str(active).ok()?;
    let a = match &a {
        Value::Object(o) => match o.get("data") {
            None | Some(Value::Null) | Some(Value::Bool(false)) => {
                Value::Object(Default::default())
            }
            Some(d) => d.clone(),
        },
        Value::Null => Value::Object(Default::default()),
        _ => return None,
    };
    let k: Value = serde_json::from_str(kids).ok()?;
    let data = match &k {
        Value::Object(o) => o.get("data").cloned().unwrap_or(Value::Null),
        Value::Null => Value::Null,
        _ => return None,
    };
    let items: Vec<Value> = match &data {
        Value::Array(v) => v.clone(),
        Value::Object(o) => match o
            .get("items")
            .filter(|v| !v.is_null() && **v != Value::Bool(false))
        {
            Some(Value::Array(v)) => v.clone(),
            Some(Value::Object(m)) => m.values().cloned().collect(),
            Some(_) => return None,
            None => match o
                .get("sessions")
                .filter(|v| !v.is_null() && **v != Value::Bool(false))
            {
                Some(Value::Array(v)) => v.clone(),
                Some(Value::Object(m)) => m.values().cloned().collect(),
                Some(_) => return None,
                None => Vec::new(),
            },
        },
        _ => Vec::new(),
    };
    for it in items {
        let Value::Object(o) = &it else { continue };
        let id = o.get("id");
        if id == Some(&Value::String(s.to_string())) {
            continue;
        }
        let parent = match o.get("parentID") {
            None | Some(Value::Null) | Some(Value::Bool(false)) => Some(s),
            Some(Value::String(p)) => Some(p.as_str()),
            Some(_) => None,
        };
        if parent != Some(s) {
            continue;
        }
        if let (Some(Value::String(id)), Value::Object(ao)) = (id, &a) {
            if ao.contains_key(id) {
                return Some(true);
            }
        }
    }
    Some(false)
}

/// Text of the notification for a signal.
pub fn signal_body(signal: &str, text: &str, folder: &str, spec: &str, plan: &str) -> String {
    if signal == "turn-end" && folder == "04_spec_review" && !spec.is_empty() {
        return format!("Spec ready for review: {spec}");
    }
    if signal == "turn-end" && folder == "06_plan_review" && !plan.is_empty() {
        return format!("Plan ready for review: {plan}");
    }
    if !text.is_empty() {
        return text.to_string();
    }
    match signal {
        "question" => "The agent has a question.",
        "turn-end" => "The agent is waiting for you.",
        "permission" => "The agent asks for a permission.",
        "error" => "The session failed.",
        "stalled" => "The session stopped.",
        other => other,
    }
    .to_string()
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Plan {
    /// target folder, empty = none
    pub target: String,
    /// 1 = log only (2 is used by cmd_signal for "deferred")
    pub log: bool,
    pub notify: bool,
}

/// The transition table for `signal` in `folder`. In postponed every signal is
/// only logged: nothing moves and nobody is notified.
pub fn signal_plan(signal: &str, folder: &str, spec: &str, from: &str, plan: &str) -> Plan {
    let mut p = Plan::default();
    let folder = match folder {
        "00_backlog" | "01_ready" | "11_done" => "",
        f => f,
    };
    let pick = |cond: bool, a: &str, b: &str| if cond { a.to_string() } else { b.to_string() };
    if folder.is_empty() {
        return p;
    }
    if folder == "postponed" {
        p.log = true;
        return p;
    }
    match (signal, folder) {
        ("question", "10_unmerged") => {
            p.log = true;
            p.notify = true;
        }
        ("turn-end", "10_unmerged") => p.log = true,
        (_, "10_unmerged") => {}
        ("question", "02_exploring") => {
            p.target = "03_brainstorming".into();
            p.notify = true;
        }
        ("question", "07_approved") => p.log = true,
        ("question", "05_planning") => {
            p.target = pick(!plan.is_empty(), "06_plan_review", "blocked");
            p.notify = true;
        }
        ("question", "08_implementing") => {
            p.target = "blocked".into();
            p.notify = true;
        }
        ("question", _) => {
            p.log = true;
            p.notify = true;
        }
        ("turn-end", "02_exploring") => {
            p.target = pick(!spec.is_empty(), "04_spec_review", "03_brainstorming");
            p.notify = true;
        }
        ("turn-end", "03_brainstorming") => {
            if !spec.is_empty() {
                p.target = "04_spec_review".into();
            } else {
                p.log = true;
            }
            p.notify = true;
        }
        ("turn-end", "05_planning") => {
            p.target = pick(!plan.is_empty(), "06_plan_review", "blocked");
            p.notify = true;
        }
        ("turn-end", "07_approved") => {}
        ("turn-end", "08_implementing") => {
            p.target = "blocked".into();
            p.notify = true;
        }
        ("turn-end", _) => {
            p.log = true;
            p.notify = true;
        }
        ("permission" | "error" | "stalled", "blocked") => {}
        ("permission" | "error" | "stalled", _) => {
            p.target = "blocked".into();
            p.notify = true;
        }
        ("input" | "answered", "blocked") => {
            let t = resolve_folder(from).unwrap_or("");
            p.target = if t.is_empty() || t == "blocked" {
                "03_brainstorming".into()
            } else {
                t.to_string()
            };
        }
        ("finishing", "09_finishing" | "blocked") => {}
        ("finishing", _) => p.target = "09_finishing".into(),
        _ => {}
    }
    p
}

/// True when `task run` posted a prompt to this task's session less than 60 s
/// ago: the plugin reports that prompt as `input`, but the user did not type
/// it. The marker is consumed.
pub fn auto_prompt_pending(id: &str) -> bool {
    let m = format!("{}/.notify/{id}.auto-prompt", store());
    if !Path::new(&m).is_file() {
        return false;
    }
    let mtime = {
        use std::os::unix::fs::MetadataExt;
        fs::metadata(&m).map(|md| md.mtime()).unwrap_or(0)
    };
    let age = epoch_now() - mtime;
    let _ = fs::remove_file(&m);
    age < 60
}

pub fn cmd_signal(args: &[String]) -> i32 {
    const USAGE: &str = "usage: task signal <id> <signal> --session <session-id> [--text TEXT]";
    let (mut id, mut signal, mut session, mut text) =
        (String::new(), String::new(), String::new(), String::new());
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        if a == "--session" {
            session = need_value(args, i).to_string();
            i += 2;
        } else if a == "--text" {
            // Empty text is fine: the plugin always passes --text.
            match args.get(i + 1) {
                Some(v) => text = v.clone(),
                None => die("--text requires a value"),
            }
            i += 2;
        } else if a.starts_with('-') {
            die(format!("unknown option: {a}"));
        } else {
            if id.is_empty() {
                id = a.to_string();
            } else if signal.is_empty() {
                signal = a.to_string();
            } else {
                die(USAGE);
            }
            i += 1;
        }
    }
    if id.is_empty() || signal.is_empty() || session.is_empty() {
        die(USAGE);
    }
    let tid = normalize_id(&id).unwrap_or_else(|| die(format!("invalid task id '{id}'")));
    if !SIGNALS.split(' ').any(|s| s == signal) {
        die(format!("unknown signal '{signal}' (signals: {SIGNALS})"));
    }
    if !valid_session(&session) {
        die(format!("invalid session id '{session}'"));
    }
    while text.ends_with('\n') {
        text.pop();
    }
    let first = trim(text.split('\n').next().unwrap_or("")).to_string();

    // The orchestrator ends its turn while background subagents still work.
    // Asking OpenCode takes a while, so it happens before the lock, on an
    // unlocked read; the table is evaluated again under the lock.
    if signal == "turn-end" {
        let f = task_file(&tid);
        fm_require(&f);
        if fm_get(&f, "session") == session {
            let p = signal_plan(
                &signal,
                &folder_of_file(&f),
                &fm_get(&f, "spec"),
                "",
                &fm_get(&f, "plan"),
            );
            if (!p.target.is_empty() || p.log) && session_has_running_children(&session, "") {
                println!("{tid}: turn-end ignored (child sessions are running)");
                return 0;
            }
        }
    }

    lock_acquire();
    let f = task_file(&tid);
    fm_require(&f);
    let cur = fm_get(&f, "session");
    if cur != session {
        eprintln!(
            "{tid}: ignored {signal} from {session} (bound to {})",
            if cur.is_empty() { "none" } else { &cur }
        );
        return 0;
    }
    let mut clear = false;
    match signal.as_str() {
        "input" => {
            if !auto_prompt_pending(&tid) {
                record_user_activity(&tid);
            }
            clear = true;
        }
        "answered" => {
            record_user_activity(&tid);
            clear = true;
        }
        _ => {}
    }
    let folder = folder_of_file(&f);
    let spec = fm_get(&f, "spec");
    let plan = fm_get(&f, "plan");
    let mut p = signal_plan(&signal, &folder, &spec, &fm_get(&f, "blocked_from"), &plan);

    let mut shown = folder.clone();
    let mut deferred = false;
    if !p.target.is_empty() && st_parent_wait_folder(&p.target) {
        let open = st_load().open_list(&tid);
        if !open.is_empty() {
            log_append(&f, "task", &format!("waiting for subtasks: {open}"));
            store_commit();
            println!(
                "{tid}: {signal} → {} deferred (waiting for subtasks: {open})",
                p.target
            );
            p.target.clear();
            deferred = true;
        }
    }
    if deferred {
        // nothing more
    } else if !p.target.is_empty() {
        let msg = if first.is_empty() {
            signal.clone()
        } else {
            format!("{signal} — {first}")
        };
        move_task(&f, &p.target, "task", &msg, "");
        store_commit();
        println!("{tid}: {folder} → {}", p.target);
        shown = p.target.clone();
    } else if p.log {
        let msg = if first.is_empty() {
            signal.clone()
        } else {
            format!("{signal}: {first}")
        };
        log_append(&f, "task", &msg);
        store_commit();
        println!("{tid}: {signal} noted");
    } else {
        println!("{tid}: {signal} ignored ({folder})");
    }

    if clear {
        notify_clear(&tid);
    }
    if p.notify {
        notify_task(
            &tid,
            &format!("{tid} · {shown}"),
            &signal_body(&signal, &text, &shown, &spec, &plan),
            &signal,
        );
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan(sig: &str, folder: &str, spec: &str, from: &str, pl: &str) -> (String, bool, bool) {
        let p = signal_plan(sig, folder, spec, from, pl);
        (p.target, p.log, p.notify)
    }

    #[test]
    fn table() {
        assert_eq!(
            plan("question", "02_exploring", "", "", ""),
            ("03_brainstorming".into(), false, true)
        );
        assert_eq!(
            plan("question", "05_planning", "", "", "p"),
            ("06_plan_review".into(), false, true)
        );
        assert_eq!(
            plan("question", "05_planning", "", "", ""),
            ("blocked".into(), false, true)
        );
        assert_eq!(
            plan("question", "04_spec_review", "", "", ""),
            ("".into(), true, true)
        );
        assert_eq!(
            plan("question", "10_unmerged", "", "", ""),
            ("".into(), true, true)
        );
        assert_eq!(
            plan("turn-end", "10_unmerged", "", "", ""),
            ("".into(), true, false)
        );
        assert_eq!(
            plan("turn-end", "02_exploring", "s", "", ""),
            ("04_spec_review".into(), false, true)
        );
        assert_eq!(
            plan("turn-end", "03_brainstorming", "", "", ""),
            ("".into(), true, true)
        );
        assert_eq!(
            plan("turn-end", "07_approved", "", "", ""),
            ("".into(), false, false)
        );
        assert_eq!(
            plan("turn-end", "08_implementing", "", "", ""),
            ("blocked".into(), false, true)
        );
        assert_eq!(
            plan("error", "blocked", "", "", ""),
            ("".into(), false, false)
        );
        assert_eq!(
            plan("error", "04_spec_review", "", "", ""),
            ("blocked".into(), false, true)
        );
        assert_eq!(
            plan("input", "blocked", "", "05_planning", ""),
            ("05_planning".into(), false, false)
        );
        assert_eq!(
            plan("answered", "blocked", "", "blocked", ""),
            ("03_brainstorming".into(), false, false)
        );
        assert_eq!(
            plan("answered", "blocked", "", "", ""),
            ("03_brainstorming".into(), false, false)
        );
        assert_eq!(
            plan("finishing", "08_implementing", "", "", ""),
            ("09_finishing".into(), false, false)
        );
        assert_eq!(
            plan("finishing", "09_finishing", "", "", ""),
            ("".into(), false, false)
        );
        assert_eq!(
            plan("question", "postponed", "", "", ""),
            ("".into(), true, false)
        );
        assert_eq!(
            plan("question", "01_ready", "", "", ""),
            ("".into(), false, false)
        );
        assert_eq!(
            plan("input", "02_exploring", "", "", ""),
            ("".into(), false, false)
        );
    }

    #[test]
    fn body() {
        assert_eq!(
            signal_body("turn-end", "", "04_spec_review", "x.md", ""),
            "Spec ready for review: x.md"
        );
        assert_eq!(
            signal_body("turn-end", "", "06_plan_review", "", "p.md"),
            "Plan ready for review: p.md"
        );
        assert_eq!(signal_body("error", "boom", "blocked", "", ""), "boom");
        assert_eq!(
            signal_body("stalled", "", "blocked", "", ""),
            "The session stopped."
        );
        assert_eq!(signal_body("input", "", "blocked", "", ""), "input");
    }

    #[test]
    fn children() {
        let active = r#"{"data":{"ses_k":{}}}"#;
        let kids =
            r#"{"data":[{"id":"ses_k","parentID":"ses_p"},{"id":"ses_o","parentID":"ses_p"}]}"#;
        assert_eq!(children_running("ses_p", active, kids), Some(true));
        assert_eq!(
            children_running("ses_p", r#"{"data":{}}"#, kids),
            Some(false)
        );
        // a child of another parent does not count
        let other = r#"{"data":[{"id":"ses_k","parentID":"ses_x"}]}"#;
        assert_eq!(children_running("ses_p", active, other), Some(false));
        // the session itself is not its own child
        let me = r#"{"data":[{"id":"ses_k"}]}"#;
        assert_eq!(children_running("ses_k", active, me), Some(false));
        let obj = r#"{"data":{"items":[{"id":"ses_k"}]}}"#;
        assert_eq!(children_running("ses_p", active, obj), Some(true));
        assert_eq!(children_running("ses_p", active, "garbage"), None);
        assert_eq!(children_running("ses_p", "garbage", kids), None);
    }
}
