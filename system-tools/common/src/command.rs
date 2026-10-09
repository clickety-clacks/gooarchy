//! Finding commands on PATH, as Omarchy's scripts do with omarchy-cmd-present and
//! omarchy-cmd-missing before they use an optional program.
//!
//! Derived from Omarchy's bin/omarchy-cmd-present and bin/omarchy-cmd-missing at commit
//! 81145eb1fd41532fcae4310b26f860608e2eaf82. Changed: library functions instead of commands, and
//! the lookup is done here rather than by the shell's `command -v`, so shell builtins, functions
//! and aliases do not count; only executable files on PATH (or at a path given with a slash) do.
//!
//! Omarchy's copyright and license notice:
//!
//!   Copyright (c) David Heinemeier Hansson
//!
//!   Permission is hereby granted, free of charge, to any person obtaining
//!   a copy of this software and associated documentation files (the
//!   "Software"), to deal in the Software without restriction, including
//!   without limitation the rights to use, copy, modify, merge, publish,
//!   distribute, sublicense, and/or sell copies of the Software, and to
//!   permit persons to whom the Software is furnished to do so, subject to
//!   the following conditions:
//!
//!   The above copyright notice and this permission notice shall be
//!   included in all copies or substantial portions of the Software.
//!
//!   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//!   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//!   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//!   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
//!   LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
//!   OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
//!   WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

use std::env;
use std::ffi::OsStr;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// True when every one of `names` is a command that can be run (omarchy-cmd-present).
pub fn present(names: &[&str]) -> bool {
    let path = env::var_os("PATH").unwrap_or_default();
    names.iter().all(|name| find_in(&path, name).is_some())
}

/// True when any of `names` is not a command that can be run (omarchy-cmd-missing).
pub fn missing(names: &[&str]) -> bool {
    !present(names)
}

/// Where `name` would be run from: the first executable file called `name` in a PATH directory,
/// or `name` itself when it contains a slash.
pub fn find(name: &str) -> Option<PathBuf> {
    find_in(&env::var_os("PATH").unwrap_or_default(), name)
}

/// True for a file (or a symlink to one) with an execute bit set.
pub fn is_executable(path: &Path) -> bool {
    path.metadata()
        .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

fn find_in(path: &OsStr, name: &str) -> Option<PathBuf> {
    if name.is_empty() {
        return None;
    }
    if name.contains('/') {
        let candidate = PathBuf::from(name);
        return is_executable(&candidate).then_some(candidate);
    }
    // An empty PATH entry means the current directory, as it does for the shell.
    env::split_paths(path)
        .map(|dir| {
            if dir.as_os_str().is_empty() {
                PathBuf::from(".")
            } else {
                dir
            }
        })
        .map(|dir| dir.join(name))
        .find(|candidate| is_executable(candidate))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Scratch {
            let dir =
                env::temp_dir().join(format!("gooarchy-common-{}-{name}", std::process::id()));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            Scratch(dir)
        }

        fn file(&self, dir: &str, name: &str, mode: u32) -> PathBuf {
            let dir = self.0.join(dir);
            fs::create_dir_all(&dir).unwrap();
            let file = dir.join(name);
            fs::write(&file, "#!/bin/sh\n").unwrap();
            fs::set_permissions(&file, fs::Permissions::from_mode(mode)).unwrap();
            file
        }

        fn path(&self, dirs: &[&str]) -> std::ffi::OsString {
            env::join_paths(dirs.iter().map(|d| self.0.join(d))).unwrap()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn finds_the_first_executable_on_path() {
        let s = Scratch::new("first");
        s.file("a", "tool", 0o644);
        let wanted = s.file("b", "tool", 0o755);
        s.file("c", "tool", 0o755);
        assert_eq!(find_in(&s.path(&["a", "b", "c"]), "tool"), Some(wanted));
    }

    #[test]
    fn a_file_without_an_execute_bit_or_a_directory_is_not_a_command() {
        let s = Scratch::new("plain");
        s.file("a", "plain", 0o644);
        fs::create_dir_all(s.0.join("a/dir")).unwrap();
        let path = s.path(&["a"]);
        assert_eq!(find_in(&path, "plain"), None);
        assert_eq!(find_in(&path, "dir"), None);
        assert_eq!(find_in(&path, ""), None);
    }

    #[test]
    fn a_name_with_a_slash_is_checked_where_it_points() {
        let s = Scratch::new("slash");
        let tool = s.file("elsewhere", "tool", 0o755);
        let name = tool.to_str().unwrap();
        assert_eq!(find_in(&s.path(&["empty"]), name), Some(tool.clone()));
        fs::set_permissions(&tool, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(find_in(&s.path(&["empty"]), name), None);
    }

    #[test]
    fn present_needs_all_and_missing_needs_any() {
        // present() and missing() read the process's PATH; give them an absolute path so the
        // test does not depend on (or change) it.
        let s = Scratch::new("all");
        let one = s.file("bin", "one", 0o755);
        let one = one.to_str().unwrap();
        let none = s.0.join("bin/none");
        let none = none.to_str().unwrap();
        assert!(present(&[one]));
        assert!(present(&[]));
        assert!(!present(&[one, none]));
        assert!(missing(&[one, none]));
        assert!(!missing(&[one]));
    }
}
