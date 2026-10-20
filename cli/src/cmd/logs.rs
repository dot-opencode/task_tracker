//! task logs: the automation worker log and a task's own `## Log` section
//! (port of lib/logs.sh).

use crate::core::{
    all_task_files, basename, die, folder_of_file, need_value, normalize_id, read_file, task_file,
};
use crate::frontmatter::fm_get;
use std::os::unix::process::CommandExt;
use std::process::Command;
use std::time::Duration;

const LOGS_USAGE: &str = "usage: task logs [<id>] [-n N] [-f]";

/// Also used by auto (launchd StandardOutPath / StandardErrorPath).
pub fn worker_log_path() -> String {
    format!(
        "{}/Library/Logs/agent-tasks.log",
        std::env::var("HOME").unwrap_or_default()
    )
}

/// Non-empty lines after the `## Log` heading (looked up only after the closing frontmatter `---`).
pub fn log_lines_of(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut infm = false;
    let mut inlog = false;
    for (i, line) in text.split('\n').enumerate() {
        if i == 0 && line == "---" {
            infm = true;
            continue;
        }
        if infm {
            if line == "---" {
                infm = false;
            }
            continue;
        }
        if inlog {
            if !line.is_empty() {
                out.push(line.to_string());
            }
            continue;
        }
        if line == "## Log" {
            inlog = true;
        }
    }
    out
}

fn tail_of(lines: &[String], n: usize) -> &[String] {
    &lines[lines.len().saturating_sub(n)..]
}

fn logs_worker(n: usize, follow: bool) {
    let path = worker_log_path();
    if !std::path::Path::new(&path).is_file() {
        println!("no worker log yet ({path}): automation has not run");
        return;
    }
    let mut c = Command::new("tail");
    c.arg("-n").arg(n.to_string());
    if follow {
        c.arg("-F").arg(&path);
        let e = c.exec();
        die(format!("cannot run tail: {e}"));
    }
    c.arg(&path);
    let _ = c.status();
}

enum Lookup {
    Found(String),
    Duplicate,
    Missing,
}

fn lookup(id: &str) -> Lookup {
    let exact = format!("{id}.md");
    let pref = format!("{id}-");
    let mut n = 0;
    let mut found = String::new();
    for f in all_task_files() {
        let b = basename(&f);
        if b == exact || (b.starts_with(&pref) && b.ends_with(".md")) {
            n += 1;
            if n == 1 {
                found = f;
            }
        }
    }
    match n {
        0 => Lookup::Missing,
        1 => Lookup::Found(found),
        _ => Lookup::Duplicate,
    }
}

fn logs_task(raw: &str, n: usize, follow: bool) {
    let id = normalize_id(raw).unwrap_or_else(|| die(format!("invalid task id '{raw}'")));
    let mut f = task_file(&id);
    let mut folder = folder_of_file(&f);
    println!("{} · {} · {}", id, folder, fm_get(&f, "title"));
    let all = log_lines_of(&read_file(&f).unwrap_or_default());
    let mut printed = all.len();
    for l in tail_of(&all, n) {
        println!("{l}");
    }
    if !follow {
        return;
    }
    let polls: Option<u64> = match std::env::var("AGENT_TASKS_LOGS_POLLS") {
        Ok(v) if !v.is_empty() => Some(v.parse().unwrap_or(0)),
        _ => None,
    };
    let interval: f64 = match std::env::var("AGENT_TASKS_LOGS_INTERVAL") {
        Ok(v) if !v.is_empty() => v.parse().unwrap_or(1.0),
        _ => 1.0,
    };
    let mut i = 0u64;
    while polls.map(|p| i < p).unwrap_or(true) {
        std::thread::sleep(Duration::from_secs_f64(interval.max(0.0)));
        i += 1;
        match lookup(&id) {
            Lookup::Duplicate => continue, // mid-move or a broken store: look again next time
            Lookup::Missing => {
                println!("-- task no longer exists");
                return;
            }
            Lookup::Found(nf) => f = nf,
        }
        let Some(text) = read_file(&f) else { continue }; // moved right after the lookup
        let all = log_lines_of(&text);
        if all.len() > printed {
            for l in &all[printed..] {
                println!("{l}");
            }
        }
        printed = all.len();
        let nfolder = folder_of_file(&f);
        if nfolder != folder {
            println!("-- moved to {nfolder}");
            folder = nfolder;
        }
    }
}

pub fn cmd_logs(args: &[String]) -> i32 {
    let mut n: Option<usize> = None;
    let mut follow = false;
    let mut id = String::new();
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "-n" => {
                let v = need_value(args, i);
                if v.is_empty() || !v.bytes().all(|b| b.is_ascii_digit()) {
                    die(format!("invalid -n '{v}'"));
                }
                n = Some(v.parse().unwrap_or(usize::MAX));
                i += 2;
            }
            "-f" => {
                follow = true;
                i += 1;
            }
            _ if a.starts_with('-') => die(LOGS_USAGE),
            _ => {
                if !id.is_empty() {
                    die(LOGS_USAGE);
                }
                id = a.to_string();
                i += 1;
            }
        }
    }
    if id.is_empty() {
        logs_worker(n.unwrap_or(50), follow);
    } else {
        logs_task(&id, n.unwrap_or(20), follow);
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn log_lines() {
        let t = "---\nid: T-1\n---\n\nbody\n## Log\n- a\n\n  cont\n- b\n";
        assert_eq!(log_lines_of(t), vec!["- a", "  cont", "- b"]);
        assert!(log_lines_of("---\nid: x\n---\nJust a body.\n").is_empty());
    }
}
