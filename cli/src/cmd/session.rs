//! Binding OpenCode sessions to tasks (lib/session.sh).

use crate::commit::store_commit;
use crate::core::*;
use crate::frontmatter::*;
use crate::lock::lock_acquire;
use serde_json::{json, Value};
use std::process::{Command, Stdio};

/// Ids of the tasks whose `session` equals `session`.
pub fn find_by_session(session: &str) -> Vec<String> {
    let files = all_task_files();
    task_rows(&files)
        .into_iter()
        .filter(|r| r.session == session)
        .map(|r| id_of_file(&r.path))
        .collect()
}

pub fn cmd_find(args: &[String]) -> i32 {
    if args.len() != 2 || args[0] != "--session" {
        die("usage: task find --session <session-id>");
    }
    if !valid_session(&args[1]) {
        die(format!("invalid session id '{}'", args[1]));
    }
    let ids = find_by_session(&args[1]);
    if ids.is_empty() {
        return 1;
    }
    for id in ids {
        println!("{id}");
    }
    0
}

pub fn on_path(cmd: &str) -> bool {
    std::env::var("PATH")
        .unwrap_or_default()
        .split(':')
        .any(|d| {
            let p = std::path::Path::new(if d.is_empty() { "." } else { d }).join(cmd);
            std::fs::metadata(&p)
                .map(|m| {
                    use std::os::unix::fs::PermissionsExt;
                    m.is_file() && m.permissions().mode() & 0o111 != 0
                })
                .unwrap_or(false)
        })
}

pub fn cmd_bind(args: &[String]) -> i32 {
    const USAGE: &str = "usage: task bind <id> --session <session-id>";
    let (mut id, mut session) = (String::new(), String::new());
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        if a == "--session" {
            session = need_value(args, i).to_string();
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
    if id.is_empty() || session.is_empty() {
        die(USAGE);
    }
    let tid = normalize_id(&id).unwrap_or_else(|| die(format!("invalid task id '{id}'")));
    if !valid_session(&session) {
        die(format!("invalid session id '{session}'"));
    }
    if !on_path("opencode") {
        die("opencode not found on PATH");
    }
    let notfound = || -> ! {
        die(format!(
            "session {session} not found (is OpenCode running?)"
        ))
    };
    let out = Command::new("opencode")
        .args(["api", "get", &format!("/api/session/{session}")])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output();
    let resp = match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
        _ => notfound(),
    };
    let v: Value = serde_json::from_str(&resp).unwrap_or_else(|_| notfound());
    if v.pointer("/data/id").and_then(|x| x.as_str()) != Some(session.as_str()) {
        notfound();
    }
    let mut merged = match v.pointer("/data/metadata") {
        Some(Value::Object(m)) => m.clone(),
        _ => serde_json::Map::new(),
    };
    merged.insert("agent_tasks".into(), json!({ "id": tid }));
    let payload = json!({ "metadata": Value::Object(merged) }).to_string();

    lock_acquire();
    let f = task_file(&tid);
    fm_require(&f);
    for other in find_by_session(&session) {
        if other != tid {
            die(format!("session {session} is already bound to {other}"));
        }
    }
    let ok = Command::new("opencode")
        .args([
            "api",
            "patch",
            &format!("/api/session/{session}"),
            "--data",
            &payload,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !ok {
        die(format!(
            "could not update metadata of session {session}; {tid} left unchanged"
        ));
    }
    if fm_set(&f, "session", &session).is_err() {
        die(format!("cannot update {f}"));
    }
    log_append(&f, "agent", &format!("bound session {session}"));
    store_commit();
    println!("{tid}: bound to {session}");
    0
}
