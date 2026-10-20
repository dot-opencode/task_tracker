//! STUB: port of lib/worktree.sh. Replace the bodies; only edit this file.

use crate::core::die;

pub fn cmd_worktree(_args: &[String]) -> i32 {
    die("worktree: not yet ported to Rust")
}

/// Cleans up the worktree of a task (called by move_task into 11_done). Never fails.
/// STUB: no-op until ported (lib/worktree.sh worktree_cleanup).
pub fn worktree_cleanup(_file: &str, _result: &str, _force: bool) {}
