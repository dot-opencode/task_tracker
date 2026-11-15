//! Shared project-registry helpers (from lib/projects.sh). The `task project`
//! command itself lives in cmd/projects.rs.

use crate::core::{basename, die, list_workspaces, read_file, store, valid_project};
use serde_json::Value;
use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};

/// Validate a settings document without interpreting or executing its instructions.
pub fn parse_project_settings(text: &str) -> Result<Value, String> {
    let value: Value =
        serde_json::from_str(text).map_err(|e| format!("invalid project settings JSON: {e}"))?;
    let object = value
        .as_object()
        .ok_or("project settings must be an object")?;
    if !object.is_empty() && object.get("version").and_then(Value::as_u64) != Some(1) {
        return Err("project settings require integer version 1".into());
    }
    for (key, section) in object {
        let fields: &[&str] = match key.as_str() {
            "version" => continue,
            "environment" => &["cwd", "start", "stop", "readiness"],
            "task_code" => &["attach", "verify_version"],
            "application" => &["url", "login", "test_data"],
            "browser" => &["navigation", "checks"],
            "tests" => {
                let tests = section
                    .as_array()
                    .ok_or("project settings tests must be an array")?;
                for test in tests {
                    validate_text_fields(test, &["name", "cwd", "command"], "tests record")?;
                    for required in ["name", "cwd", "command"] {
                        if test.get(required).is_none() {
                            return Err(format!(
                                "project settings tests record requires {required}"
                            ));
                        }
                    }
                }
                continue;
            }
            _ => return Err(format!("unknown project settings field '{key}'")),
        };
        validate_text_fields(section, fields, key)?;
    }
    Ok(value)
}

fn validate_text_fields(value: &Value, fields: &[&str], section: &str) -> Result<(), String> {
    let object = value
        .as_object()
        .ok_or_else(|| format!("project settings {section} must be an object"))?;
    for (key, value) in object {
        if !fields.contains(&key.as_str()) {
            return Err(format!("unknown project settings {section} field '{key}'"));
        }
        if !value.is_string() {
            return Err(format!("project settings {section}.{key} must be a string"));
        }
    }
    Ok(())
}

/// Read the path and optional validated settings together from one registry snapshot.
pub fn read_project(ws: &str, name: &str) -> Result<(String, Option<Value>), String> {
    let file = format!("{}/{}/.projects/{}", store(), ws, name);
    let text = fs::read_to_string(&file).map_err(|e| format!("cannot read {file}: {e}"))?;
    let (path, payload) = text.split_once('\n').unwrap_or((&text, ""));
    let settings = if payload.trim().is_empty() {
        None
    } else {
        Some(parse_project_settings(payload)?)
    };
    Ok((path.to_string(), settings))
}

/// Replace settings while retaining the registered path. Caller holds the store lock.
pub fn write_project_settings(
    ws: &str,
    name: &str,
    settings: Option<&Value>,
) -> Result<(), String> {
    let file = format!("{}/{}/.projects/{}", store(), ws, name);
    let text = fs::read_to_string(&file).map_err(|e| format!("cannot read {file}: {e}"))?;
    let path = text.split('\n').next().unwrap_or("");
    let payload = match settings {
        Some(value) => {
            let value = parse_project_settings(&value.to_string())?;
            format!("{}\n", serde_json::to_string_pretty(&value).unwrap())
        }
        None => String::new(),
    };
    fs::write(&file, format!("{path}\n{payload}")).map_err(|e| format!("cannot write {file}: {e}"))
}

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
