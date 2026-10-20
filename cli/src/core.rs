//! Store location, configuration, ids, folder names and small shared helpers
//! (port of lib/core.sh).

use std::fs;
use std::io::Read;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::OnceLock;

pub const VERSION: &str = "0.2.0";

pub const FOLDERS: [&str; 15] = [
    "00_backlog",
    "01_ready",
    "02_exploring",
    "03_brainstorming",
    "04_spec_review",
    "05_planning",
    "06_plan_review",
    "07_approved",
    "08_implementing",
    "09_finishing",
    "10_unmerged",
    "11_done",
    "blocked",
    "postponed",
    "archive",
];
pub const WAITING_FOLDERS: [&str; 5] = [
    "03_brainstorming",
    "04_spec_review",
    "06_plan_review",
    "09_finishing",
    "blocked",
];
/// Folders where an agent is at work (max_active, stale check, doctor).
pub const AGENT_FOLDERS: [&str; 3] = ["02_exploring", "05_planning", "08_implementing"];
pub const RESULTS: [&str; 5] = ["pr", "merged", "kept", "discarded", "cancelled"];

pub fn folders_str() -> String {
    FOLDERS.join(" ")
}

pub fn results_str() -> String {
    RESULTS.join(" ")
}

// ---------------------------------------------------------------- output

pub fn die(msg: impl AsRef<str>) -> ! {
    eprintln!("task: {}", msg.as_ref());
    exit(1)
}

pub fn warn(msg: impl AsRef<str>) {
    eprintln!("task: {}", msg.as_ref());
}

/// Exits after releasing the store lock (the bash EXIT trap).
pub fn exit(code: i32) -> ! {
    crate::lock::lock_release();
    std::process::exit(code)
}

// ---------------------------------------------------------------- store

static STORE: OnceLock<String> = OnceLock::new();

pub fn store() -> &'static str {
    STORE.get_or_init(|| {
        let mut s = match std::env::var("AGENT_TASKS_HOME") {
            Ok(v) if !v.is_empty() => v,
            _ => format!("{}/.agent-tasks", std::env::var("HOME").unwrap_or_default()),
        };
        if !s.starts_with('/') {
            let cwd = std::env::current_dir()
                .ok()
                .and_then(|p| fs::canonicalize(p).ok())
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            s = format!("{}/{}", cwd, s);
        }
        if s != "/" && s.ends_with('/') {
            s.pop();
        }
        s
    })
}

/// Root of the skill (the directory holding bin/, lib/, opencode/, launchd/).
pub fn task_root() -> String {
    if let Ok(v) = std::env::var("AGENT_TASKS_ROOT") {
        if !v.is_empty() {
            return v;
        }
    }
    // <repo>/target/release/task -> <repo>/skills/agent-tasks
    if let Ok(exe) = std::env::current_exe() {
        let exe = fs::canonicalize(&exe).unwrap_or(exe);
        let mut cur = exe.parent();
        while let Some(d) = cur {
            let cand = d.join("skills/agent-tasks");
            if cand.join("bin/task").exists() {
                return cand.to_string_lossy().into_owned();
            }
            cur = d.parent();
        }
    }
    String::new()
}

/// The shim that re-invokes the CLI (what bash called TASK_BIN).
pub fn task_bin() -> String {
    format!("{}/bin/task", task_root())
}

// ---------------------------------------------------------------- strings

fn is_space(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\r' | '\x0b' | '\x0c')
}

pub fn trim(s: &str) -> &str {
    s.trim_matches(is_space)
}

pub fn single_line(s: &str) -> bool {
    !s.contains(['\n', '\r', '\t'])
}

/// Lines as bash's `while read; done <<< "$text"` sees them.
pub fn lines_of(text: &str) -> Vec<&str> {
    text.split('\n').collect()
}

/// `-` reads stdin. Trailing newlines are stripped in both cases.
pub fn read_text_arg(text: &str) -> String {
    let mut t = if text == "-" {
        let mut buf = Vec::new();
        let _ = std::io::stdin().read_to_end(&mut buf);
        String::from_utf8_lossy(&buf).into_owned()
    } else {
        text.to_string()
    };
    while t.ends_with('\n') {
        t.pop();
    }
    t
}

/// Option value at args[i+1]; dies when it is missing or empty.
pub fn need_value(args: &[String], i: usize) -> &str {
    match args.get(i + 1) {
        Some(v) if !v.is_empty() => v,
        _ => die(format!("{} requires a value", args[i])),
    }
}

pub fn valid_ws(s: &str) -> bool {
    let mut c = s.chars();
    match c.next() {
        Some(f) if f.is_ascii_lowercase() || f.is_ascii_digit() => {}
        _ => return false,
    }
    c.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

pub fn valid_session(s: &str) -> bool {
    match s.strip_prefix("ses") {
        Some(rest) if !rest.is_empty() => rest
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-'),
        _ => false,
    }
}

pub fn valid_result(s: &str) -> bool {
    RESULTS.contains(&s)
}

pub fn valid_project(s: &str) -> bool {
    let mut c = s.chars();
    match c.next() {
        Some(f) if f.is_ascii_alphanumeric() => {}
        _ => return false,
    }
    c.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.' || c == '-')
}

pub fn basename(p: &str) -> &str {
    let t = p.trim_end_matches('/');
    t.rsplit('/').next().unwrap_or(t)
}

pub fn dirname(p: &str) -> &str {
    match p.rfind('/') {
        Some(0) => "/",
        Some(i) => &p[..i],
        None => ".",
    }
}

// ---------------------------------------------------------------- files

/// File as text (invalid UTF-8 replaced); None when unreadable.
pub fn read_file(path: &str) -> Option<String> {
    fs::read(path)
        .ok()
        .map(|b| String::from_utf8_lossy(&b).into_owned())
}

// ---------------------------------------------------------------- time

extern "C" {
    fn tzset();
}

fn local_tm() -> libc::tm {
    unsafe {
        tzset();
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        tm
    }
}

/// `YYYY-MM-DD` in local time (`date +%Y-%m-%d`).
pub fn date_ymd() -> String {
    let tm = local_tm();
    format!(
        "{:04}-{:02}-{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday
    )
}

/// `YYYY-MM-DD HH:MM` in local time (`date '+%Y-%m-%d %H:%M'`).
pub fn date_ymd_hm() -> String {
    let tm = local_tm();
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min
    )
}

pub fn epoch_now() -> i64 {
    unsafe { libc::time(std::ptr::null_mut()) as i64 }
}

// ---------------------------------------------------------------- git

/// `git -C STORE <args>`; stdout captured, stderr inherited.
pub fn git_out(args: &[&str]) -> std::process::Output {
    Command::new("git")
        .arg("-C")
        .arg(store())
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::inherit())
        .output()
        .unwrap_or_else(|e| die(format!("cannot run git: {e}")))
}

/// `git -C STORE <args>`; everything inherited. Returns success.
pub fn git_ok(args: &[&str]) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(store())
        .args(args)
        .stdin(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

// ---------------------------------------------------------------- config

/// Flat `key = value` lines; `#` starts a comment, double quotes are dropped.
pub fn config_get(key: &str, default: &str) -> String {
    let mut val = String::new();
    if let Some(text) = read_file(&format!("{}/config.toml", store())) {
        for raw in text.split('\n') {
            let line = match raw.find('#') {
                Some(i) => &raw[..i],
                None => raw,
            };
            let Some(eq) = line.find('=') else { continue };
            let k = line[..eq].trim_matches([' ', '\t']);
            let v = line[eq + 1..].trim_matches([' ', '\t']);
            if k == key {
                val = v.replace('"', "");
            }
        }
    }
    if val.is_empty() {
        default.to_string()
    } else {
        val
    }
}

pub fn default_config() -> &'static str {
    "default_workspace = \"work\"\n\
max_active = 2           # automation limit for 02_exploring + 05_planning + 08_implementing\n\
agent = \"\"               # empty: OpenCode default agent\n\
model = \"\"               # empty: OpenCode default model; explicit provider/model, wins over preset\n\
preset = \"\"              # oh-my-opencode-slim preset for task sessions; empty: OpenCode default model\n\
quiet_minutes = 3        # no question alert if the user answered in this session recently\n\
stale_minutes = 30       # a session in 2 or 6 without activity counts as stopped\n\
mr_check_minutes = 10    # check MRs/PRs of unmerged tasks at most this often; 0 disables\n\
archive_after_days = 14  # done tasks move to archive after this many days (also those archived in ai_task_tracker, at once); 0 disables all automatic archiving\n"
}

pub fn default_gitignore() -> &'static str {
    ".auto\n.lock/\n.lock.steal/\n.notify/\n.obsidian/\n.DS_Store\n*.tmp\n"
}

pub fn slim_config_file() -> String {
    match std::env::var("AGENT_TASKS_SLIM_CONFIG") {
        Ok(v) if !v.is_empty() => v,
        _ => format!(
            "{}/.config/opencode/oh-my-opencode-slim.json",
            std::env::var("HOME").unwrap_or_default()
        ),
    }
}

// ---------------------------------------------------------------- workspaces

pub fn ensure_workspace(ws: &str) {
    for f in FOLDERS.iter().chain([".projects"].iter()) {
        let d = format!("{}/{}/{}", store(), ws, f);
        if !Path::new(&d).is_dir() {
            let _ = fs::create_dir_all(&d);
        }
    }
}

pub fn list_workspaces() -> Vec<String> {
    let mut out = Vec::new();
    if let Ok(rd) = fs::read_dir(store()) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            let p = e.path();
            if p.is_dir() && p.join("00_backlog").is_dir() {
                out.push(name);
            }
        }
    }
    out.sort();
    out
}

/// A workspace is born with `task project add --ws W`; elsewhere a typo must not create one.
pub fn require_workspace(ws: &str) {
    if Path::new(&format!("{}/{}/00_backlog", store(), ws)).is_dir() {
        return;
    }
    die(format!(
        "unknown workspace '{}' (existing: {})",
        ws,
        list_workspaces().join(" ")
    ));
}

pub fn ensure_store() {
    let st = store();
    let _ = fs::create_dir_all(st);
    let mut fresh = false;
    let mut took_lock = false;
    if !Path::new(&format!("{st}/.git")).is_dir() {
        if !crate::lock::lock_held() {
            took_lock = true;
        }
        crate::lock::lock_acquire();
        if !Path::new(&format!("{st}/.git")).is_dir() {
            fresh = true;
        }
    }
    let gi = format!("{st}/.gitignore");
    if !Path::new(&gi).is_file() {
        let _ = fs::write(&gi, default_gitignore());
    }
    let cfg = format!("{st}/config.toml");
    if !Path::new(&cfg).is_file() {
        let _ = fs::write(&cfg, default_config());
    }
    let ws = config_get("default_workspace", "work");
    if !valid_ws(&ws) {
        die(format!("invalid default_workspace '{ws}' in {st}/config.toml"));
    }
    ensure_workspace(&ws);
    if fresh {
        // .git appears last: a concurrent command that sees it finds a complete store.
        git_ok(&["-c", "advice.defaultBranchName=false", "init", "-q"]);
        git_ok(&["add", "-A"]);
        if !git_ok(&["commit", "-q", "-m", "tasks: init store"]) {
            die(format!(
                "commit failed in {st} — is git user.name / user.email configured?"
            ));
        }
    }
    if took_lock {
        crate::lock::lock_release();
    }
}

// ---------------------------------------------------------------- ids

/// T-0083, t-83, 83 and 0083 all name the same task.
pub fn normalize_id(raw: &str) -> Option<String> {
    let n = if raw.starts_with("T-") || raw.starts_with("t-") {
        &raw[2..]
    } else {
        raw
    };
    if n.is_empty() || !n.bytes().all(|b| b.is_ascii_digit()) || n.len() > 9 {
        return None;
    }
    let v: u64 = n.parse().ok()?;
    if v == 0 {
        return None;
    }
    Some(format!("T-{:04}", v))
}

pub fn id_of_file(file: &str) -> String {
    let b = basename(file);
    let r = b.strip_prefix("T-").unwrap_or(b);
    let digits: String = r.chars().take_while(|c| c.is_ascii_digit()).collect();
    format!("T-{}", digits)
}

fn rel_to_store(file: &str) -> &str {
    let prefix = format!("{}/", store());
    file.strip_prefix(prefix.as_str()).unwrap_or(file)
}

pub fn ws_of_file(file: &str) -> String {
    let rel = rel_to_store(file);
    rel.split('/').next().unwrap_or("").to_string()
}

pub fn folder_of_file(file: &str) -> String {
    let rel = rel_to_store(file);
    let rest = rel.split_once('/').map(|x| x.1).unwrap_or(rel);
    rest.split('/').next().unwrap_or("").to_string()
}

/// Matches the glob `T-[0-9]*.md`.
fn is_task_name(name: &str) -> bool {
    let b = name.as_bytes();
    b.len() >= 6 && name.starts_with("T-") && b[2].is_ascii_digit() && name.ends_with(".md")
}

/// Task files of one directory (full paths, sorted by name).
pub fn task_files_in(dir: &str) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    if let Ok(rd) = fs::read_dir(dir) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if is_task_name(&name) {
                names.push(name);
            }
        }
    }
    names.sort();
    names.into_iter().map(|n| format!("{dir}/{n}")).collect()
}

pub fn all_task_files() -> Vec<String> {
    let mut out = Vec::new();
    for ws in list_workspaces() {
        for fo in FOLDERS {
            out.extend(task_files_in(&format!("{}/{}/{}", store(), ws, fo)));
        }
    }
    out
}

pub fn task_file(raw: &str) -> String {
    let id = normalize_id(raw).unwrap_or_else(|| die(format!("invalid task id '{raw}'")));
    let exact = format!("{id}.md");
    let pref = format!("{id}-");
    let mut found = String::new();
    let mut other = String::new();
    let mut n = 0;
    for f in all_task_files() {
        let b = basename(&f);
        if b == exact || (b.starts_with(&pref) && b.ends_with(".md")) {
            n += 1;
            if n == 1 {
                found = f.clone();
            } else {
                other = f.clone();
            }
        }
    }
    if n == 0 {
        die(format!("no task {id}"));
    }
    if n != 1 {
        die(format!(
            "duplicate task id {id}: {found} and {other} (run 'task doctor')"
        ));
    }
    found
}

/// Highest number in the whole store plus one; there is no separate counter.
pub fn next_id() -> u64 {
    let mut max = 0u64;
    for f in all_task_files() {
        let id = id_of_file(&f);
        let n: u64 = id[2..].parse().unwrap_or(0);
        if n > max {
            max = n;
        }
    }
    max + 1
}

/// Folder name without the numeric prefix: 00_backlog -> backlog, blocked -> blocked.
pub fn folder_status(f: &str) -> &str {
    let b = f.as_bytes();
    if b.len() >= 3 && b[0].is_ascii_digit() && b[1].is_ascii_digit() && b[2] == b'_' {
        &f[3..]
    } else {
        f
    }
}

/// Exact name, number (3 or 03) or status name (spec_review, blocked).
pub fn resolve_folder(x: &str) -> Option<&'static str> {
    let xn: Option<u32> = if !x.is_empty() && x.bytes().all(|b| b.is_ascii_digit()) && x.len() <= 3
    {
        x.parse().ok()
    } else {
        None
    };
    for f in FOLDERS {
        if x == f || x == folder_status(f) {
            return Some(f);
        }
        let num = f.split('_').next().unwrap_or("");
        if num.len() == 2 && num.bytes().all(|b| b.is_ascii_digit()) {
            if let (Some(xn), Ok(nv)) = (xn, num.parse::<u32>()) {
                if xn == nv {
                    return Some(f);
                }
            }
        }
    }
    None
}

/// Task files of the given folders (all workspaces), least recently changed
/// first: ctime is the last inode change (a move, but also every log append or
/// edit), which is the intended queue order. Ties go to the lower path.
/// `with_session` skips unbound tasks.
pub fn oldest_tasks_in(with_session: bool, folders: &[&str]) -> Vec<String> {
    let mut list: Vec<((i64, i64), String)> = Vec::new();
    for ws in list_workspaces() {
        for fo in folders {
            for f in task_files_in(&format!("{}/{}/{}", store(), ws, fo)) {
                if with_session && crate::frontmatter::fm_get(&f, "session").is_empty() {
                    continue;
                }
                let t = fs::metadata(&f).map(|m| (m.ctime(), m.ctime_nsec())).unwrap_or((0, 0));
                list.push((t, f));
            }
        }
    }
    list.sort();
    list.into_iter().map(|x| x.1).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize() {
        assert_eq!(normalize_id("T-0083").as_deref(), Some("T-0083"));
        assert_eq!(normalize_id("t-83").as_deref(), Some("T-0083"));
        assert_eq!(normalize_id("83").as_deref(), Some("T-0083"));
        assert_eq!(normalize_id("0"), None);
        assert_eq!(normalize_id("x"), None);
        assert_eq!(normalize_id("1234567890"), None);
    }

    #[test]
    fn folders() {
        assert_eq!(resolve_folder("3"), Some("03_brainstorming"));
        assert_eq!(resolve_folder("plan_review"), Some("06_plan_review"));
        assert_eq!(resolve_folder("blocked"), Some("blocked"));
        assert_eq!(resolve_folder("12"), None);
        assert_eq!(resolve_folder("100"), None);
        assert_eq!(resolve_folder("0"), Some("00_backlog"));
    }

    #[test]
    fn names() {
        assert!(is_task_name("T-0001.md"));
        assert!(is_task_name("T-1-x.md"));
        assert!(!is_task_name("T-.md"));
        assert!(!is_task_name(".T-0001.1.tmp"));
    }
}
