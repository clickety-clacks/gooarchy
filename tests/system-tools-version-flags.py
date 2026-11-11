#!/usr/bin/env python3
"""Check every Gooarchy system binary's source-version contract in isolation."""

import os
from pathlib import Path
import subprocess
import tempfile


TOOLS = (
    "gooarchy",
    "gooarchy-boot",
    "gooarchy-hw",
    "gooarchy-lock",
    "gooarchy-look",
    "gooarchy-network",
    "gooarchy-software",
    "gooarchy-source",
    "gooarchy-update",
)


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    manifest = root / "system-tools" / "Cargo.toml"
    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True
    ).strip()

    with tempfile.TemporaryDirectory(prefix="gooarchy-version-flags-") as temporary:
        temporary_path = Path(temporary)
        fake_commands = temporary_path / "bin"
        fake_commands.mkdir()
        native_link_dir = temporary_path / "native"
        native_link_dir.mkdir()

        # The CI image has PAM's runtime library but not its unversioned linker name.
        pam_link = next(
            (
                Path(line.split("=>", 1)[1].strip())
                for line in subprocess.check_output(
                    ["ldconfig", "-p"], text=True
                ).splitlines()
                if "libpam.so.0 " in line and "=>" in line
            ),
            None,
        )
        if pam_link is None or not pam_link.is_file():
            raise SystemExit("the CI runner does not expose its PAM runtime library")
        (native_link_dir / "libpam.so").symlink_to(pam_link)

        call_log = temporary_path / "external-command-calls"
        for name in ("flock", "systemd-inhibit", "pacman", "sudo"):
            command = fake_commands / name
            command.write_text(
                '#!/bin/sh\nprintf "%s\\n" "${0##*/}" >>"$GOOARCHY_VERSION_TEST_CALL_LOG"\nexit 97\n',
                encoding="utf-8",
            )
            command.chmod(0o755)

        environment = os.environ.copy()
        rustflags = environment.get("RUSTFLAGS", "").strip()
        environment["RUSTFLAGS"] = f"{rustflags} -L native={native_link_dir}".strip()
        environment["GOOARCHY_VERSION_TEST_CALL_LOG"] = str(call_log)
        environment["PATH"] = f"{fake_commands}{os.pathsep}{environment.get('PATH', '')}"
        environment["HOME"] = str(temporary_path)
        environment["XDG_RUNTIME_DIR"] = str(temporary_path)
        environment["WAYLAND_DISPLAY"] = "gooarchy-version-test-no-display"

        subprocess.run(
            ["cargo", "build", "--manifest-path", str(manifest), "--workspace", "--locked"],
            cwd=root,
            env=environment,
            check=True,
        )
        target = Path(
            environment.get("CARGO_TARGET_DIR", root / "system-tools" / "target")
        ) / "debug"

        for name in TOOLS:
            result = subprocess.run(
                [str(target / name), "--version"],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
            )
            last_token = result.stdout.split()[-1] if result.stdout.split() else ""
            if result.returncode != 0 or result.stderr or last_token != commit:
                raise SystemExit(
                    f"{name} --version violated the source-commit contract "
                    f"(exit {result.returncode}, final token {last_token!r})"
                )

        if call_log.exists() and call_log.read_text(encoding="utf-8"):
            raise SystemExit("a --version command invoked a guarded external command")

    print("all system-tool --version commands report the exact source commit")


if __name__ == "__main__":
    main()
