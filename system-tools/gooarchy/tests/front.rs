//! The built `gooarchy` run from a directory of stand-in tools.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::Mutex;

// A file written in one test thread can still be open for writing in a child another thread is
// forking, and running it then fails with "Text file busy". One test at a time avoids that.
static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

struct Tools(PathBuf);

impl Tools {
    /// A directory holding a copy of `gooarchy`, an executable `gooarchy-echo` that prints its
    /// arguments and exits 3, and a `gooarchy-plain` that is not executable.
    fn new(name: &str) -> Tools {
        let dir =
            std::env::temp_dir().join(format!("gooarchy-front-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::copy(env!("CARGO_BIN_EXE_gooarchy"), dir.join("gooarchy")).unwrap();
        write(
            &dir.join("gooarchy-echo"),
            "#!/bin/sh\nfor a; do echo \"[$a]\"; done\nexit 3\n",
            0o755,
        );
        write(&dir.join("gooarchy-plain"), "#!/bin/sh\nexit 0\n", 0o644);
        Tools(dir)
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(self.0.join("gooarchy"))
            .args(args)
            .output()
            .unwrap()
    }
}

impl Drop for Tools {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn write(path: &Path, text: &str, mode: u32) {
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[test]
fn with_no_arguments_it_lists_the_executable_tools_beside_it() {
    let _one = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
    let tools = Tools::new("list");
    for args in [&[][..], &["--help"], &["-h"]] {
        let out = tools.run(args);
        let stdout = text(&out.stdout);
        assert_eq!(out.status.code(), Some(0), "{args:?}");
        assert!(
            stdout.starts_with("Usage: gooarchy <tool> [arguments]"),
            "{stdout}"
        );
        assert!(stdout.contains("\n  echo\n"), "{stdout}");
        assert!(!stdout.contains("plain"), "{stdout}");
    }
}

#[test]
fn a_tool_runs_with_its_arguments_and_its_exit_status() {
    let _one = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
    let tools = Tools::new("run");
    let out = tools.run(&["echo", "one", "two words", "--help"]);
    assert_eq!(text(&out.stdout), "[one]\n[two words]\n[--help]\n");
    assert_eq!(out.status.code(), Some(3));
}

#[test]
fn an_unknown_or_unrunnable_tool_exits_127_with_a_suggestion_when_one_fits() {
    let _one = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
    let tools = Tools::new("unknown");

    let out = tools.run(&["ec"]);
    let stderr = text(&out.stderr);
    assert_eq!(out.status.code(), Some(127));
    assert!(
        stderr.starts_with("gooarchy: unknown tool: ec\n"),
        "{stderr}"
    );
    assert!(stderr.contains("Did you mean: gooarchy echo ?"), "{stderr}");
    assert!(out.stdout.is_empty());

    for name in ["plain", "nothing", "../gooarchy-echo", "-x"] {
        let out = tools.run(&[name]);
        assert_eq!(out.status.code(), Some(127), "{name}");
        assert!(
            text(&out.stderr).contains(&format!("unknown tool: {name}")),
            "{name}"
        );
    }
}
