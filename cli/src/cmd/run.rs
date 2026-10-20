//! One automation tick, `task run --once`, started by launchd every minute (lib/run.sh).

use crate::cmd::archive::archive_due;
use crate::cmd::auto::{auto_enabled, auto_file, auto_off, auto_plist, auto_unload};
use crate::cmd::edit::move_task;
use crate::cmd::session::on_path;
use crate::cmd::signal::{active_count, max_active, session_has_running_children};
use crate::commit::store_commit;
use crate::core::*;
use crate::frontmatter::*;
use crate::lock::{lock_acquire, lock_release};
use crate::preset::resolve_task_model;
use crate::projects::project_path;
use crate::subtasks::{oldest_unblocked_in, st_sweep};
use serde_json::{json, Map, Value};
use std::fs;
use std::io::Write;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::process::{Command, Stdio};

fn run_say(msg: impl AsRef<str>) {
    println!("[agent-tasks] {}", msg.as_ref());
}

/// Moves the task to blocked with a reason, under the lock.
fn run_block(id: &str, reason: &str) {
    lock_acquire();
    let f = task_file(id);
    let from = folder_of_file(&f);
    if from != "blocked" {
        move_task(&f, "blocked", "task", reason, "");
        store_commit();
    }
    lock_release();
    run_say(format!("{id}: {from} → blocked — {reason}"));
}

/// `opencode api <method> <path> [--data json]`: stdout when the request succeeds.
pub fn run_api(method: &str, path: &str, data: Option<&str>) -> Option<String> {
    let mut c = Command::new("opencode");
    c.args(["api", method, path]);
    if let Some(d) = data {
        c.args(["--data", d]);
    }
    let o = c
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if o.status.success() {
        Some(String::from_utf8_lossy(&o.stdout).into_owned())
    } else {
        None
    }
}

pub fn api_get(path: &str) -> Option<String> {
    run_api("get", path, None)
}

fn notify_marker(id: &str) -> String {
    format!("{}/.notify/{id}.auto-prompt", store())
}

/// Marks the task's next `input` signal as ours, not the user's (quiet rule):
/// the plugin's prompt hook also fires for prompts posted through the API.
fn run_mark_prompt(id: &str) {
    let _ = fs::create_dir_all(format!("{}/.notify", store()));
    let _ = fs::write(notify_marker(id), "");
}

/// Posts a prompt to a session; automated prompts carry metadata.agent_tasks.automated.
fn run_send_prompt(id: &str, session: &str, payload: Value) -> bool {
    let mut payload = payload;
    if let Value::Object(m) = &mut payload {
        m.insert("metadata".into(), json!({"agent_tasks": {"automated": true}}));
    }
    run_mark_prompt(id);
    if run_api(
        "post",
        &format!("/api/session/{session}/prompt"),
        Some(&payload.to_string()),
    )
    .is_none()
    {
        let _ = fs::remove_file(notify_marker(id));
        return false;
    }
    true
}

/// The "plan approved, implement it" prompt (also used by `task approve --now`).
pub fn run_send_implement(id: &str, session: &str) -> bool {
    run_send_prompt(
        id,
        session,
        json!({
            "text": "The implementation plan was approved. Implement it with subagent-driven-development, following the plan.",
            "skills": [{"id": "subagent-driven-development"}],
            "delivery": "queue"
        }),
    )
}

/// Sessions of 02/05/08 that do nothing for stale_minutes get `stalled`.
fn run_stale_check(active: &Value) {
    let mut stale = config_get("stale_minutes", "30");
    if stale.is_empty() || !stale.bytes().all(|b| b.is_ascii_digit()) {
        stale = "30".into();
    }
    let stale: i64 = stale.parse().unwrap_or(i64::MAX / 120);
    let now = epoch_now();
    let active_str = json!({ "data": active }).to_string();
    for f in all_task_files() {
        if !AGENT_FOLDERS.contains(&folder_of_file(&f).as_str()) {
            continue;
        }
        let s = fm_get(&f, "session");
        if s.is_empty() {
            continue;
        }
        let id = id_of_file(&f);
        if !valid_session(&s) {
            warn(format!("{id} has an invalid session field; skipped"));
            continue;
        }
        if active.as_object().map(|o| o.contains_key(&s)).unwrap_or(false) {
            continue;
        }
        let mtime = fs::metadata(&f).map(|m| m.mtime()).unwrap_or(0);
        if now - mtime < stale.saturating_mul(60) {
            continue;
        }
        if session_has_running_children(&s, &active_str) {
            continue;
        }
        run_say(format!("{id}: no activity for {stale} min"));
        let out = Command::new(task_bin())
            .args([
                "signal",
                &id,
                "stalled",
                "--session",
                &s,
                "--text",
                &format!("no activity for {stale} min"),
            ])
            .stdin(Stdio::null())
            .stderr(Stdio::inherit())
            .output();
        match out {
            Ok(o) => {
                let text = String::from_utf8_lossy(&o.stdout);
                let mut so = std::io::stdout();
                for l in text.split_inclusive('\n') {
                    let _ = write!(so, "[agent-tasks] {l}");
                }
                if !text.is_empty() && !text.ends_with('\n') {
                    let _ = writeln!(so);
                }
                if !o.status.success() {
                    // bash: the pipeline status is sed's, so this never fired; kept silent.
                }
            }
            Err(_) => warn(format!("signal stalled failed for {id}")),
        }
    }
}

/// 07_approved → 08_implementing, then tell the session to implement the plan.
fn run_continue(file: &str) {
    let id = id_of_file(file);
    lock_acquire();
    let f = task_file(&id);
    if folder_of_file(&f) != "07_approved" {
        lock_release();
        return;
    }
    let s = fm_get(&f, "session");
    if s.is_empty() {
        lock_release();
        run_block(&id, "approved task has no session to continue");
        return;
    }
    if !valid_session(&s) {
        lock_release();
        run_block(&id, &format!("{id} has an invalid session field"));
        return;
    }
    move_task(&f, "08_implementing", "task", "implementation starts (active period)", "");
    store_commit();
    lock_release();
    if !run_send_implement(&id, &s) {
        run_block(&id, &format!("could not send the implementation prompt to session {s}"));
        return;
    }
    run_say(format!("{id}: 07_approved → 08_implementing (session {s})"));
}

/// jq `@uri`: everything but unreserved characters is percent-encoded.
pub fn uri_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Glob `?*/?*`: a slash with something before and after it.
fn model_shaped(m: &str) -> bool {
    let b = m.as_bytes();
    b.iter()
        .enumerate()
        .any(|(i, c)| *c == b'/' && i > 0 && i + 1 < b.len())
}

/// 01_ready → 02_exploring in a new session started with brainstorming.
fn run_start(file: &str) {
    let id = id_of_file(file);
    let ws = ws_of_file(file);
    let project = fm_get(file, "project");
    if project.is_empty() {
        run_block(&id, "task has no project");
        return;
    }
    let dir = project_path(&ws, &project);
    if dir.is_empty() {
        run_block(&id, &format!("project {project} is not registered"));
        return;
    }
    if !Path::new(&dir).is_dir() {
        run_block(&id, &format!("project directory missing: {dir}"));
        return;
    }
    let title = fm_get(file, "title");
    let agent = config_get("agent", "");
    let model = config_get("model", "");
    if !model.is_empty() && !model_shaped(&model) {
        run_block(
            &id,
            &format!("invalid model '{model}' in config.toml (expected provider/model)"),
        );
        return;
    }
    let model_ref = match resolve_task_model() {
        Ok((r, _)) => r,
        Err(()) => {
            run_block(
                &id,
                &format!(
                    "preset '{}' not found in {}",
                    config_get("preset", ""),
                    slim_config_file()
                ),
            );
            return;
        }
    };
    let mut body = Map::new();
    body.insert("location".into(), json!({"directory": dir}));
    body.insert("title".into(), json!(format!("{id}: {title}")));
    body.insert("metadata".into(), json!({"agent_tasks": {"id": id}}));
    if !agent.is_empty() {
        body.insert("agent".into(), json!(agent));
    }
    if let Some(m) = model_ref {
        body.insert("model".into(), m);
    }
    let resp = run_api("post", "/api/session", Some(&Value::Object(body).to_string()))
        .unwrap_or_default();
    let s = serde_json::from_str::<Value>(&resp)
        .ok()
        .and_then(|v| v.pointer("/data/id").and_then(|x| x.as_str()).map(String::from))
        .unwrap_or_default();
    if !valid_session(&s) {
        run_block(&id, "could not create an OpenCode session");
        return;
    }

    lock_acquire();
    let f = task_file(&id);
    if folder_of_file(&f) != "01_ready" {
        lock_release();
        run_say(format!("{id}: left 01_ready meanwhile; session {s} is unused"));
        return;
    }
    let old = fm_get(&f, "session");
    if !old.is_empty() && old != s {
        log_append(&f, "task", &format!("restart: previous session {old}"));
    }
    if fm_set(&f, "session", &s).is_err() {
        die(format!("cannot update {f}"));
    }
    let f = move_task(&f, "02_exploring", "task", &format!("started session {s}"), "");
    store_commit();
    lock_release();

    let text = format!("You are working on task {id} (attached). Explore the codebase yourself first. Then ask the user your first question with the question tool: one question, with options and your recommendation. Do not start implementing.");
    // The path becomes a URI: percent-encode everything but "/" (a store path may contain spaces).
    let uri = format!(
        "file://{}",
        f.split('/').map(uri_encode).collect::<Vec<_>>().join("/")
    );
    let payload = json!({
        "text": text,
        "skills": [{"id": "brainstorming"}],
        "files": [{"uri": uri, "name": format!("{id}.md")}],
        "delivery": "queue"
    });
    if !run_send_prompt(&id, &s, payload) {
        run_block(&id, &format!("could not send the first prompt to session {s}"));
        return;
    }
    run_say(format!("{id}: 01_ready → 02_exploring (session {s})"));
}

pub fn cmd_run(args: &[String]) -> i32 {
    if args.len() != 1 || args[0] != "--once" {
        die("usage: task run --once");
    }
    // Before the .auto checks: archiving must also happen while automation is off.
    archive_due(false);
    crate::cmd::check_mrs::mr_check_due();
    st_sweep();
    if !Path::new(&auto_file()).is_file() {
        // A job left behind (e.g. `auto off` killed half-way): unload it.
        if Path::new(&auto_plist()).is_file() {
            let _ = fs::remove_file(auto_plist());
            auto_unload();
        }
        return 0;
    }
    if !auto_enabled() {
        // Message first: auto_off ends with a bootout that kills this job.
        run_say("automation off (the active period ended)");
        // auto_off prints "automation off" to stdout, which bash discarded.
        let _ = std::io::stdout().flush();
        auto_off_quiet();
        return 0;
    }
    lock_acquire();
    store_commit();
    lock_release();

    if !on_path("opencode") {
        eprintln!("[agent-tasks] opencode not found on PATH; nothing to do");
        return 1;
    }
    let active = api_get("/api/session/active")
        .and_then(|a| serde_json::from_str::<Value>(&a).ok())
        .and_then(|v| v.get("data").cloned())
        .filter(|d| d.is_object());
    match active {
        Some(a) => run_stale_check(&a),
        None => eprintln!(
            "[agent-tasks] cannot list active sessions (is OpenCode running?); stale check skipped"
        ),
    }

    let max = max_active();
    while (active_count() as u64) < max {
        if let Some(f) = oldest_unblocked_in(&["07_approved"]) {
            run_continue(&f);
            continue;
        }
        if let Some(f) = oldest_unblocked_in(&["01_ready"]) {
            run_start(&f);
            continue;
        }
        break;
    }
    0
}

/// `auto_off >/dev/null`: same effects, nothing printed.
fn auto_off_quiet() {
    // Redirect stdout to /dev/null around auto_off.
    unsafe {
        let saved = libc::dup(1);
        let null = libc::open(c"/dev/null".as_ptr(), libc::O_WRONLY);
        if null >= 0 {
            libc::dup2(null, 1);
            libc::close(null);
        }
        auto_off();
        if saved >= 0 {
            libc::dup2(saved, 1);
            libc::close(saved);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uri() {
        assert_eq!(uri_encode("a b"), "a%20b");
        assert_eq!(uri_encode("T-0001.md~_"), "T-0001.md~_");
        assert_eq!(uri_encode("é"), "%C3%A9");
    }

    #[test]
    fn model_glob() {
        assert!(model_shaped("a/b"));
        assert!(model_shaped("a/b/c"));
        assert!(!model_shaped("/b"));
        assert!(!model_shaped("a/"));
        assert!(!model_shaped("ab"));
    }
}
