#!/usr/bin/env python3
"""Exercise network/installer failure handling with no real service or package actions."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
subprocess.run(
    ["cargo", "build", "--manifest-path", str(ROOT / "system-tools/Cargo.toml"),
     "-p", "gooarchy-network", "--locked"], check=True
)
BINARY = ROOT / "system-tools/target/debug/gooarchy-network"

with tempfile.TemporaryDirectory(prefix="gooarchy-network-test-") as directory:
    scratch = Path(directory)
    commands = scratch / "bin"
    commands.mkdir()
    log = scratch / "commands.log"
    stub = commands / "stub"
    stub.write_text("""#!/usr/bin/env python3
import os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TEST_LOG"], "a") as log:
    log.write(name + " " + " ".join(args) + "\\n")
if name == "id":
    print("0")
elif name == "ip":
    if os.environ["CASE"] != "networkd-fails":
        print("default via 192.0.2.1 dev eth0")
elif name == "systemctl":
    service = args[-1]
    if args[0] == "is-active":
        active = (service == "NetworkManager.service" and os.environ["CASE"] == "manager"
                  or service == "systemd-networkd.service" and os.environ["CASE"] not in ("networkd-fails", "other-manager"))
        sys.exit(0 if active else 3)
    if args[0] == "is-enabled":
        sys.exit(1)
    if service in os.environ.get("FAIL_SERVICES", "").split(","):
        print("simulated startup failure: " + service, file=sys.stderr)
        sys.exit(1)
elif name == "gooarchy":
    if args[:2] == ["network", "ensure"]:
        print("iwd.service could not start (simulated absent radio)", file=sys.stderr)
        sys.exit(int(os.environ["NETWORK_EXIT"]))
    if args == ["hw", "apply"]:
        sys.exit(int(os.environ.get("HW_EXIT", "0")))
elif name not in ("pacman", "networkctl", "mkdir", "sh", "ln", "sudo"):
    sys.exit("unexpected command: " + name)
""")
    stub.chmod(0o755)
    for name in ("id", "ip", "systemctl", "pacman", "networkctl", "mkdir", "sh", "ln", "sudo", "gooarchy"):
        (commands / name).symlink_to(stub)
    env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
               TEST_LOG=str(log), CASE="iwd-fails")

    def network(case, failed):
        log.write_text("")
        result = subprocess.run([str(BINARY), "ensure", "--yes"], env=dict(
            env, CASE=case, FAIL_SERVICES=failed), text=True, capture_output=True)
        return result, log.read_text()

    # Working managers/routes remain untouched (PR #83 network-preservation behavior).
    for case in ("manager", "other-manager"):
        result, calls = network(case, "")
        assert result.returncode == 0, result.stderr
        assert "configuration unchanged" in result.stdout
        assert "systemctl enable" not in calls and "pacman" not in calls
        assert "sh " not in calls and "ln " not in calls

    # iwd failure cannot skip the following resolver service; failures remain named.
    result, calls = network("iwd-fails", "iwd.service,systemd-resolved.service")
    assert result.returncode != 0
    assert "enable --now systemd-resolved.service" in calls
    assert "could not start iwd.service" in result.stderr
    assert "could not start systemd-resolved.service" in result.stderr
    assert "network setup is incomplete" in result.stderr
    assert "/etc/resolv.conf was left unchanged" in result.stderr
    assert "sh " not in calls and "ln " not in calls

    # An unavailable networkd must not prevent trying iwd and resolved either.
    result, calls = network("networkd-fails",
                            "systemd-networkd.service,iwd.service,systemd-resolved.service")
    assert result.returncode != 0
    for service in ("systemd-networkd", "iwd", "systemd-resolved"):
        assert f"could not start {service}.service" in result.stderr
    assert "networkctl reload" not in calls and "ln " not in calls

    # Source the actual canonical post-install step under the installer's errexit.
    for yes in ("0", "1"):
        for status in ("0", "1", "5"):
            log.write_text("")
            result = subprocess.run(
                ["bash", "-eEo", "pipefail", "-c",
                 'source "$1"; echo installer-continued', "test",
                 str(ROOT / "install/post-install/tools.sh")],
                env=dict(env, GOOARCHY_YES=yes, NETWORK_EXIT=status),
                text=True, capture_output=True)
            assert result.returncode == 0 and "installer-continued" in result.stdout
            assert ("Warning: Gooarchy network setup" in result.stderr) == (status != "0")
            assert ("network ensure --yes" in log.read_text()) == (yes == "1")
    # Do not accidentally suppress unrelated hardware step failures.
    result = subprocess.run(
        ["bash", "-eEo", "pipefail", "-c", 'source "$1"; echo installer-continued',
         "test", str(ROOT / "install/post-install/tools.sh")],
        env=dict(env, HW_EXIT="9", NETWORK_EXIT="0"), text=True, capture_output=True)
    assert result.returncode == 9 and "installer-continued" not in result.stdout

print("network service failures, preserved working managers, and installer continuation: PASS")
