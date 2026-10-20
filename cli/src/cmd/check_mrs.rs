//! STUB: port of lib/mrcheck.sh. Replace the bodies; only edit this file.

use crate::core::die;

pub fn cmd_check_mrs(_args: &[String]) -> i32 {
    die("check-mrs: not yet ported to Rust")
}

/// Cheap when not due (called by `ls`). STUB: no-op until ported (mr_check_due).
pub fn mr_check_due() {}
