//! What Gooarchy's system tools share. Each `gooarchy-<subsystem>` binary in this workspace uses
//! it for the things every tool does the same way; something only one tool needs stays in that
//! tool.

pub mod command;
mod failure;

pub use failure::{Failure, run};
