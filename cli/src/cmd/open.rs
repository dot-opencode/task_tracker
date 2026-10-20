//! Notifications (alerter) and opening a task's session in Ghostty (lib/open.sh).

use crate::cmd::session::on_path;
use crate::cmd::signal::oldest_task_in;
use crate::core::*;
use crate::frontmatter::fm_get;
use serde_json::Value;
use std::fs;
use std::io::Write;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::process::{Command, Stdio};

fn notify_dir() -> String {
    format!("{}/.notify", store())
}

fn first_line(path: &str) -> Option<String> {
    let t = read_file(path)?;
    Some(t.split('\n').next().unwrap_or("").to_string())
}

fn all_digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

/// `ps -o ppid= -p <pid>`.
fn parent_pid(p: &str) -> String {
    Command::new("ps")
        .args(["-o", "ppid=", "-p", p])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .chars()
                .filter(|c| *c != ' ' && *c != '\n')
                .collect()
        })
        .unwrap_or_default()
}

/// True when `target` is this process or one of its ancestors. `task open`
/// started by the Open button runs inside the alerter's subshell, whose pid is
/// in the pid file.
pub fn is_own_ancestor(target: &str) -> bool {
    let mut p = std::process::id().to_string();
    let mut n = 0;
    while !p.is_empty() && p.parse::<i64>().map(|v| v > 1).unwrap_or(false) && n < 64 {
        if p == target {
            return true;
        }
        p = parent_pid(&p);
        n += 1;
    }
    false
}

/// Kills `pid` and its descendants (the alerter runs inside a detached subshell).
pub fn kill_tree(pid: &str) {
    if !all_digits(pid) {
        return;
    }
    if let Ok(o) = Command::new("pgrep")
        .args(["-P", pid])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
    {
        for kid in String::from_utf8_lossy(&o.stdout).split_whitespace() {
            kill_tree(kid);
        }
    }
    if let Ok(p) = pid.parse::<i32>() {
        unsafe {
            libc::kill(p, libc::SIGTERM);
        }
    }
}

/// Ends the previous alerter of a task, if any. When we run inside that
/// alerter's subshell (the Open button), the pid file is just removed.
pub fn notify_kill(id: &str) {
    let pidf = format!("{}/{id}.alerter-pid", notify_dir());
    if !Path::new(&pidf).is_file() {
        return;
    }
    let pid = first_line(&pidf).unwrap_or_default();
    let _ = fs::remove_file(&pidf);
    if !all_digits(&pid) {
        return;
    }
    if is_own_ancestor(&pid) {
        return;
    }
    kill_tree(&pid);
}

/// True when the user acted in the task's session less than quiet_minutes ago.
pub fn notify_quiet(id: &str) -> bool {
    let f = format!("{}/{id}.last-user", notify_dir());
    if !Path::new(&f).is_file() {
        return false;
    }
    let mut last = first_line(&f).unwrap_or_default();
    if !all_digits(&last) {
        last = fs::metadata(&f).map(|m| m.mtime()).unwrap_or(0).to_string();
    }
    let mut q = config_get("quiet_minutes", "3");
    if !all_digits(&q) {
        q = "3".into();
    }
    let last: i64 = last.parse().unwrap_or(i64::MAX);
    let q: i64 = q.parse().unwrap_or(i64::MAX / 120);
    epoch_now() - last < q.saturating_mul(60)
}

/// One alert per task; Open runs `task open <id>`. The quiet rule covers the
/// user's own conversation only: errors and stalled sessions always alert.
pub fn notify_task(id: &str, title: &str, body: &str, signal: &str) {
    if !matches!(signal, "error" | "stalled") && notify_quiet(id) {
        return;
    }
    if !on_path("alerter") {
        warn("alerter not found; notification skipped");
        return;
    }
    let file = all_task_files()
        .into_iter()
        .find(|p| {
            let b = basename(p);
            let n = id;
            b == format!("{n}.md") || (b.starts_with(&format!("{n}-")) && b.ends_with(".md"))
        })
        .unwrap_or_default();
    let mut project = String::new();
    if !file.is_empty() {
        project = fm_get(&file, "project");
    }
    if project.is_empty() {
        project = "no project".into();
    }
    let _ = fs::create_dir_all(notify_dir());
    notify_kill(id);
    // Detached and with every stream closed: the caller (the plugin, launchd)
    // must not wait for the user to react. --opt=value: a body starting with
    // '-' must not be read as an option.
    let script = r#"ans="$(alerter --title="$1" --subtitle="$2" --message="$3" \
  --actions Open --group "$4" --timeout 86400 --sound default 2>/dev/null)" || ans=""
case "$ans" in
  Open|@CONTENTCLICKED|@ACTIONCLICKED) "$5" open "$4" ;;
esac"#;
    let child = Command::new("sh")
        .arg("-c")
        .arg(script)
        .arg("sh")
        .arg(title)
        .arg(&project)
        .arg(body)
        .arg(id)
        .arg(task_bin())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    if let Ok(c) = child {
        let _ = fs::write(
            format!("{}/{id}.alerter-pid", notify_dir()),
            format!("{}\n", c.id()),
        );
    }
}

pub fn notify_clear(id: &str) {
    if on_path("alerter") {
        let _ = Command::new("alerter")
            .args(["--remove", id])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    notify_kill(id);
}

const APPLESCRIPT: &str = r#"set tag to system attribute "TASK_TAG"
set dir to system attribute "TASK_DIR"
set cmd to system attribute "TASK_CMD"
set mark to system attribute "TASK_MARK"
tell application "Ghostty"
  activate
  if mark is not "" then
    repeat with w in windows
      repeat with t in tabs of w
        repeat with term in terminals of t
          if ((working directory of term) as text) is dir and ((id of term) as text) is mark then
            focus term
            return "focused"
          end if
        end repeat
      end repeat
    end repeat
  end if
  set cfg to new surface configuration
  set initial working directory of cfg to dir
  set initial input of cfg to cmd & linefeed
  if (count of windows) > 0 then
    set newTab to new tab in (item 1 of windows) with configuration cfg
  else
    set newWin to new window with configuration cfg
    set newTab to item 1 of tabs of newWin
  end if
  set term to item 1 of terminals of newTab
  perform action ("set_tab_title:" & tag) on term
  return "opened " & ((id of term) as text)
end tell
"#;

pub fn cmd_open(args: &[String]) -> i32 {
    if args.len() != 1 {
        die("usage: task open <id>");
    }
    let tid =
        normalize_id(&args[0]).unwrap_or_else(|| die(format!("invalid task id '{}'", args[0])));
    let f = task_file(&tid);
    let session = fm_get(&f, "session");
    let short: u64 = tid[2..].parse().unwrap_or(0);
    if session.is_empty() {
        die(format!(
            "{tid} has no session; start it with 'task mv {short} ready' or bind one"
        ));
    }
    // The value reaches a URL and a command typed into a terminal.
    if !valid_session(&session) {
        die(format!("{tid} has an invalid session field"));
    }
    let title = fm_get(&f, "title");
    if !on_path("opencode") {
        die("opencode not found on PATH");
    }
    let notfound = || -> ! {
        die(format!(
            "session {session} not found (is OpenCode running?)"
        ))
    };
    let resp = match Command::new("opencode")
        .args(["api", "get", &format!("/api/session/{session}")])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
    {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
        _ => notfound(),
    };
    let dir = serde_json::from_str::<Value>(&resp)
        .ok()
        .and_then(|v| {
            for p in ["/data/location/directory", "/data/directory"] {
                if let Some(s) = v.pointer(p).and_then(|x| x.as_str()) {
                    return Some(s.to_string());
                }
            }
            None
        })
        .unwrap_or_default();
    if dir.is_empty() {
        notfound();
    }
    notify_clear(&tid);
    let markf = format!("{}/{tid}.tab", notify_dir());
    let mark = if Path::new(&markf).is_file() {
        first_line(&markf).unwrap_or_default()
    } else {
        String::new()
    };
    if !on_path("osascript") {
        die(format!(
            "osascript not found; open the session with: opencode --session {session}"
        ));
    }
    // Tab titles are overwritten by OpenCode, so a tab is recognised by its
    // working directory plus the terminal id remembered in the marker file.
    let child = Command::new("osascript")
        .env("TASK_TAG", format!("{tid} {title}"))
        .env("TASK_DIR", &dir)
        .env("TASK_CMD", format!("opencode --session {session}"))
        .env("TASK_MARK", &mark)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn();
    let out = match child {
        Ok(mut c) => {
            if let Some(mut si) = c.stdin.take() {
                let _ = si.write_all(APPLESCRIPT.as_bytes());
            }
            match c.wait_with_output() {
                Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
                _ => die("could not open a Ghostty tab (osascript failed)"),
            }
        }
        Err(_) => die("could not open a Ghostty tab (osascript failed)"),
    };
    let out = out.trim_end_matches('\n');
    if out == "focused" {
        println!("focused {tid}");
    } else if let Some(rest) = out.strip_prefix("opened ") {
        let _ = fs::create_dir_all(notify_dir());
        let _ = fs::write(&markf, format!("{rest}\n"));
        println!("opened {tid} in a new tab");
    } else {
        die(format!("unexpected answer from osascript: {out}"));
    }
    0
}

pub fn cmd_next(args: &[String]) -> i32 {
    if !args.is_empty() {
        die("usage: task next");
    }
    match oldest_task_in(true, &WAITING_FOLDERS) {
        None => {
            println!("nothing is waiting for you");
            0
        }
        Some(f) => cmd_open(&[id_of_file(&f)]),
    }
}
