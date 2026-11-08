use common::Failure;
use std::fs;
use std::io::{BufRead, Write};
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

const STORE: &str = "/.snapshots";
const PREFIX: &str = "gooarchy-";

struct Snapshot {
    id: u64,
    name: String,
}

struct Layout {
    root_id: u64,
}

enum RootFilesystem {
    Btrfs(Layout),
    Other(String),
}

pub fn take(label: &str, output: &mut impl Write) -> Result<(), Failure> {
    match filesystem()? {
        RootFilesystem::Other(name) => {
            writeln!(
                output,
                "Snapshots need a Btrfs root; no snapshot was taken (root is {name})."
            )?;
            Ok(())
        }
        RootFilesystem::Btrfs(layout) => {
            let name = snapshot_name(label)?;
            create_snapshot(&layout, &name, output).map(|_| ())
        }
    }
}

pub fn list(output: &mut impl Write) -> Result<(), Failure> {
    require_btrfs(filesystem()?)?;
    let snapshots = list_snapshots()?;
    if snapshots.is_empty() {
        writeln!(output, "No Gooarchy snapshots are stored under {STORE}.")?;
        return Ok(());
    }
    writeln!(output, "Gooarchy snapshots under {STORE}:")?;
    for snapshot in snapshots {
        writeln!(output, "{}\t{}", snapshot.id, snapshot.name)?;
    }
    Ok(())
}

pub fn restore(
    selector: &str,
    input: &mut impl BufRead,
    output: &mut impl Write,
) -> Result<(), Failure> {
    let layout = require_btrfs(filesystem()?)?;
    if !boot_uses_default_subvolume()? {
        return Err(Failure::new(
            "restore needs the booted root to use Btrfs's default subvolume; this system selects a root subvolume explicitly, so Gooarchy left the boot setup unchanged",
        ));
    }
    let snapshots = list_snapshots()?;
    let selected = snapshots
        .into_iter()
        .find(|snapshot| snapshot.id.to_string() == selector || snapshot.name == selector)
        .ok_or_else(|| {
            Failure::new(format!(
                "no Gooarchy snapshot matches {selector:?}; run 'gooarchy boot snapshot list'"
            ))
        })?;
    let default_id = default_subvolume_id()?;
    if default_id == selected.id {
        writeln!(
            output,
            "Btrfs already selects snapshot {} (ID {}).",
            selected.name, selected.id
        )?;
        return Ok(());
    }

    writeln!(
        output,
        "Restore Btrfs root to snapshot {} (ID {}).",
        selected.name, selected.id
    )?;
    writeln!(
        output,
        "Reason: return the root filesystem to the selected snapshot."
    )?;
    writeln!(
        output,
        "This changes Btrfs's default root for the next boot and does not edit bootloader files."
    )?;
    writeln!(
        output,
        "Undo: run 'gooarchy boot snapshot list', then restore another snapshot before restarting."
    )?;
    write!(output, "Continue? [y/N] ")?;
    output.flush()?;
    if !confirmed(input)? {
        writeln!(
            output,
            "Restore cancelled; the selected root was not changed."
        )?;
        return Ok(());
    }

    let backup_name = snapshot_name("before-restore")?;
    let backup = create_snapshot(&layout, &backup_name, output)?;
    let id = selected.id.to_string();
    run_privileged("btrfs", &["subvolume", "set-default", &id, "/"])?;
    writeln!(
        output,
        "Btrfs will use snapshot {} (ID {}) after restart.",
        selected.name, selected.id
    )?;
    writeln!(
        output,
        "To undo before restarting, run 'gooarchy boot snapshot restore {}'.",
        backup.id
    )?;
    Ok(())
}

fn filesystem() -> Result<RootFilesystem, Failure> {
    let root_mount = mount_info("/")?;
    if root_mount.fstype != "btrfs" {
        return Ok(RootFilesystem::Other(root_mount.fstype));
    }

    let root_id = subvolume_id("/").map_err(|_| {
        Failure::new("the Btrfs root is not a snapshotable subvolume; Gooarchy will not change the subvolume layout")
    })?;
    if root_id == 5 {
        return Err(Failure::new(
            "the Btrfs root is the top-level subvolume, which Gooarchy cannot snapshot; no subvolumes were created or changed",
        ));
    }

    let snapshots_mount = mount_info(STORE).map_err(|_| layout_error())?;
    if snapshots_mount.target != STORE
        || snapshots_mount.fstype != "btrfs"
        || snapshots_mount.uuid.is_empty()
        || snapshots_mount.uuid != root_mount.uuid
    {
        return Err(layout_error());
    }
    let store_id = subvolume_id(STORE).map_err(|_| layout_error())?;
    if store_id == 5 {
        return Err(layout_error());
    }

    Ok(RootFilesystem::Btrfs(Layout { root_id }))
}

fn require_btrfs(filesystem: RootFilesystem) -> Result<Layout, Failure> {
    match filesystem {
        RootFilesystem::Btrfs(layout) => Ok(layout),
        RootFilesystem::Other(_) => Err(Failure::new("snapshots need a Btrfs root")),
    }
}

fn layout_error() -> Failure {
    Failure::new(format!(
        "Btrfs snapshots need an existing same-filesystem subvolume mounted at {STORE}; Gooarchy will not create or rearrange subvolumes"
    ))
}

struct MountInfo {
    target: String,
    fstype: String,
    uuid: String,
}

fn mount_info(path: &str) -> Result<MountInfo, Failure> {
    let output = Command::new("findmnt")
        .args([
            "--noheadings",
            "--raw",
            "--output",
            "TARGET,FSTYPE,UUID",
            "--target",
            path,
        ])
        .output()
        .map_err(|error| {
            Failure::new(format!("cannot read mount information for {path}: {error}"))
        })?;
    if !output.status.success() {
        return Err(Failure::new(format!(
            "cannot read mount information for {path}"
        )));
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let fields: Vec<&str> = text.split_whitespace().collect();
    if fields.len() < 3 {
        return Err(Failure::new(format!(
            "mount information for {path} is incomplete"
        )));
    }
    Ok(MountInfo {
        target: fields[0].to_owned(),
        fstype: fields[1].to_owned(),
        uuid: fields[2].to_owned(),
    })
}

fn subvolume_id(path: &str) -> Result<u64, Failure> {
    let output = run_privileged("btrfs", &["subvolume", "show", path])?;
    parse_subvolume_id(&String::from_utf8_lossy(&output.stdout))
        .ok_or_else(|| Failure::new(format!("could not read the Btrfs subvolume ID for {path}")))
}

fn default_subvolume_id() -> Result<u64, Failure> {
    let output = run_privileged("btrfs", &["subvolume", "get-default", "/"])?;
    parse_subvolume_id(&String::from_utf8_lossy(&output.stdout))
        .ok_or_else(|| Failure::new("could not read the Btrfs default subvolume ID"))
}

fn parse_subvolume_id(text: &str) -> Option<u64> {
    text.lines().find_map(|line| {
        if let Some((field, value)) = line.split_once(':')
            && field.trim() == "Subvolume ID"
        {
            return value.trim().parse::<u64>().ok();
        }
        let mut fields = line.split_whitespace();
        (fields.next() == Some("ID"))
            .then(|| fields.next()?.parse::<u64>().ok())
            .flatten()
    })
}

fn list_snapshots() -> Result<Vec<Snapshot>, Failure> {
    let output = run_privileged("btrfs", &["subvolume", "list", "-o", STORE])?;
    Ok(parse_snapshots(&String::from_utf8_lossy(&output.stdout)))
}

fn parse_snapshots(text: &str) -> Vec<Snapshot> {
    text.lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            if fields.len() < 2 || fields[0] != "ID" {
                return None;
            }
            let id = fields[1].parse().ok()?;
            let (_, path) = line.split_once(" path ")?;
            let name = path.rsplit('/').next()?.trim();
            if !name.starts_with(PREFIX) || name.contains('/') {
                return None;
            }
            Some(Snapshot {
                id,
                name: name.to_owned(),
            })
        })
        .collect()
}

fn snapshot_name(label: &str) -> Result<String, Failure> {
    let label: String = label
        .chars()
        .filter(|character| character.is_ascii_alphanumeric() || *character == '-')
        .take(32)
        .collect();
    let label = if label.is_empty() { "manual" } else { &label };
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| Failure::new(format!("cannot read the current time: {error}")))?
        .as_nanos();
    Ok(format!("{PREFIX}{label}-{timestamp}"))
}

fn create_snapshot(
    layout: &Layout,
    name: &str,
    output: &mut impl Write,
) -> Result<Snapshot, Failure> {
    let path = format!("{STORE}/{name}");
    writeln!(
        output,
        "Create Btrfs snapshot {name} of root subvolume ID {}.",
        layout.root_id
    )?;
    writeln!(
        output,
        "Reason: preserve the current root before a system change."
    )?;
    run_privileged("btrfs", &["subvolume", "snapshot", "/", &path])?;
    let id = subvolume_id(&path)?;
    writeln!(
        output,
        "Created Gooarchy snapshot {name} (ID {id}) under {STORE}."
    )?;
    Ok(Snapshot {
        id,
        name: name.to_owned(),
    })
}

fn boot_uses_default_subvolume() -> Result<bool, Failure> {
    let fstab = fs::read_to_string("/etc/fstab").map_err(|error| {
        Failure::new(format!(
            "cannot check the root mount entry in /etc/fstab: {error}"
        ))
    })?;
    for line in fstab.lines().map(str::trim) {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() > 3 && fields[1] == "/" && has_subvolume_option(fields[3]) {
            return Ok(false);
        }
    }

    let cmdline = fs::read_to_string("/proc/cmdline").map_err(|error| {
        Failure::new(format!(
            "cannot check the current kernel root options: {error}"
        ))
    })?;
    for argument in cmdline.split_whitespace() {
        if let Some(options) = argument.strip_prefix("rootflags=") {
            if options.split(',').any(has_subvolume_option) {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

fn has_subvolume_option(options: &str) -> bool {
    options
        .split(',')
        .any(|option| option.starts_with("subvol=") || option.starts_with("subvolid="))
}

fn confirmed(input: &mut impl BufRead) -> Result<bool, Failure> {
    let mut answer = String::new();
    input.read_line(&mut answer)?;
    Ok(matches!(
        answer.trim().to_ascii_lowercase().as_str(),
        "y" | "yes"
    ))
}

fn run_privileged(program: &str, args: &[&str]) -> Result<Output, Failure> {
    let output = Command::new("sudo")
        .arg("--")
        .arg(program)
        .args(args)
        .stdin(Stdio::inherit())
        .stderr(Stdio::inherit())
        .output()
        .map_err(|error| Failure::new(format!("cannot run {program} with sudo: {error}")))?;
    if output.status.success() {
        Ok(output)
    } else {
        Err(Failure::new(format!(
            "{program} failed with {}",
            output.status
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn parses_subvolume_ids_from_show_and_get_default_output() {
        assert_eq!(
            parse_subvolume_id("Name: @\nSubvolume ID: 256\n"),
            Some(256)
        );
        assert_eq!(
            parse_subvolume_id("ID 256 gen 500 top level 5 path @\n"),
            Some(256)
        );
        assert_eq!(parse_subvolume_id("no subvolume\n"), None);
    }

    #[test]
    fn lists_only_gooarchy_snapshots_by_id_and_final_path_component() {
        let output = parse_snapshots(
            "ID 259 gen 700 top level 5 path @snapshots/gooarchy-update-123\n\
             ID 260 gen 701 top level 5 path @snapshots/other-tool-456\n\
             ID 261 gen 702 top level 5 path @snapshots/archive/gooarchy-manual-789\n",
        );
        assert_eq!(output.len(), 2);
        assert_eq!(output[0].id, 259);
        assert_eq!(output[0].name, "gooarchy-update-123");
        assert_eq!(output[1].id, 261);
    }

    #[test]
    fn root_boot_options_detect_explicit_subvolume_selection() {
        assert!(has_subvolume_option("rw,subvol=@,compress=zstd"));
        assert!(has_subvolume_option("rootflags=subvolid=256"));
        assert!(!has_subvolume_option("rw,compress=zstd,ssd"));
    }

    #[test]
    fn snapshot_labels_cannot_add_a_path_component() {
        let name = snapshot_name("before/restore ..").unwrap();
        assert!(name.starts_with("gooarchy-beforerestore-"));
        assert!(
            !Path::new(&name)
                .components()
                .any(|part| part.as_os_str() == "..")
        );
    }
}
