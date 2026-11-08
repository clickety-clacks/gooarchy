use common::Failure;
use std::env;
use std::ffi::OsStr;
use std::fs;
use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::process::{Command, ExitCode, ExitStatus, Output, Stdio};

const MINIMUM_FREE_BYTES: u64 = 10 * 1024 * 1024 * 1024;
const PACMAN_LOG: &str = "/var/log/pacman.log";

pub fn run_locked() -> ExitCode {
    match lock_and_run() {
        Ok(status) => exit_status(status),
        Err(error) => fail(error),
    }
}

pub fn run_inhibited() -> ExitCode {
    match inhibit_and_run() {
        Ok(status) => exit_status(status),
        Err(error) => fail(error),
    }
}

pub fn pacman_guard() -> ExitCode {
    if env::var_os("GOOARCHY_UPDATE").as_deref() == Some(OsStr::new("1")) {
        ExitCode::SUCCESS
    } else {
        fail(Failure::new(
            "a Wayfire upgrade needs its matching Scottland package; run 'gooarchy update' so both are updated together",
        ))
    }
}

pub fn run_update(input: &mut impl BufRead, output: &mut impl Write) -> Result<(), Failure> {
    require_commands(&[
        "pacman",
        "sudo",
        "env",
        "flock",
        "systemd-inhibit",
        "df",
        "findmnt",
    ])?;
    let free = root_free_bytes()?;
    if free < MINIMUM_FREE_BYTES {
        return Err(Failure::new(format!(
            "the root filesystem has {} bytes free; Gooarchy update needs at least 10 GiB before it can take a safety snapshot",
            free
        )));
    }

    let before = versions()?;
    writeln!(
        output,
        "Update Arch packages, installed AUR/git packages and Gooarchy."
    )?;
    writeln!(
        output,
        "Reason: apply the current package updates and rebuild foreign Git packages against the updated system."
    )?;
    writeln!(
        output,
        "Undo: on Btrfs, restore the pre-update snapshot shown below; on other filesystems, reinstall prior package archives from the pacman cache when available."
    )?;
    write!(output, "Continue? [y/N] ")?;
    output.flush()?;
    if !confirmed(input)? {
        writeln!(output, "Update cancelled; no package changes were made.")?;
        return Ok(());
    }

    let snapshot = take_snapshot(output)?;
    if let Some(id) = snapshot {
        writeln!(
            output,
            "Undo this update with: gooarchy boot snapshot restore {id} (then restart)."
        )?;
    }
    let log_start = fs::metadata(PACMAN_LOG).map(|metadata| metadata.len()).ok();

    pacman(&["-Sy", "--needed", "archlinux-keyring"])?;
    pacman(&["-Syu"])?;
    let wayfire_after_arch_update = package_version("wayfire")?;
    let rebuild_scottland = before.wayfire != wayfire_after_arch_update;
    run_software_aur_update(rebuild_scottland)?;
    run_tool("gooarchy-source", &["update"])?;

    let after = versions()?;
    report_versions(&before, &after, output)?;
    if before.wayfire != after.wayfire || before.scottland != after.scottland {
        writeln!(
            output,
            "Log out of Wayfire and log in again to start the updated compositor and Scottland."
        )?;
    }
    if before.linux != after.linux {
        writeln!(
            output,
            "The installed Linux kernel changed; restart the system to use it."
        )?;
    }
    if let Some(log_start) = log_start {
        match new_pacman_log(log_start) {
            Ok(log) if initramfs_failed(&log) => {
                writeln!(
                    output,
                    "Warning: pacman logged an initramfs generation error. Review /var/log/pacman.log before restarting."
                )?;
            }
            Ok(_) => {}
            Err(_) => {
                writeln!(
                    output,
                    "Could not check the new pacman log entries for initramfs errors; review /var/log/pacman.log."
                )?;
            }
        }
    } else {
        writeln!(
            output,
            "Could not record the pacman log position; review /var/log/pacman.log for initramfs errors."
        )?;
    }
    if before.wayfire == after.wayfire && before.scottland == after.scottland {
        writeln!(
            output,
            "No Wayfire or Scottland version change was detected; log out and back in only if you want to restart the current session."
        )?;
    }
    writeln!(output, "Gooarchy update completed.")?;
    Ok(())
}

fn lock_and_run() -> Result<ExitStatus, Failure> {
    let executable = env::current_exe()
        .map_err(|error| Failure::new(format!("cannot locate gooarchy-update: {error}")))?;
    let lock = lock_path()?;
    Command::new("flock")
        .args(["--nonblock", "--conflict-exit-code", "75"])
        .arg(lock)
        .arg(executable)
        .arg("--locked")
        .status()
        .map_err(|error| Failure::new(format!("cannot start the update lock: {error}")))
}

fn lock_path() -> Result<PathBuf, Failure> {
    let uid = Command::new("id")
        .arg("-u")
        .output()
        .map_err(|error| Failure::new(format!("cannot determine the current user ID: {error}")))?;
    if !uid.status.success() {
        return Err(Failure::new(
            "cannot determine the current user ID for the update lock",
        ));
    }
    let uid = String::from_utf8_lossy(&uid.stdout).trim().to_owned();
    let directory = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(env::temp_dir);
    Ok(directory.join(format!("gooarchy-update-{uid}.lock")))
}

fn inhibit_and_run() -> Result<ExitStatus, Failure> {
    let executable = env::current_exe()
        .map_err(|error| Failure::new(format!("cannot locate gooarchy-update: {error}")))?;
    Command::new("systemd-inhibit")
        .args([
            "--what=sleep",
            "--why=Gooarchy system update",
            "--mode=block",
            "--",
        ])
        .arg(executable)
        .arg("--inhibited")
        .status()
        .map_err(|error| {
            Failure::new(format!(
                "cannot hold a sleep inhibitor for the update: {error}"
            ))
        })
}

fn exit_status(status: ExitStatus) -> ExitCode {
    if status.success() {
        return ExitCode::SUCCESS;
    }
    if status.code() == Some(75) {
        return fail(Failure::new("another Gooarchy update is already running"));
    }
    ExitCode::from(status.code().unwrap_or(1).clamp(1, 255) as u8)
}

fn fail(error: Failure) -> ExitCode {
    eprintln!("gooarchy-update: {error}");
    ExitCode::from(error.code)
}

fn require_commands(commands: &[&str]) -> Result<(), Failure> {
    let missing: Vec<&str> = commands
        .iter()
        .copied()
        .filter(|command| common::command::find(command).is_none())
        .collect();
    if missing.is_empty() {
        Ok(())
    } else {
        Err(Failure::new(format!(
            "required update command(s) are missing: {}",
            missing.join(", ")
        )))
    }
}

fn root_free_bytes() -> Result<u64, Failure> {
    let output = Command::new("df")
        .args(["--output=avail", "--block-size=1", "/"])
        .output()
        .map_err(|error| Failure::new(format!("cannot check free space on /: {error}")))?;
    if !output.status.success() {
        return Err(Failure::new(
            "cannot check free space on the root filesystem",
        ));
    }
    parse_available_bytes(&String::from_utf8_lossy(&output.stdout))
        .ok_or_else(|| Failure::new("could not read the available bytes on the root filesystem"))
}

fn parse_available_bytes(output: &str) -> Option<u64> {
    output
        .lines()
        .rev()
        .find_map(|line| line.trim().parse().ok())
}

fn confirmed(input: &mut impl BufRead) -> Result<bool, Failure> {
    let mut answer = String::new();
    input.read_line(&mut answer)?;
    Ok(matches!(
        answer.trim().to_ascii_lowercase().as_str(),
        "y" | "yes"
    ))
}

fn take_snapshot(output: &mut impl Write) -> Result<Option<u64>, Failure> {
    let filesystem = Command::new("findmnt")
        .args(["--noheadings", "--output", "FSTYPE", "--target", "/"])
        .output()
        .map_err(|error| Failure::new(format!("cannot identify the root filesystem: {error}")))?;
    if !filesystem.status.success() {
        return Err(Failure::new(
            "cannot identify the root filesystem before updating",
        ));
    }
    let fstype = String::from_utf8_lossy(&filesystem.stdout)
        .trim()
        .to_owned();
    if fstype != "btrfs" {
        writeln!(
            output,
            "No Btrfs snapshot was taken; snapshots need a Btrfs root (root is {fstype})."
        )?;
        return Ok(None);
    }

    run_tool("gooarchy-boot", &["snapshot", "take", "update"])?;
    let listed = run_tool_output("gooarchy-boot", &["snapshot", "list"])?;
    let id = parse_snapshot_list(&String::from_utf8_lossy(&listed.stdout))
        .into_iter()
        .filter(|(_, name)| name.starts_with("gooarchy-update-"))
        .max_by_key(|(id, _)| *id)
        .map(|(id, _)| id)
        .ok_or_else(|| Failure::new("the Btrfs snapshot was created, but its ID could not be read from gooarchy boot snapshot list"))?;
    Ok(Some(id))
}

fn parse_snapshot_list(output: &str) -> Vec<(u64, String)> {
    output
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let id = fields.next()?.parse().ok()?;
            let name = fields.next()?.to_owned();
            Some((id, name))
        })
        .collect()
}

#[derive(Default)]
struct Versions {
    wayfire: Option<String>,
    scottland: Option<String>,
    linux: Option<String>,
    gooarchy: Option<String>,
}

fn versions() -> Result<Versions, Failure> {
    Ok(Versions {
        wayfire: package_version("wayfire")?,
        scottland: package_version("scottland")?,
        linux: package_version("linux")?,
        gooarchy: package_version("gooarchy")?,
    })
}

fn package_version(package: &str) -> Result<Option<String>, Failure> {
    let output = Command::new("pacman")
        .args(["-Q", "--", package])
        .output()
        .map_err(|error| {
            Failure::new(format!("cannot query installed {package} version: {error}"))
        })?;
    if !output.status.success() {
        return Ok(None);
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let fields: Vec<&str> = text.split_whitespace().collect();
    Ok(fields.get(1).map(|version| (*version).to_owned()))
}

fn report_versions(
    before: &Versions,
    after: &Versions,
    output: &mut impl Write,
) -> Result<(), Failure> {
    report_version("Wayfire", &before.wayfire, &after.wayfire, output)?;
    report_version("Scottland", &before.scottland, &after.scottland, output)?;
    report_version("Gooarchy", &before.gooarchy, &after.gooarchy, output)?;
    Ok(())
}

fn report_version(
    name: &str,
    before: &Option<String>,
    after: &Option<String>,
    output: &mut impl Write,
) -> Result<(), Failure> {
    match (before, after) {
        (Some(before), Some(after)) if before != after => {
            writeln!(output, "{name}: {before} → {after}")?
        }
        (None, Some(after)) => writeln!(output, "{name}: installed {after}")?,
        (Some(before), None) => writeln!(output, "{name}: no longer installed (was {before})")?,
        _ => {}
    }
    Ok(())
}

fn pacman(args: &[&str]) -> Result<(), Failure> {
    let mut command = Command::new("sudo");
    command
        .arg("--")
        .arg("env")
        .arg("GOOARCHY_UPDATE=1")
        .arg("pacman")
        .args(args);
    let status = command
        .status()
        .map_err(|error| Failure::new(format!("cannot start pacman: {error}")))?;
    if status.success() {
        Ok(())
    } else {
        Err(Failure::new(format!("pacman failed with {status}")))
    }
}

fn tool_path(name: &str) -> Result<PathBuf, Failure> {
    let current = env::current_exe()
        .map_err(|error| Failure::new(format!("cannot locate Gooarchy's system tools: {error}")))?;
    let sibling = current
        .parent()
        .ok_or_else(|| Failure::new("cannot locate Gooarchy's system tools directory"))?
        .join(name);
    if sibling.is_file() {
        Ok(sibling)
    } else {
        Ok(PathBuf::from(name))
    }
}

fn run_tool(name: &str, args: &[&str]) -> Result<(), Failure> {
    let status = Command::new(tool_path(name)?)
        .args(args)
        .status()
        .map_err(|error| Failure::new(format!("cannot run {name}: {error}")))?;
    if status.success() {
        Ok(())
    } else {
        Err(Failure::new(format!("{name} failed with {status}")))
    }
}

fn run_tool_output(name: &str, args: &[&str]) -> Result<Output, Failure> {
    let output = Command::new(tool_path(name)?)
        .args(args)
        .stdin(Stdio::inherit())
        .stderr(Stdio::inherit())
        .output()
        .map_err(|error| Failure::new(format!("cannot run {name}: {error}")))?;
    if output.status.success() {
        Ok(output)
    } else {
        Err(Failure::new(format!(
            "{name} failed with {}",
            output.status
        )))
    }
}

fn run_software_aur_update(rebuild_scottland: bool) -> Result<(), Failure> {
    let software = tool_path("gooarchy-software")?;
    let mut command = Command::new(software);
    command.args(["pkg", "aur", "__update"]);
    if rebuild_scottland {
        command.arg("scottland");
    }
    let status = command
        .status()
        .map_err(|error| Failure::new(format!("cannot start AUR package updates: {error}")))?;
    if status.success() {
        Ok(())
    } else {
        Err(Failure::new(format!(
            "AUR package updates failed with {status}"
        )))
    }
}

fn new_pacman_log(previous_len: u64) -> Result<String, Failure> {
    let bytes = fs::read(PACMAN_LOG).map_err(|error| Failure::new(error.to_string()))?;
    let start = usize::try_from(previous_len).unwrap_or(usize::MAX);
    let new_bytes = if start <= bytes.len() {
        &bytes[start..]
    } else {
        &bytes[..]
    };
    Ok(String::from_utf8_lossy(new_bytes).into_owned())
}

fn initramfs_failed(log: &str) -> bool {
    let lines: Vec<String> = log.lines().map(|line| line.to_ascii_lowercase()).collect();
    for index in 0..lines.len() {
        let from = index.saturating_sub(4);
        let to = (index + 5).min(lines.len());
        let context = lines[from..to].join(" ");
        let initramfs = context.contains("mkinitcpio") || context.contains("initramfs");
        let failure =
            context.contains("error") || context.contains("failed") || context.contains("failure");
        if initramfs && failure {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn reads_df_available_bytes_without_accepting_headers_or_extra_fields() {
        assert_eq!(parse_available_bytes("Avail\n  123456\n"), Some(123456));
        assert_eq!(parse_available_bytes("Avail\n  123456 x\n"), None);
    }

    #[test]
    fn initramfs_errors_in_the_same_log_window_are_detected() {
        assert!(initramfs_failed(
            "[ALPM-SCRIPTLET] running mkinitcpio -P\n[ALPM-SCRIPTLET] ERROR: image generation failed\n"
        ));
        assert!(!initramfs_failed(
            "[ALPM-SCRIPTLET] running mkinitcpio -P\n[ALPM-SCRIPTLET] image generation completed\n"
        ));
        assert!(!initramfs_failed(
            "[ALPM] warning: package file was skipped\n"
        ));
    }

    #[test]
    fn the_update_prompt_requires_an_explicit_yes() {
        assert!(confirmed(&mut Cursor::new(b"yes\n".to_vec())).unwrap());
        assert!(confirmed(&mut Cursor::new(b"Y\n".to_vec())).unwrap());
        assert!(!confirmed(&mut Cursor::new(b"\n".to_vec())).unwrap());
    }

    #[test]
    fn snapshot_list_extracts_only_id_and_name_rows() {
        assert_eq!(
            parse_snapshot_list(
                "Gooarchy snapshots under /.snapshots:\n259\tgooarchy-update-123\n"
            ),
            [(259, "gooarchy-update-123".to_owned())]
        );
    }
}
