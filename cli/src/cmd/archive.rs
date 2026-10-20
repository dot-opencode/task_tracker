//! Archive: done tasks that stay finished for archive_after_days leave the view (lib/archive.sh).

use crate::cmd::edit::move_task;
use crate::commit::store_commit;
use crate::core::*;
use crate::frontmatter::fm_require;
use crate::lock::{lock_acquire, lock_held, lock_release};
use std::fs;

/// "Now" as `YYYY-MM-DD HH:MM` (local time, like the log). AGENT_TASKS_NOW is a
/// test affordance and takes the same format.
pub fn archive_now() -> String {
    match std::env::var("AGENT_TASKS_NOW") {
        Ok(v) if !v.is_empty() => v,
        _ => date_ymd_hm(),
    }
}

/// Minutes since the epoch (days-from-civil) of `YYYY-MM-DD` + `HH:MM`, awk-lenient.
fn mins(d: &str, t: &str) -> i64 {
    let num = |s: Option<&str>| -> i64 { leading_int(s.unwrap_or("")) };
    let mut it = d.split('-');
    let mut y = num(it.next());
    let m = num(it.next());
    let dd = num(it.next());
    let mut tt = t.split(':');
    let hh = num(tt.next());
    let mm = num(tt.next());
    if m <= 2 {
        y -= 1;
    }
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + dd - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    (era * 146097 + doe) * 1440 + hh * 60 + mm
}

/// awk string-to-number: leading digits, else 0.
fn leading_int(s: &str) -> i64 {
    let digits: String = s.trim_start().chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().unwrap_or(0)
}

fn is_date_prefix(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() >= 10
        && b[..10].iter().enumerate().all(|(i, c)| match i {
            4 | 7 => *c == b'-',
            _ => c.is_ascii_digit(),
        })
}

/// `YYYY-MM-DD HH:MM ` prefix of a log entry (after "- ").
fn is_log_entry(rest: &str) -> bool {
    let b = rest.as_bytes();
    b.len() >= 17
        && is_date_prefix(rest)
        && b[10] == b' '
        && b[11].is_ascii_digit()
        && b[12].is_ascii_digit()
        && b[13] == b':'
        && b[14].is_ascii_digit()
        && b[15].is_ascii_digit()
        && b[16] == b' '
}

/// `imported from ai_task_tracker (status X, archived[,)]`
fn is_import_archived(msg: &str) -> bool {
    let Some(rest) = msg.strip_prefix("imported from ai_task_tracker (status ") else {
        return false;
    };
    // [^,)]+ then ", archived" followed by , or )
    let Some(end) = rest.find([',', ')']) else {
        return false;
    };
    if end == 0 || rest.as_bytes()[end] != b',' {
        return false;
    }
    match rest[end + 1..].strip_prefix(" archived") {
        Some(r) => r.starts_with(',') || r.starts_with(')'),
        None => false,
    }
}

/// (path, why) for every task in `dir` that was archived in ai_task_tracker
/// (`import`) or whose done age is at least `days` days (`age`).
/// Done age: now minus the newest `## Log` entry that is not an import/migration
/// marker; without one, the `created` date.
pub fn archive_due_files(days: i64, dir: &str) -> Vec<(String, &'static str)> {
    let now = archive_now();
    let mut it = now.split(' ');
    let nowm = mins(it.next().unwrap_or(""), it.next().unwrap_or(""));
    let mut wss: Vec<String> = Vec::new();
    if let Ok(rd) = fs::read_dir(store()) {
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if !n.starts_with('.') {
                wss.push(n);
            }
        }
    }
    wss.sort();
    let mut out = Vec::new();
    for ws in wss {
        for f in task_files_in(&format!("{}/{}/{}", store(), ws, dir)) {
            let Some(text) = read_file(&f) else { continue };
            if text.is_empty() {
                continue;
            }
            let mut created: Option<i64> = None;
            let mut last: Option<i64> = None;
            let (mut fm, mut inlog, mut arch) = (0, false, false);
            for (n, line) in text.split('\n').enumerate() {
                if n == 0 && line == "---" {
                    fm = 1;
                    continue;
                }
                if fm == 1 {
                    if line == "---" {
                        fm = 2;
                        continue;
                    }
                    if let Some(v) = line.strip_prefix("created:") {
                        let v = v.trim_start_matches([' ', '\t']);
                        if is_date_prefix(v) {
                            created = Some(mins(&v[..10], "00:00"));
                        }
                    }
                    continue;
                }
                if line == "## Log" {
                    inlog = true;
                    continue;
                }
                if inlog && line.starts_with("- ") && is_log_entry(&line[2..]) {
                    let rest = &line[2..];
                    let (d, t) = (&rest[..10], &rest[11..16]);
                    let mut msg = &rest[17..];
                    if let Some(i) = msg.find(": ") {
                        msg = &msg[i + 2..];
                    }
                    if is_import_archived(msg) {
                        arch = true;
                    }
                    if msg.starts_with("imported from ai_task_tracker")
                        || msg.starts_with("folder layout migration")
                    {
                        continue;
                    }
                    let v = mins(d, t);
                    if last.map(|l| v > l).unwrap_or(true) {
                        last = Some(v);
                    }
                }
            }
            if arch {
                out.push((f, "import"));
                continue;
            }
            let last = last.or(created);
            if let Some(l) = last {
                if nowm - l >= days * 1440 {
                    out.push((f, "age"));
                }
            }
        }
    }
    out
}

/// Moves every due task to archive in one commit. Silent and lock-free when
/// nothing is due (it runs often); prints `archived N task(s)` otherwise
/// (to stderr when `to_stderr`). Returns the number archived.
pub fn archive_due(to_stderr: bool) -> usize {
    let days = config_get("archive_after_days", "14");
    if days.is_empty() || !days.bytes().all(|b| b.is_ascii_digit()) {
        return 0;
    }
    let days: i64 = days.parse().unwrap_or(0);
    if days <= 0 {
        return 0;
    }
    if archive_due_files(days, "11_done").is_empty() {
        return 0;
    }
    let took = !lock_held();
    lock_acquire();
    let due = archive_due_files(days, "11_done");
    let mut n = 0;
    for (f, why) in due {
        if why == "import" {
            move_task(&f, "archive", "task", "archived (already archived in ai_task_tracker)", "");
        } else {
            move_task(&f, "archive", "task", &format!("archived after {days} days in done"), "");
        }
        n += 1;
    }
    if n > 0 {
        store_commit();
        if to_stderr {
            eprintln!("archived {n} task(s)");
        } else {
            println!("archived {n} task(s)");
        }
    }
    if took {
        lock_release();
    }
    n
}

pub fn cmd_archive(args: &[String]) -> i32 {
    const USAGE: &str = "usage: task archive <id> | --due";
    let mut id = String::new();
    let mut due = false;
    for a in args {
        match a.as_str() {
            "--due" => due = true,
            s if s.starts_with('-') => die(format!("unknown option: {s}")),
            s => {
                if !id.is_empty() {
                    die(USAGE);
                }
                id = s.to_string();
            }
        }
    }
    if due {
        if !id.is_empty() {
            die(USAGE);
        }
        if archive_due(false) == 0 {
            println!("nothing to archive");
        }
        return 0;
    }
    if id.is_empty() {
        die(USAGE);
    }
    lock_acquire();
    let f = task_file(&id);
    fm_require(&f);
    let tid = normalize_id(&id).unwrap();
    let from = folder_of_file(&f);
    if from != "11_done" {
        die(format!("{tid} is in {from}; only done tasks can be archived"));
    }
    move_task(&f, "archive", "task", "archived", "");
    store_commit();
    println!("{tid}: 11_done → archive");
    0
}

pub fn cmd_unarchive(args: &[String]) -> i32 {
    if args.len() != 1 {
        die("usage: task unarchive <id>");
    }
    lock_acquire();
    let f = task_file(&args[0]);
    fm_require(&f);
    let tid = normalize_id(&args[0]).unwrap();
    let from = folder_of_file(&f);
    if from != "archive" {
        die(format!("{tid} is in {from}; not archived"));
    }
    move_task(&f, "11_done", "task", "unarchived", "");
    store_commit();
    println!("{tid}: archive → 11_done");
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minutes() {
        assert_eq!(mins("1970-01-02", "01:30") - mins("1970-01-01", "00:00"), 1440 + 90);
        assert!(mins("2026-10-02", "00:00") > mins("2026-10-01", "23:59"));
    }

    #[test]
    fn import_marker() {
        assert!(is_import_archived(
            "imported from ai_task_tracker (status done, archived)"
        ));
        assert!(is_import_archived(
            "imported from ai_task_tracker (status done, archived, x)"
        ));
        assert!(!is_import_archived(
            "imported from ai_task_tracker (status done)"
        ));
    }
}
