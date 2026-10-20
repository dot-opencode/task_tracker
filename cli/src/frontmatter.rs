//! Task file format: frontmatter, body, ## Result, ## Log (lib/frontmatter.sh).

use crate::core::{self, die, lines_of, read_file, store};
use std::fs;
use std::io::Write;

fn unquote(raw: &str) -> String {
    if raw.len() >= 2 && raw.starts_with('"') && raw.ends_with('"') {
        let inner: Vec<char> = raw[1..raw.len() - 1].chars().collect();
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
        out
    } else {
        raw.to_string()
    }
}

/// Value of a frontmatter key (unquoted); empty when missing.
pub fn fm_get(file: &str, key: &str) -> String {
    let Some(text) = read_file(file) else {
        return String::new();
    };
    fm_get_text(&text, key)
}

pub fn fm_get_text(text: &str, key: &str) -> String {
    let prefix = format!("{key}: ");
    for (i, line) in text.split('\n').enumerate() {
        if i == 0 {
            if line != "---" {
                return String::new();
            }
            continue;
        }
        if line == "---" {
            return String::new();
        }
        if let Some(rest) = line.strip_prefix(&prefix) {
            return unquote(rest);
        }
    }
    String::new()
}

pub fn fm_quote_always(v: &str) -> String {
    format!("\"{}\"", v.replace('\\', "\\\\").replace('"', "\\\""))
}

/// Plain scalar when YAML-safe, double-quoted otherwise.
pub fn fm_quote(v: &str) -> String {
    let first_ok = v
        .chars()
        .next()
        .map(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '~' | '.' | '/'))
        .unwrap_or(false);
    if first_ok && !v.contains(['"', '\\']) {
        let lower = v.to_ascii_lowercase();
        let reserved = matches!(
            lower.as_str(),
            "null" | "true" | "false" | "yes" | "no" | "on" | "off" | "~"
        );
        if !reserved
            && !is_numberish(v)
            && !v.contains(": ")
            && !v.contains(" #")
            && !v.ends_with(':')
        {
            return v.to_string();
        }
    }
    fm_quote_always(v)
}

/// `^[-+]?[0-9][0-9._:-]*$`
fn is_numberish(v: &str) -> bool {
    let s = v.strip_prefix(['-', '+']).unwrap_or(v);
    let mut c = s.chars();
    match c.next() {
        Some(f) if f.is_ascii_digit() => {}
        _ => return false,
    }
    c.all(|c| c.is_ascii_digit() || matches!(c, '.' | '_' | ':' | '-'))
}

/// Free text must not contain lines that the Result/Log layout relies on.
pub fn reject_sections(what: &str, text: &str) {
    for line in lines_of(text) {
        if line == "## Log" || line == "## Result" {
            die(format!("{what} must not contain a '{line}' line"));
        }
    }
}

fn closed_frontmatter(text: &str) -> bool {
    for (i, line) in text.split('\n').enumerate() {
        if i == 0 {
            if line != "---" {
                return false;
            }
            continue;
        }
        if line == "---" {
            return true;
        }
    }
    false
}

/// Dies unless line 1 is `---` and a closing `---` follows. Every mutating
/// command calls this first.
pub fn fm_require(file: &str) {
    let ok = read_file(file).map(|t| closed_frontmatter(&t)).unwrap_or(false);
    if !ok {
        let rel = file
            .strip_prefix(&format!("{}/", store()))
            .unwrap_or(file);
        die(format!("malformed frontmatter in {rel} (run 'task doctor')"));
    }
}

/// Lines as awk sees them (no empty phantom line after a trailing newline).
fn awk_lines(text: &str) -> Vec<&str> {
    let mut v: Vec<&str> = text.split('\n').collect();
    if v.last() == Some(&"") {
        v.pop();
    }
    v
}

fn tmp_for(file: &str) -> String {
    let base = file.strip_suffix(".md").unwrap_or(file);
    format!("{}.{}.tmp", base, std::process::id())
}

fn commit_tmp(tmp: &str, file: &str, out: &str) -> Result<(), ()> {
    if fs::write(tmp, out).is_err() {
        let _ = fs::remove_file(tmp);
        return Err(());
    }
    if fs::rename(tmp, file).is_err() {
        let _ = fs::remove_file(tmp);
        return Err(());
    }
    Ok(())
}

/// Sets `key: val` in the frontmatter. Fails (file untouched) when the
/// frontmatter has no closing `---`.
pub fn fm_set(file: &str, key: &str, val: &str) -> Result<(), ()> {
    let text = read_file(file).ok_or(())?;
    let prefix = format!("{key}: ");
    let mut out = String::new();
    let (mut infm, mut done, mut closed) = (false, false, false);
    for (i, line) in awk_lines(&text).into_iter().enumerate() {
        if i == 0 && line == "---" {
            infm = true;
            out.push_str(line);
            out.push('\n');
            continue;
        }
        if infm && line == "---" {
            if !done {
                out.push_str(&format!("{key}: {val}\n"));
                done = true;
            }
            infm = false;
            closed = true;
            out.push_str(line);
            out.push('\n');
            continue;
        }
        if infm && line.starts_with(&prefix) {
            if !done {
                out.push_str(&format!("{key}: {val}\n"));
                done = true;
            }
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    if !closed {
        return Err(());
    }
    commit_tmp(&tmp_for(file), file, &out)
}

pub fn fm_unset(file: &str, key: &str) -> Result<(), ()> {
    let text = read_file(file).ok_or(())?;
    let prefix = format!("{key}: ");
    let mut out = String::new();
    let (mut infm, mut closed) = (false, false);
    for (i, line) in awk_lines(&text).into_iter().enumerate() {
        if i == 0 && line == "---" {
            infm = true;
            out.push_str(line);
            out.push('\n');
            continue;
        }
        if infm && line == "---" {
            infm = false;
            closed = true;
            out.push_str(line);
            out.push('\n');
            continue;
        }
        if infm && line.starts_with(&prefix) {
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    if !closed {
        return Err(());
    }
    commit_tmp(&tmp_for(file), file, &out)
}

/// Append-only, so it cannot damage existing content.
pub fn log_append(file: &str, author: &str, msg: &str) {
    let Ok(bytes) = fs::read(file) else {
        die(format!("no such task file: {file}"));
    };
    let mut add = String::new();
    if !bytes.is_empty() && *bytes.last().unwrap() != b'\n' {
        add.push('\n');
    }
    let text = String::from_utf8_lossy(&bytes);
    let has_log = text.split('\n').any(|l| l == "## Log");
    if !has_log {
        // last line of the file (with the newline we may have just added)
        let mut full = text.to_string();
        full.push_str(&add);
        let last = full
            .strip_suffix('\n')
            .unwrap_or(&full)
            .rsplit('\n')
            .next()
            .unwrap_or("");
        let last = if full.is_empty() { "" } else { last };
        if !last.is_empty() {
            add.push('\n');
        }
        add.push_str("## Log\n");
    }
    let stamp = core::date_ymd_hm();
    for (i, line) in lines_of(msg).into_iter().enumerate() {
        if i == 0 {
            add.push_str(&format!("- {stamp} {author}: {line}\n"));
        } else {
            add.push_str(&format!("  {line}\n"));
        }
    }
    let mut f = fs::OpenOptions::new()
        .append(true)
        .open(file)
        .unwrap_or_else(|_| die(format!("no such task file: {file}")));
    let _ = f.write_all(add.as_bytes());
}

/// Puts text into ## Result (created when missing), right before ## Log.
/// Fails (file untouched) when the frontmatter is not closed.
pub fn result_append(file: &str, text: &str) -> Result<(), ()> {
    let content = read_file(file).ok_or(())?;
    let lines = awk_lines(&content);
    let nr = lines.len();
    let (mut infm, mut closed) = (false, false);
    let mut logat = 0usize;
    for (i, line) in lines.iter().enumerate() {
        let n = i + 1;
        if n == 1 {
            if *line == "---" {
                infm = true;
            }
            continue;
        }
        if infm {
            if *line == "---" {
                infm = false;
                closed = true;
            }
            continue;
        }
        if closed && logat == 0 && *line == "## Log" {
            logat = n;
        }
    }
    if !closed {
        return Err(());
    }
    if logat == 0 {
        logat = nr + 1;
    }
    let mut last = logat - 1;
    while last > 0 && lines[last - 1].is_empty() {
        last -= 1;
    }
    let mut out = String::new();
    let mut has = false;
    for i in 1..=last {
        if i > 1 && lines[i - 1] == "## Result" {
            has = true;
        }
        out.push_str(lines[i - 1]);
        out.push('\n');
    }
    if !has {
        out.push_str("\n## Result\n");
    }
    out.push('\n');
    out.push_str(text);
    out.push_str("\n\n");
    for i in logat..=nr {
        out.push_str(lines[i - 1]);
        out.push('\n');
    }
    commit_tmp(&tmp_for(file), file, &out)
}

/// One row per file: path, id, title, project, created, session.
#[derive(Debug, Clone, Default)]
pub struct Row {
    pub path: String,
    pub id: String,
    pub title: String,
    pub project: String,
    pub created: String,
    pub session: String,
}

pub fn task_rows(files: &[String]) -> Vec<Row> {
    let mut rows = Vec::new();
    for f in files {
        let Some(text) = read_file(f) else { continue };
        if text.is_empty() {
            continue; // awk never sees a first line
        }
        let mut row = Row {
            path: f.clone(),
            ..Default::default()
        };
        let mut state = 0;
        for (i, line) in text.split('\n').enumerate() {
            if i == 0 {
                state = if line == "---" { 1 } else { 0 };
                continue;
            }
            if state == 1 {
                if line == "---" {
                    state = 2;
                    continue;
                }
                if let Some(p) = line.find(": ") {
                    let k = &line[..p];
                    let v = unquote(&line[p + 2..]);
                    match k {
                        "id" => row.id = v,
                        "title" => row.title = v,
                        "project" => row.project = v,
                        "created" => row.created = v,
                        "session" => row.session = v,
                        _ => {}
                    }
                }
            }
        }
        rows.push(row);
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpfile(name: &str, content: &str) -> String {
        let dir = std::env::temp_dir().join(format!("at-fm-{}-{}", std::process::id(), name));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let p = dir.join("raw.md");
        fs::write(&p, content).unwrap();
        p.to_string_lossy().into_owned()
    }

    #[test]
    fn rewriters_fail_without_anchor() {
        let body = "---\nid: T-0001\nsource: x\n\n## Log\n";
        let f = tmpfile("anchor", body);
        assert!(fm_set(&f, "pr", "y").is_err());
        assert!(fm_unset(&f, "source").is_err());
        assert!(result_append(&f, "text").is_err());
        assert_eq!(fs::read_to_string(&f).unwrap(), body);
        let dir = std::path::Path::new(&f).parent().unwrap();
        let tmps = fs::read_dir(dir)
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
            .count();
        assert_eq!(tmps, 0);
    }

    #[test]
    fn set_unset_roundtrip() {
        let f = tmpfile("rt", "---\nid: T-0001\n---\n\nbody\n");
        fm_set(&f, "pr", "http://x").unwrap();
        assert_eq!(fm_get(&f, "pr"), "http://x");
        fm_set(&f, "pr", "http://y").unwrap();
        assert_eq!(fs::read_to_string(&f).unwrap().matches("pr: ").count(), 1);
        fm_unset(&f, "pr").unwrap();
        assert_eq!(fm_get(&f, "pr"), "");
    }

    #[test]
    fn quote_rules() {
        assert_eq!(fm_quote("plain-value"), "plain-value");
        assert_eq!(fm_quote("https://a.example/x?y=1"), "https://a.example/x?y=1");
        assert_eq!(fm_quote("a: b"), "\"a: b\"");
        assert_eq!(fm_quote("a #b"), "\"a #b\"");
        assert_eq!(fm_quote("ends:"), "\"ends:\"");
        assert_eq!(fm_quote("-dash"), "\"-dash\"");
        assert_eq!(fm_quote("q\"uote"), "\"q\\\"uote\"");
    }

    #[test]
    fn typed_scalars_round_trip() {
        let f = tmpfile("typed", "---\nid: T-0001\n---\n");
        for v in ["123", "2026-10-01", "true", "null", "~", "No", "OFF", "1.5", "-7", "12:30"] {
            fm_set(&f, "source", &fm_quote(v)).unwrap();
            assert!(fs::read_to_string(&f).unwrap().contains(&format!("source: \"{v}\"\n")));
            assert_eq!(fm_get(&f, "source"), v);
        }
        for v in ["https://x.example/a", "dev_env", "nullable", "2026-10-01-x"] {
            fm_set(&f, "source", &fm_quote(v)).unwrap();
            assert!(fs::read_to_string(&f).unwrap().contains(&format!("source: {v}\n")));
            assert_eq!(fm_get(&f, "source"), v);
        }
    }

    #[test]
    fn title_round_trip() {
        let t = "He said \"hi\" \\ back";
        let q = fm_quote_always(t);
        assert_eq!(q, "\"He said \\\"hi\\\" \\\\ back\"");
        assert_eq!(fm_get_text(&format!("---\ntitle: {q}\n---\n"), "title"), t);
    }
}
