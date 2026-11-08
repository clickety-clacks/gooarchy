use crate::commands::{Runner, args as command_args, command_error, output_text, strings};
use crate::ui;
use common::Failure;
use std::cmp::Ordering;
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
            install_official(packages, runner, output)?;
            Ok(ExitCode::SUCCESS)
        }
        [command, packages @ ..] if command == "drop" => {
            require_packages(packages, "pkg drop PACKAGE...")?;
            remove_packages(packages, runner, output)?;
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
                install_official(&selected, runner, output)?;
            }
            Ok(ExitCode::SUCCESS)
        }
        [command] if command == "remove" => {
            let choices = listed_packages(runner, "pacman", &command_args(&["-Qqe"]))?;
            let selected = pick_packages(input, output, &choices, "Select packages to remove: ")?;
            if !selected.is_empty() {
                remove_packages(&selected, runner, output)?;
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
            install_aur(packages, runner, output)?;
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
                install_aur(&selected, runner, output)?;
            }
            Ok(ExitCode::SUCCESS)
        }
        [command, forced @ ..] if command == "__update" => {
            if forced.iter().any(|package| package != "scottland") {
                return Err(ui::usage(
                    "internal AUR update accepts only the scottland rebuild hint",
                ));
            }
            update_installed_aur(forced, runner, output)?;
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

fn install_official(
    packages: &[String],
    runner: &Runner,
    output: &mut impl Write,
) -> Result<(), Failure> {
    announce_change(
        output,
        format!("Install official packages: {}.", packages.join(", ")),
        "these packages were selected from the Arch repositories; pacman resolves their dependencies.",
        format!("gooarchy software pkg drop {}", package_args(packages)),
    )?;
    let mut install_args = command_args(&["pacman", "-S", "--needed", "--"]);
    install_args.extend(strings(packages));
    runner.status("sudo", &install_args)?;
    if !all_installed(packages, runner)? {
        return Err(Failure::new("one or more packages did not install"));
    }
    Ok(())
}

fn remove_packages(
    packages: &[String],
    runner: &Runner,
    output: &mut impl Write,
) -> Result<(), Failure> {
    let mut installed = Vec::new();
    for package in packages {
        if all_installed(std::slice::from_ref(package), runner)? {
            installed.push(package.clone());
        }
    }
    if installed.is_empty() {
        writeln!(output, "None of the requested packages is installed.")?;
        return Ok(());
    }
    announce_change(
        output,
        format!("Remove packages: {}.", installed.join(", ")),
        "pacman will remove the requested packages and dependencies no longer required by any installed package.",
        format!(
            "Arch: gooarchy software pkg add {}; AUR: gooarchy software pkg aur add {}",
            package_args(&installed),
            package_args(&installed)
        ),
    )?;
    let mut remove_args = command_args(&["pacman", "-Rns", "--"]);
    remove_args.extend(strings(&installed));
    runner.status("sudo", &remove_args)
}

fn announce_change(
    output: &mut impl Write,
    change: impl AsRef<str>,
    reason: impl AsRef<str>,
    undo: impl AsRef<str>,
) -> Result<(), Failure> {
    writeln!(output, "{}", change.as_ref())?;
    writeln!(output, "Reason: {}", reason.as_ref())?;
    writeln!(output, "Undo: {}", undo.as_ref())?;
    output.flush()?;
    Ok(())
}

fn package_args(packages: &[String]) -> String {
    packages
        .iter()
        .map(|package| format!("'{}'", package.replace('\'', "'\\''")))
        .collect::<Vec<_>>()
        .join(" ")
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

fn install_aur(
    packages: &[String],
    runner: &Runner,
    output: &mut impl Write,
) -> Result<(), Failure> {
    let missing = missing_packages(packages, runner)?;
    if missing.is_empty() {
        writeln!(output, "All requested AUR packages are already installed.")?;
        return Ok(());
    }
    if !runner.exists("git") {
        return Err(Failure::new("git is required to install AUR packages"));
    }
    if !runner.exists("makepkg") {
        return Err(Failure::new("makepkg is required to install AUR packages"));
    }

    announce_change(
        output,
        format!("Build and install AUR packages: {}.", missing.join(", ")),
        "the selected packages are built locally with makepkg, using the same dependency flow as Strata.",
        format!("gooarchy software pkg drop {}", package_args(&missing)),
    )?;

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
        build_and_install_aur_base(&base, &packages, runner, false)?;
    }
    if !all_installed(&missing, runner)? {
        return Err(Failure::new("one or more AUR packages did not install"));
    }
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
struct ForeignPackage {
    name: String,
    version: String,
}

#[derive(Debug, PartialEq, Eq)]
struct AurPackage {
    name: String,
    base: String,
    version: String,
}

fn update_installed_aur(
    forced_rebuilds: &[String],
    runner: &Runner,
    output: &mut impl Write,
) -> Result<(), Failure> {
    let installed_output = runner.output("pacman", &command_args(&["-Qm"]))?;
    if !installed_output.status.success() {
        return Err(command_error("pacman", &installed_output));
    }
    let installed = parse_foreign_packages(&output_text(&installed_output));
    if installed.is_empty() {
        writeln!(
            output,
            "No installed foreign packages were found to update."
        )?;
        return Ok(());
    }

    let mut query = vec![("v", "5"), ("type", "info")];
    for package in &installed {
        query.push(("arg[]", package.name.as_str()));
    }
    let response = aur_request(runner, &query)?;
    let parsed = runner.output_with_input(
        "jq",
        &command_args(&[
            "-r",
            ".results[]? | [.Name, (.PackageBase // .Name), (.Version // \"\")] | @tsv",
        ]),
        &response.stdout,
    )?;
    if !parsed.status.success() {
        return Err(command_error("jq", &parsed));
    }
    let aur_packages = parse_aur_package_info(&output_text(&parsed));
    let aur_by_name: BTreeMap<&str, &AurPackage> = aur_packages
        .iter()
        .map(|package| (package.name.as_str(), package))
        .collect();

    let mut installed_by_base: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut rebuild_bases = HashSet::new();
    let mut not_in_aur = Vec::new();
    for package in &installed {
        let Some(aur_package) = aur_by_name.get(package.name.as_str()) else {
            not_in_aur.push(package.name.clone());
            continue;
        };
        if !valid_package_name(&aur_package.base) || aur_package.version.is_empty() {
            return Err(Failure::new(format!(
                "AUR returned incomplete package information for {}",
                package.name
            )));
        }
        installed_by_base
            .entry(aur_package.base.clone())
            .or_default()
            .push(package.name.clone());
        let vcs_package = is_vcs_package(&package.name);
        let forced = forced_rebuilds
            .iter()
            .any(|forced| forced == &package.name || forced == &aur_package.base);
        let version_is_newer = if vcs_package || forced || package.version == aur_package.version {
            false
        } else {
            aur_version_is_newer(&package.version, &aur_package.version, runner)?
        };
        if needs_aur_rebuild(
            &package.name,
            &aur_package.base,
            version_is_newer,
            forced_rebuilds,
        ) {
            rebuild_bases.insert(aur_package.base.clone());
        }
    }

    if !not_in_aur.is_empty() {
        writeln!(
            output,
            "Leaving foreign packages not published in the AUR unchanged: {}.",
            not_in_aur.join(", ")
        )?;
    }
    if rebuild_bases.is_empty() {
        writeln!(output, "Installed AUR packages are up to date.")?;
        return Ok(());
    }

    if !runner.exists("git") {
        return Err(Failure::new("git is required to update AUR packages"));
    }
    if !runner.exists("makepkg") {
        return Err(Failure::new("makepkg is required to update AUR packages"));
    }

    let selected: Vec<String> = installed_by_base
        .iter()
        .filter(|(base, _)| rebuild_bases.contains(*base))
        .flat_map(|(_, packages)| packages.iter().cloned())
        .collect();
    writeln!(
        output,
        "Rebuild installed AUR/git packages: {}.",
        selected.join(", ")
    )?;
    if forced_rebuilds.iter().any(|package| package == "scottland") {
        writeln!(
            output,
            "Reason: update newer AUR versions, refresh VCS packages, and rebuild Scottland after a Wayfire change."
        )?;
    } else {
        writeln!(
            output,
            "Reason: update newer AUR versions and refresh packages built from Git or another VCS."
        )?;
    }
    writeln!(
        output,
        "Undo: restore the pre-update Btrfs snapshot shown by gooarchy update, or reinstall prior package archives from the pacman cache."
    )?;

    for (base, packages) in installed_by_base {
        if rebuild_bases.contains(&base) {
            build_and_install_aur_base(&base, &packages, runner, true)?;
        }
    }
    if !all_installed(&selected, runner)? {
        return Err(Failure::new(
            "one or more updated AUR packages are no longer installed",
        ));
    }
    Ok(())
}

fn parse_foreign_packages(text: &str) -> Vec<ForeignPackage> {
    text.lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            Some(ForeignPackage {
                name: fields.next()?.to_owned(),
                version: fields.next()?.to_owned(),
            })
        })
        .collect()
}

fn parse_aur_package_info(text: &str) -> Vec<AurPackage> {
    text.lines()
        .filter_map(|line| {
            let mut fields = line.splitn(3, '\t');
            Some(AurPackage {
                name: fields.next()?.to_owned(),
                base: fields.next()?.to_owned(),
                version: fields.next()?.to_owned(),
            })
        })
        .collect()
}

fn needs_aur_rebuild(
    name: &str,
    base: &str,
    version_is_newer: bool,
    forced_rebuilds: &[String],
) -> bool {
    version_is_newer
        || is_vcs_package(name)
        || forced_rebuilds
            .iter()
            .any(|forced| forced == name || forced == base)
}

fn aur_version_is_newer(
    installed_version: &str,
    aur_version: &str,
    runner: &Runner,
) -> Result<bool, Failure> {
    let comparison = runner.output("vercmp", &command_args(&[aur_version, installed_version]))?;
    if !comparison.status.success() {
        return Err(command_error("vercmp", &comparison));
    }
    match parse_version_comparison(&output_text(&comparison)) {
        Some(Ordering::Greater) => Ok(true),
        Some(Ordering::Equal | Ordering::Less) => Ok(false),
        None => Err(Failure::new(
            "could not compare installed and AUR package versions",
        )),
    }
}

fn parse_version_comparison(text: &str) -> Option<Ordering> {
    match text.trim().parse::<i32>().ok()?.cmp(&0) {
        Ordering::Less => Some(Ordering::Less),
        Ordering::Equal => Some(Ordering::Equal),
        Ordering::Greater => Some(Ordering::Greater),
    }
}

fn is_vcs_package(name: &str) -> bool {
    ["-git", "-hg", "-svn", "-bzr", "-cvs", "-darcs"]
        .iter()
        .any(|suffix| name.ends_with(suffix))
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
    update_flow: bool,
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
    let mut install_args = if update_flow {
        command_args(&[
            "env",
            "GOOARCHY_UPDATE=1",
            "pacman",
            "-U",
            "--noconfirm",
            "--",
        ])
    } else {
        command_args(&["pacman", "-U", "--noconfirm", "--"])
    };
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
    fn package_change_message_explains_reason_and_undo() {
        let mut output = Vec::new();
        announce_change(
            &mut output,
            "Install package: example.",
            "selected from the Arch repositories.",
            "gooarchy software pkg drop 'example'",
        )
        .unwrap();
        let output = String::from_utf8(output).unwrap();
        assert!(output.contains("Install package: example."));
        assert!(output.contains("Reason: selected from the Arch repositories."));
        assert!(output.contains("Undo: gooarchy software pkg drop 'example'"));
        assert_eq!(
            package_args(&["example".into(), "two words".into()]),
            "'example' 'two words'"
        );
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

    #[test]
    fn parses_pacman_foreign_packages_and_aur_versions() {
        assert_eq!(
            parse_foreign_packages("strata-git 1.2.r4.gabc-1\nscottland 3.0-2\n"),
            [
                ForeignPackage {
                    name: "strata-git".to_owned(),
                    version: "1.2.r4.gabc-1".to_owned(),
                },
                ForeignPackage {
                    name: "scottland".to_owned(),
                    version: "3.0-2".to_owned(),
                },
            ]
        );
        assert_eq!(
            parse_aur_package_info("strata-git\tstrata\t1.2.r4.gabc-1\n"),
            [AurPackage {
                name: "strata-git".to_owned(),
                base: "strata".to_owned(),
                version: "1.2.r4.gabc-1".to_owned(),
            }]
        );
    }

    #[test]
    fn rebuilds_newer_and_vcs_aur_packages_and_wayfire_changed_scottland() {
        let forced = vec!["scottland".to_owned()];
        assert!(!needs_aur_rebuild("ordinary", "ordinary", false, &[]));
        assert!(needs_aur_rebuild("ordinary", "ordinary", true, &[]));
        assert!(needs_aur_rebuild("strata-git", "strata-git", false, &[]));
        assert!(needs_aur_rebuild("scottland", "scottland", false, &forced));
        assert_eq!(parse_version_comparison("-4\n"), Some(Ordering::Less));
        assert_eq!(parse_version_comparison("0\n"), Some(Ordering::Equal));
        assert_eq!(parse_version_comparison("2\n"), Some(Ordering::Greater));
        assert_eq!(parse_version_comparison("invalid"), None);
    }
}
