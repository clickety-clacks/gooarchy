//! Gooarchy's system updater, adapted from Omarchy's `omarchy-update` stages.
//!
//! Copyright (c) David Heinemeier Hansson. The MIT notice is in
//! `system-tools/LICENSE-omarchy`.

mod update;

use common::Failure;
use std::env;
use std::io;
use std::process::ExitCode;

fn main() -> ExitCode {
    if common::report_version_if_requested("gooarchy-update") {
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
    match args.as_slice() {
        [] => update::run_locked(),
        [command] if command == "--help" || command == "-h" => {
            print!(
                "Usage: gooarchy update\n\
Updates Arch packages, installed AUR/git packages and Gooarchy itself.\n"
            );
            ExitCode::SUCCESS
        }
        [command] if command == "pacman-guard" => update::pacman_guard(),
        [command] if command == "--locked" => update::run_inhibited(),
        [command] if command == "--inhibited" => {
            let result = update::run_update(&mut io::stdin().lock(), &mut io::stdout().lock());
            result.map_or_else(fail, |_| ExitCode::SUCCESS)
        }
        _ => fail(Failure::with_code(2, "usage: gooarchy update")),
    }
}

fn fail(error: Failure) -> ExitCode {
    eprintln!("gooarchy-update: {error}");
    ExitCode::from(error.code)
}
