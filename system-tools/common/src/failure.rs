//! How a tool fails: it says why on stderr, prefixed with its name, and exits nonzero.

use std::fmt;
use std::io::{self, Write};
use std::process::ExitCode;

/// Why a tool stopped, and the exit status it stops with.
#[derive(Debug, PartialEq, Eq)]
pub struct Failure {
    pub code: u8,
    pub message: String,
}

impl Failure {
    /// A failure with exit status 1.
    pub fn new(message: impl Into<String>) -> Failure {
        Failure::with_code(1, message)
    }

    /// A failure with its own exit status (2 for usage errors, 127 for a command not found, and
    /// so on). A status of 0 would report success, so it becomes 1.
    pub fn with_code(code: u8, message: impl Into<String>) -> Failure {
        Failure {
            code: code.max(1),
            message: message.into(),
        }
    }
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl From<io::Error> for Failure {
    fn from(error: io::Error) -> Failure {
        Failure::new(error.to_string())
    }
}

/// Runs a tool's body and turns its result into the process's exit status, writing
/// "`tool`: message" to stderr when it fails. A tool's `main` is `common::run("gooarchy-x", body)`.
pub fn run(tool: &str, body: impl FnOnce() -> Result<(), Failure>) -> ExitCode {
    match body() {
        Ok(()) => ExitCode::SUCCESS,
        Err(failure) => {
            let _ = writeln!(io::stderr(), "{}", report(tool, &failure));
            ExitCode::from(failure.code)
        }
    }
}

fn report(tool: &str, failure: &Failure) -> String {
    format!("{tool}: {}", failure.message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failure_never_exits_zero() {
        assert_eq!(Failure::with_code(0, "x").code, 1);
        assert_eq!(Failure::new("x").code, 1);
        assert_eq!(Failure::with_code(127, "x").code, 127);
    }

    #[test]
    fn the_report_names_the_tool() {
        assert_eq!(
            report("gooarchy-x", &Failure::new("no disk")),
            "gooarchy-x: no disk"
        );
    }

    #[test]
    fn run_maps_the_result_to_an_exit_status() {
        assert_eq!(run("t", || Ok(())), ExitCode::SUCCESS);
        assert_eq!(
            run("t", || Err(Failure::with_code(3, "x"))),
            ExitCode::from(3)
        );
    }
}
