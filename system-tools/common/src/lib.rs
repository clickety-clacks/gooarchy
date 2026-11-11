//! What Gooarchy's system tools share. Each `gooarchy-<subsystem>` binary in this workspace uses
//! it for the things every tool does the same way; something only one tool needs stays in that
//! tool.

pub mod command;
mod failure;

pub use failure::{Failure, run};

pub const BUILD_COMMIT: &str = env!("GOOARCHY_COMMON_BUILD_COMMIT");

/// Print the exact source commit and return true for a leading `--version` argument.
pub fn report_version_if_requested(tool: &str) -> bool {
    if std::env::args_os().nth(1).as_deref() != Some(std::ffi::OsStr::new("--version")) {
        return false;
    }
    println!("{}", version_line(tool));
    true
}

fn version_line(tool: &str) -> String {
    format!("{tool} build commit {BUILD_COMMIT}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_line_ends_with_the_exact_source_commit() {
        let line = version_line("gooarchy-tool");
        assert_eq!(line.split_whitespace().last(), Some(BUILD_COMMIT));
    }
}
