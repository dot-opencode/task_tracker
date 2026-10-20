//! Installing the OpenCode plugin as a symlink into the global plugins directory
//! (port of lib/install.sh).

use crate::core::{die, task_root};
use std::fs;
use std::os::unix::fs::symlink;
use std::path::Path;

fn deprecated() {
    eprintln!(
        "task: install-opencode is deprecated; prefer `opencode plugin add github:dot-opencode/task_tracker#release`"
    );
}

pub fn cmd_install_opencode(args: &[String]) -> i32 {
    if !args.is_empty() {
        die("usage: task install-opencode");
    }
    let source = format!("{}/opencode/agent-tasks.js", task_root());
    if !Path::new(&source).is_file() {
        die(format!("OpenCode plugin not found at {source}"));
    }
    let base = match std::env::var("XDG_CONFIG_HOME") {
        Ok(v) if !v.is_empty() => v,
        _ => format!("{}/.config", std::env::var("HOME").unwrap_or_default()),
    };
    let config_dir = format!("{base}/opencode/plugins");
    let destination = format!("{config_dir}/agent-tasks.js");
    let _ = fs::create_dir_all(&config_dir);
    let dp = Path::new(&destination);
    if dp
        .symlink_metadata()
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
    {
        // A dangling link is replaced.
        let current = fs::canonicalize(dp)
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
        if current == source {
            deprecated();
            println!("OpenCode plugin already installed: {destination}");
            return 0;
        }
        let _ = fs::remove_file(dp);
    } else if dp.exists() {
        die(format!("refusing to overwrite non-symlink: {destination}"));
    }
    if symlink(&source, dp).is_err() {
        die(format!("cannot create symlink {destination}"));
    }
    deprecated();
    println!(
        "installed OpenCode plugin: {destination} (run 'opencode reload' or restart OpenCode)"
    );
    0
}
