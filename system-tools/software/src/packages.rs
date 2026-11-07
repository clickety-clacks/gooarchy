use crate::commands::{Runner, args as command_args, command_error, output_text, strings};
use crate::ui;
use common::Failure;
use std::collections::{BTreeMap, HashSet};
use std::env;
use std::ffi::OsString;
use std::fs;
use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

const AUR_RPC: &str = "https://aur.archlinux.org/rpc/";

pub fn dispatch(
    args: &[String],
    runner: &Runner,
    input: &mut impl BufRead,
    output: &mut impl Write,
) -> Result<ExitCode, Failure> {
    match args {
        [command, packages @ ..] if command == "add" => {
            require_packages(packages, "pkg add PACKAGE...")?;
            install_official(packages, runner)?;
            Ok(ExitCode::SUCCESS)
        }
        [command, packages @ ..] if command == "drop" => {
            require_packages(packages, "pkg drop PACKAGE...")?;
            remove_packages(packages, runner)?;
            Ok(ExitCode::SUCCESS)
        }
        [command, packages @ ..] if command == "present" || command == "missing" => {
            require_packages(
                packages,
                if command == "present" {
                    "pkg present PACKAGE..."
                } else {
                    "pkg missing PACKAGE..."
                },
            )?;
            let present = all_installed(packages, runner)?;
            let result = if command == "present" {
                present
            } else {
                !present
            };
            Ok(if result {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(1)
            })
        }
        [command] if command == "install" => {
            let choices = listed_packages(runner, "pacman", &command_args(&["-Slq"]))?;
            let selected = pick_packages(input, output, &choices, "Select packages to install: ")?;
            if !selected.is_empty() {
                install_official(&selected, runner)?;
            }
            Ok(ExitCode::SUCCESS)
        }
        [command] if command == "remove" => {
            let choices = listed_packages(runner, "pacman", &command_args(&["-Qqe"]))?;
            let selected = pick_packages(input, output, &choices, "Select packages to remove: ")?;
            if !selected.is_empty() {
                remove_packages(&selected, runner)?;
            }
            Ok(ExitCode::SUCCESS)
        }
        [command, rest @ ..] if command == "aur" => aur_dispatch(rest, runner, input, output),
        [] => Err(ui::usage("expected a package command")),
        [command, ..] => Err(ui::usage(format!("unknown package command: {command}"))),
    }
}

fn aur_dispatch(
    args: &[String],
    runner: &Runner,
    input: &mut impl BufRead,
    output: &mut impl Write,
) -> Result<ExitCode, Failure> {
    match args {
        [command] if command == "accessible" => {
            aur_request(runner, &[("v", "5"), ("type", "info"), ("arg", "base")])?;
            writeln!(output, "AUR is accessible")?;
            Ok(ExitCode::SUCCESS)
        }
        [command, packages @ ..] if command == "add" => {
            require_packages(packages, "pkg aur add PACKAGE...")?;
            install_aur(packages, runner)?;
            Ok(ExitCode::SUCCESS)
        }
        [command] if command == "install" => {
            let query = ui::prompt(input, output, "Search AUR packages: ")?;
            if query.is_empty() {
                return Ok(ExitCode::SUCCESS);
            }
            let choices = search_aur(runner, &query)?;
            if choices.is_empty() {
                writeln!(output, "No AUR packages found for {query}.")?;
                return Ok(ExitCode::SUCCESS);
            }
            let selected =
                pick_packages(input, output, &choices, "Select AUR packages to install: ")?;
            if !selected.is_empty() {
                install_aur(&selected, runner)?;
            }
            Ok(ExitCode::SUCCESS)
        }
        [] => Err(ui::usage("expected pkg aur add, install, or accessible")),
        [command, ..] => Err(ui::usage(format!("unknown AUR command: {command}"))),
    }
}

fn require_packages(packages: &[String], usage: &str) -> Result<(), Failure> {
    if packages.is_empty() {
        Err(ui::usage(format!("usage: gooarchy software {usage}")))
    } else {
        Ok(())
    }
}

fn all_installed(packages: &[String], runner: &Runner) -> Result<bool, Failure> {
    for package in packages {
        let result = runner.output("pacman", &command_args(&["-Q", "--", package]))?;
        if !result.status.success() {
            return Ok(false);
        }
    }
    Ok(true)
}

fn install_official(packages: &[String], runner: &Runner) -> Result<(), Failure> {
    let mut install_args = command_args(&["pacman", "-S", "--noconfirm", "--needed", "--"]);
    install_args.extend(strings(packages));
    runner.status("sudo", &install_args)?;
    if !all_installed(packages, runner)? {
        return Err(Failure::new("one or more packages did not install"));
    }
    Ok(())
}

fn remove_packages(packages: &[String], runner: &Runner) -> Result<(), Failure> {
    let mut installed = Vec::new();
    for package in packages {
        if all_installed(std::slice::from_ref(package), runner)? {
            installed.push(package.clone());
        }
    }
    if installed.is_empty() {
        return Ok(());
    }
    let mut remove_args = command_args(&["pacman", "-Rns", "--noconfirm", "--"]);
    remove_args.extend(strings(&installed));
    runner.status("sudo", &remove_args)
}

fn listed_packages(
    runner: &Runner,
    command: &str,
    command_args: &[OsString],
) -> Result<Vec<(String, String)>, Failure> {
    let result = runner.output(command, command_args)?;
    if !result.status.success() {
        return Err(command_error(command, &result));
    }
    let mut seen = HashSet::new();
    Ok(output_text(&result)
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .filter(|name| seen.insert((*name).to_owned()))
        .map(|name| (name.to_owned(), name.to_owned()))
        .collect())
}

fn pick_packages(
    input: &mut impl BufRead,
    output: &mut impl Write,
    choices: &[(String, String)],
    prompt: &str,
) -> Result<Vec<String>, Failure> {
    if choices.is_empty() {
        writeln!(output, "No packages found.")?;
        return Ok(Vec::new());
    }
    ui::pick(input, output, choices, true, prompt)
}

fn aur_request(runner: &Runner, query: &[(&str, &str)]) -> Result<std::process::Output, Failure> {
    let mut command_args = command_args(&["--fail", "--silent", "--show-error", "--get"]);
    for (key, value) in query {
        command_args.push(OsString::from("--data-urlencode"));
        command_args.push(OsString::from(format!("{key}={value}")));
    }
    command_args.push(OsString::from(AUR_RPC));
    let result = runner.output("curl", &command_args)?;
    if result.status.success() {
        Ok(result)
    } else {
        Err(command_error("curl", &result))
    }
}

fn aur_names(runner: &Runner, query: &[(&str, &str)]) -> Result<Vec<(String, String)>, Failure> {
    let response = aur_request(runner, query)?;
    let parsed = runner.output_with_input(
        "jq",
        &command_args(&[
            "-r",
            ".results[]? | [.Name, (.PackageBase // .Name)] | @tsv",
        ]),
        &response.stdout,
    )?;
    if !parsed.status.success() {
        return Err(command_error("jq", &parsed));
    }
    let mut packages = Vec::new();
    for line in output_text(&parsed).lines() {
        let mut fields = line.splitn(2, '\t');
        let Some(name) = fields.next().filter(|field| !field.is_empty()) else {
            continue;
        };
        let Some(base) = fields.next().filter(|field| !field.is_empty()) else {
            continue;
        };
        packages.push((name.to_owned(), base.to_owned()));
    }
    Ok(packages)
}

fn search_aur(runner: &Runner, query: &str) -> Result<Vec<(String, String)>, Failure> {
    let response = aur_request(runner, &[("v", "5"), ("type", "search"), ("arg", query)])?;
    let parsed = runner.output_with_input(
        "jq",
        &command_args(&["-r", ".results[]? | [.Name, .Name] | @tsv"]),
        &response.stdout,
    )?;
    if !parsed.status.success() {
        return Err(command_error("jq", &parsed));
    }
    let mut seen = HashSet::new();
    Ok(output_text(&parsed)
        .lines()
        .filter_map(|line| line.split_once('\t').map(|(name, _)| name.trim()))
        .filter(|name| !name.is_empty() && seen.insert((*name).to_owned()))
        .map(|name| (name.to_owned(), name.to_owned()))
        .collect())
}

fn install_aur(packages: &[String], runner: &Runner) -> Result<(), Failure> {
    let missing = missing_packages(packages, runner)?;
    if missing.is_empty() {
        return Ok(());
    }
    if !runner.exists("git") {
        return Err(Failure::new("git is required to install AUR packages"));
    }
    if !runner.exists("makepkg") {
        return Err(Failure::new("makepkg is required to install AUR packages"));
    }

    let mut bases: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for package in &missing {
        if !valid_package_name(package) {
            return Err(ui::usage(format!("invalid package name: {package}")));
        }
        let found = aur_names(runner, &[("v", "5"), ("type", "info"), ("arg", package)])?;
        let (name, base) = found
            .into_iter()
            .find(|(name, _)| name == package)
            .ok_or_else(|| Failure::new(format!("AUR package not found: {package}")))?;
        if !valid_package_name(&base) {
            return Err(Failure::new(format!(
                "AUR returned an invalid package base for {name}"
            )));
        }
        bases.entry(base).or_default().push(name);
    }

    for (base, packages) in bases {
        build_and_install_aur_base(&base, &packages, runner)?;
    }
    if !all_installed(&missing, runner)? {
        return Err(Failure::new("one or more AUR packages did not install"));
    }
    Ok(())
}

fn missing_packages(packages: &[String], runner: &Runner) -> Result<Vec<String>, Failure> {
    let mut missing = Vec::new();
    for package in packages {
        if !all_installed(std::slice::from_ref(package), runner)? {
            missing.push(package.clone());
        }
    }
    Ok(missing)
}

fn build_and_install_aur_base(
    base: &str,
    packages: &[String],
    runner: &Runner,
) -> Result<(), Failure> {
    let scratch = Scratch::new()?;
    let source = scratch.path.join("source");
    let repository = format!("https://aur.archlinux.org/{base}.git");
    let clone_args = vec![
        OsString::from("clone"),
        OsString::from("--quiet"),
        OsString::from(repository),
        source.as_os_str().to_owned(),
    ];
    runner.status("git", &clone_args)?;
    runner.status_in(
        "makepkg",
        &command_args(&[
            "--syncdeps",
            "--rmdeps",
            "--noconfirm",
            "--needed",
            "--force",
            "--cleanbuild",
        ]),
        &source,
    )?;

    let listed = runner.output_in("makepkg", &command_args(&["--packagelist"]), &source)?;
    if !listed.status.success() {
        return Err(command_error("makepkg", &listed));
    }
    let wanted: HashSet<&str> = packages.iter().map(String::as_str).collect();
    let mut files = Vec::new();
    let mut found = HashSet::new();
    for line in output_text(&listed)
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        let path = PathBuf::from(line);
        let path = if path.is_absolute() {
            path
        } else {
            source.join(path)
        };
        let package_info = runner.output(
            "pacman",
            &command_args(&[
                "-Qp",
                "--",
                path.to_str()
                    .ok_or_else(|| Failure::new("package path is not UTF-8"))?,
            ]),
        )?;
        if !package_info.status.success() {
            continue;
        }
        let package_name = output_text(&package_info)
            .split_whitespace()
            .next()
            .map(str::to_owned);
        let Some(name) = package_name else {
            continue;
        };
        if wanted.contains(name.as_str()) && found.insert(name) {
            files.push(path.into_os_string());
        }
    }
    let missing: Vec<&str> = packages
        .iter()
        .map(String::as_str)
        .filter(|package| !found.contains(*package))
        .collect();
    if !missing.is_empty() {
        return Err(Failure::new(format!(
            "makepkg did not build requested package(s): {}",
            missing.join(", ")
        )));
    }
    let mut install_args = command_args(&["pacman", "-U", "--noconfirm", "--"]);
    install_args.extend(files);
    runner.status("sudo", &install_args)
}

fn valid_package_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"@._+-".contains(&byte))
}

struct Scratch {
    path: PathBuf,
}

impl Scratch {
    fn new() -> Result<Scratch, Failure> {
        let root = env::temp_dir();
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|error| Failure::new(format!("cannot create temporary directory: {error}")))?
            .as_nanos();
        for attempt in 0..100_u32 {
            let path = root.join(format!(
                "gooarchy-aur-{}-{nonce}-{attempt}",
                std::process::id()
            ));
            match fs::create_dir(&path) {
                Ok(()) => return Ok(Scratch { path }),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => {
                    return Err(Failure::new(format!(
                        "cannot create AUR build directory: {error}"
                    )));
                }
            }
        }
        Err(Failure::new(
            "cannot create a temporary AUR build directory",
        ))
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Fixture {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = env::temp_dir().join(format!(
                "gooarchy-software-test-{}-{nonce}",
                std::process::id()
            ));
            fs::create_dir_all(&path).unwrap();
            Fixture(path)
        }

        fn command(&self, name: &str, source: &str) {
            let path = self.0.join(name);
            fs::write(&path, format!("#!/bin/sh\n{source}\n")).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn present_requires_every_requested_package_and_missing_means_any_absent() {
        let fixture = Fixture::new();
        fixture.command("pacman", "[ \"$3\" = present ]");
        let runner = Runner::in_path(fixture.0.clone());
        let packages = vec!["present".to_owned(), "absent".to_owned()];
        assert!(!all_installed(&packages, &runner).unwrap());
        assert!(all_installed(&["present".to_owned()], &runner).unwrap());
        assert!(all_installed(&[], &runner).unwrap());
    }

    #[test]
    fn package_names_allow_arch_characters_but_not_path_separators() {
        assert!(valid_package_name("example-plus_1.2@repo"));
        assert!(!valid_package_name("../example"));
        assert!(!valid_package_name(""));
    }

    #[test]
    fn aur_add_only_builds_packages_that_are_missing() {
        let fixture = Fixture::new();
        fixture.command("pacman", "[ \"$3\" = installed ]");
        let runner = Runner::in_path(fixture.0.clone());
        assert_eq!(
            missing_packages(&["installed".to_owned(), "absent".to_owned()], &runner).unwrap(),
            vec!["absent".to_owned()]
        );
    }

    #[test]
    fn search_results_are_deduplicated_before_picking() {
        let names = ["one", "one", "two"];
        let mut seen = HashSet::new();
        let unique: Vec<_> = names
            .into_iter()
            .filter(|name| seen.insert(*name))
            .collect();
        assert_eq!(unique, ["one", "two"]);
    }
}
