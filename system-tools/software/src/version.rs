use crate::commands::{Runner, args, output_text};
use common::Failure;
use std::io::Write;

const BUILD_COMMIT: &str = env!("GOOARCHY_SOFTWARE_BUILD_COMMIT");

pub fn report(runner: &Runner, output: &mut impl Write) -> Result<(), Failure> {
    let gooarchy = installed_package(runner, "gooarchy")?;
    let scottland = installed_package(runner, "scottland")?;
    writeln!(output, "Gooarchy: {gooarchy} (commit {BUILD_COMMIT})")?;
    writeln!(output, "Scottland: {scottland}")?;
    Ok(())
}

fn installed_package(runner: &Runner, name: &str) -> Result<String, Failure> {
    let result = runner.output("pacman", &args(&["-Q", "--", name]))?;
    if result.status.success() {
        Ok(output_text(&result).trim().to_owned())
    } else {
        Ok("not installed".to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn reports_both_installed_package_versions_and_the_build_commit() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = env::temp_dir().join(format!(
            "gooarchy-version-test-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&directory).unwrap();
        let pacman = directory.join("pacman");
        fs::write(
            &pacman,
            "#!/bin/sh\nif [ \"$3\" = gooarchy ]; then echo 'gooarchy 0.0.1.r7.g1234567-1'; else echo 'scottland 0.3.1-1'; fi\n",
        )
        .unwrap();
        fs::set_permissions(&pacman, fs::Permissions::from_mode(0o755)).unwrap();
        let runner = Runner::in_path(PathBuf::from(&directory));
        let mut output = Vec::new();
        report(&runner, &mut output).unwrap();
        let output = String::from_utf8(output).unwrap();
        assert!(output.contains("Gooarchy: gooarchy 0.0.1.r7.g1234567-1"));
        assert!(output.contains(BUILD_COMMIT));
        assert!(output.contains("Scottland: scottland 0.3.1-1"));
        fs::remove_dir_all(directory).unwrap();
    }
}
