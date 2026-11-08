//! Detect this machine and apply the laptop-specific fixes Gooarchy has data for.

use common::Failure;
use std::env;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const HELP: &str = "Usage: gooarchy hw <apply|is laptop|match PATTERN|audio-tuning status|apply>\n\
Detects the current machine and applies supported Gooarchy laptop fixes.\n";
const SPEAKER_PROFILE: &str = include_str!("../profiles/dell-xps-2026.conf");
const SPEAKER_PROFILE_PATH: &str = "pipewire/pipewire.conf.d/90-gooarchy-speaker-tuning.conf";

fn main() -> ExitCode {
    common::run("gooarchy-hw", run)
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
        [command] if command == "apply" => apply(),
        [command, detector] if command == "is" && detector == "laptop" => {
            if is_laptop() {
                Ok(())
            } else {
                Err(Failure::new("this machine is not identified as a laptop"))
            }
        }
        [command, pattern] if command == "match" => {
            if matches_dmi(pattern) {
                Ok(())
            } else {
                Err(Failure::new(format!("machine does not match {pattern:?}")))
            }
        }
        [command, action] if command == "audio-tuning" && action == "status" => audio_status(),
        [command, action] if command == "audio-tuning" && action == "apply" => apply_audio_tuning(),
        _ => Err(Failure::with_code(2, format!("invalid command\n{HELP}"))),
    }
}

fn print_help() -> Result<(), Failure> {
    io::stdout().write_all(HELP.as_bytes())?;
    Ok(())
}

fn apply() -> Result<(), Failure> {
    if !is_laptop() {
        println!("No laptop-specific hardware fixes apply to this machine.");
        return Ok(());
    }

    apply_audio_tuning()
}

/// A lid switch is the most direct laptop signal. DMI chassis type is the fallback, using the
/// laptop and portable values used by Omarchy's hardware detector.
fn is_laptop() -> bool {
    let lid_root = Path::new("/proc/acpi/button/lid");
    if fs::read_dir(lid_root).is_ok_and(|entries| {
        entries
            .flatten()
            .any(|entry| entry.path().join("state").exists())
    }) {
        return true;
    }

    read_trimmed(Path::new("/sys/class/dmi/id/chassis_type"))
        .is_some_and(|value| matches!(value.as_str(), "8" | "9" | "10" | "14" | "30" | "31" | "32"))
}

/// Match a case-insensitive literal in the DMI product name or family.
fn matches_dmi(pattern: &str) -> bool {
    ["product_name", "product_family"].iter().any(|field| {
        read_trimmed(&Path::new("/sys/class/dmi/id").join(field))
            .is_some_and(|value| value.to_lowercase().contains(&pattern.to_lowercase()))
    })
}

fn audio_status() -> Result<(), Failure> {
    let sku = read_trimmed(Path::new("/sys/class/dmi/id/product_sku"));
    let model = read_trimmed(Path::new("/sys/class/dmi/id/product_name"));
    let Some(sku) = sku.filter(|sku| supported_sku(sku)) else {
        println!("Speaker tuning: no supported Gooarchy profile for this machine.");
        return Ok(());
    };

    let config = speaker_config_path()?;
    let state = match fs::read(&config) {
        Ok(contents) if contents == SPEAKER_PROFILE.as_bytes() => "installed",
        Ok(_) => "another file already uses the Gooarchy profile path",
        Err(error) if error.kind() == io::ErrorKind::NotFound => "not installed",
        Err(error) => {
            return Err(Failure::new(format!(
                "cannot read {}: {error}",
                config.display()
            )));
        }
    };
    println!("Speaker tuning: Dell XPS 14/16 (2026), DMI SKU {sku} ({state}).");
    if let Some(model) = model {
        println!("Detected product: {model}");
    }
    println!(
        "The measured profile is for XPS 14 SKU 0DB9; XPS 16 SKU 0DBA is included on the source report."
    );
    println!("Profile path: {}", config.display());
    Ok(())
}

fn apply_audio_tuning() -> Result<(), Failure> {
    let Some(sku) = read_trimmed(Path::new("/sys/class/dmi/id/product_sku")) else {
        println!("Speaker tuning: DMI product SKU is unavailable; no change made.");
        return Ok(());
    };
    if !supported_sku(&sku) {
        println!(
            "Speaker tuning: no supported Gooarchy profile for DMI SKU {sku}; no change made."
        );
        return Ok(());
    }

    let config = speaker_config_path()?;
    match fs::read(&config) {
        Ok(contents) if contents == SPEAKER_PROFILE.as_bytes() => {
            println!("Speaker tuning is already configured for DMI SKU {sku}.");
            return Ok(());
        }
        Ok(_) => {
            return Err(Failure::new(format!(
                "{} already exists with different contents; it was left unchanged",
                config.display()
            )));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(Failure::new(format!(
                "cannot read {}: {error}",
                config.display()
            )));
        }
    }

    let parent = config
        .parent()
        .ok_or_else(|| Failure::new("cannot find the PipeWire config directory"))?;
    fs::create_dir_all(parent)
        .map_err(|error| Failure::new(format!("cannot create {}: {error}", parent.display())))?;
    fs::write(&config, SPEAKER_PROFILE)
        .map_err(|error| Failure::new(format!("cannot write {}: {error}", config.display())))?;

    println!("Installed the Dell XPS 14/16 speaker tuning for DMI SKU {sku}.");
    println!(
        "PipeWire will load it on its next start. To undo, remove {}.",
        config.display()
    );
    Ok(())
}

fn supported_sku(sku: &str) -> bool {
    ["0DB9", "0DBA"]
        .iter()
        .any(|supported| sku.eq_ignore_ascii_case(supported))
}

fn speaker_config_path() -> Result<PathBuf, Failure> {
    let config_home = env::var_os("XDG_CONFIG_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .ok_or_else(|| {
            Failure::new("HOME or XDG_CONFIG_HOME must identify the user's config directory")
        })?;
    Ok(config_home.join(SPEAKER_PROFILE_PATH))
}

fn read_trimmed(path: &Path) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}
