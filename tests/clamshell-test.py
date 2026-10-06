#!/usr/bin/env python3
"""Test Gooarchy's clamshell mode (gooarchy-clamshell on the lid switch) in a headless Scottland.

Needs a Scottland checkout with its plugin and test helpers built (make test-hooks), whose
Scottland has output control (scottland-output); run it on a test machine, never on a desktop in
use. Everything it creates is under this checkout's build/clamshell-test/, removed at the start
of the next run; the session is stopped at the end.

  tests/clamshell-test.py /path/to/scottland      exits 1 if anything fails

The session runs Scottland's shipped config plus Gooarchy's lid fragment (35-gooarchy-lid) and
no other integration. Setup the test supplies, none of it Gooarchy's code: a laptop with a dock
(the first virtual output is named eDP-1 and outputs added later DP-1, by Scottland's
tests/output-names.c; docking adds and removes DP-1 through Wayfire's headless-output IPC), the lid
(Scottland's test-only virtual switch takes Wayfire's own switch path, only libinput bypassed, and
/proc/acpi/button/lid/LID0/state is a file in the compositor's mount namespace the test writes
with each event), the connected connectors (GOOARCHY_DRM_PATH), and the panel's configured scale
and position (an overrides.ini in the session's own config). gooarchy-clamshell is wrapped to
record when it finished; the script itself runs unchanged.

Oracles: Wayfire's own output list (which outputs are on, and their layout geometry, where the
scale shows as logical size) and a screencopy of the panel (grim -o) for whether it renders.
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
if len(sys.argv) != 2 or not (Path(sys.argv[1]) / "tests/headless.sh").exists():
    sys.exit(__doc__.split("\n\n")[1])
scottland = Path(sys.argv[1]).resolve()
root = repo / "build/clamshell-test"
failures, passes = [], 0


def check(name, ok, detail=""):
    global passes
    if not ok:
        failures.append(name)
    else:
        passes += 1
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f": {detail}"), flush=True)
    return ok


def wait(predicate, timeout=15.0):
    """Poll predicate() until truthy; (ok, last value)."""
    deadline = time.monotonic() + timeout
    value = predicate()
    while not value and time.monotonic() < deadline:
        time.sleep(0.05)
        value = predicate()
    return bool(value), value


if root.exists():
    shutil.rmtree(root)
home, bin_dir, hooks = root / "home", root / "bin", root / "hooks"
for directory in (home, bin_dir, hooks, root / "tmp"):
    directory.mkdir(parents=True)

# Scottland's helpers with Gooarchy's lid fragment added; no other integration's generators (an
# Omarchy adapter's would import the test machine's own Hyprland config).
built = scottland / "build/hooks"
for entry in built.iterdir():
    if entry.name in ("config.d", "autostart.d"):
        (hooks / entry.name).mkdir(parents=True)
        for item in entry.iterdir():
            if "omarchy" not in item.name:
                (hooks / entry.name / item.name).symlink_to(item.resolve())
    else:
        (hooks / entry.name).symlink_to(entry.resolve())
(hooks / "config.d/35-gooarchy-lid").symlink_to(repo / "session/35-gooarchy-lid")
(hooks / "autostart.d/45-gooarchy-clamshell").symlink_to(repo / "session/autostart.d/45-gooarchy-clamshell")

log = root / "calls.log"
log.touch()
(bin_dir / "gooarchy-clamshell").write_text(f'''#!/bin/sh
# Test stand-in: run Gooarchy's script unchanged and record that it finished.
"{repo}/session/libexec/gooarchy-clamshell" "$@"; status=$?
printf 'gooarchy-clamshell-done\\t%s\\n' "$status" >>'{log}'
exit $status
''')
(bin_dir / "gooarchy-clamshell").chmod(0o755)

lid_state = root / "lid-state"
lid_state.write_text("state:      open  \n")
drm = root / "drm"
for connector in ("card0-eDP-1", "card0-DP-1"):
    (drm / connector).mkdir(parents=True)
(drm / "card0-eDP-1/status").write_text("connected\n")
(drm / "card0-DP-1/status").write_text("disconnected\n")
names = root / "output-names.so"
subprocess.run(["cc", "-shared", "-fPIC", "-O1", "-o", str(names), str(scottland / "tests/output-names.c"),
                "-ldl"], check=True)
outputs_map = "HEADLESS-1=eDP-1," + ",".join(f"HEADLESS-{n}=DP-1" for n in range(2, 8))
wrap = root / "wrap-compositor"
wrap.write_text(f'''#!/bin/sh
exec bwrap --dev-bind / / --tmpfs /proc/acpi --dir /proc/acpi/button/lid/LID0 \\
  --bind '{lid_state}' /proc/acpi/button/lid/LID0/state \\
  env LD_PRELOAD='{names}' SCOTTLAND_TEST_OUTPUT_NAMES={outputs_map} GOOARCHY_DRM_PATH='{drm}' "$@"
''')
wrap.chmod(0o755)

session_dir = root / "session"
env = {**os.environ, "HOME": str(home), "SCOTTLAND_HEADLESS_DIR": str(session_dir),
       "SCOTTLAND_TEST_PATH": str(bin_dir), "SCOTTLAND_TEST_HOOKS": str(hooks),
       "SCOTTLAND_TEST_WRAP": str(wrap), "TMPDIR": str(root / "tmp")}


def harness(*args, timeout=60):
    return subprocess.run([str(scottland / "tests/headless.sh"), *args], env=env, text=True,
                          capture_output=True, timeout=timeout)


def ipc(method, data=None):
    reply = harness("ipc", method, json.dumps(data or {})).stdout.strip()
    try:
        return json.loads(reply)
    except ValueError:
        return reply


def run(*command):
    return harness("run", *command)


def outputs():
    reply = ipc("window-rules/list-outputs")
    return {o["name"]: {k: int(v) for k, v in o["geometry"].items()} for o in reply} \
        if isinstance(reply, list) else {}


def capture(output, name):
    path = root / f"{name}.ppm"
    result = run("timeout", "5", "grim", "-t", "ppm", "-o", output, str(path))
    if result.returncode != 0 or not path.exists():
        return None
    header = path.read_bytes()[:32].split()
    return int(header[1]), int(header[2])


def done_count():
    return log.read_text().count("gooarchy-clamshell-done\t0")


def lid(closed):
    """The lid as the hardware reports it: the ACPI state file, then the switch event."""
    before = done_count()
    with open(lid_state, "r+") as handle:  # in place: the compositor's namespace binds this file
        handle.write("state:      closed\n" if closed else "state:      open  \n")
    ipc("scottland/test-switch", {"device": "Lid Switch", "state": closed})
    return wait(lambda: done_count() > before, timeout=30)


def dock(connected):
    (drm / "card0-DP-1/status").write_text("connected\n" if connected else "disconnected\n")
    if connected:
        return ipc("wayfire/create-headless-output", {"width": 1920, "height": 1080})
    return ipc("wayfire/destroy-headless-output", {"output": "DP-1"})


def output_tool(*args):
    return run(str(hooks / "libexec/scottland-output"), *args)


PANEL = {"x": 1920, "y": 0, "width": 853, "height": 480}  # 1280x720 at scale 1.5
DOCK = {"x": 0, "y": 0, "width": 1920, "height": 1080}
flag = session_dir / "state/gooarchy/clamshell/panel-off"

started = harness("start", timeout=120)
try:
    check("session starts", started.returncode == 0, started.stderr)
    config = (session_dir / "wayfire.ini").read_text()
    check("Gooarchy's lid fragment binds the lid (either way, also locked) to gooarchy-clamshell",
          "switch_command_gooarchy_lid = gooarchy-clamshell" in config and
          "switch_locked_gooarchy_lid = true" in config and "switch_state_gooarchy_lid = toggle" in config)

    # The user's display settings: the panel at scale 1.5 right of where the dock goes.
    (session_dir / "config/scottland/overrides.ini").write_text(
        "[output:eDP-1]\nscale = 1.5\nposition = 1920,0\n\n[output:DP-1]\nposition = 0,0\n")
    output_tool("reset")
    ok, seen = wait(lambda: outputs().get("eDP-1") == PANEL)
    check("setup: the panel at its configured scale 1.5 and position 1920,0", ok, seen)

    dock(True)
    ok, seen = wait(lambda: outputs().get("DP-1") == DOCK)
    check("setup: docked, DP-1 at 0,0", ok, seen)

    ok, _ = lid(True)
    check("closing the lid runs gooarchy-clamshell", ok)
    ok, seen = wait(lambda: "eDP-1" not in outputs(), timeout=10)
    check("docked lid close turns the laptop panel off", ok, seen)
    check("the external display stays on, in place", outputs().get("DP-1") == DOCK, outputs())
    check("the panel no longer renders (screencopy of eDP-1 fails)", capture("eDP-1", "closed") is None)
    check("the script records that it turned the panel off", flag.exists())

    ok, _ = lid(False)
    check("opening the lid runs gooarchy-clamshell", ok)
    ok, seen = wait(lambda: outputs().get("eDP-1") == PANEL, timeout=10)
    check("lid open brings the panel back at its scale (1.5) and position (1920,0)", ok, seen)
    shot = capture("eDP-1", "open")
    check("the panel renders again (screencopy of eDP-1 is its 1280x720 mode)", shot == (1280, 720), shot)
    check("the record is gone", not flag.exists())

    # A panel the user turned off stays off while docked.
    output_tool("set", "eDP-1", "--off")
    ok, seen = wait(lambda: "eDP-1" not in outputs())
    check("setup: the user turns the laptop display off", ok, seen)
    ok, _ = lid(True)
    check("lid close runs gooarchy-clamshell", ok)
    check("lid close leaves the user's choice alone", "eDP-1" not in outputs() and not flag.exists(),
          (outputs(), flag.exists()))
    ok, _ = lid(False)
    check("lid open runs gooarchy-clamshell", ok)
    check("lid open keeps the display the user turned off off while docked", "eDP-1" not in outputs(), outputs())

    # Undocking with the panel turned off by hand: nothing else shows the desktop, so it comes on.
    dock(False)
    ok, seen = wait(lambda: "DP-1" not in outputs())
    check("setup: undocked", ok, seen)
    ok, _ = lid(True)
    check("undocked lid close runs gooarchy-clamshell", ok)
    ok, seen = wait(lambda: outputs().get("eDP-1") == PANEL, timeout=10)
    check("with no external display, the panel turned off by hand comes back on, as configured", ok, seen)
    ok, _ = lid(False)
    check("undocked lid open: the panel stays on", ok and outputs().get("eDP-1") == PANEL, outputs())

    # Session start with the lid already closed on a dock: the panel starts off. The session's
    # start hook, run as Scottland's autostart does, inside the compositor.
    dock(True)
    ok, seen = wait(lambda: outputs().get("DP-1") == DOCK)
    check("setup: docked again", ok, seen)
    with open(lid_state, "r+") as handle:
        handle.write("state:      closed\n")
    before = done_count()
    ipc("stipc/run", {"cmd": str(hooks / "autostart.d/45-gooarchy-clamshell")})
    ok, _ = wait(lambda: done_count() > before, timeout=30)
    check("the session start hook runs gooarchy-clamshell", ok)
    ok, seen = wait(lambda: "eDP-1" not in outputs(), timeout=10)
    check("a session starting closed on a dock turns the panel off", ok, seen)
    ok, _ = lid(False)
    ok2, seen = wait(lambda: outputs().get("eDP-1") == PANEL, timeout=10)
    check("then opening the lid brings it back as configured", ok and ok2, seen)
finally:
    if (session_dir / "wayfire.log").exists():  # evidence outlives the session directory
        shutil.copy(session_dir / "wayfire.log", root / "wayfire.log")
    harness("stop")

print(f"\n{passes} passed, {len(failures)} failed")
sys.exit(1 if failures else 0)
