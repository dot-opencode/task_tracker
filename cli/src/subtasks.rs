//! Subtasks (`parent`) and dependencies (`depends_on`) (lib/subtasks.sh).
//!
//! `st_load` scans every task file once into an `St` index; the helpers read
//! it. Call `st_load` again after files moved.

use crate::core::{self, die, folder_of_file, id_of_file, read_file, store, task_file, ws_of_file};
use crate::cmd::edit::move_task;
use crate::frontmatter::{fm_set, result_append};
use std::collections::HashSet;

#[derive(Debug, Clone, Default)]
pub struct Entry {
    pub id: String,
    pub folder: String,
    pub parent: String,
    pub deps: Vec<String>,
    pub ws: String,
    /// path relative to the store
    pub rel: String,
}

#[derive(Debug, Clone, Default)]
pub struct St {
    pub entries: Vec<Entry>,
}

/// awk `nid`: strip quotes/space, `T-83`/`83` -> `T-0083`, anything else as is.
fn nid(s: &str) -> String {
    let t = s.trim_matches(|c: char| c == '"' || c.is_whitespace());
    let digits = t
        .strip_prefix("T-")
        .or_else(|| t.strip_prefix("t-"))
        .unwrap_or(t);
    if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
        let n: u64 = digits.parse().unwrap_or(0);
        return format!("T-{:04}", n);
    }
    t.to_string()
}

fn ids_of(s: &str) -> Vec<String> {
    s.replace(',', " ").split_whitespace().map(nid).collect()
}

pub fn st_load() -> St {
    let mut entries = Vec::new();
    let prefix = format!("{}/", store());
    for f in core::all_task_files() {
        let text = read_file(&f).unwrap_or_default();
        let mut parent = String::new();
        let mut deps = Vec::new();
        let mut state = 0;
        for (i, line) in text.split('\n').enumerate() {
            if i == 0 {
                state = if line == "---" { 1 } else { 0 };
                continue;
            }
            if state == 1 {
                if line == "---" {
                    state = 2;
                    continue;
                }
                if let Some(v) = line.strip_prefix("parent: ") {
                    parent = nid(v);
                } else if let Some(v) = line.strip_prefix("depends_on: ") {
                    deps = ids_of(v);
                }
            }
        }
        let b = core::basename(&f);
        let digits: String = b[2..].chars().take_while(|c| c.is_ascii_digit()).collect();
        let id = nid(&format!("T-{digits}"));
        entries.push(Entry {
            id,
            folder: folder_of_file(&f),
            parent,
            deps,
            ws: ws_of_file(&f),
            rel: f.strip_prefix(&prefix).unwrap_or(&f).to_string(),
        });
    }
    St { entries }
}

/// Normalized unique ids from a comma/space separated list.
pub fn st_parse_ids(raw: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for t in raw.replace(',', " ").split_whitespace() {
        let n = core::normalize_id(t).unwrap_or_else(|| die(format!("invalid task id '{t}'")));
        if !out.contains(&n) {
            out.push(n);
        }
    }
    out
}

fn done_like(f: &str) -> bool {
    f == "11_done" || f == "archive"
}

impl St {
    fn find(&self, id: &str) -> Option<&Entry> {
        self.entries.iter().find(|e| e.id == id)
    }
    pub fn folder(&self, id: &str) -> String {
        self.find(id).map(|e| e.folder.clone()).unwrap_or_default()
    }
    pub fn parent_of(&self, id: &str) -> String {
        self.find(id).map(|e| e.parent.clone()).unwrap_or_default()
    }
    pub fn deps_of(&self, id: &str) -> Vec<String> {
        self.find(id).map(|e| e.deps.clone()).unwrap_or_default()
    }
    pub fn children(&self, id: &str) -> Vec<String> {
        self.entries
            .iter()
            .filter(|e| e.parent == id)
            .map(|e| e.id.clone())
            .collect()
    }
    /// Children that are not yet in 11_done/archive.
    pub fn open_children(&self, id: &str) -> Vec<String> {
        self.entries
            .iter()
            .filter(|e| e.parent == id && !done_like(&e.folder))
            .map(|e| e.id.clone())
            .collect()
    }
    /// Number of children of <id> in 11_done or archive.
    pub fn done_count(&self, id: &str) -> usize {
        self.entries
            .iter()
            .filter(|e| e.parent == id && done_like(&e.folder))
            .count()
    }
    /// depends_on ids whose task is not in 10_unmerged/11_done/archive (a missing task blocks).
    pub fn blocked_by(&self, id: &str) -> Vec<String> {
        let mut deps: Vec<String> = Vec::new();
        for e in &self.entries {
            if e.id == id {
                deps = e.deps.clone();
            }
        }
        deps.into_iter()
            .filter(|d| {
                let f = self
                    .entries
                    .iter()
                    .rev()
                    .find(|e| &e.id == d)
                    .map(|e| e.folder.as_str())
                    .unwrap_or("");
                f != "10_unmerged" && !done_like(f)
            })
            .collect()
    }
    /// Open children of <id> on one line ("T-0084 T-0085").
    pub fn open_list(&self, id: &str) -> String {
        self.open_children(id).join(" ")
    }
    /// 0 when from can reach target through depends_on edges.
    fn depends_reach(&self, from: &str, target: &str) -> bool {
        let mut stack: Vec<String> = vec![from.to_string()];
        let mut seen: HashSet<String> = HashSet::new();
        while !stack.is_empty() {
            let n = stack.remove(0);
            if n.is_empty() {
                continue;
            }
            if n == target {
                return true;
            }
            if !seen.insert(n.clone()) {
                continue;
            }
            stack.extend(self.deps_of(&n));
        }
        false
    }
    /// Parents that should be closed: all children done, parent still open.
    pub fn closable(&self) -> Vec<String> {
        let mut ids: Vec<String> = Vec::new();
        for e in &self.entries {
            if !e.parent.is_empty() && !ids.contains(&e.parent) {
                ids.push(e.parent.clone());
            }
        }
        let mut out: Vec<String> = ids
            .into_iter()
            .filter(|id| {
                let kids: Vec<&Entry> = self.entries.iter().filter(|e| &e.parent == id).collect();
                let tot = kids.len();
                let dn = kids.iter().filter(|e| done_like(&e.folder)).count();
                let f = self.folder(id);
                self.find(id).is_some()
                    && tot == dn
                    && f != "postponed"
                    && f != "11_done"
                    && f != "archive"
            })
            .collect();
        out.sort();
        out
    }
    /// Problems in parent/depends_on links, as (rel path, message).
    pub fn problems(&self) -> Vec<(String, String)> {
        // last entry wins per id, like awk's array assignment
        let get = |id: &str| self.entries.iter().rev().find(|e| e.id == id);
        let mut out = Vec::new();
        let cnt = self.entries.len();
        for e in &self.entries {
            let id = &e.id;
            let p = &e.parent;
            let me = get(id).unwrap();
            if !p.is_empty() {
                if p == id {
                    out.push((me.rel.clone(), "parent is the task itself".to_string()));
                } else if get(p).is_none() {
                    out.push((me.rel.clone(), format!("parent {p} does not exist")));
                } else {
                    if get(p).unwrap().ws != me.ws {
                        out.push((me.rel.clone(), format!("parent {p} is in another workspace")));
                    }
                    let mut x = p.clone();
                    let mut steps = 0;
                    while !x.is_empty() && steps <= cnt {
                        if &x == id {
                            out.push((me.rel.clone(), format!("parent cycle through {p}")));
                            break;
                        }
                        x = get(&x).map(|e| e.parent.clone()).unwrap_or_default();
                        steps += 1;
                    }
                }
            }
            for d in &me.deps {
                if d == id {
                    out.push((me.rel.clone(), "depends_on itself".to_string()));
                    continue;
                }
                if get(d).is_none() {
                    out.push((me.rel.clone(), format!("depends_on {d} does not exist")));
                    continue;
                }
                let mut vis: HashSet<String> = HashSet::new();
                if self.dfs(d, id, &mut vis) {
                    out.push((me.rel.clone(), format!("dependency cycle through {d}")));
                }
            }
        }
        out
    }
    fn dfs(&self, node: &str, target: &str, vis: &mut HashSet<String>) -> bool {
        if node == target {
            return true;
        }
        if !vis.insert(node.to_string()) {
            return false;
        }
        let deps = self
            .entries
            .iter()
            .rev()
            .find(|e| e.id == node)
            .map(|e| e.deps.clone())
            .unwrap_or_default();
        deps.iter().any(|d| self.dfs(d, target, vis))
    }
}

/// True for folders a parent may not enter while subtasks are open.
pub fn st_parent_wait_folder(f: &str) -> bool {
    matches!(f, "09_finishing" | "10_unmerged" | "11_done")
}

/// Dies when the task has open subtasks.
pub fn st_guard_open(id: &str) {
    let open = st_load().open_list(id);
    if !open.is_empty() {
        die(format!("{id} has open subtasks: {open} (use --force)"));
    }
}

pub fn st_validate_parent(id: &str, file: &str, p: &str) {
    if p == id {
        die(format!("{id} cannot be its own parent"));
    }
    let pf = task_file(p);
    if ws_of_file(&pf) != ws_of_file(file) {
        die(format!("parent {p} is in another workspace"));
    }
    let st = st_load();
    let mut x = p.to_string();
    let mut steps = 0;
    while !x.is_empty() && steps <= 10000 {
        if x == id {
            die(format!("parent cycle: {p} is below {id}"));
        }
        x = st.parent_of(&x);
        steps += 1;
    }
}

pub fn st_validate_depends(id: &str, ids: &[String]) {
    let st = st_load();
    for d in ids {
        if d.is_empty() {
            continue;
        }
        if d == id {
            die(format!("{id} cannot depend on itself"));
        }
        task_file(d);
        if st.depends_reach(d, id) {
            die(format!("dependency cycle: {d} already depends on {id}"));
        }
    }
}

/// Closes the parent <id> when every child is in 11_done/archive. Needs the lock.
/// Returns false when it did not close anything.
pub fn st_try_close(id: &str) -> bool {
    let st = st_load();
    let folder = st.folder(id);
    if matches!(folder.as_str(), "" | "postponed" | "11_done" | "archive") {
        return false;
    }
    let kids = st.children(id);
    if kids.is_empty() || !st.open_children(id).is_empty() {
        return false;
    }
    let pf = task_file(id);
    let list = kids.join(", ");
    move_task(&pf, "11_done", "task", "all subtasks done", "subtasks");
    let pf = task_file(id);
    if fm_set(&pf, "result", "subtasks").is_err() {
        die(format!("cannot update {pf}"));
    }
    if result_append(&pf, &format!("All subtasks done: {list}")).is_err() {
        die(format!("cannot update {pf}"));
    }
    true
}

/// A task just landed in 11_done or archive: close its parent when that was the last open child.
pub fn st_autoclose(file: &str) {
    let st = st_load();
    let parent = st.parent_of(&id_of_file(file));
    if parent.is_empty() {
        return;
    }
    st_try_close(&parent);
}

/// Closes every parent whose children are all done (hand-moved files). Cheap and
/// lock-free when nothing is due; commits once otherwise.
pub fn st_sweep() {
    if st_load().closable().is_empty() {
        return;
    }
    let took = !crate::lock::lock_held();
    crate::lock::lock_acquire();
    let mut n = 0;
    loop {
        let list = st_load().closable();
        let Some(id) = list.first() else { break };
        if !st_try_close(id) {
            break;
        }
        n += 1;
    }
    if n > 0 {
        crate::commit::store_commit();
        println!("closed {n} parent task(s): all subtasks done");
    }
    if took {
        crate::lock::lock_release();
    }
}

/// Oldest task of the folders without blocked_by.
pub fn oldest_unblocked_in(folders: &[&str]) -> Option<String> {
    let st = st_load();
    for f in core::oldest_tasks_in(false, folders) {
        if st.blocked_by(&id_of_file(&f)).is_empty() {
            return Some(f);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nid_forms() {
        assert_eq!(nid("T-83"), "T-0083");
        assert_eq!(nid("\"t-7\""), "T-0007");
        assert_eq!(nid("12"), "T-0012");
        assert_eq!(nid("abc"), "abc");
        assert_eq!(ids_of("T-1, 2 T-3"), vec!["T-0001", "T-0002", "T-0003"]);
    }

    #[test]
    fn reach_and_blocked() {
        let mk = |id: &str, folder: &str, deps: &[&str]| Entry {
            id: id.into(),
            folder: folder.into(),
            deps: deps.iter().map(|s| s.to_string()).collect(),
            ws: "w".into(),
            rel: format!("w/{folder}/{id}.md"),
            ..Default::default()
        };
        let st = St {
            entries: vec![
                mk("T-0001", "00_backlog", &["T-0002"]),
                mk("T-0002", "01_ready", &["T-0003"]),
                mk("T-0003", "11_done", &[]),
            ],
        };
        assert!(st.depends_reach("T-0001", "T-0003"));
        assert!(!st.depends_reach("T-0003", "T-0001"));
        assert_eq!(st.blocked_by("T-0001"), vec!["T-0002"]);
        assert!(st.blocked_by("T-0002").is_empty());
        assert!(st.problems().is_empty());
    }
}
