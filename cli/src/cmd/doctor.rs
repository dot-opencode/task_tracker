//! Read-only consistency checks of the store (lib/doctor.sh).

use crate::core::*;
use crate::preset::preset_model_ref;
use crate::projects::project_path;
use crate::subtasks::st_load;
use std::fs;
use std::path::Path;

/// Gregorian calendar validation of YYYY-MM-DD.
pub fn valid_calendar_date(date: &str) -> bool {
    let b = date.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return false;
    }
    if !b
        .iter()
        .enumerate()
        .all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit())
    {
        return false;
    }
    let year: i64 = date[..4].parse().unwrap_or(0);
    let month = &date[5..7];
    let day: i64 = date[8..].parse().unwrap_or(0);
    let max = match month {
        "01" | "03" | "05" | "07" | "08" | "10" | "12" => 31,
        "04" | "06" | "09" | "11" => 30,
        "02" => {
            if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) {
                29
            } else {
                28
            }
        }
        _ => return false,
    };
    day >= 1 && day <= max
}

const KNOWN: [&str; 16] = [
    "id",
    "title",
    "project",
    "created",
    "source",
    "session",
    "spec",
    "plan",
    "pr",
    "blocked_from",
    "postponed_from",
    "result",
    "worktree",
    "legacy_id",
    "parent",
    "depends_on",
];

fn unq(v: &str) -> String {
    let b = v.as_bytes();
    if b.len() >= 2 && b[0] == b'"' && b[b.len() - 1] == b'"' {
        let inner: Vec<char> = v[1..v.len() - 1].chars().collect();
        let n = inner.len();
        let mut out = String::new();
        let mut i = 0;
        while i < n {
            let mut c = inner[i];
            if c == '\\' && i + 1 < n {
                i += 1;
                c = inner[i];
            }
            out.push(c);
            i += 1;
        }
        return out;
    }
    v.to_string()
}

enum Item {
    Problem(String),
    Field(String, String),
    NoFrontmatter,
}

/// Structure of one task file (the awk of doctor_scan).
fn doctor_scan(text: &str) -> Vec<Item> {
    let mut out = Vec::new();
    let mut lines: Vec<&str> = text.split('\n').collect();
    if text.ends_with('\n') || text.is_empty() {
        lines.pop();
    }
    let mut state = 0;
    let (mut nofm, mut closed, mut haslog) = (false, false, false);
    let mut seen: Vec<String> = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        if *line == "## Log" {
            haslog = true;
        }
        if i == 0 {
            if *line != "---" {
                out.push(Item::Problem("no frontmatter".into()));
                out.push(Item::NoFrontmatter);
                state = 2;
                nofm = true;
            } else {
                state = 1;
            }
            continue;
        }
        if state == 1 {
            if *line == "---" {
                state = 2;
                closed = true;
                continue;
            }
            let b = line.as_bytes();
            let shaped = !b.is_empty() && (b[0].is_ascii_lowercase() || b[0] == b'_') && {
                let key_len = b
                    .iter()
                    .take_while(|c| c.is_ascii_lowercase() || **c == b'_')
                    .count();
                b.get(key_len) == Some(&b':')
            };
            if shaped {
                let p = line.find(':').unwrap();
                let after = line.as_bytes().get(p + 1).copied();
                if after.is_some() && after != Some(b' ') {
                    out.push(Item::Problem(format!("bad frontmatter line '{line}'")));
                    continue;
                }
                let k = &line[..p];
                let v = if line.len() > p + 2 {
                    &line[p + 2..]
                } else {
                    ""
                };
                if seen.iter().any(|s| s == k) {
                    out.push(Item::Problem(format!("duplicate key '{k}'")));
                }
                seen.push(k.to_string());
                if !KNOWN.contains(&k) {
                    out.push(Item::Problem(format!("unknown key '{k}'")));
                } else {
                    if k == "title" && v.contains('\t') {
                        out.push(Item::Problem("title contains a tab".into()));
                    }
                    out.push(Item::Field(k.to_string(), unq(v)));
                }
            } else {
                out.push(Item::Problem(format!("bad frontmatter line '{line}'")));
            }
        }
    }
    if !nofm && !closed {
        out.push(Item::Problem("frontmatter not closed".into()));
    }
    if !haslog {
        out.push(Item::Problem("no ## Log section".into()));
    }
    out
}

pub fn cmd_doctor(args: &[String]) -> i32 {
    if !args.is_empty() {
        die("usage: task doctor");
    }
    let mut problems = String::new();
    let mut count = 0usize;
    let mut ntasks = 0usize;
    let mut nproj = 0usize;
    let mut idlist: Vec<(String, String)> = Vec::new();
    let mut add = |rel: &str, msg: &str| {
        problems.push_str(&format!("{rel}: {msg}\n"));
        count += 1;
    };
    let prefix = format!("{}/", store());

    for f in all_task_files() {
        ntasks += 1;
        let rel = f.strip_prefix(prefix.as_str()).unwrap_or(&f).to_string();
        let ws = ws_of_file(&f);
        let folder = folder_of_file(&f);
        let fid = id_of_file(&f);
        idlist.push((fid.clone(), rel.clone()));
        let (mut f_id, mut f_title, mut f_project, mut f_created) =
            (String::new(), String::new(), String::new(), String::new());
        let (mut f_session, mut f_result, mut f_blocked, mut f_postponed) =
            (String::new(), String::new(), String::new(), String::new());
        let mut skip = false;
        let text = read_file(&f).unwrap_or_default();
        for it in doctor_scan(&text) {
            match it {
                Item::Problem(p) => add(&rel, &p),
                Item::NoFrontmatter => skip = true,
                Item::Field(k, v) => match k.as_str() {
                    "id" => f_id = v,
                    "title" => f_title = v,
                    "project" => f_project = v,
                    "created" => f_created = v,
                    "session" => f_session = v,
                    "result" => f_result = v,
                    "blocked_from" => f_blocked = v,
                    "postponed_from" => f_postponed = v,
                    _ => {}
                },
            }
        }
        if skip {
            continue;
        }
        if f_id != fid {
            add(&rel, &format!("id '{f_id}' does not match file name"));
        }
        if f_title.is_empty() {
            add(&rel, "empty title");
        }
        if !valid_calendar_date(&f_created) {
            add(&rel, &format!("invalid created date '{f_created}'"));
        }
        if !f_result.is_empty() && f_result != "subtasks" && !valid_result(&f_result) {
            add(&rel, &format!("invalid result '{f_result}'"));
        }
        if folder == "10_unmerged" && !matches!(f_result.as_str(), "pr" | "kept") {
            let r = if f_result.is_empty() {
                "none"
            } else {
                &f_result
            };
            add(
                &rel,
                &format!("in 10_unmerged with result '{r}' (expected pr or kept)"),
            );
        }
        if !f_project.is_empty() {
            if !valid_project(&f_project) {
                add(&rel, &format!("invalid project name '{f_project}'"));
            } else if !Path::new(&format!("{}/{ws}/.projects/{f_project}", store())).is_file() {
                add(&rel, &format!("unknown project '{f_project}'"));
            }
        }
        if !f_session.is_empty() && !valid_session(&f_session) {
            add(&rel, &format!("invalid session id '{f_session}'"));
        }
        if folder == "blocked" && f_blocked.is_empty() {
            add(&rel, "in blocked without blocked_from");
        }
        if folder != "blocked" && !f_blocked.is_empty() {
            add(&rel, "blocked_from outside blocked");
        }
        if !f_blocked.is_empty()
            && (!FOLDERS.contains(&f_blocked.as_str()) || f_blocked == "blocked")
        {
            add(&rel, &format!("invalid blocked_from '{f_blocked}'"));
        }
        if folder == "postponed" && f_postponed.is_empty() {
            add(&rel, "in postponed without postponed_from");
        }
        if folder != "postponed" && !f_postponed.is_empty() {
            add(&rel, "postponed_from outside postponed");
        }
        if !f_postponed.is_empty()
            && (!FOLDERS.contains(&f_postponed.as_str()) || f_postponed == "postponed")
        {
            add(&rel, &format!("invalid postponed_from '{f_postponed}'"));
        }
        if AGENT_FOLDERS.contains(&folder.as_str()) && f_session.is_empty() {
            add(&rel, &format!("in {folder} without session"));
        }
    }

    // Stable sort keeps folder order, so the first file of an id is the "also" one.
    idlist.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    let mut prev: Option<(String, String)> = None;
    for (id, rel) in &idlist {
        match &prev {
            Some((pid, first)) if pid == id => {
                add(rel, &format!("duplicate id {id} (also {first})"));
            }
            _ => prev = Some((id.clone(), rel.clone())),
        }
    }

    for ws_p in list_workspaces() {
        let dir = format!("{}/{ws_p}/.projects", store());
        let mut names: Vec<String> = Vec::new();
        if let Ok(rd) = fs::read_dir(&dir) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') {
                    continue;
                }
                if e.path().is_file() {
                    names.push(name);
                }
            }
        }
        names.sort();
        for name in names {
            nproj += 1;
            let p = project_path(&ws_p, &name);
            if !Path::new(&p).is_dir() || p.is_empty() {
                add(
                    &format!("{ws_p}/.projects/{name}"),
                    &format!("path does not exist: {p}"),
                );
            }
        }
    }

    for (rel, msg) in st_load().problems() {
        if rel.is_empty() {
            continue;
        }
        add(&rel, &msg);
    }

    let p = config_get("preset", "");
    if !p.is_empty() && preset_model_ref(&p).is_none() {
        add(
            "config.toml",
            &format!("preset '{p}' not found in {}", slim_config_file()),
        );
    }

    if count > 0 {
        print!("{problems}");
        println!("{count} problem(s)");
        return 1;
    }
    let mut line = format!("ok: {ntasks} task");
    if ntasks != 1 {
        line.push('s');
    }
    line.push_str(&format!(", {nproj} project"));
    if nproj != 1 {
        line.push('s');
    }
    println!("{line}");
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates() {
        assert!(valid_calendar_date("2026-10-01"));
        assert!(valid_calendar_date("2024-02-29"));
        assert!(!valid_calendar_date("2026-02-29"));
        assert!(!valid_calendar_date("1900-02-29"));
        assert!(valid_calendar_date("2000-02-29"));
        assert!(!valid_calendar_date("2026-13-01"));
        assert!(!valid_calendar_date("2026-1-01"));
        assert!(!valid_calendar_date(""));
    }

    #[test]
    fn scan() {
        let items = doctor_scan("---\nid: T-0001\nbogus: 1\nid: x\n---\n\n");
        let probs: Vec<String> = items
            .iter()
            .filter_map(|i| match i {
                Item::Problem(p) => Some(p.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(
            probs,
            vec![
                "unknown key 'bogus'",
                "duplicate key 'id'",
                "no ## Log section"
            ]
        );
        assert_eq!(unq("\"a\\\"b\""), "a\"b");
    }
}
