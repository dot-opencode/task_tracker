//! Creating and reading tasks: new, show, path, ls (lib/tasks.sh).

use crate::commit::store_commit;
use crate::core::*;
use crate::frontmatter::*;
use crate::lock::lock_acquire;
use crate::projects::{detect_project, project_ws};
use crate::subtasks::*;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::io::Write;

/// ASCII words of the title joined by '-', at most 50 characters.
pub fn slugify(title: &str) -> String {
    let lowered: String = title
        .bytes()
        .map(|b| {
            let b = b.to_ascii_lowercase();
            if b.is_ascii_lowercase() || b.is_ascii_digit() {
                b as char
            } else {
                ' '
            }
        })
        .collect();
    let mut out = String::new();
    for w in lowered.split_whitespace() {
        if out.is_empty() {
            out = w.chars().take(50).collect();
        } else if out.len() + 1 + w.len() <= 50 {
            out.push('-');
            out.push_str(w);
        } else {
            break;
        }
    }
    out
}

pub fn valid_slug(s: &str) -> bool {
    let mut c = s.chars();
    s.chars().count() <= 50
        && matches!(c.next(), Some(f) if f.is_ascii_lowercase() || f.is_ascii_digit())
        && c.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

const NEW_USAGE: &str = "usage: task new <title> [--project P] [--ws W] [--source URL] [--slug S] [--body TEXT|-] [--ready] [--parent ID] [--depends ID,...]";

pub fn cmd_new(args: &[String]) -> i32 {
    let mut title = String::new();
    let (mut project, mut ws_opt, mut source, mut slug, mut body) = (
        String::new(),
        String::new(),
        String::new(),
        String::new(),
        String::new(),
    );
    let (mut have_body, mut ready) = (false, false);
    let (mut parent, mut depends) = (String::new(), String::new());
    let mut opts = true;
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        if opts && a == "--" {
            opts = false;
            i += 1;
            continue;
        }
        if !opts && a.starts_with('-') && a.len() >= 2 {
            if !title.is_empty() {
                die("usage: task new <title> [options] (quote the title)");
            }
            title = a.to_string();
            i += 1;
            continue;
        }
        match a {
            "--project" => {
                project = need_value(args, i).to_string();
                i += 2;
            }
            "--ws" => {
                ws_opt = need_value(args, i).to_string();
                i += 2;
            }
            "--source" => {
                source = need_value(args, i).to_string();
                i += 2;
            }
            "--slug" => {
                slug = need_value(args, i).to_string();
                i += 2;
            }
            "--body" => {
                body = need_value(args, i).to_string();
                have_body = true;
                i += 2;
            }
            "--ready" => {
                ready = true;
                i += 1;
            }
            "--parent" => {
                parent = need_value(args, i).to_string();
                i += 2;
            }
            "--depends" => {
                depends.push(' ');
                depends.push_str(need_value(args, i));
                i += 2;
            }
            _ if a.starts_with('-') => die(format!("unknown option: {a}")),
            _ => {
                if !title.is_empty() {
                    die("usage: task new <title> [options] (quote the title)");
                }
                title = a.to_string();
                i += 1;
            }
        }
    }
    let title = trim(&title).to_string();
    if title.is_empty() {
        die(NEW_USAGE);
    }
    if !single_line(&title) {
        die("title must be a single line");
    }
    if !ws_opt.is_empty() && !valid_ws(&ws_opt) {
        die(format!("invalid workspace '{ws_opt}'"));
    }
    // A registered project implies its workspace; without one --ws must name an existing workspace.
    if !ws_opt.is_empty() && project.is_empty() {
        require_workspace(&ws_opt);
    }
    if !source.is_empty() && !single_line(&source) {
        die("source must be a single line");
    }
    if have_body {
        body = read_text_arg(&body);
        reject_sections("body", &body);
    }
    if !slug.is_empty() {
        if !valid_slug(&slug) {
            die(format!(
                "invalid slug '{slug}' (lowercase letters, digits, hyphens; at most 50 characters)"
            ));
        }
    } else {
        slug = slugify(&title);
    }

    let mut pid = String::new();
    let mut pf = String::new();
    if !parent.is_empty() {
        pid = normalize_id(&parent).unwrap_or_else(|| die(format!("invalid task id '{parent}'")));
        pf = task_file(&pid);
    }
    let ws;
    if !project.is_empty() {
        if !valid_project(&project) {
            die(format!("invalid project name '{project}'"));
        }
        ws = project_ws(&project, &ws_opt);
    } else if !pid.is_empty() {
        ws = ws_of_file(&pf);
        if !ws_opt.is_empty() && ws_opt != ws {
            die(format!("parent {pid} is in workspace {ws}, not {ws_opt}"));
        }
        project = fm_get(&pf, "project");
    } else if let Some((dws, dname)) = detect_project(&ws_opt) {
        ws = dws;
        project = dname;
    } else {
        ws = if ws_opt.is_empty() {
            config_get("default_workspace", "work")
        } else {
            ws_opt.clone()
        };
    }
    if !pid.is_empty() && ws != ws_of_file(&pf) {
        die(format!("parent {pid} is in another workspace"));
    }
    let deps = st_parse_ids(&depends);
    for d in &deps {
        task_file(d);
    }
    let depends = deps.join(" ");
    let folder = if ready { "01_ready" } else { "00_backlog" };

    lock_acquire();
    ensure_workspace(&ws);
    let n = next_id();
    let id = format!("T-{:04}", n);
    let slug_part = if slug.is_empty() {
        String::new()
    } else {
        format!("-{slug}")
    };
    let dir = format!("{}/{}/{}", store(), ws, folder);
    let tmp = format!("{}/.{}.{}.tmp", dir, id, std::process::id());
    let dest = format!("{dir}/{id}{slug_part}.md");
    let mut content = format!("---\nid: {id}\ntitle: {}\n", fm_quote_always(&title));
    if !project.is_empty() {
        content.push_str(&format!("project: {}\n", fm_quote(&project)));
    }
    content.push_str(&format!("created: {}\n", date_ymd()));
    if !source.is_empty() {
        content.push_str(&format!("source: {}\n", fm_quote(&source)));
    }
    if !pid.is_empty() {
        content.push_str(&format!("parent: {pid}\n"));
    }
    if !depends.is_empty() {
        content.push_str(&format!("depends_on: {depends}\n"));
    }
    content.push_str("---\n\n");
    if !body.is_empty() {
        content.push_str(&body);
        content.push('\n');
    }
    if fs::write(&tmp, content).is_err() {
        die(format!("cannot write {tmp}"));
    }
    log_append(&tmp, "task", &format!("created in {folder}"));
    if fs::rename(&tmp, &dest).is_err() {
        die(format!("cannot move {tmp} to {dest}"));
    }
    store_commit();
    println!("{id}");
    0
}

pub fn cmd_show(args: &[String]) -> i32 {
    if args.len() != 1 {
        die("usage: task show <id>");
    }
    let f = task_file(&args[0]);
    let bytes = fs::read(&f).unwrap_or_default();
    let mut out = std::io::stdout();
    let _ = out.write_all(&bytes);
    let st = st_load();
    let kids = st.children(&id_of_file(&f));
    if !kids.is_empty() {
        println!();
        println!("## Subtasks");
        for k in kids {
            let kf = task_file(&k);
            println!(
                "subtasks: {} {} {}",
                k,
                folder_of_file(&kf),
                fm_get(&kf, "title")
            );
        }
    }
    0
}

pub fn cmd_path(args: &[String]) -> i32 {
    if args.len() != 1 {
        die("usage: task path <id>");
    }
    println!("{}", task_file(&args[0]));
    0
}

struct Rec {
    ws: String,
    folder: String,
    id: String,
    title: String,
    project: String,
    created: String,
    session: String,
    path: String,
    status: String,
    parent: String,
    deps: Vec<String>,
    blocked: Vec<String>,
    children: Vec<String>,
    done: usize,
}

fn pad(s: &str, w: usize) -> String {
    let n = s.chars().count();
    format!("{}{}  ", s, " ".repeat(w.saturating_sub(n)))
}

fn emit(
    i: usize,
    depth: usize,
    kids: &HashMap<usize, Vec<usize>>,
    seen: &mut [bool],
    ord: &mut Vec<(usize, usize)>,
) {
    if seen[i] {
        return;
    }
    seen[i] = true;
    ord.push((i, depth));
    if let Some(ks) = kids.get(&i) {
        for &k in ks {
            emit(k, depth + 1, kids, seen, ord);
        }
    }
}

fn print_table(recs: &[Rec]) {
    let n = recs.len();
    let mut idx: HashMap<&str, usize> = HashMap::new();
    let mut multi = false;
    for (i, r) in recs.iter().enumerate() {
        idx.insert(r.id.as_str(), i);
        if i > 0 && r.ws != recs[0].ws {
            multi = true;
        }
    }
    let has_parent = |i: usize| -> Option<usize> {
        let p = recs[i].parent.as_str();
        if !p.is_empty() {
            if let Some(&pi) = idx.get(p) {
                if pi != i {
                    return Some(pi);
                }
            }
        }
        None
    };
    let mut kids: HashMap<usize, Vec<usize>> = HashMap::new();
    for i in 0..n {
        if let Some(p) = has_parent(i) {
            kids.entry(p).or_default().push(i);
        }
    }
    let mut seen = vec![false; n];
    let mut ord = Vec::new();
    for i in 0..n {
        if has_parent(i).is_none() {
            emit(i, 0, &kids, &mut seen, &mut ord);
        }
    }
    for i in 0..n {
        emit(i, 0, &kids, &mut seen, &mut ord);
    }
    let (mut ww, mut wi, mut ws_w, mut wp) = (2usize, 2usize, 6usize, 7usize);
    let mut titles: HashMap<usize, String> = HashMap::new();
    for &(i, depth) in &ord {
        let r = &recs[i];
        let mut t = r.title.clone();
        if depth > 0 {
            t = format!("↳ {t}");
        }
        if !r.children.is_empty() {
            t = format!("{t} [{}/{}]", r.done, r.children.len());
        }
        if !r.blocked.is_empty() {
            t = format!("{t} (waits {})", r.blocked.join(" "));
        }
        titles.insert(i, t);
        ww = ww.max(r.ws.chars().count());
        wi = wi.max(r.id.chars().count());
        ws_w = ws_w.max(r.status.chars().count());
        let pr = if r.project.is_empty() {
            "-"
        } else {
            &r.project
        };
        wp = wp.max(pr.chars().count());
    }
    let mut head = String::new();
    if multi {
        head.push_str(&pad("WS", ww));
    }
    head.push_str(&pad("ID", wi));
    head.push_str(&pad("STATUS", ws_w));
    head.push_str(&pad("PROJECT", wp));
    head.push_str("TITLE");
    println!("{head}");
    for &(i, _) in &ord {
        let r = &recs[i];
        let mut line = String::new();
        if multi {
            line.push_str(&pad(&r.ws, ww));
        }
        line.push_str(&pad(&r.id, wi));
        line.push_str(&pad(&r.status, ws_w));
        line.push_str(&pad(
            if r.project.is_empty() {
                "-"
            } else {
                &r.project
            },
            wp,
        ));
        line.push_str(&titles[&i]);
        println!("{line}");
    }
}

pub fn cmd_ls(args: &[String]) -> i32 {
    const USAGE: &str = "usage: task ls [<folder>|--waiting|--all] [--ws W] [--parent ID] [--json]";
    let mut mode = "default";
    let mut folder = "";
    let (mut ws, mut parent) = (String::new(), String::new());
    let mut json = false;
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--waiting" => {
                mode = "waiting";
                i += 1;
            }
            "--all" => {
                mode = "all";
                i += 1;
            }
            "--json" => {
                json = true;
                i += 1;
            }
            "--ws" => {
                ws = need_value(args, i).to_string();
                i += 2;
            }
            "--parent" => {
                let v = need_value(args, i);
                parent = normalize_id(v).unwrap_or_else(|| die(format!("invalid task id '{v}'")));
                i += 2;
            }
            _ if a.starts_with('-') => die(format!("unknown option: {a}")),
            _ => {
                if !folder.is_empty() {
                    die(USAGE);
                }
                folder = resolve_folder(a).unwrap_or_else(|| {
                    die(format!("unknown folder '{a}' (folders: {})", folders_str()))
                });
                mode = "folder";
                i += 1;
            }
        }
    }
    if !ws.is_empty() {
        if !valid_ws(&ws) {
            die(format!("invalid workspace '{ws}'"));
        }
        require_workspace(&ws);
    }
    let n = crate::cmd::archive::archive_due(true);
    let _ = n;
    crate::cmd::check_mrs::mr_check_due();
    let st = st_load();
    if !parent.is_empty() {
        task_file(&parent);
    }
    let (mut arch_n, mut post_n) = (0, 0);
    let mut files: Vec<String> = Vec::new();
    for f in all_task_files() {
        if !parent.is_empty() && st.parent_of(&id_of_file(&f)) != parent {
            continue;
        }
        let w = ws_of_file(&f);
        let fo = folder_of_file(&f);
        if !ws.is_empty() && w != ws {
            continue;
        }
        let keep = match mode {
            "all" => true,
            "folder" => fo == folder,
            "waiting" => WAITING_FOLDERS.contains(&fo.as_str()),
            _ => {
                // Everything that is not archived, done included.
                if fo == "archive" {
                    arch_n += 1;
                    false
                } else if fo == "postponed" {
                    post_n += 1;
                    false
                } else {
                    true
                }
            }
        };
        if keep {
            files.push(f);
        }
    }
    let mut recs: Vec<Rec> = Vec::new();
    for row in task_rows(&files) {
        let tid = id_of_file(&row.path);
        let fo = folder_of_file(&row.path);
        recs.push(Rec {
            ws: ws_of_file(&row.path),
            status: folder_status(&fo).to_string(),
            folder: fo,
            id: tid.clone(),
            title: row.title,
            project: row.project,
            created: row.created,
            session: row.session,
            path: row.path,
            parent: st.parent_of(&tid),
            deps: st.deps_of(&tid),
            blocked: st.blocked_by(&tid),
            children: st.children(&tid),
            done: st.done_count(&tid),
        });
    }

    if json {
        let opt = |s: &str| if s.is_empty() { Value::Null } else { json!(s) };
        let arr: Vec<Value> = recs
            .iter()
            .map(|r| {
                json!({
                    "id": r.id, "title": r.title, "project": opt(&r.project),
                    "workspace": r.ws, "folder": r.folder, "status": r.status,
                    "created": r.created, "session": opt(&r.session), "path": r.path,
                    "parent": opt(&r.parent), "depends_on": r.deps,
                    "blocked_by": r.blocked, "children": r.children,
                })
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&arr).unwrap());
        return 0;
    }
    if recs.is_empty() {
        println!("no tasks");
    } else {
        print_table(&recs);
    }
    if mode == "default" && post_n > 0 {
        println!("postponed: {post_n} (task ls postponed)");
    }
    if mode == "default" && arch_n > 0 {
        println!("archive: {arch_n} (task ls archive)");
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_rules() {
        assert_eq!(
            slugify("Fix internal service URL: port drift (ABC-6719)"),
            "fix-internal-service-url-port-drift-abc-6719"
        );
        assert_eq!(
            slugify("Добавить SAN для ianus.localhost"),
            "san-ianus-localhost"
        );
        assert_eq!(slugify("Исправить дрейф"), "");
        assert_eq!(
            slugify("aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd eeeeeeeeee ffffffffff"),
            "aaaaaaaaaa-bbbbbbbbbb-cccccccccc-dddddddddd"
        );
        assert_eq!(slugify(&"x".repeat(60)), "x".repeat(50));
        assert_eq!(slugify("!!!"), "");
        assert!(valid_slug("custom-name"));
        assert!(!valid_slug("Bad Slug"));
        assert!(!valid_slug(&"a".repeat(51)));
    }
}
