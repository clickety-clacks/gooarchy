use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=../../.git/HEAD");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let output = Command::new("git")
        .args([
            "-C",
            repo.to_str().expect("workspace path is UTF-8"),
            "rev-parse",
            "HEAD",
        ])
        .output()
        .expect("git is required to identify the Gooarchy source commit");
    assert!(
        output.status.success(),
        "could not read the Gooarchy source commit"
    );
    let commit = String::from_utf8(output.stdout).expect("git commit id is UTF-8");
    let commit = commit.trim();
    assert!(
        commit.len() == 40 && commit.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "git returned an invalid Gooarchy source commit"
    );
    println!("cargo:rustc-env=GOOARCHY_COMMON_BUILD_COMMIT={commit}");
}
