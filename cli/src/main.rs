//! `task` — Rust port of the Bash CLI (bin/task + lib/*.sh).

// Several shared helpers are only used by commands still being ported.
#![allow(dead_code)]

mod cmd;
mod commit;
mod core;
mod frontmatter;
mod lock;
mod projects;
mod subtasks;

use crate::core::{die, ensure_store, exit, VERSION};

const USAGE: &str = "usage: task <command> [args]        (task --version prints the version)

tasks:
  task new <title> [--project P] [--ws W] [--source URL] [--slug S] [--body TEXT|-] [--ready] [--parent ID] [--depends ID,ID]
  task ls [<folder>|--waiting|--all] [--ws W] [--parent ID] [--json]
  task show <id>
  task logs [<id>] [-n N] [-f]
  task path <id>
  task mv <id> <folder> [--reason TEXT] [--force]
  task log <id> <message|-> [--author A]
  task set <id> <key> <value>      (also parent <id>, depends_on \"<ids>\")
  task unset <id> <key>
  task done <id> --result pr|merged|kept|discarded|cancelled [--summary TEXT|-] [--force]
  task merged <id> [--summary TEXT|-] [--force]
  task worktree <id> [--branch B] [--base REF] | --remove [--force]
  task check-mrs                      (check MR/PR state of unmerged tasks now)
  task archive <id> | --due
  task unarchive <id>
  task postpone <id> [--reason TEXT]
  task resume <id>
  task bind <id> --session <session-id>
  task find --session <session-id>

store:
  task project add [<name> [<path>]] [--ws W]
  task project ls [--ws W]
  task project import-memory [--ws W]
  task backup
  task doctor

automation:
  task signal <id> <signal> --session <session-id> [--text TEXT]
  task approve <id> [--now]
  task auto [on [DURATION] | off]
  task run --once
  task open <id>
  task next
  task install-opencode

<id>: T-0083, t-83 or 83
folders: 00_backlog 01_ready 02_exploring 03_brainstorming 04_spec_review 05_planning
         06_plan_review 07_approved 08_implementing 09_finishing 10_unmerged 11_done blocked postponed archive
         (also by number or status name: 3, 03, plan_review)
store: $AGENT_TASKS_HOME, default ~/.agent-tasks
";

type Handler = fn(&[String]) -> i32;

fn handler(cmd: &str) -> Option<Handler> {
    Some(match cmd {
        "approve" => cmd::approve::cmd_approve,
        "archive" => cmd::archive::cmd_archive,
        "auto" => cmd::auto::cmd_auto,
        "backup" => commit::cmd_backup,
        "bind" => cmd::session::cmd_bind,
        "check-mrs" => cmd::check_mrs::cmd_check_mrs,
        "doctor" => cmd::doctor::cmd_doctor,
        "done" => cmd::edit::cmd_done,
        "find" => cmd::session::cmd_find,
        "install-opencode" => cmd::install::cmd_install_opencode,
        "log" => cmd::edit::cmd_log,
        "logs" => cmd::logs::cmd_logs,
        "ls" => cmd::tasks::cmd_ls,
        "merged" => cmd::edit::cmd_merged,
        "mv" => cmd::edit::cmd_mv,
        "new" => cmd::tasks::cmd_new,
        "next" => cmd::open::cmd_next,
        "open" => cmd::open::cmd_open,
        "path" => cmd::tasks::cmd_path,
        "postpone" => cmd::postpone::cmd_postpone,
        "project" => cmd::projects::cmd_project,
        "resume" => cmd::postpone::cmd_resume,
        "run" => cmd::run::cmd_run,
        "set" => cmd::edit::cmd_set,
        "show" => cmd::tasks::cmd_show,
        "signal" => cmd::signal::cmd_signal,
        "unarchive" => cmd::archive::cmd_unarchive,
        "unset" => cmd::edit::cmd_unset,
        "worktree" => cmd::worktree::cmd_worktree,
        _ => return None,
    })
}

/// `^[a-z][a-z-]*$`
fn command_shaped(s: &str) -> bool {
    let mut c = s.chars();
    matches!(c.next(), Some(f) if f.is_ascii_lowercase()) && c.all(|c| c.is_ascii_lowercase() || c == '-')
}

fn real_main() -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("");
    match cmd {
        "-v" | "--version" => {
            println!("task {VERSION}");
            return 0;
        }
        "-h" | "--help" | "help" => {
            print!("{USAGE}");
            return 0;
        }
        "" => {
            if args.is_empty() {
                eprint!("{USAGE}");
                return 1;
            }
        }
        _ => {}
    }
    if !command_shaped(cmd) {
        die(format!("unknown command: {cmd} (see 'task --help')"));
    }
    let Some(h) = handler(cmd) else {
        if let Some(field) = cmd.strip_prefix("set-").filter(|f| !f.is_empty()) {
            // Agents guess `set-url`, `set-pr`…: point them at the real form.
            die(format!(
                "unknown command: {cmd}; to set a field use 'task set <id> {field} <value>' (keys: title project source session spec plan pr result parent depends_on)"
            ));
        }
        die(format!("unknown command: {cmd} (see 'task --help')"));
    };
    let rest = &args[1..];
    // `task <cmd> --help` prints that command's usage lines instead of failing on an unknown option.
    if matches!(rest.first().map(|s| s.as_str()), Some("-h" | "--help")) {
        let exact = format!("  task {cmd}");
        let lines: Vec<&str> = USAGE
            .lines()
            .filter(|l| {
                l.strip_prefix(exact.as_str())
                    .map(|r| r.is_empty() || r.starts_with(' '))
                    .unwrap_or(false)
            })
            .collect();
        if lines.is_empty() {
            print!("{USAGE}");
        } else {
            for l in lines {
                println!("{l}");
            }
        }
        return 0;
    }
    ensure_store();
    h(rest)
}

fn main() {
    // Behave like a shell tool when the reader closes the pipe.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    let code = real_main();
    exit(code);
}
