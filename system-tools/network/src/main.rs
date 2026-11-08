//! Keep Gooarchy's network stack in place, report its state, and recover Wi-Fi through iwd.

use common::Failure;
use std::env;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

const HELP: &str = "Usage: gooarchy network <ensure [--yes]|status|restart-wifi>\n\
ensure       Install and start the selected stack components when needed\n\
status       Show stack state and the current network connection\n\
restart-wifi Unblock Wi-Fi and rescan through iwd\n";
const SERVICES: [(&str, &str); 3] = [
    ("systemd-networkd", "systemd-networkd.service"),
    ("iwd", "iwd.service"),
    ("systemd-resolved", "systemd-resolved.service"),
];
const NETWORKD_ADMIN_DIRS: [&str; 3] = [
    "/etc/systemd/network",
    "/run/systemd/network",
    "/usr/local/lib/systemd/network",
];
const NETWORKD_CONFIG_PATH: &str = "/etc/systemd/network/zz-gooarchy-dhcp.network";
const NETWORKD_VENDOR_CONFIG_PATH: &str = "/usr/lib/systemd/network/zz-gooarchy-dhcp.network";
const NETWORKD_DHCP_CONFIG: &str = "[Match]\nName=en* eth* wl* wlan*\n\n[Network]\nDHCP=yes\n";
const RESOLV_CONF_PATH: &str = "/etc/resolv.conf";
const RESOLVED_STUB_PATH: &str = "/run/systemd/resolve/stub-resolv.conf";
const RESOLVED_COMPAT_PATH: &str = "/run/systemd/resolve/resolv.conf";
const RESOLVED_STATIC_PATH: &str = "/usr/lib/systemd/resolv.conf";

enum NetworkConfigState {
    DefaultRouteAlreadyActive,
    Existing(PathBuf),
    Added,
}

enum ResolverConfigState {
    AlreadyResolved,
    Added,
    Preserved,
}

fn main() -> std::process::ExitCode {
    common::run("gooarchy-network", run)
}

fn run() -> Result<(), Failure> {
    let args = env::args_os()
        .skip(1)
        .map(|arg| {
            arg.into_string()
                .map_err(|_| Failure::with_code(2, "arguments must be UTF-8"))
        })
        .collect::<Result<Vec<_>, _>>()?;

    match args.as_slice() {
        [] => print_help(),
        [arg] if matches!(arg.as_str(), "-h" | "--help" | "help") => print_help(),
        [action] if action == "status" => status(),
        [action] if action == "ensure" => ensure(false),
        [action, yes] if action == "ensure" && yes == "--yes" => ensure(true),
        [action] if action == "restart-wifi" => restart_wifi(),
        _ => Err(Failure::with_code(2, format!("invalid command\n{HELP}"))),
    }
}

fn print_help() -> Result<(), Failure> {
    io::stdout().write_all(HELP.as_bytes())?;
    Ok(())
}

fn status() -> Result<(), Failure> {
    println!("Gooarchy network services:");
    for (name, service) in SERVICES {
        let active = service_active(service)?;
        let enabled = service_enabled(service)?;
        println!(
            "  {name}: {} ({})",
            if active { "active" } else { "inactive" },
            if enabled { "enabled" } else { "not enabled" }
        );
    }

    if service_active("systemd-networkd.service")? {
        println!("\nLinks:");
        show_readonly("networkctl", &["list", "--no-pager"])?;
        println!("\nCurrent network details:");
        show_readonly("networkctl", &["status", "--no-pager"])?;
    }
    if service_active("iwd.service")? {
        println!("\nWi-Fi stations:");
        show_wifi_status()?;
    }
    Ok(())
}

fn ensure(yes: bool) -> Result<(), Failure> {
    if service_active("NetworkManager.service")? {
        println!(
            "NetworkManager is active; Gooarchy left the current network manager, services, and configuration unchanged."
        );
        return Ok(());
    }

    let networkd_active = service_active("systemd-networkd.service")?;
    let route_present = default_route_present()?;
    if !networkd_active && route_present {
        println!(
            "A default route is active without systemd-networkd; Gooarchy left the current network manager, services, and configuration unchanged."
        );
        return Ok(());
    }

    if !package_installed("systemd")? {
        return Err(Failure::new(
            "the systemd package is absent; Gooarchy will not replace the system base",
        ));
    }
    if !package_installed("iwd")? {
        let mut args = vec!["-S", "--needed"];
        if yes {
            args.push("--noconfirm");
        }
        args.push("iwd");
        run_privileged("pacman", &args)?;
    }

    let network_config = if route_present {
        NetworkConfigState::DefaultRouteAlreadyActive
    } else if let Some(path) = existing_networkd_config()? {
        NetworkConfigState::Existing(path)
    } else if write_networkd_default()? {
        NetworkConfigState::Added
    } else {
        NetworkConfigState::Existing(PathBuf::from(NETWORKD_CONFIG_PATH))
    };

    for (name, service) in SERVICES {
        ensure_service(name, service)?;
    }
    if matches!(&network_config, NetworkConfigState::Added) {
        run_privileged("networkctl", &["reload"])?;
    }

    let resolver_config = ensure_resolved_resolv_conf()?;
    match network_config {
        NetworkConfigState::DefaultRouteAlreadyActive => println!(
            "A default route was already active; Gooarchy did not add a networkd DHCP fallback."
        ),
        NetworkConfigState::Existing(path) => {
            println!(
                "Existing networkd configuration at {} was left unchanged.",
                path.display()
            );
        }
        NetworkConfigState::Added => println!(
            "Added a DHCP fallback for standard Ethernet and Wi-Fi links not matched by earlier networkd configuration."
        ),
    }
    match resolver_config {
        ResolverConfigState::AlreadyResolved => {
            println!("/etc/resolv.conf already points to systemd-resolved.");
        }
        ResolverConfigState::Added => {
            println!("Linked the previously absent /etc/resolv.conf to systemd-resolved.");
        }
        ResolverConfigState::Preserved => {
            println!("Existing /etc/resolv.conf was left unchanged.");
        }
    }

    if default_route_present()? {
        println!("A default route is active.");
    } else {
        println!(
            "No default route is active; network connectivity is not confirmed. See `gooarchy network status` for the current link and Wi-Fi state."
        );
    }
    Ok(())
}

fn existing_networkd_config() -> Result<Option<PathBuf>, Failure> {
    for directory in NETWORKD_ADMIN_DIRS {
        let entries = match fs::read_dir(directory) {
            Ok(entries) => entries,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(Failure::new(format!(
                    "could not inspect networkd configuration directory {directory}: {error}"
                )));
            }
        };

        for entry in entries {
            let entry = entry.map_err(|error| {
                Failure::new(format!(
                    "could not read networkd configuration directory {directory}: {error}"
                ))
            })?;
            if entry
                .path()
                .extension()
                .and_then(|extension| extension.to_str())
                == Some("network")
            {
                return Ok(Some(entry.path()));
            }
        }
    }

    if path_entry_exists(NETWORKD_VENDOR_CONFIG_PATH)? {
        return Ok(Some(PathBuf::from(NETWORKD_VENDOR_CONFIG_PATH)));
    }
    Ok(None)
}

fn write_networkd_default() -> Result<bool, Failure> {
    if path_entry_exists(NETWORKD_CONFIG_PATH)? {
        return Ok(false);
    }

    run_privileged("mkdir", &["-p", "/etc/systemd/network"])?;
    match run_privileged_with_input(
        "sh",
        &[
            "-c",
            "set -C; cat > \"$1\"",
            "gooarchy-network",
            NETWORKD_CONFIG_PATH,
        ],
        NETWORKD_DHCP_CONFIG,
    ) {
        Ok(()) => Ok(true),
        Err(error) => match fs::read(NETWORKD_CONFIG_PATH) {
            Ok(contents) if contents == NETWORKD_DHCP_CONFIG.as_bytes() => Ok(false),
            Ok(_) => Err(Failure::new(format!(
                "could not add the Gooarchy networkd fallback; {NETWORKD_CONFIG_PATH} exists and was left unchanged ({})",
                error.message
            ))),
            Err(read_error) => Err(Failure::new(format!(
                "could not add the Gooarchy networkd fallback ({}) and could not inspect {NETWORKD_CONFIG_PATH}: {read_error}",
                error.message
            ))),
        },
    }
}

fn ensure_resolved_resolv_conf() -> Result<ResolverConfigState, Failure> {
    match fs::symlink_metadata(RESOLV_CONF_PATH) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() {
                let target = fs::read_link(RESOLV_CONF_PATH).map_err(|error| {
                    Failure::new(format!("could not read {RESOLV_CONF_PATH}: {error}"))
                })?;
                if target == Path::new(RESOLVED_STUB_PATH)
                    || target == Path::new(RESOLVED_COMPAT_PATH)
                    || target == Path::new(RESOLVED_STATIC_PATH)
                {
                    return Ok(ResolverConfigState::AlreadyResolved);
                }
            }
            Ok(ResolverConfigState::Preserved)
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            if !Path::new(RESOLVED_STUB_PATH).exists() {
                return Err(Failure::new(format!(
                    "systemd-resolved did not provide {RESOLVED_STUB_PATH}; {RESOLV_CONF_PATH} was not created"
                )));
            }

            match run_privileged("ln", &["-s", RESOLVED_STUB_PATH, RESOLV_CONF_PATH]) {
                Ok(()) => Ok(ResolverConfigState::Added),
                Err(_error) if path_entry_exists(RESOLV_CONF_PATH)? => {
                    Ok(ResolverConfigState::Preserved)
                }
                Err(error) => Err(error),
            }
        }
        Err(error) => Err(Failure::new(format!(
            "could not inspect {RESOLV_CONF_PATH}: {error}"
        ))),
    }
}

fn path_entry_exists(path: &str) -> Result<bool, Failure> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(Failure::new(format!("could not inspect {path}: {error}"))),
    }
}

fn show_wifi_status() -> Result<(), Failure> {
    let output = match command_output("iwctl", &["station", "list"]) {
        Ok(output) if output.status.success() => output,
        Ok(output) => return Err(command_failure("iwctl", &output)),
        Err(error) if error.message.contains("not installed") => {
            println!("iwctl: not installed");
            return Ok(());
        }
        Err(error) => return Err(error),
    };

    io::stdout().write_all(&output.stdout)?;
    let stations = station_names(&String::from_utf8_lossy(&output.stdout));
    if stations.is_empty() {
        println!("No Wi-Fi stations are available.");
        return Ok(());
    }

    for device in stations {
        println!("\nCurrent connection for {device}:");
        show_readonly("iwctl", &["station", device.as_str(), "show"])?;
    }
    Ok(())
}

fn ensure_service(name: &str, service: &str) -> Result<(), Failure> {
    if service_active(service)? {
        println!("{name} is already active; left it unchanged.");
        return Ok(());
    }

    if service_enabled(service)? {
        run_privileged("systemctl", &["start", service])?;
    } else {
        run_privileged("systemctl", &["enable", "--now", service])?;
    }
    println!("Started {name}.");
    Ok(())
}

fn restart_wifi() -> Result<(), Failure> {
    if !package_installed("iwd")? {
        return Err(Failure::new(
            "iwd is not installed; run `gooarchy network ensure` first",
        ));
    }

    run_privileged("rfkill", &["unblock", "wifi"])?;
    run_privileged("systemctl", &["restart", "iwd.service"])?;

    let stations = checked_output("iwctl", &["station", "list"])?;
    let devices = station_names(&String::from_utf8_lossy(&stations.stdout));
    if devices.is_empty() {
        println!("Wi-Fi was unblocked and iwd restarted; iwd reports no station to scan.");
        return Ok(());
    }

    for device in &devices {
        checked_output("iwctl", &["station", device, "scan"])?;
    }
    println!(
        "Wi-Fi was unblocked; iwd restarted and scan started on {}.",
        devices.join(", ")
    );
    Ok(())
}

fn service_active(service: &str) -> Result<bool, Failure> {
    Ok(
        command_output("systemctl", &["is-active", "--quiet", service])?
            .status
            .success(),
    )
}

fn service_enabled(service: &str) -> Result<bool, Failure> {
    Ok(
        command_output("systemctl", &["is-enabled", "--quiet", service])?
            .status
            .success(),
    )
}

fn package_installed(package: &str) -> Result<bool, Failure> {
    let output = command_output("pacman", &["-Q", package])?;
    if output.status.success() {
        return Ok(true);
    }
    let error = String::from_utf8_lossy(&output.stderr);
    if error.contains("was not found") {
        return Ok(false);
    }
    Err(command_failure("pacman", &output))
}

fn default_route_present() -> Result<bool, Failure> {
    for args in [
        &["route", "show", "default"][..],
        &["-6", "route", "show", "default"][..],
    ] {
        let output = checked_output("ip", args)?;
        if !String::from_utf8_lossy(&output.stdout).trim().is_empty() {
            return Ok(true);
        }
    }
    Ok(false)
}

fn station_names(output: &str) -> Vec<String> {
    let mut names = Vec::new();
    for line in output.lines() {
        let Some(name) = line.split_whitespace().next() else {
            continue;
        };
        let looks_like_device = name.starts_with("wl") || name.starts_with("phy");
        let safe_name = name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
        if looks_like_device && safe_name && !names.iter().any(|existing| existing == name) {
            names.push(name.to_owned());
        }
    }
    names
}

fn run_privileged(program: &str, args: &[&str]) -> Result<(), Failure> {
    let mut command = if effective_uid()? == 0 {
        Command::new(program)
    } else {
        let mut command = Command::new("sudo");
        command.arg("--").arg(program);
        command
    };
    let status = command.args(args).status().map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            Failure::new(format!("required command is not installed: {program}"))
        } else {
            Failure::new(format!("could not run {program}: {error}"))
        }
    })?;
    if status.success() {
        Ok(())
    } else {
        Err(Failure::with_code(
            status.code().unwrap_or(1).clamp(1, u8::MAX as i32) as u8,
            format!("{program} {} failed", args.join(" ")),
        ))
    }
}

fn run_privileged_with_input(program: &str, args: &[&str], input: &str) -> Result<(), Failure> {
    let mut command = if effective_uid()? == 0 {
        Command::new(program)
    } else {
        let mut command = Command::new("sudo");
        command.arg("--").arg(program);
        command
    };
    let mut child = command
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            if error.kind() == io::ErrorKind::NotFound {
                Failure::new(format!("required command is not installed: {program}"))
            } else {
                Failure::new(format!("could not run {program}: {error}"))
            }
        })?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| Failure::new(format!("could not provide input to {program}")))?;
    let write_result = stdin.write_all(input.as_bytes());
    drop(stdin);

    let output = child
        .wait_with_output()
        .map_err(|error| Failure::new(format!("could not wait for {program}: {error}")))?;
    if !output.status.success() {
        return Err(command_failure(program, &output));
    }
    write_result
        .map_err(|error| Failure::new(format!("could not write input to {program}: {error}")))
}

fn effective_uid() -> Result<u32, Failure> {
    let output = checked_output("id", &["-u"])?;
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse()
        .map_err(|_| Failure::new("could not determine the effective user ID"))
}

fn show_readonly(program: &str, args: &[&str]) -> Result<(), Failure> {
    match command_output(program, args) {
        Ok(output) if output.status.success() => {
            io::stdout().write_all(&output.stdout)?;
            Ok(())
        }
        Ok(output) => {
            let detail = String::from_utf8_lossy(&output.stderr);
            Err(Failure::new(format!("{program} failed: {}", detail.trim())))
        }
        Err(error) if error.message.contains("not installed") => {
            println!("{program}: not installed");
            Ok(())
        }
        Err(error) => Err(error),
    }
}

fn checked_output(program: &str, args: &[&str]) -> Result<Output, Failure> {
    let output = command_output(program, args)?;
    if output.status.success() {
        Ok(output)
    } else {
        Err(command_failure(program, &output))
    }
}

fn command_output(program: &str, args: &[&str]) -> Result<Output, Failure> {
    Command::new(program).args(args).output().map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            Failure::new(format!("required command is not installed: {program}"))
        } else {
            Failure::new(format!("could not run {program}: {error}"))
        }
    })
}

fn command_failure(program: &str, output: &Output) -> Failure {
    let detail = String::from_utf8_lossy(&output.stderr);
    let detail = detail.trim();
    if detail.is_empty() {
        Failure::new(format!("{program} exited with {}", output.status))
    } else {
        Failure::new(format!("{program} failed: {detail}"))
    }
}
