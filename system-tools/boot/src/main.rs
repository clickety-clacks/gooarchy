//! Gooarchy's Btrfs snapshot commands, adapted from Omarchy's `omarchy-snapshot`.
//!
//! Copyright (c) David Heinemeier Hansson. The MIT notice is in
//! `system-tools/LICENSE-omarchy`.

mod snapshots;

use common::Failure;
use std::env;
use std::io::{self, BufRead, Write};
use std::process::ExitCode;

const HELP: &str = "Usage: gooarchy boot snapshot <take|list|restore> [NAME|ID]\n\
take [LABEL]   Snapshot the current Btrfs root subvolume\n\
list           List Gooarchy snapshots\n\
restore ID     Select a snapshot as the Btrfs default root for the next boot\n";

fn main() -> ExitCode {
    if common::report_version_if_requested("gooarchy-boot") {
        return ExitCode::SUCCESS;
    }
    let args = match env::args_os()
        .skip(1)
        .map(|arg| arg.into_string())
        .collect::<Result<Vec<_>, _>>()
    {
        Ok(args) => args,
        Err(_) => return fail(Failure::with_code(2, "arguments must be UTF-8")),
    };
    let result = dispatch(&args, &mut io::stdin().lock(), &mut io::stdout().lock());
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => fail(error),
    }
}

fn fail(error: Failure) -> ExitCode {
    eprintln!("gooarchy-boot: {error}");
    ExitCode::from(error.code)
}

fn dispatch(
    args: &[String],
    input: &mut impl BufRead,
    output: &mut impl Write,
) -> Result<(), Failure> {
    match args {
        [] => {
            write!(output, "{HELP}")?;
            Ok(())
        }
        [command] if command == "--help" || command == "-h" => {
            write!(output, "{HELP}")?;
            Ok(())
        }
        [area, command] if area == "snapshot" && command == "take" => {
            snapshots::take("manual", output)
        }
        [area, command, label] if area == "snapshot" && command == "take" => {
            snapshots::take(label, output)
        }
        [area, command] if area == "snapshot" && command == "list" => snapshots::list(output),
        [area, command, selector] if area == "snapshot" && command == "restore" => {
            snapshots::restore(selector, input, output)
        }
        _ => Err(Failure::with_code(
            2,
            format!("usage: gooarchy boot snapshot <take|list|restore> [LABEL|ID]\n{HELP}"),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn help_is_available_without_a_subcommand() {
        let mut output = Vec::new();
        dispatch(&[], &mut Cursor::new(Vec::<u8>::new()), &mut output).unwrap();
        assert!(String::from_utf8(output).unwrap().contains("restore ID"));
    }

    #[test]
    fn unknown_snapshot_commands_are_usage_errors() {
        let error = dispatch(
            &["snapshot".to_owned(), "delete".to_owned()],
            &mut Cursor::new(Vec::<u8>::new()),
            &mut Vec::new(),
        )
        .unwrap_err();
        assert_eq!(error.code, 2);
    }
}
