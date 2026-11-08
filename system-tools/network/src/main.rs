//! Keep Gooarchy's network stack in place, report its state, and recover Wi-Fi through iwd.

use common::Failure;
use std::env;
use std::io::{self, Write};
use std::process::{Command, Output};

const HELP: &str = "Usage: gooarchy network <ensure [--yes]|status|restart-wifi>\n\
ensure       Install and start the selected stack components when needed\n\
status       Show systemd-networkd, iwd, and systemd-resolved state\n\
restart-wifi Unblock Wi-Fi and rescan through iwd\n";
const SERVICES: [(&str, &str); 3] = [
    ("systemd-networkd", "systemd-networkd.service"),
    ("iwd", "iwd.service"),
    ("systemd-resolved", "systemd-resolved.service"),
];

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
    }
    if service_active("iwd.service")? {
        println!("\nWi-Fi stations:");
        show_readonly("iwctl", &["station", "list"])?;
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
    if !networkd_active && default_route_present()? {
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

    for (name, service) in SERVICES {
        ensure_service(name, service)?;
    }
    println!("Gooarchy network stack is ready; no network configuration files were changed.");
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
