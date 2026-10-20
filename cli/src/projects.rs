//! Shared project-registry helpers (from lib/projects.sh). The `task project`
//! command itself lives in cmd/projects.rs.

use crate::core::{basename, die, list_workspaces, read_file, store, valid_project};
use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};

/// Repository path registered for <ws>/<name>; empty when unknown.
pub fn project_path(ws: &str, name: &str) -> String {
    let f = format!("{}/{}/.projects/{}", store(), ws, name);
    if Path::new(&f).is_file() {
        if let Some(t) = read_file(&f) {
            return t.split('\n').next().unwrap_or("").to_string();
        }
    }
    String::new()
}

/// Workspace holding project `name` (restricted to `only` when non-empty).
pub fn project_ws(name: &str, only: &str) -> String {
    if !valid_project(name) {
        die(format!("invalid project name '{name}'"));
    }
    let mut found: Vec<String> = Vec::new();
    for ws in list_workspaces() {
        if !only.is_empty() && ws != only {
            continue;
        }
        if Path::new(&format!("{}/{}/.projects/{}", store(), ws, name)).is_file() {
            found.push(ws);
        }
    }
    if found.is_empty() {
        die(format!(
            "unknown project '{name}' (register it: task project add {name} <path>)"
        ));
    }
    if found.len() != 1 {
        die(format!(
            "project '{name}' is registered in workspaces: {} — pass --ws",
            found.join(" ")
        ));
    }
    found.remove(0)
}

fn git_cwd(args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(
        String::from_utf8_lossy(&out.stdout)
            .trim_end_matches('\n')
            .to_string(),
    )
}

fn pwd_p() -> String {
    std::env::current_dir()
        .ok()
        .and_then(|p| fs::canonicalize(p).ok())
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Current directory, but a git worktree maps to the same place in its main checkout.
pub fn cwd_equivalent() -> String {
    let here = pwd_p();
    let common =
        git_cwd(&["rev-parse", "--path-format=absolute", "--git-common-dir"]).unwrap_or_default();
    let Some(parent_raw) = common.strip_suffix("/.git") else {
        return here;
    };
    let Ok(parent) = fs::canonicalize(parent_raw) else {
        return here;
    };
    let parent = parent.to_string_lossy().into_owned();
    let prefix = git_cwd(&["rev-parse", "--show-prefix"]).unwrap_or_default();
    let prefix = prefix.trim_end_matches('/');
    if prefix.is_empty() {
        parent
    } else {
        format!("{parent}/{prefix}")
    }
}

/// (ws, name) of the registered project with the longest path containing the cwd.
pub fn detect_project(only: &str) -> Option<(String, String)> {
    let here = cwd_equivalent();
    let mut best: Option<(String, String)> = None;
    let mut best_len = 0usize;
    for ws in list_workspaces() {
        if !only.is_empty() && ws != only {
            continue;
        }
        let dir = format!("{}/{}/.projects", store(), ws);
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        let mut names: Vec<String> = rd
            .flatten()
            .filter(|e| e.path().is_file())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        for n in names {
            let p = project_path(&ws, basename(&n));
            if p.is_empty() {
                continue;
            }
            if here == p || here.starts_with(&format!("{p}/")) {
                let len = p.chars().count();
                if len > best_len {
                    best_len = len;
                    best = Some((ws.clone(), n.clone()));
                }
            }
        }
    }
    best
}
