//! Auto-commit of the store with messages built from the staged diff (lib/commit.sh).

use crate::core::{self, die, git_out, store, FOLDERS};

/// `<ws>/<folder>/T-NNNN[-slug].md` -> (ws, id, folder).
pub fn parse_task_path(path: &str) -> Option<(String, String, String)> {
    let parts: Vec<&str> = path.split('/').collect();
    if parts.len() != 3 {
        // `*/*/*` needs at least 3 parts; more than 3 means the file part has a '/'
        return None;
    }
    let (ws, folder, file) = (parts[0], parts[1], parts[2]);
    let b = file.as_bytes();
    if !(file.starts_with("T-") && b.len() >= 3 && b[2].is_ascii_digit() && file.ends_with(".md"))
        || file.len() < 6
    {
        return None;
    }
    if !FOLDERS.contains(&folder) {
        return None;
    }
    Some((ws.to_string(), core::id_of_file(file), folder.to_string()))
}

/// `YYYY-MM-DD ` prefix.
fn is_log_date_line(rest: &str) -> bool {
    let b = rest.as_bytes();
    if b.len() < 11 {
        return false;
    }
    let digit = |i: usize| b[i].is_ascii_digit();
    digit(0)
        && digit(1)
        && digit(2)
        && digit(3)
        && b[4] == b'-'
        && digit(5)
        && digit(6)
        && b[7] == b'-'
        && digit(8)
        && digit(9)
        && b[10] == b' '
}

/// True when the staged change of a task file only appends log-like lines.
fn staged_log_only(path: &str) -> bool {
    let out = git_out(&["diff", "--cached", "-U0", "--no-color", "--", path]);
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    let text = text.trim_end_matches('\n');
    let mut inhunk = false;
    for line in text.split('\n') {
        if line.starts_with("@@") {
            inhunk = true;
            continue;
        }
        if !inhunk {
            continue;
        }
        let ok = if let Some(rest) = line.strip_prefix("+- ") {
            is_log_date_line(rest)
        } else {
            line.starts_with("+  ") || line == "+" || line == "+## Log" || line.starts_with('\\')
        };
        if !ok {
            return false;
        }
    }
    true
}

/// Pairs delete+add of the same task id into synthetic rename lines.
fn pair_task_moves(lines: &[Vec<String>]) -> Vec<Vec<String>> {
    fn key(p: &str) -> Option<String> {
        let a: Vec<&str> = p.split('/').collect();
        if a.len() != 3 {
            return None;
        }
        let fname = a[2];
        if !fname.starts_with("T-") {
            return None;
        }
        let digits: String = fname[2..]
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect();
        if digits.is_empty() {
            return None;
        }
        let n: u64 = digits.parse().unwrap_or(0);
        Some(format!("{}/{}", a[0], n))
    }
    let n = lines.len();
    let st = |i: usize| lines[i][0].chars().next().unwrap_or(' ');
    let p1 = |i: usize| lines[i].get(1).cloned().unwrap_or_default();
    let dk: Vec<Option<String>> = (0..n)
        .map(|i| if st(i) == 'D' { key(&p1(i)) } else { None })
        .collect();
    let ak: Vec<Option<String>> = (0..n)
        .map(|i| if st(i) == 'A' { key(&p1(i)) } else { None })
        .collect();
    let mut used = vec![false; n];
    let mut mate: Vec<Option<usize>> = vec![None; n];
    for i in 0..n {
        let Some(k) = &dk[i] else { continue };
        for j in 0..n {
            if !used[j] && ak[j].as_ref() == Some(k) {
                used[j] = true;
                mate[i] = Some(j);
                break;
            }
        }
    }
    let mut out = Vec::new();
    for i in 0..n {
        if used[i] {
            continue;
        }
        if let Some(j) = mate[i] {
            out.push(vec!["R".to_string(), p1(i), p1(j)]);
        } else {
            out.push(lines[i].clone());
        }
    }
    out
}

fn commit_message() -> String {
    let out = git_out(&[
        "-c",
        "core.quotepath=false",
        "diff",
        "--cached",
        "--name-status",
        "-M",
    ]);
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    let raw: Vec<Vec<String>> = text
        .split('\n')
        .filter(|l| !l.is_empty())
        .map(|l| l.split('\t').map(|s| s.to_string()).collect())
        .collect();
    let rows = pair_task_moves(&raw);

    let mut n = 0usize;
    let mut ids: Vec<String> = Vec::new();
    let mut entries: Vec<(String, String)> = Vec::new();
    for r in &rows {
        let status = &r[0];
        if status.is_empty() {
            continue;
        }
        let p1 = r.get(1).cloned().unwrap_or_default();
        let p2 = r.get(2).cloned().unwrap_or_default();
        let code = status.chars().next().unwrap();
        let mut ws = String::new();
        if let Some((w, _)) = p1.split_once('/') {
            if std::path::Path::new(&format!("{}/{}/00_backlog", store(), w)).is_dir() {
                ws = w.to_string();
            }
        }
        let desc;
        match code {
            'R' => {
                let a = parse_task_path(&p1);
                let b = parse_task_path(&p2);
                match (a, b) {
                    (Some((_, old_id, old_folder)), Some((tws, tid, tfolder))) if tid == old_id => {
                        desc = if old_folder == tfolder {
                            format!("{tid} edit")
                        } else {
                            format!("{tid} {old_folder} → {tfolder}")
                        };
                        ids.push(tid);
                        ws = tws;
                    }
                    _ => desc = format!("rename {p1} → {p2}"),
                }
            }
            'A' | 'M' | 'D' => {
                if let Some((tws, tid, _)) = parse_task_path(&p1) {
                    ids.push(tid.clone());
                    ws = tws;
                    desc = match code {
                        'A' => format!("{tid} new"),
                        'D' => format!("{tid} deleted"),
                        _ => {
                            if staged_log_only(&p1) {
                                format!("{tid} log")
                            } else {
                                format!("{tid} edit")
                            }
                        }
                    };
                } else {
                    let rel = p1.split_once('/').map(|x| x.1).unwrap_or(&p1);
                    if let Some(name) = rel.strip_prefix(".projects/") {
                        let verb = match code {
                            'A' => "added",
                            'D' => "removed",
                            _ => "updated",
                        };
                        desc = format!("project {name} {verb}");
                    } else {
                        desc = match code {
                            'A' => format!("add {p1}"),
                            'D' => format!("delete {p1}"),
                            _ => format!("update {p1}"),
                        };
                    }
                }
            }
            _ => desc = format!("update {p1}"),
        }
        n += 1;
        entries.push((ws, desc));
    }

    if n == 1 {
        let (ws, desc) = &entries[0];
        return if ws.is_empty() {
            format!("tasks: {desc}")
        } else {
            format!("tasks({ws}): {desc}")
        };
    }
    ids.sort();
    ids.dedup();
    let m = ids.len();
    let mut msg = if m == 0 {
        format!("tasks: {n} changes\n\n")
    } else if m == 1 {
        format!("tasks: {n} changes in 1 task\n\n")
    } else {
        format!("tasks: {n} changes in {m} tasks\n\n")
    };
    for (ws, desc) in &entries {
        if !ws.is_empty() || !desc.is_empty() {
            if ws.is_empty() {
                msg.push_str(&format!("- {desc}\n"));
            } else {
                msg.push_str(&format!("- {ws}: {desc}\n"));
            }
        }
    }
    msg.trim_end_matches('\n').to_string()
}

/// Commits everything that changed, including manual edits. false = nothing to commit.
pub fn store_commit() -> bool {
    let st = store();
    if !core::git_ok(&["add", "-A"]) {
        die(format!("git add failed in {st}"));
    }
    let rc = std::process::Command::new("git")
        .arg("-C")
        .arg(st)
        .args(["diff", "--cached", "--quiet"])
        .status()
        .ok()
        .and_then(|s| s.code())
        .unwrap_or(-1);
    match rc {
        0 => return false,
        1 => {}
        c => die(format!("git diff failed in {st} (exit {c})")),
    }
    let msg = commit_message();
    if !core::git_ok(&["commit", "-q", "-m", &msg]) {
        die(format!(
            "commit failed in {st} — is git user.name / user.email configured?"
        ));
    }
    true
}

pub fn cmd_backup(args: &[String]) -> i32 {
    if !args.is_empty() {
        die("usage: task backup");
    }
    crate::lock::lock_acquire();
    if store_commit() {
        println!("backed up");
    } else {
        println!("nothing to back up");
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_paths() {
        assert_eq!(
            parse_task_path("work/01_ready/T-0001-x.md"),
            Some(("work".into(), "T-0001".into(), "01_ready".into()))
        );
        assert_eq!(parse_task_path("work/nope/T-0001.md"), None);
        assert_eq!(parse_task_path("work/01_ready/x.md"), None);
        assert_eq!(parse_task_path("work/.projects/api"), None);
    }

    #[test]
    fn pairs_moves() {
        let l = vec![
            vec!["D".to_string(), "w/00_backlog/T-0001-a.md".to_string()],
            vec!["A".to_string(), "w/11_done/T-0001-a.md".to_string()],
        ];
        let o = pair_task_moves(&l);
        assert_eq!(o.len(), 1);
        assert_eq!(
            o[0],
            vec!["R", "w/00_backlog/T-0001-a.md", "w/11_done/T-0001-a.md"]
        );
    }
}
