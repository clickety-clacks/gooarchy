//! `gooarchy`: runs Gooarchy's system tools. `gooarchy <tool> [arguments]` runs `gooarchy-<tool>`
//! with the arguments, from the directory `gooarchy` itself is in; with no arguments (or -h,
//! --help) it lists the tools there.
//!
//! Derived from Omarchy's bin/omarchy at commit 81145eb1fd41532fcae4310b26f860608e2eaf82, which
//! runs `omarchy-<group>-<command>` from its own directory for `omarchy <group> <command>`.
//! Changed: Omarchy's command metadata, groups and JSON listing are left out, because each
//! Gooarchy tool is one binary per subsystem that takes its own subcommands; kept are running the
//! tool with exec from the front command's directory, the "Did you mean" suggestion by prefix,
//! and exit status 127 for an unknown command.
//!
//! Omarchy's copyright and license notice:
//!
//!   Copyright (c) David Heinemeier Hansson
//!
//!   Permission is hereby granted, free of charge, to any person obtaining
//!   a copy of this software and associated documentation files (the
//!   "Software"), to deal in the Software without restriction, including
//!   without limitation the rights to use, copy, modify, merge, publish,
//!   distribute, sublicense, and/or sell copies of the Software, and to
//!   permit persons to whom the Software is furnished to do so, subject to
//!   the following conditions:
//!
//!   The above copyright notice and this permission notice shall be
//!   included in all copies or substantial portions of the Software.
//!
//!   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//!   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//!   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//!   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
//!   LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
//!   OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
//!   WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

use common::Failure;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

const PREFIX: &str = "gooarchy-";

fn main() -> ExitCode {
    common::run("gooarchy", front)
}

fn front() -> Result<(), Failure> {
    let mut args = env::args_os().skip(1);
    let first = args.next();
    let dir = tools_dir()?;
    let name = match first.as_ref().map(|a| a.to_str()) {
        None | Some(Some("-h" | "--help")) => {
            print!("{}", help(&dir, &tools(&dir)));
            return Ok(());
        }
        Some(name) => name,
    };
    let tool = name.and_then(|name| tool_path(&dir, name));
    let Some(tool) = tool else {
        let shown = first.unwrap_or_default().to_string_lossy().into_owned();
        return Err(unknown(&shown, &tools(&dir)));
    };
    let rest: Vec<OsString> = args.collect();
    let error = Command::new(&tool).args(rest).exec();
    Err(Failure::with_code(
        126,
        format!("could not run {}: {error}", tool.display()),
    ))
}

/// The directory the tools are in: the one `gooarchy` was run from.
fn tools_dir() -> Result<PathBuf, Failure> {
    let exe = env::current_exe()
        .map_err(|e| Failure::new(format!("cannot tell where gooarchy is installed: {e}")))?;
    exe.parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| Failure::new("cannot tell where gooarchy is installed"))
}

fn tool_path(dir: &Path, name: &str) -> Option<PathBuf> {
    if name.is_empty() || name.starts_with('-') || name.contains('/') {
        return None;
    }
    let path = dir.join(format!("{PREFIX}{name}"));
    common::command::is_executable(&path).then_some(path)
}

/// The tools in `dir`, by the name `gooarchy` runs them with, sorted.
fn tools(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter_map(|file| file.strip_prefix(PREFIX).map(str::to_owned))
        .filter(|name| tool_path(dir, name).is_some())
        .collect();
    names.sort();
    names
}

fn help(dir: &Path, tools: &[String]) -> String {
    let mut text = format!(
        "Usage: gooarchy <tool> [arguments]\n\nRuns {PREFIX}<tool> from {}.\n",
        dir.display()
    );
    if tools.is_empty() {
        text.push_str("No tools are installed there.\n");
    } else {
        text.push_str("\nTools:\n");
        for tool in tools {
            text.push_str(&format!("  {tool}\n"));
        }
    }
    text
}

fn unknown(name: &str, tools: &[String]) -> Failure {
    let mut message = format!("unknown tool: {name}");
    if let Some(guess) = tools
        .iter()
        .find(|tool| !name.is_empty() && tool.starts_with(name))
    {
        message.push_str(&format!("\nDid you mean: gooarchy {guess} ?"));
    }
    message.push_str("\nRun 'gooarchy' to list the tools.");
    Failure::with_code(127, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn an_unknown_tool_suggests_one_it_begins() {
        let failure = unknown("up", &names(&["boot", "update"]));
        assert_eq!(failure.code, 127);
        assert!(failure.message.contains("Did you mean: gooarchy update ?"));
    }

    #[test]
    fn an_unknown_tool_without_a_match_suggests_nothing() {
        let failure = unknown("zzz", &names(&["boot"]));
        assert!(!failure.message.contains("Did you mean"));
        assert!(
            !unknown("", &names(&["boot"]))
                .message
                .contains("Did you mean")
        );
    }

    #[test]
    fn names_that_are_not_a_tool_name_are_refused_before_any_lookup() {
        let dir = Path::new("/");
        for name in ["", "-x", "../bin/sh", "a/b"] {
            assert_eq!(tool_path(dir, name), None, "{name}");
        }
    }

    #[test]
    fn help_lists_the_tools_or_says_there_are_none() {
        let dir = Path::new("/usr/bin");
        let listed = help(dir, &names(&["boot", "update"]));
        assert!(listed.contains("Runs gooarchy-<tool> from /usr/bin."));
        assert!(listed.contains("\n  boot\n  update\n"));
        assert!(help(dir, &[]).contains("No tools are installed there."));
    }
}
