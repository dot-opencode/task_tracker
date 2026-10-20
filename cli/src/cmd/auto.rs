//! Active period: `.auto` in the store plus the launchd job that runs
//! `task run --once` (lib/auto.sh).

use crate::cmd::session::on_path;
use crate::cmd::signal::{active_count, count_tasks_in, max_active};
use crate::core::*;
use crate::preset::resolve_task_model;
use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};

pub const AUTO_LABEL: &str = "agent-tasks.run";

fn home() -> String {
    std::env::var("HOME").unwrap_or_default()
}

pub fn auto_file() -> String {
    format!("{}/.auto", store())
}

pub fn auto_plist() -> String {
    format!("{}/Library/LaunchAgents/{AUTO_LABEL}.plist", home())
}

pub fn worker_log_path() -> String {
    format!("{}/Library/Logs/agent-tasks.log", home())
}

/// Value of `<key>=` from .auto (empty when absent or not a number).
pub fn auto_field(key: &str) -> String {
    let Some(text) = read_file(&auto_file()) else {
        return String::new();
    };
    for line in text.split('\n') {
        let (k, v) = match line.split_once('=') {
            Some((k, v)) => (k, v),
            None => (line, ""),
        };
        if k == key {
            // awk -F= prints $2: up to the next "="
            let v = v.split('=').next().unwrap_or("");
            if v.is_empty() || !v.bytes().all(|b| b.is_ascii_digit()) {
                return String::new();
            }
            return v.to_string();
        }
    }
    String::new()
}

fn until_value() -> i64 {
    let u = auto_field("until");
    if u.is_empty() {
        0
    } else {
        u.parse().unwrap_or(i64::MAX)
    }
}

/// True when .auto exists and has not expired (until=0 means no end).
pub fn auto_enabled() -> bool {
    if !Path::new(&auto_file()).is_file() {
        return false;
    }
    let until = until_value();
    until == 0 || epoch_now() < until
}

/// Seconds left, or None for no end.
pub fn auto_remaining() -> Option<i64> {
    let until = until_value();
    if until == 0 {
        return None;
    }
    Some((until - epoch_now()).max(0))
}

/// 30m 2h 1h30m 90m → seconds.
pub fn parse_duration(d: &str) -> Option<i64> {
    if d.is_empty() {
        return None;
    }
    let (h, rest) = match d.find('h') {
        Some(i) => (&d[..i], &d[i + 1..]),
        None => ("", d),
    };
    let (m, tail) = match rest.find('m') {
        Some(i) => (&rest[..i], &rest[i + 1..]),
        None => ("", rest),
    };
    if !tail.is_empty() {
        return None;
    }
    let digits = |s: &str| s.bytes().all(|b| b.is_ascii_digit());
    if h.is_empty() && d.contains('h') {
        return None;
    }
    if m.is_empty() && rest.contains('m') {
        return None;
    }
    if !digits(h) || !digits(m) {
        return None;
    }
    if h.len() > 4 || m.len() > 6 {
        return None;
    }
    let hv: i64 = if h.is_empty() { 0 } else { h.parse().ok()? };
    let mv: i64 = if m.is_empty() { 0 } else { m.parse().ok()? };
    if hv * 60 + mv <= 0 {
        return None;
    }
    Some((hv * 60 + mv) * 60)
}

/// seconds → 1h42m / 5m
pub fn fmt_duration(s: i64) -> String {
    let m = (s + 59) / 60;
    let (h, m) = (m / 60, m % 60);
    if h > 0 {
        format!("{h}h{m:02}m")
    } else {
        format!("{m}m")
    }
}

fn tm_of(epoch: i64) -> libc::tm {
    unsafe {
        let t = epoch as libc::time_t;
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        tm
    }
}

/// epoch → HH:MM today, else YYYY-MM-DD HH:MM
pub fn fmt_until(epoch: i64) -> String {
    let tm = tm_of(epoch);
    let ymd = format!("{:04}-{:02}-{:02}", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday);
    if ymd == date_ymd() {
        format!("{:02}:{:02}", tm.tm_hour, tm.tm_min)
    } else {
        format!("{ymd} {:02}:{:02}", tm.tm_hour, tm.tm_min)
    }
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// awk's gsub replacement: `&` in the value would be the matched text; the
/// values are already XML-escaped, so `&amp;` etc. stay literal here because
/// they come through ENVIRON (no `&` expansion of ENVIRON values in gsub
/// replacements is *not* guaranteed) — plain replace matches the tests.
fn auto_write_plist() {
    let tpl = format!("{}/launchd/{AUTO_LABEL}.plist.tpl", task_root());
    let dest = auto_plist();
    let Some(text) = read_file(&tpl).filter(|_| Path::new(&tpl).is_file()) else {
        die(format!("launchd template not found: {tpl}"));
    };
    let path = format!(
        "{}/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        home()
    );
    let _ = fs::create_dir_all(dirname(&dest));
    let _ = fs::create_dir_all(format!("{}/Library/Logs", home()));
    let out = text
        .replace("__TASK_BIN__", &xml_escape(&task_bin()))
        .replace("__PATH__", &xml_escape(&path))
        .replace("__STORE__", &xml_escape(store()))
        .replace("__LOG__", &xml_escape(&worker_log_path()));
    let tmp = format!("{dest}.tmp");
    if fs::write(&tmp, out).is_err() {
        let _ = fs::remove_file(&tmp);
        die(format!("cannot write {dest}"));
    }
    if fs::rename(&tmp, &dest).is_err() {
        die(format!("cannot write {dest}"));
    }
}

fn uid() -> u32 {
    unsafe { libc::getuid() }
}

fn launchctl(args: &[&str]) -> bool {
    Command::new("launchctl")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub fn auto_unload() {
    launchctl(&["bootout", &format!("gui/{}/{AUTO_LABEL}", uid())]);
}

/// Loads the job, or restarts it when it is already loaded: bootout followed
/// at once by bootstrap races (bootstrap fails with 5/36 while the old
/// instance is being torn down).
fn auto_load(plist: &str) -> bool {
    let domain = format!("gui/{}", uid());
    let target = format!("{domain}/{AUTO_LABEL}");
    if launchctl(&["print", &target]) {
        launchctl(&["kickstart", "-k", &target]);
        return true;
    }
    let mut tries = 0;
    while !launchctl(&["bootstrap", &domain, plist]) {
        tries += 1;
        if tries >= 5 {
            return launchctl(&["print", &target]);
        }
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    true
}

fn auto_on(args: &[String]) {
    let mut secs = 0;
    if let Some(d) = args.first() {
        secs = parse_duration(d)
            .unwrap_or_else(|| die(format!("invalid duration '{d}' (examples: 30m 2h 1h30m)")));
    }
    if !on_path("launchctl") {
        die("launchctl not found");
    }
    let now = epoch_now();
    let until = if secs > 0 { now + secs } else { 0 };
    let _ = fs::write(auto_file(), format!("until={until}\nsince={now}\n"));
    auto_write_plist();
    let plist = auto_plist();
    if !auto_load(&plist) {
        let _ = fs::remove_file(auto_file());
        let _ = fs::remove_file(&plist);
        die(format!("launchctl could not load {plist}"));
    }
    if until > 0 {
        println!("automation on (until {})", fmt_until(until));
    } else {
        println!("automation on (until 'task auto off')");
    }
}

/// Files and the message first, bootout last: when `task run` (the job itself)
/// turns automation off at expiry, bootout SIGTERMs this very process.
pub fn auto_off() {
    let _ = fs::remove_file(auto_plist());
    let _ = fs::remove_file(auto_file());
    println!("automation off");
    use std::io::Write;
    let _ = std::io::stdout().flush();
    if on_path("launchctl") {
        auto_unload();
    }
}

fn auto_status() {
    if auto_enabled() {
        match auto_remaining() {
            None => println!("automation: on (until 'task auto off')"),
            Some(left) => println!("automation: on, {} left", fmt_duration(left)),
        }
    } else if Path::new(&auto_file()).is_file() {
        println!("automation: off (expired)");
    } else {
        println!("automation: off");
    }
    println!("active agents: {}/{}", active_count(), max_active());
    match resolve_task_model() {
        Ok((_, label)) => println!("model: {label}"),
        Err(()) => println!(
            "model: unresolved (preset '{}' not found in {})",
            config_get("preset", ""),
            slim_config_file()
        ),
    }
    let approved = count_tasks_in(&["07_approved"]);
    let ready = count_tasks_in(&["01_ready"]);
    println!("queue: {approved} approved, {ready} ready");
}

pub fn cmd_auto(args: &[String]) -> i32 {
    const USAGE: &str = "usage: task auto [on [DURATION] | off]";
    let sub = args.first().map(|s| s.as_str()).unwrap_or("");
    let rest = if args.is_empty() { args } else { &args[1..] };
    match sub {
        "" => {
            if !rest.is_empty() {
                die(USAGE);
            }
            auto_status();
        }
        "on" => {
            if rest.len() > 1 {
                die(USAGE);
            }
            auto_on(rest);
        }
        "off" => {
            if !rest.is_empty() {
                die(USAGE);
            }
            auto_off();
        }
        _ => die(USAGE),
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations() {
        assert_eq!(parse_duration("1h30m"), Some(5400));
        assert_eq!(parse_duration("30m"), Some(1800));
        assert_eq!(parse_duration("2h"), Some(7200));
        assert_eq!(parse_duration("90m"), Some(5400));
        assert_eq!(parse_duration("0m"), None);
        assert_eq!(parse_duration(""), None);
        assert_eq!(parse_duration("h"), None);
        assert_eq!(parse_duration("5"), None);
        assert_eq!(parse_duration("1m1h"), None);
        assert_eq!(parse_duration("12345h"), None);
        assert_eq!(fmt_duration(6120), "1h42m");
        assert_eq!(fmt_duration(300), "5m");
    }

    #[test]
    fn escape() {
        assert_eq!(xml_escape("a&b<c>"), "a&amp;b&lt;c&gt;");
    }
}
