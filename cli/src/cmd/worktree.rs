//! Task worktrees: <repo>/.worktrees/<T-id>, removed when the task reaches 11_done
//! (port of lib/worktree.sh).

use crate::commit::store_commit;
use crate::core::{basename, die, dirname, id_of_file, need_value, task_file, ws_of_file};
use crate::frontmatter::{fm_get, fm_quote, fm_require, fm_set, fm_unset, log_append};
use crate::lock::lock_acquire;
use crate::projects::project_path;
use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

const USAGE: &str = "usage: task worktree <id> [--branch B] [--base REF] | --remove [--force]";

/// Repo path of the task's project; empty when the task has no registered project.
fn worktree_repo(file: &str) -> String {
    let proj = fm_get(file, "project");
    if proj.is_empty() {
        return String::new();
    }
    project_path(&ws_of_file(file), &proj)
}

/// `git -C dir <args>` quietly; Some(trimmed stdout) on success.
fn git_in(dir: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim_end_matches('\n').to_string())
}

/// Registered worktree: the directory exists and git recognises it.
fn worktree_alive(path: &str) -> bool {
    Path::new(&format!("{path}/.git")).exists()
        && git_in(path, &["rev-parse", "--is-inside-work-tree"]).is_some()
}

/// Cleans up the worktree of a task. Never fails: problems are logged.
/// `result` decides about the branch (only `merged` deletes it, and only with -d).
/// `force` removes a dirty worktree too.
pub fn worktree_cleanup(file: &str, result: &str, force: bool) {
    let wt = fm_get(file, "worktree");
    if wt.is_empty() {
        return;
    }
    let repo = worktree_repo(file);
    if repo.is_empty() || !Path::new(&repo).is_dir() {
        log_append(file, "task", &format!("worktree kept: project repository not found for {wt}"));
        return;
    }
    if !Path::new(&wt).is_dir() {
        let _ = git_in(&repo, &["worktree", "prune"]);
        let _ = fm_unset(file, "worktree");
        log_append(file, "task", &format!("worktree {wt} already gone"));
        return;
    }
    if !force && !git_in(&wt, &["status", "--porcelain"]).unwrap_or_default().is_empty() {
        log_append(file, "task", &format!("worktree kept: uncommitted changes in {wt}"));
        return;
    }
    let branch = git_in(&wt, &["symbolic-ref", "--short", "-q", "HEAD"]).unwrap_or_default();
    let mut args = vec!["-C", repo.as_str(), "worktree", "remove"];
    if force {
        args.push("--force");
    }
    args.push(wt.as_str());
    let out = Command::new("git")
        .args(&args)
        .stdin(Stdio::null())
        .output();
    match out {
        Ok(o) if o.status.success() => {}
        other => {
            let msg = match other {
                Ok(o) => format!(
                    "{}{}",
                    String::from_utf8_lossy(&o.stdout),
                    String::from_utf8_lossy(&o.stderr)
                ),
                Err(e) => e.to_string(),
            };
            let first = msg.split('\n').next().unwrap_or("");
            log_append(file, "task", &format!("worktree kept: cannot remove {wt}: {first}"));
            return;
        }
    }
    let _ = fm_unset(file, "worktree");
    log_append(file, "task", &format!("worktree removed: {wt}"));
    if result == "merged" && !branch.is_empty() && git_in(&repo, &["branch", "-d", &branch]).is_none() {
        log_append(file, "task", &format!("branch {branch} kept (not merged locally)"));
    }
}

pub fn cmd_worktree(args: &[String]) -> i32 {
    let (mut id, mut branch, mut base) = (String::new(), String::new(), String::new());
    let (mut remove, mut force) = (false, false);
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--branch" => {
                branch = need_value(args, i).to_string();
                i += 2;
            }
            "--base" => {
                base = need_value(args, i).to_string();
                i += 2;
            }
            "--remove" => {
                remove = true;
                i += 1;
            }
            "--force" => {
                force = true;
                i += 1;
            }
            _ if a.starts_with('-') => die(format!("unknown option: {a}")),
            _ => {
                if !id.is_empty() {
                    die(USAGE);
                }
                id = a.to_string();
                i += 1;
            }
        }
    }
    if id.is_empty() {
        die(USAGE);
    }
    if !remove && force {
        die("--force only goes with --remove");
    }
    if remove && (!branch.is_empty() || !base.is_empty()) {
        die("--remove does not take --branch or --base");
    }
    lock_acquire();
    let f = task_file(&id);
    fm_require(&f);
    let tid = id_of_file(&f);
    let wt = fm_get(&f, "worktree");

    if remove {
        if wt.is_empty() {
            println!("{tid} has no worktree");
            return 0;
        }
        worktree_cleanup(&f, "", force);
        store_commit();
        if !fm_get(&f, "worktree").is_empty() {
            println!("{tid}: worktree kept (see the log; --force removes it anyway)");
        } else {
            println!("{tid}: worktree removed");
        }
        return 0;
    }

    if fm_get(&f, "project").is_empty() {
        die(format!("{tid} has no project; run: task set {tid} project <name>"));
    }
    let repo = worktree_repo(&f);
    if repo.is_empty() {
        die(format!(
            "project of {tid} has no path (register it: task project add <name> <path>)"
        ));
    }
    if !Path::new(&repo).is_dir() {
        die(format!("project path does not exist: {repo}"));
    }
    if git_in(&repo, &["rev-parse", "--git-dir"]).is_none() {
        die(format!("not a git repository: {repo}"));
    }
    let repo = fs::canonicalize(&repo)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or(repo);

    if !wt.is_empty() && worktree_alive(&wt) {
        println!("{wt}");
        return 0;
    }

    let wt = format!("{repo}/.worktrees/{tid}");
    if Path::new(&wt).exists() && !worktree_alive(&wt) {
        die(format!("{wt} exists but is not a git worktree"));
    }

    if !Path::new(&wt).exists() {
        if git_in(&repo, &["check-ignore", "-q", ".worktrees"]).is_none() {
            let excl = git_in(
                &repo,
                &["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"],
            )
            .unwrap_or_else(|| die("cannot locate git exclude file"));
            let _ = fs::create_dir_all(dirname(&excl));
            let existing = fs::read(&excl).unwrap_or_default();
            let mut add = String::new();
            if !existing.is_empty() && *existing.last().unwrap() != b'\n' {
                add.push('\n');
            }
            add.push_str(".worktrees/\n");
            if let Ok(mut h) = fs::OpenOptions::new().append(true).create(true).open(&excl) {
                let _ = h.write_all(add.as_bytes());
            }
        }
        if branch.is_empty() {
            let b = basename(&f);
            let b = b.strip_suffix(".md").unwrap_or(b);
            let slug = b.strip_prefix(tid.as_str()).unwrap_or(b);
            let slug = slug.strip_prefix('-').unwrap_or(slug);
            branch = if slug.is_empty() {
                format!("task/{tid}")
            } else {
                format!("task/{tid}-{slug}")
            };
        }
        let exists = git_in(&repo, &["show-ref", "--verify", "--quiet", &format!("refs/heads/{branch}")])
            .is_some();
        let mut a: Vec<&str> = vec!["-C", &repo, "worktree", "add", "-q"];
        if exists {
            a.push(&wt);
            a.push(&branch);
        } else {
            a.extend(["-b", &branch, &wt]);
            if !base.is_empty() {
                a.push(&base);
            }
        }
        let ok = Command::new("git")
            .args(&a)
            .stdin(Stdio::null())
            .stdout(Stdio::from(std::io::stderr()))
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !ok {
            die("git worktree add failed");
        }
    } else {
        branch = git_in(&wt, &["symbolic-ref", "--short", "-q", "HEAD"])
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "(detached)".to_string());
    }
    if fm_set(&f, "worktree", &fm_quote(&wt)).is_err() {
        die(format!("cannot update {f}"));
    }
    log_append(&f, "task", &format!("worktree {wt} (branch {branch})"));
    store_commit();
    println!("{wt}");
    0
}
