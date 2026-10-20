//! Store lock: a mkdir-based mutex with the holder's pid inside (lib/lock.sh).

use crate::core::{die, store};
use std::ffi::CString;
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;
use std::time::{Duration, SystemTime};

static HELD: AtomicBool = AtomicBool::new(false);
static CPATHS: OnceLock<(CString, CString)> = OnceLock::new();

pub fn lock_held() -> bool {
    HELD.load(Ordering::SeqCst)
}

fn older_than_minute(p: &str) -> bool {
    fs::metadata(p)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| SystemTime::now().duration_since(t).ok())
        .map(|d| d > Duration::from_secs(60))
        .unwrap_or(false)
}

fn read_pid(lock: &str) -> Option<String> {
    let text = fs::read(format!("{lock}/pid")).ok()?;
    let text = String::from_utf8_lossy(&text).into_owned();
    Some(text.split('\n').next().unwrap_or("").to_string())
}

/// Dead pid, or no pid file for over a minute (the holder died between mkdir and
/// writing it). An unreadable or odd pid counts as alive: never steal on doubt.
fn lock_is_stale(lock: &str) -> bool {
    if Path::new(&format!("{lock}/pid")).is_file() {
        let pid = read_pid(lock).unwrap_or_default();
        if pid.is_empty() || !pid.bytes().all(|b| b.is_ascii_digit()) {
            return false;
        }
        match pid.parse::<i32>() {
            Ok(p) => unsafe { libc::kill(p, 0) != 0 },
            Err(_) => false,
        }
    } else {
        Path::new(lock).is_dir() && older_than_minute(lock)
    }
}

extern "C" fn on_signal(_: libc::c_int) {
    unsafe {
        if let Some((pid, dir)) = CPATHS.get() {
            libc::unlink(pid.as_ptr());
            libc::rmdir(dir.as_ptr());
        }
        libc::_exit(130);
    }
}

pub fn lock_acquire() {
    if lock_held() {
        return;
    }
    let lock = format!("{}/.lock", store());
    let steal = format!("{lock}.steal");
    let timeout: u64 = std::env::var("AGENT_TASKS_LOCK_TIMEOUT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(10);
    let max = timeout * 10;
    let mut tries = 0u64;
    while fs::create_dir(&lock).is_err() {
        // Two waiters can both see a dead holder; if each simply removed the lock,
        // the second rm would delete the first one's fresh lock. The steal is
        // serialised by a second mkdir and staleness is re-checked under it.
        if Path::new(&steal).is_dir() && older_than_minute(&steal) {
            let _ = fs::remove_dir(&steal); // a stealer died inside the window
        }
        if lock_is_stale(&lock) && fs::create_dir(&steal).is_ok() {
            if lock_is_stale(&lock) {
                let _ = fs::remove_dir_all(&lock);
            }
            let _ = fs::remove_dir(&steal);
            continue;
        }
        let mut pid = read_pid(&lock).unwrap_or_default();
        if !pid.bytes().all(|b| b.is_ascii_digit()) {
            pid.clear();
        }
        if tries >= max {
            die(format!(
                "store is locked by pid {} ({})",
                if pid.is_empty() { "unknown" } else { &pid },
                lock
            ));
        }
        tries += 1;
        std::thread::sleep(Duration::from_millis(100));
    }
    let _ = fs::write(format!("{lock}/pid"), format!("{}\n", std::process::id()));
    if let (Ok(p), Ok(d)) = (
        CString::new(format!("{lock}/pid")),
        CString::new(lock.clone()),
    ) {
        let _ = CPATHS.set((p, d));
    }
    HELD.store(true, Ordering::SeqCst);
    unsafe {
        for s in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
            libc::signal(s, on_signal as *const () as usize);
        }
    }
}

pub fn lock_release() {
    if HELD.swap(false, Ordering::SeqCst) {
        let _ = fs::remove_dir_all(format!("{}/.lock", store()));
    }
}
