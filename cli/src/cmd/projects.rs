//! `task project add|ls|import-memory` (lib/projects.sh). Shared helpers
//! (project_path, project_ws, detect_project) live in crate::projects.

use crate::commit::store_commit;
use crate::core::*;
use crate::lock::lock_acquire;
use crate::projects::project_path;
use std::fs;
use std::path::Path;

/// Writes the registry entry; returns added|updated|unchanged.
fn register_project(ws: &str, name: &str, path: &str) -> &'static str {
    let f = format!("{}/{}/.projects/{}", store(), ws, name);
    if Path::new(&f).is_file() {
        let old = read_file(&f)
            .map(|t| t.split('\n').next().unwrap_or("").to_string())
            .unwrap_or_default();
        if old == path {
            return "unchanged";
        }
        if fs::write(&f, format!("{path}\n")).is_err() {
            die(format!("cannot write {f}"));
        }
        return "updated";
    }
    let _ = fs::create_dir_all(format!("{}/{}/.projects", store(), ws));
    if fs::write(&f, format!("{path}\n")).is_err() {
        die(format!("cannot write {f}"));
    }
    "added"
}

fn canon(p: &str) -> String {
    fs::canonicalize(p)
        .map(|c| c.to_string_lossy().into_owned())
        .unwrap_or_else(|_| p.to_string())
}

fn project_add(args: &[String]) {
    const USAGE: &str = "usage: task project add [<name> [<path>]] [--ws W]";
    let (mut name, mut path, mut ws) = (String::new(), String::new(), String::new());
    let mut n = 0;
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        if a == "--ws" {
            ws = need_value(args, i).to_string();
            i += 2;
        } else if a.starts_with('-') {
            die(format!("unknown option: {a}"));
        } else {
            n += 1;
            match n {
                1 => name = a.to_string(),
                2 => path = a.to_string(),
                _ => die(USAGE),
            }
            i += 1;
        }
    }
    if path.is_empty() {
        path = ".".into();
    }
    if !Path::new(&path).is_dir() {
        die(format!("not a directory: {path}"));
    }
    let path = canon(&path);
    if name.is_empty() {
        name = basename(&path).to_string();
    }
    if !valid_project(&name) {
        die(format!("invalid project name '{name}'"));
    }
    if ws.is_empty() {
        ws = config_get("default_workspace", "work");
    }
    if !valid_ws(&ws) {
        die(format!("invalid workspace '{ws}'"));
    }
    lock_acquire();
    ensure_workspace(&ws);
    match register_project(&ws, &name, &path) {
        "added" => println!("added project {name} ({ws}): {path}"),
        "updated" => println!("updated project {name} ({ws}): {path}"),
        _ => println!("project {name} ({ws}) is already registered: {path}"),
    }
    store_commit();
}

fn project_ls(args: &[String]) {
    let mut ws = String::new();
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--ws" {
            ws = need_value(args, i).to_string();
            i += 2;
        } else {
            die("usage: task project ls [--ws W]");
        }
    }
    if !ws.is_empty() {
        if !valid_ws(&ws) {
            die(format!("invalid workspace '{ws}'"));
        }
        require_workspace(&ws);
    }
    let mut rows: Vec<(String, String)> = Vec::new();
    for w in list_workspaces() {
        if !ws.is_empty() && w != ws {
            continue;
        }
        let Ok(rd) = fs::read_dir(format!("{}/{}/.projects", store(), w)) else {
            continue;
        };
        let mut names: Vec<String> = rd
            .flatten()
            .filter(|e| e.path().is_file())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        for n in names {
            rows.push((w.clone(), n));
        }
    }
    if rows.is_empty() {
        println!("no projects");
        return;
    }
    let wsw = rows.iter().map(|r| r.0.chars().count()).max().unwrap_or(0);
    let nw = rows.iter().map(|r| r.1.chars().count()).max().unwrap_or(0);
    for (w, n) in &rows {
        let p = project_path(w, n);
        let suffix = if Path::new(&p).is_dir() {
            ""
        } else {
            " (missing)"
        };
        println!(
            "{w}{}  {n}{}  {p}{suffix}",
            " ".repeat(wsw - w.chars().count()),
            " ".repeat(nw - n.chars().count())
        );
    }
}

fn project_import_memory(args: &[String]) {
    let mut ws = String::new();
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--ws" {
            ws = need_value(args, i).to_string();
            i += 2;
        } else {
            die("usage: task project import-memory [--ws W]");
        }
    }
    if !ws.is_empty() && !valid_ws(&ws) {
        die(format!("invalid workspace '{ws}'"));
    }
    let mem = match std::env::var("AGENT_MEMORY_HOME") {
        Ok(v) if !v.is_empty() => v,
        _ => format!(
            "{}/.agent-memory",
            std::env::var("HOME").unwrap_or_default()
        ),
    };
    if !Path::new(&mem).is_dir() {
        die(format!("no agent-memory store at {mem}"));
    }
    lock_acquire();
    let (mut imported, mut updated, mut unchanged, mut skipped) = (0, 0, 0, 0);
    let mut skipped_names: Vec<String> = Vec::new();
    let mut wdirs: Vec<String> = fs::read_dir(&mem)
        .map(|rd| {
            rd.flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    wdirs.sort();
    for w in wdirs {
        let pdir = format!("{mem}/{w}/projects");
        let Ok(rd) = fs::read_dir(&pdir) else {
            continue;
        };
        let mut names: Vec<String> = rd
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        for name in names {
            let pf = format!("{pdir}/{name}/.project-path");
            if !Path::new(&pf).is_file() {
                continue;
            }
            if !ws.is_empty() && w != ws {
                continue;
            }
            if !valid_ws(&w) {
                continue;
            }
            let p = read_file(&pf)
                .map(|t| t.split('\n').next().unwrap_or("").to_string())
                .unwrap_or_default();
            if !valid_project(&name) || p.is_empty() || !Path::new(&p).is_dir() {
                skipped += 1;
                skipped_names.push(name);
                continue;
            }
            ensure_workspace(&w);
            match register_project(&w, &name, &canon(&p)) {
                "added" => imported += 1,
                "updated" => updated += 1,
                _ => unchanged += 1,
            }
        }
    }
    println!("imported {imported}, updated {updated}, unchanged {unchanged}, skipped {skipped}");
    if skipped > 0 {
        println!("skipped (path missing): {}", skipped_names.join(", "));
    }
    store_commit();
}

pub fn cmd_project(args: &[String]) -> i32 {
    let sub = args.first().map(|s| s.as_str()).unwrap_or("");
    let rest = if args.is_empty() { &[][..] } else { &args[1..] };
    match sub {
        "add" => project_add(rest),
        "ls" => project_ls(rest),
        "import-memory" => project_import_memory(rest),
        _ => die("usage: task project add|ls|import-memory"),
    }
    0
}
