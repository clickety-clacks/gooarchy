//! Gooarchy's software manager, adapted from Omarchy's package and web-app commands at
//! commit 81145eb1fd41532fcae4310b26f860608e2eaf82.
//!
//! Copyright (c) David Heinemeier Hansson. The MIT notice is in `system-tools/LICENSE-omarchy`.

mod commands;
mod packages;
mod ui;
mod version;
mod webapps;

use commands::Runner;
use common::Failure;
use std::env;
use std::io;
use std::process::ExitCode;

const HELP: &str = "Usage: gooarchy software <pkg|webapp|version> ...\n\
Also: gooarchy version\n\n\
pkg add|drop PACKAGE...       Install or remove Arch packages\n\
pkg present|missing PACKAGE... Check installed package state\n\
pkg install|remove             Pick official packages to install or remove\n\
pkg aur add PACKAGE...         Build and install AUR packages\n\
pkg aur install                Search and pick AUR packages to install\n\
pkg aur accessible             Check whether the AUR responds\n\
webapp install [NAME URL]      Create a launcher for a web app\n\
webapp launch [--focus ID] URL Launch or focus a Chromium app window\n\
webapp remove [NAME]           Pick or remove a web-app launcher\n\
webapp remove-all              Remove Gooarchy web-app launchers\n\
version                        Show installed Gooarchy and Scottland versions\n";

fn main() -> ExitCode {
    if common::report_version_if_requested("gooarchy-software") {
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
    let runner = Runner::system();
    let result = dispatch(
        args,
        &runner,
        &mut io::stdin().lock(),
        &mut io::stdout().lock(),
    );
    match result {
        Ok(code) => code,
        Err(error) => fail(error),
    }
}

fn fail(error: Failure) -> ExitCode {
    eprintln!("gooarchy-software: {error}");
    ExitCode::from(error.code)
}

fn dispatch(
    args: Vec<String>,
    runner: &Runner,
    input: &mut impl io::BufRead,
    output: &mut impl io::Write,
) -> Result<ExitCode, Failure> {
    match args.as_slice() {
        [] => {
            write_help(output)?;
            Ok(ExitCode::SUCCESS)
        }
        [arg] if matches!(arg.as_str(), "-h" | "--help" | "help") => {
            write_help(output)?;
            Ok(ExitCode::SUCCESS)
        }
        [command, rest @ ..] if command == "pkg" => packages::dispatch(rest, runner, input, output),
        [command, rest @ ..] if command == "webapp" => {
            webapps::dispatch(rest, runner, input, output)
        }
        [command] if command == "version" => {
            version::report(runner, output)?;
            Ok(ExitCode::SUCCESS)
        }
        [command, ..] if command == "version" => Err(ui::usage("version takes no arguments")),
        [command, ..] => Err(ui::usage(format!("unknown command: {command}"))),
    }
}

fn write_help(output: &mut impl io::Write) -> Result<(), Failure> {
    output.write_all(HELP.as_bytes())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn top_level_help_names_the_software_commands() {
        let runner = Runner::system();
        let mut input = Cursor::new(Vec::<u8>::new());
        let mut output = Vec::new();
        let code = dispatch(vec![], &runner, &mut input, &mut output).unwrap();
        assert_eq!(code, ExitCode::SUCCESS);
        let help = String::from_utf8(output).unwrap();
        assert!(help.contains("pkg aur add"));
        assert!(help.contains("webapp remove-all"));
        assert!(help.contains("version"));
    }
}
