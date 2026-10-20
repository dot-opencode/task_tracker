//! Auto-check of MR/PR state for tasks in 10_unmerged (port of lib/mrcheck.sh).

use crate::cmd::edit::move_task;
use crate::commit::store_commit;
use crate::core::{
    config_get, die, epoch_now, id_of_file, list_workspaces, read_file, store, task_files_in, warn,
};
use crate::frontmatter::{fm_get, fm_set, log_append};
use crate::lock::{lock_acquire, lock_held, lock_release};
use crate::subtasks::st_load;
use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn mr_debug(msg: &str) {
    if std::env::var("AGENT_TASKS_DEBUG")
        .map(|v| !v.is_empty())
        .unwrap_or(false)
    {
        warn(format!("mrcheck: {msg}"));
    }
}

fn have_cmd(name: &str) -> bool {
    let Ok(path) = std::env::var("PATH") else {
        return false;
    };
    path.split(':').any(|d| {
        let d = if d.is_empty() { "." } else { d };
        let p = format!("{d}/{name}");
        fs::metadata(&p)
            .map(|m| {
                use std::os::unix::fs::PermissionsExt;
                m.is_file() && m.permissions().mode() & 0o111 != 0
            })
            .unwrap_or(false)
    })
}

/// Runs a command with a ~15 s timeout; stdout on success.
fn mr_run(args: &[&str], envs: &[(&str, &str)]) -> Option<String> {
    let secs: f64 = std::env::var("AGENT_TASKS_MRCHECK_TIMEOUT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(15.0);
    let mut c = Command::new(args[0]);
    c.args(&args[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    for (k, v) in envs {
        c.env(k, v);
    }
    let mut child = c.spawn().ok()?;
    let mut stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = std::io::Read::read_to_end(&mut stdout, &mut buf);
        buf
    });
    let start = Instant::now();
    let deadline = Duration::from_secs_f64(secs.max(0.0));
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break Some(s),
            Ok(None) => {
                if start.elapsed() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(_) => break None,
        }
    };
    let buf = reader.join().unwrap_or_default();
    if !status?.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&buf).into_owned())
}

fn json_state(out: Option<String>) -> String {
    out.and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
        .and_then(|v| {
            v.get("state")
                .and_then(|s| s.as_str().map(|s| s.to_string()))
        })
        .unwrap_or_default()
}

fn leading_digits(s: &str) -> &str {
    let end = s
        .bytes()
        .position(|b| !b.is_ascii_digit())
        .unwrap_or(s.len());
    &s[..end]
}

/// merged|closed|open for a MR/PR URL; None when unknown.
fn mr_state(url: &str) -> Option<&'static str> {
    const MARK: &str = "/-/merge_requests/";
    if let Some(rest) = url.strip_prefix("https://") {
        if let Some(pos) = rest.find(MARK) {
            if rest[pos + MARK.len()..].starts_with(|c: char| c.is_ascii_digit()) {
                if !have_cmd("glab") {
                    mr_debug("glab not found");
                    return None;
                }
                let host = rest.split('/').next().unwrap_or("");
                let path = rest.split_once('/').map(|x| x.1).unwrap_or("");
                // bash: n = text after the last marker; proj = text before the first marker
                let n = leading_digits(path.rsplit_once(MARK).map(|x| x.1).unwrap_or(""));
                let proj = path.split(MARK).next().unwrap_or("").replace('/', "%2F");
                let api = format!("projects/{proj}/merge_requests/{n}");
                let envs: Vec<(&str, &str)> = if host != "gitlab.com" {
                    vec![("GITLAB_HOST", host)]
                } else {
                    vec![]
                };
                let st = json_state(mr_run(&["glab", "api", &api], &envs));
                return match st.as_str() {
                    "merged" => Some("merged"),
                    "closed" => Some("closed"),
                    "opened" | "locked" => Some("open"),
                    _ => {
                        mr_debug(&format!("glab: no state for {url}"));
                        None
                    }
                };
            }
        }
        // https://github.com/*/*/pull/[0-9]*
        if let Some(r) = rest.strip_prefix("github.com/") {
            // glob `*` spans slashes: need "<x>/<y>...pull/<digit>..."
            if let Some(p) = r.find("/pull/") {
                let before = &r[..p];
                if before.contains('/')
                    && !before.starts_with('/')
                    && !before.ends_with('/')
                    && r[p + 6..].starts_with(|c: char| c.is_ascii_digit())
                {
                    if !have_cmd("gh") {
                        mr_debug("gh not found");
                        return None;
                    }
                    let st = json_state(mr_run(&["gh", "pr", "view", url, "--json", "state"], &[]));
                    return match st.as_str() {
                        "MERGED" => Some("merged"),
                        "CLOSED" => Some("closed"),
                        "OPEN" => Some("open"),
                        _ => {
                            mr_debug(&format!("gh: no state for {url}"));
                            None
                        }
                    };
                }
            }
        }
    }
    None
}

/// Checks every unmerged task with a pr URL. Output lines (per task) go to
/// stdout only when `force`.
fn mr_check_run(force: bool) {
    let st = store();
    let mut files = Vec::new();
    for ws in list_workspaces() {
        for f in task_files_in(&format!("{st}/{ws}/10_unmerged")) {
            if !fm_get(&f, "pr").is_empty() {
                files.push(f);
            }
        }
    }
    let _ = fs::create_dir_all(format!("{st}/.notify"));
    let _ = fs::write(
        format!("{st}/.notify/mrcheck.last"),
        format!("{}\n", epoch_now()),
    );
    if files.is_empty() {
        if force {
            println!("no unmerged tasks with a pr link");
        }
        return;
    }
    let took = !lock_held();
    lock_acquire();
    let mut n = 0;
    for f in &files {
        if !Path::new(f).exists() {
            continue;
        }
        let url = fm_get(f, "pr");
        let tid = id_of_file(f);
        let line = match mr_state(&url) {
            Some("merged") => {
                let open = st_load().open_list(&tid);
                if !open.is_empty() {
                    if force {
                        println!("{tid}: merged, waiting for subtasks: {open}");
                    }
                    continue;
                }
                let moved = move_task(f, "11_done", "task", "MR merged (auto-check)", "merged");
                let _ = fm_set(&moved, "result", "merged");
                let _ = fs::remove_file(format!("{st}/.notify/{tid}.mrclosed"));
                n += 1;
                format!("{tid}: merged → 11_done")
            }
            Some("closed") => {
                let marker = format!("{st}/.notify/{tid}.mrclosed");
                if !Path::new(&marker).is_file() {
                    log_append(
                        f,
                        "task",
                        &format!(
                            "MR closed without merge; run task done {tid} --result discarded or keep working"
                        ),
                    );
                    let _ = fs::write(&marker, "");
                    n += 1;
                }
                format!("{tid}: closed without merge")
            }
            Some(_) => format!("{tid}: open"),
            None => format!("{tid}: unknown (check skipped)"),
        };
        if force {
            println!("{line}");
        }
    }
    if n > 0 {
        store_commit();
    }
    if took {
        lock_release();
    }
    if n > 0 && !force {
        eprintln!("merged {n} task(s)");
    }
}

/// Cheap when not due: a config read and a timestamp compare.
pub fn mr_check_due() {
    if std::env::var("AGENT_TASKS_MRCHECK").unwrap_or_else(|_| "1".into()) == "0" {
        return;
    }
    let mins = config_get("mr_check_minutes", "10");
    if mins.is_empty() || !mins.bytes().all(|b| b.is_ascii_digit()) {
        return;
    }
    let mins: i64 = mins.parse().unwrap_or(0);
    if mins <= 0 {
        return;
    }
    let last = read_file(&format!("{}/.notify/mrcheck.last", store()))
        .map(|t| t.split('\n').next().unwrap_or("").to_string())
        .unwrap_or_default();
    let last: i64 = if !last.is_empty() && last.bytes().all(|b| b.is_ascii_digit()) {
        last.parse().unwrap_or(0)
    } else {
        0
    };
    if epoch_now() - last < mins * 60 {
        return;
    }
    mr_check_run(false);
}

pub fn cmd_check_mrs(args: &[String]) -> i32 {
    if !args.is_empty() {
        die("usage: task check-mrs");
    }
    mr_check_run(true);
    0
}
