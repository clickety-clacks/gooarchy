#!/usr/bin/env python3
"""Check a Gooarchy session from inside the guest (tests/vm/run.sh copies and runs this).

  guest-check.py OUTDIR [--gpu virgl|software]

Waits for the Scottland session the boot started on tty1, enters its environment, then uses it
the way a person would, through Wayfire's virtual input (stipc): Super+Enter for a terminal, the
flavorings' keys for Strata and Chromium, Super+drag to move windows into the periphery and onto
a rail. Each step is checked against Scottland's own model (scottland/layout-state) and against
the screen (grim). Checks named "config: ..." only read configuration or state; the others
exercise behavior. Observations record what the built system lacks (DEFICIT.md) and never fail.

Writes results.json, screenshots and session logs to OUTDIR, also when something breaks midway;
exits 1 if a check fails. Every compositor call has a deadline, and so does the whole run.
"""
import glob
import json
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
from datetime import datetime, timezone

OUT = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "/tmp/gooarchy-check/out"
GPU = sys.argv[sys.argv.index("--gpu") + 1] if "--gpu" in sys.argv else "virgl"
RUNTIME = f"/run/user/{os.getuid()}"
HOME = os.path.expanduser("~")
WAYFIRE_LOG = f"{HOME}/.local/state/scottland/wayfire.log"
IPC_TIMEOUT = 10
IPC_MAX_REPLY = 16 * 1024 * 1024
RUN_DEADLINE = 1200
results = []
observations = []
failures = 0
screenshots_failed = []


class Deadline(Exception):
    pass


def log(message):
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


def check(name, ok, detail=""):
    global failures
    results.append({"check": name, "ok": bool(ok), "detail": detail})
    failures += 0 if ok else 1
    log(f"{'PASS' if ok else 'FAIL'} {name}{': ' + str(detail) if detail else ''}")
    return ok


def observe(name, value):
    """A fact about the built system recorded for DEFICIT.md; never fails the run."""
    observations.append({"observation": name, "value": value})
    log(f"OBSERVED {name}: {value}")


def run(*command, timeout=20):
    try:
        r = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        return (r.stdout + r.stderr).strip()
    except Exception as error:
        return f"({error})"


def run_rc(*command, timeout=20):
    try:
        r = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip()
    except Exception as error:
        return -1, f"({error})"


def wait_for(predicate, timeout=30, interval=0.25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except Deadline:
            raise
        except Exception:
            pass
        time.sleep(interval)
    return None


# ---- talking to Wayfire ---------------------------------------------------------------------

def recv_exactly(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError(f"the compositor closed the connection after {len(data)} of {size} bytes")
        data += chunk
    return data


def ipc(method, data=None, path=None):
    """One Wayfire IPC call, with a deadline, EOF and size checks."""
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(IPC_TIMEOUT)
        s.connect(path or os.environ["WAYFIRE_SOCKET"])
        body = json.dumps({"method": method, "data": data or {}}).encode()
        s.sendall(struct.pack("<I", len(body)) + body)
        size = struct.unpack("<I", recv_exactly(s, 4))[0]
        if size > IPC_MAX_REPLY:
            raise ConnectionError(f"reply of {size} bytes is too large")
        return json.loads(recv_exactly(s, size))


def session_env():
    """The running session's environment, as Scottland recorded it (autostart.d/01-record-environment)."""
    for path in sorted(glob.glob(f"{RUNTIME}/scottland/*.env")):
        env = {}
        with open(path, "rb") as f:
            for entry in f.read().split(b"\0"):
                key, sep, value = entry.decode(errors="replace").partition("=")
                if sep:
                    env[key] = value
        sock = env.get("WAYFIRE_SOCKET")
        if sock and os.path.exists(sock):
            try:
                ipc("scottland/layout-state", path=sock)
                return env
            except (OSError, ValueError):
                pass
    return None


def views():
    return ipc("scottland/layout-state").get("views", [])


def view(view_id):
    return next((v for v in views() if v.get("id") == view_id), None)


def find(app_id_part):
    for v in views():
        if app_id_part.lower() in (v.get("app_id") or "").lower():
            return v
    return None


def all_views():
    return ipc("window-rules/list-views")


def key(name, down):
    ipc("stipc/feed_key", {"key": name, "state": down})


def press(*names):
    for n in names:
        key(n, True)
        time.sleep(0.1)
    for n in reversed(names):
        key(n, False)
        time.sleep(0.1)


def open_with(keys, app_id, timeout):
    """Press a shortcut and wait for the app's window; press it once more if nothing came (the
    retry is recorded in the check's detail)."""
    press(*keys)
    v = wait_for(lambda: find(app_id), timeout=timeout)
    if v:
        return v, ""
    press(*keys)
    v = wait_for(lambda: find(app_id), timeout=timeout)
    return v, " (needed a second press)" if v else ""


def super_drag(v, x2, y2=None, steps=30):
    """Super+left-drag a window from its center (Scottland's move binding) to (x2, y2)."""
    box = v.get("scene_frame") or v["frame"]
    x, y = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2
    y2 = y if y2 is None else y2
    ipc("stipc/move_cursor", {"x": x, "y": y})
    time.sleep(0.1)
    key("KEY_LEFTMETA", True)
    time.sleep(0.05)
    ipc("stipc/feed_button", {"combo": "BTN_LEFT", "mode": "press"})
    time.sleep(0.1)
    for i in range(1, steps + 1):
        ipc("stipc/move_cursor", {"x": x + (x2 - x) * i / steps, "y": y + (y2 - y) * i / steps})
        time.sleep(0.02)
    time.sleep(0.3)
    ipc("stipc/feed_button", {"combo": "BTN_LEFT", "mode": "release"})
    time.sleep(0.05)
    key("KEY_LEFTMETA", False)


# ---- the screen -----------------------------------------------------------------------------

def shot(name):
    """A grim screenshot; a missing or invalid file fails the screenshots check at the end."""
    path = os.path.join(OUT, name)
    rc = subprocess.run(["grim", path], capture_output=True, timeout=30).returncode
    ok = rc == 0 and os.path.exists(path) and open(path, "rb").read(8) == b"\x89PNG\r\n\x1a\n"
    if not ok:
        screenshots_failed.append(name)
    log(f"screenshot {path}{'' if ok else ' FAILED'}")
    return ok


def grab_ppm(x, y, w, h):
    return subprocess.run(["grim", "-t", "ppm", "-g", f"{x},{y} {w}x{h}", "-"], capture_output=True,
                          timeout=30, check=True).stdout


def looks_drawn(ppm):
    """True if a PPM region shows a picture (varied, not black): the wallpaper rather than nothing."""
    parts = ppm.split(b"\n", 3)
    if len(parts) < 4 or parts[0] != b"P6":
        return False
    pixels = parts[3]
    values = pixels[::7]  # a sample of channel values
    if not values:
        return False
    mean = sum(values) / len(values)
    var = sum((v - mean) ** 2 for v in values) / len(values)
    return mean > 20 and var > 100


# ---- parsing helpers (also exercised by tests/vm/selftest.py) -------------------------------

def volume_of(text):
    """The number in wpctl's "Volume: 0.40" (None if absent)."""
    for word in text.replace("Volume:", " ").split():
        try:
            return float(word)
        except ValueError:
            continue
    return None


def sink_present(rc, inspect_output):
    """wpctl inspect @DEFAULT_AUDIO_SINK@ succeeded and describes a node."""
    return rc == 0 and "node.name" in inspect_output


def night_longitude(now=None):
    """A longitude where it is local solar midnight right now (the sun is down at the equator)."""
    now = now or datetime.now(timezone.utc)
    hours = now.hour + now.minute / 60
    return ((-hours * 15 + 180) % 360) - 180


def helpers(pattern="/usr/lib/scottland/", session=None):
    """PIDs whose command line contains PATTERN (optionally only in login session SESSION)."""
    found = []
    for p in os.listdir("/proc"):
        if not p.isdigit() or int(p) == os.getpid():
            continue
        try:
            cmd = open(f"/proc/{p}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue
        if pattern in cmd and not cmd.startswith(("sh -c", "/bin/sh -c")):
            if session is None or session_of(p) == session:
                found.append(int(p))
    return found


def session_gone(sid):
    return run_rc("loginctl", "show-session", sid, "-p", "State", "--value")[0] != 0


def color_scheme():
    return run("gsettings", "get", "org.gnome.desktop.interface", "color-scheme").strip("'")


def wayfire_pid():
    return run("pgrep", "-xo", "wayfire")


def session_of(pid):
    try:
        with open(f"/proc/{pid}/cgroup") as f:
            for line in f:
                if line.startswith("0::") and "session-" in line:
                    return line.strip().rsplit("session-", 1)[1].split(".scope")[0]
    except OSError:
        pass
    return None


def session_state(sid):
    return run("loginctl", "show-session", sid, "-p", "State", "--value")


def enter_session(timeout=90):
    """Use the session running now (after a logout): its environment, and the test's virtual input."""
    env = wait_for(session_env, timeout=timeout, interval=1)
    if not env:
        return False
    os.environ.update(env)
    plugins = ipc("wayfire/get-config-option", {"option": "core/plugins"}).get("value", "")
    if "stipc" not in plugins.split():
        ipc("wayfire/set-config-options", {"core/plugins": plugins + " stipc"})
    ready = wait_for(lambda: "error" not in ipc("stipc/move_cursor", {"x": 10, "y": 10}), timeout=15)
    if ready:
        prime_keyboard()
    return ready


def prime_keyboard():
    """Wayfire's virtual keyboard (stipc) can drop the first modifier chord after it appears; a
    harmless Shift tap first keeps that test artifact out of the results."""
    press("KEY_LEFTSHIFT")
    time.sleep(0.5)


def save_session_log(name):
    try:
        shutil.copy(WAYFIRE_LOG, os.path.join(OUT, name))
    except OSError:
        pass


# ---- the checks -----------------------------------------------------------------------------

def check_solar_schedule():
    # The guest may already be dark and may have network access. Establish a
    # no-location fixture rather than assuming an untouched light preference.
    solar = f"{HOME}/.config/scottland/solar.ini"
    saved = None
    if os.path.exists(solar):
        with open(solar, "rb") as stream:
            saved = (stream.read(), os.stat(solar).st_mode & 0o7777)
    os.makedirs(os.path.dirname(solar), exist_ok=True)
    try:
        with open(solar, "w") as stream:
            stream.write("[solar]\nenabled = true\nallow_ip = false\nlocation_set = false\n")
        before = color_scheme()
        rc, mode = run_rc("/usr/lib/scottland/libexec/scottland-solar-theme", "once", timeout=30)
        after = color_scheme()
        observe("Sunlight with no configured location or IP lookup", mode)
        check("with no location, Sunlight preserves the existing color scheme",
              rc == 0 and mode == "off" and after == before,
              f"{before} -> {after}; solar mode {mode}; exit {rc}")
        run("gsettings", "set", "org.gnome.desktop.interface", "color-scheme", "prefer-light")
        light = wait_for(lambda: color_scheme() == "prefer-light", timeout=15)
        with open(solar, "w") as f:
            f.write(f"[solar]\nenabled = true\nallow_ip = false\nlocation_set = true\nlatitude = 0\n"
                    f"longitude = {night_longitude():.2f}\n")
        # The schedule re-reads its location when its settings change; asking GeoClue (absent here)
        # first can take its D-Bus timeout, so allow two minutes.
        dark = wait_for(lambda: color_scheme() == "prefer-dark", timeout=120)
        check("with a location where it's night, Sunlight switches to dark",
              light and dark, f"light setup {bool(light)}; final {color_scheme()}")
        shot("11-sunlight-dark.png")
        warning = subprocess.run(["gooarchy-theme", "light"], capture_output=True, text=True).stderr
        check("gooarchy-theme warns that Sunlight is on", "Sunlight" in warning, warning.strip()[:100])
        back = wait_for(lambda: color_scheme() == "prefer-dark", timeout=30)
        check("Sunlight overrides a manual light choice at night (documented)", back, color_scheme())
        with open(solar, "w") as f:
            f.write("[solar]\nenabled = false\n")
        run("gooarchy-theme", "light")
        stays = not wait_for(lambda: color_scheme() == "prefer-dark", timeout=25)
        check("with Sunlight off, a manual light choice stays", stays and color_scheme() == "prefer-light", color_scheme())
    finally:
        if saved is None:
            if os.path.exists(solar):
                os.unlink(solar)
        else:
            with open(solar, "wb") as stream:
                stream.write(saved[0])
            os.chmod(solar, saved[1])


def main():
    log("waiting for the Scottland session on tty1")
    env = wait_for(session_env, timeout=180, interval=2)
    if not check("a Scottland session is running (autologin on tty1 -> start-scottland)", env):
        return
    os.environ.update(env)
    save_session_log("wayfire-session1.log")
    state = wait_for(lambda: ipc("scottland/layout-state"), timeout=60)
    check("the Scottland plugin answers (scottland/layout-state)", state and "views" in state)
    plugins = ipc("wayfire/get-config-option", {"option": "core/plugins"}).get("value", "")
    check("config: Wayfire runs Scottland's config with the scottland plugin", "scottland" in plugins.split(), plugins)
    try:
        screen = ipc("window-rules/list-outputs")[0]["geometry"]
    except Exception:
        screen = {"x": 0, "y": 0, "width": 1920, "height": 1080}
    log(f"screen {screen}")

    # Renderer: the expected one for the VM's graphics, and Scottland's goo on it.
    wlog = open(WAYFIRE_LOG, errors="replace").read()
    renderer = next((l.split("GL renderer:", 1)[1].strip() for l in wlog.splitlines() if "GL renderer:" in l), "")
    expected = {"virgl": "virgl", "software": "llvmpipe"}.get(GPU, GPU)
    check(f"Wayfire renders with {expected} ({GPU} graphics)", expected in renderer, renderer)
    goo = [l.split(" - ", 1)[-1] for l in wlog.splitlines() if "scottland goo:" in l]
    check("Scottland's goo renderer starts on GL", any("OpenGL ES" in l for l in goo), " | ".join(goo))

    # Test-only: Wayfire's virtual input plugin, loaded into the running session (not into
    # Gooarchy's config).
    if "stipc" not in plugins.split():
        ipc("wayfire/set-config-options", {"core/plugins": plugins + " stipc"})
    check("virtual input (stipc) loaded for the test",
          wait_for(lambda: "error" not in ipc("stipc/move_cursor", {"x": 10, "y": 10}), timeout=15))
    prime_keyboard()

    wait_for(lambda: run("pgrep", "-x", "swaybg"), timeout=20)
    time.sleep(2)
    shot("01-desktop.png")
    corner = grab_ppm(int(screen["x"]) + 20, int(screen["y"]) + 20, 240, 240)
    check("the wallpaper is visible on screen (sampled, not just a running process)", looks_drawn(corner))

    # A terminal: Super+Enter (Scottland's shipped binding, Ghostty).
    term, note = open_with(("KEY_LEFTMETA", "KEY_ENTER"), "ghostty", 20)
    check("Super+Enter opens a terminal (Ghostty)", term, term and f"{term.get('app_id')}{note}")
    time.sleep(2)
    shot("02-terminal.png")

    # Strata: Super+Shift+F (flavorings).
    strata, note = open_with(("KEY_LEFTMETA", "KEY_LEFTSHIFT", "KEY_F"), "strata", 20)
    check("Super+Shift+F opens Strata", strata, strata and f"{strata.get('app_id')}{note}")
    time.sleep(2)
    shot("03-strata.png")

    # Chromium: Super+Shift+B (flavorings). Arch's Chromium opens a placeholder "Additional Terms
    # of Service" dialog (no app-id) on its first run; accept it with Enter as a user would.
    def chromium_or_terms():
        return find("chromium") or next((v for v in views() if "Terms of Service" in (v.get("title") or "")), None)
    press("KEY_LEFTMETA", "KEY_LEFTSHIFT", "KEY_B")
    first = wait_for(chromium_or_terms, timeout=30)
    note = ""
    if not first:
        press("KEY_LEFTMETA", "KEY_LEFTSHIFT", "KEY_B")
        first, note = wait_for(chromium_or_terms, timeout=30), " (needed a second press)"
    if first and "Terms of Service" in (first.get("title") or ""):
        time.sleep(2)
        shot("04a-chromium-first-run-terms.png")
        press("KEY_ENTER")
        note += "; accepted the first-run terms dialog"
    chromium = wait_for(lambda: find("chromium"), timeout=30)
    check("Super+Shift+B opens Chromium", chromium, chromium and f"{chromium.get('app_id')}: {chromium.get('title')}{note}")
    wait_for(lambda: "New Tab" in (find("chromium") or {}).get("title", ""), timeout=20)
    shot("04-chromium.png")
    prefs = f"{HOME}/.config/chromium/Default/Preferences"
    frame = wait_for(lambda: json.load(open(prefs)).get("browser", {}).get("custom_chrome_frame", "unset") is False
                     and "false", timeout=15)
    check("config: Chromium prefers the system title bar (browser.custom_chrome_frame = false)", frame)

    # The periphery: the window dragged away from the center scales down (that window, by id).
    if chromium:
        ipc("scottland/present", {"window": chromium["id"]})  # setup: Chromium centered, on top
        before = wait_for(lambda: (lambda v: v if v and v.get("zone") == "center" else None)(view(chromium["id"])),
                          timeout=10) or view(chromium["id"])
        super_drag(before, screen["x"] + screen["width"] * 0.82)
        after = wait_for(lambda: (lambda v: v if v and (v.get("applied_scale") or 1) < 0.95 else None)(
            view(chromium["id"])), timeout=10) or view(chromium["id"])
        check("the window dragged into the periphery scales down (Chromium, by id)",
              before and after and before.get("zone") == "center" and after.get("zone") != "center"
              and (after.get("applied_scale") or 1) < 0.95,
              f"{before.get('zone')} {round(before.get('applied_scale') or 0, 3)} -> "
              f"{after.get('zone')} {round(after.get('applied_scale') or 0, 3)}" if before and after else "")
        shot("05-periphery.png")

    # A rail: the window dragged to the screen's edge becomes a widget there (Strata, by id).
    strata = find("strata")
    if strata:
        ipc("scottland/present", {"window": strata["id"]})
        time.sleep(1)
        super_drag(view(strata["id"]), screen["x"] + screen["width"] - 4, screen["y"] + screen["height"] * 0.4, steps=40)
        widget = wait_for(lambda: (lambda v: v if v and v.get("widgetized") else None)(view(strata["id"])), timeout=15)
        card = wait_for(lambda: next((v for v in all_views() if v.get("title") == "Scottland widget: Strata"
                                      and v.get("mapped")), None), timeout=15)
        edge = None
        if card:
            g = card.get("geometry") or card.get("bbox") or {}
            edge = g.get("x", 0) + g.get("width", 0)
        on_rail = edge is not None and edge >= screen["x"] + screen["width"] * 0.9
        check("the window dragged to the edge becomes a widget card on the right rail (Strata, by id)",
              widget and widget.get("zone") == "widget" and on_rail,
              f"zone {widget and widget.get('zone')}, card right edge {edge} of {screen['width']}")
        time.sleep(2)
        shot("06-rail-widget.png")

    with open(os.path.join(OUT, "layout-state.json"), "w") as f:
        json.dump(ipc("scottland/layout-state"), f, indent=1)

    # Strata as org.freedesktop.FileManager1 ("Show in folder"), with Strata closed and running.
    pictures = run("xdg-user-dir", "PICTURES")
    target = next(iter(sorted(glob.glob(f"{pictures}/*") + glob.glob(f"{HOME}/*"))), HOME)
    run("pkill", "-x", "strata")
    wait_for(lambda: not find("strata"), timeout=10)
    rc, out = run_rc("gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1", "--object-path",
                     "/org/freedesktop/FileManager1", "--method", "org.freedesktop.FileManager1.ShowItems",
                     f"['file://{target}']", "")
    shown = wait_for(lambda: find("strata"), timeout=20)
    check("FileManager1.ShowItems opens Strata when it isn't running", rc == 0 and shown, out or rc)
    rc, out = run_rc("gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1", "--object-path",
                     "/org/freedesktop/FileManager1", "--method", "org.freedesktop.FileManager1.ShowFolders",
                     f"['file://{HOME}']", "")
    check("FileManager1.ShowFolders answers while Strata runs", rc == 0, out or rc)
    shot("07-filemanager1.png")

    # The portal's file chooser (xdg-desktop-portal-gtk): opens, and cancels.
    rc, out = run_rc("gdbus", "call", "--session", "--dest", "org.freedesktop.portal.Desktop", "--object-path",
                     "/org/freedesktop/portal/desktop", "--method", "org.freedesktop.portal.FileChooser.OpenFile",
                     "", "Gooarchy check", "{}")
    dialog = wait_for(lambda: next((v for v in all_views() if v.get("title") == "Gooarchy check" and v.get("mapped")),
                                   None), timeout=20)
    shot("08-file-chooser.png")
    if dialog:
        press("KEY_ESC")
    gone = dialog and wait_for(lambda: not any(v.get("title") == "Gooarchy check" for v in all_views()), timeout=10)
    check("the portal's file chooser opens a dialog and cancels", rc == 0 and dialog and gone, out[:120])

    # Configuration the session should carry.
    env_wayfire = open(f"/proc/{wayfire_pid()}/environ", "rb").read().split(b"\0")
    check("config: MOSH_TITLE_NOPREFIX=1 in the session", b"MOSH_TITLE_NOPREFIX=1" in env_wayfire)
    tmux = run("tmux", "-L", "gooarchy-check", "-f", "/etc/tmux.conf", "start-server", ";",
               "show-options", "-g", "set-titles", ";", "show-options", "-g", "set-titles-string")
    run("tmux", "-L", "gooarchy-check", "kill-server")
    check("config: tmux titles on, reading \"session on host\"", "set-titles on" in tmux and "#S on #h" in tmux,
          tmux.replace("\n", "; "))
    for option in ("input/tap_to_click", "input/tap_and_drag", "input/drag_lock"):
        value = ipc("wayfire/get-config-option", {"option": option}).get("value")
        check(f"config: touchpad {option} on", str(value).lower() in ("true", "1"), value)
    def portal_matches_scheme():
        expected = "1" if color_scheme() == "prefer-dark" else "2"
        scheme = run("busctl", "--user", "call", "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                     "org.freedesktop.portal.Settings", "ReadOne", "ss", "org.freedesktop.appearance", "color-scheme")
        return scheme if scheme.endswith(expected) else None
    scheme = wait_for(portal_matches_scheme, timeout=15)
    check("the settings portal reports the current color scheme", scheme, scheme or color_scheme())
    folder = run("xdg-mime", "query", "default", "inode/directory")
    check("config: folders open in Strata", "Strata" in folder, folder)
    claude = json.load(open(f"{HOME}/.claude.json")).get("preferredNotifChannel")
    check("config: Claude Code set to ring the terminal bell", claude == "terminal_bell", claude)
    codex = open(f"{HOME}/.codex/config.toml").read()
    check("config: Codex set to ring the terminal bell", 'notification_method = "bel"' in codex)
    check("config: private settings files stay private (0600)",
          all(oct(os.stat(p).st_mode & 0o777) == "0o600" for p in (f"{HOME}/.claude.json", f"{HOME}/.codex/config.toml")),
          {p: oct(os.stat(p).st_mode & 0o777) for p in (f"{HOME}/.claude.json", f"{HOME}/.codex/config.toml")})
    for scope, unit in (("--user", "pipewire"), ("--user", "wireplumber"), ("--user", "pipewire-pulse.socket"),
                        ("--system", "rtkit-daemon")):
        active = run("systemctl", scope, "is-active", unit)
        check(f"{unit} running", active == "active", active)
    rc, inspect = run_rc("wpctl", "inspect", "@DEFAULT_AUDIO_SINK@")
    sink = next((l.split("=", 1)[1].strip() for l in inspect.splitlines() if "node.name" in l), "")
    check("PipeWire has a default audio sink (QEMU's sound card; nothing was played)", sink_present(rc, inspect), sink)

    # Keyboard layout: Scottland ships "us"; Gooarchy takes the system's layout when it has one.
    layout = ipc("wayfire/get-config-option", {"option": "input/xkb_layout"}).get("value")
    check("config: keyboard layout is us when the system sets none", layout == "us", layout)
    run("sudo", "localectl", "set-x11-keymap", "de")
    build = "/usr/lib/scottland/libexec/scottland-build-config"
    run(build)  # what the next login (or Scottland's config watcher) does
    layout = wait_for(lambda: (lambda v: v if v == "de" else None)(
        ipc("wayfire/get-config-option", {"option": "input/xkb_layout"}).get("value")), timeout=15)
    check("the system's keyboard layout (localectl set-x11-keymap de) reaches the session", layout == "de", layout)
    run("sudo", "localectl", "set-x11-keymap", "us")
    run(build)
    wait_for(lambda: ipc("wayfire/get-config-option", {"option": "input/xkb_layout"}).get("value") == "us", timeout=15)

    # Keys Scottland's shipped config binds.
    rc1, before = run_rc("wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@")
    press("KEY_VOLUMEUP")
    after = wait_for(lambda: (lambda t: t if volume_of(t[1]) != volume_of(before) else None)(
        run_rc("wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@")), timeout=5) or (1, "")
    check("the volume-up key raises the volume", rc1 == 0 and after[0] == 0 and volume_of(before) is not None
          and volume_of(after[1]) is not None and volume_of(after[1]) > volume_of(before), f"{before} -> {after[1]}")
    shots_before = set(os.listdir(pictures)) if os.path.isdir(pictures) else set()
    press("KEY_PRINT")
    new = wait_for(lambda: set(os.listdir(pictures)) - shots_before, timeout=10)
    check(f"Print saves a screenshot in the Pictures folder ({pictures})", new, sorted(new or []))
    # A moved (or localized) Pictures folder.
    dirs = f"{HOME}/.config/user-dirs.dirs"
    saved = open(dirs).read()
    with open(dirs, "w") as f:
        f.write(saved.replace('XDG_PICTURES_DIR="$HOME/Pictures"', 'XDG_PICTURES_DIR="$HOME/Bilder"'))
    press("KEY_PRINT")
    moved = wait_for(lambda: os.listdir(f"{HOME}/Bilder"), timeout=10)
    check("Print follows a moved Pictures folder (~/Bilder)", moved, moved)
    with open(dirs, "w") as f:
        f.write(saved)

    # Scottland Settings is a layer-shell overlay, not a window in Scottland's model.
    press("KEY_LEFTMETA", "KEY_COMMA")
    settings = wait_for(lambda: [v for v in all_views() if v.get("app-id") == "scottland-settings" and v.get("mapped")],
                        timeout=30)
    check("Super+comma opens Scottland Settings", settings, settings and settings[0].get("app-id"))
    time.sleep(2)
    shot("09-scottland-settings.png")
    run("pkill", "-f", "qs -n -p /usr/share/scottland/settings")

    # A terminal bell in a window you're not using becomes Scottland attention (what coding agents
    # ring when they need you). The bell rings when the check says so, once the window is unfocused.
    fifo = "/tmp/gooarchy-check/bell"
    if os.path.exists(fifo):
        os.unlink(fifo)
    os.mkfifo(fifo)
    subprocess.Popen(["ghostty", "--gtk-single-instance=false", "--title=bell-check", "-e", "sh", "-c",
                      f"while read x < {fifo}; do printf '\\a'; done"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    bell = wait_for(lambda: next((v for v in views() if "bell-check" in (v.get("title") or "")), None), timeout=60)
    other = find("chromium")
    steps, rings, lit = [], 0, None
    if bell and other:
        steps.append("window up")
        ipc("scottland/present", {"window": other["id"]})
        unfocused = wait_for(lambda: not (view(bell["id"]) or {}).get("focused"), timeout=10)
        steps.append("unfocused" if unfocused else "still focused")
        for rings in (1, 2):
            with open(fifo, "w") as f:
                f.write("ring\n")
            lit = wait_for(lambda: (lambda v: v if v and v.get("attention") else None)(view(bell["id"])), timeout=15)
            if lit:
                break
        v = view(bell["id"]) or {}
        steps.append(f"title {v.get('title')!r}")
    else:
        steps.append("bell window up" if bell else "bell window never appeared")
    check("a bell in an unfocused terminal lights it up (Scottland attention)", lit,
          "; ".join(steps) + (f"; lit after {rings} ring(s)" if lit else ""))
    shot("10-bell-attention.png")

    check_solar_schedule()

    # Calibration: the wallpaper check must reject a desktop without its wallpaper.
    run("pkill", "-f", "gooarchy-wallpaper")
    run("pkill", "-x", "swaybg")
    time.sleep(2)
    blank = grab_ppm(int(screen["x"]) + 20, int(screen["y"]) + 20, 240, 240)
    check("calibration: the wallpaper check rejects a desktop whose wallpaper is gone", not looks_drawn(blank))

    # What isn't there (DEFICIT.md), recorded from the running system.
    observe("desktop notifications", run("gdbus", "call", "--session", "--dest", "org.freedesktop.Notifications",
                                         "--object-path", "/org/freedesktop/Notifications", "--method",
                                         "org.freedesktop.Notifications.GetServerInformation"))
    bus = run("busctl", "--user", "list")
    observe("status tray (StatusNotifierWatcher)", "present" if "StatusNotifierWatcher" in bus else "absent")
    observe("secret service (keyring)", "present" if "org.freedesktop.secrets" in bus else "absent")
    observe("polkit authentication agent", "present" if run("pgrep", "-f", "polkit.*agent") else "absent")
    observe("lock screen client", run("sh", "-c", "command -v swaylock hyprlock gtklock waylock || echo none"))
    observe("idle settings (Wayfire idle plugin)", {o: ipc("wayfire/get-config-option", {"option": f"idle/{o}"}).get("value")
                                                   for o in ("screensaver_timeout", "dpms_timeout")})
    observe("portal interfaces", sorted(set(
        w for w in run("busctl", "--user", "introspect", "org.freedesktop.portal.Desktop",
                       "/org/freedesktop/portal/desktop").split() if w.startswith("org.freedesktop.portal."))))
    observe("Xwayland", run("sh", "-c", "command -v Xwayland || echo 'not installed (X11-only apps cannot run)'"))
    observe("network stack", run("sh", "-c", "for s in NetworkManager iwd systemd-networkd; do "
                                              "printf '%s=%s ' $s $(systemctl is-enabled $s 2>/dev/null || echo absent); done"))
    observe("packages not installed", [p for p in ("bluez", "upower", "power-profiles-daemon", "cups", "networkmanager",
                                                   "iwd", "xdg-desktop-portal-wlr", "xorg-xwayland", "linux-firmware",
                                                   "gnome-keyring", "zram-generator", "noto-fonts-cjk")
                                       if subprocess.run(["pacman", "-Q", p], capture_output=True).returncode])
    observe("launcher, bar, notification daemon processes",
            run("sh", "-c", "pgrep -a -x 'waybar|wofi|fuzzel|rofi|mako|dunst|swaync|walker' || echo none"))
    observe("swap and OOM policy", run("sh", "-c", "swapon --show --noheadings; systemctl is-enabled systemd-oomd 2>&1"))
    observe("Wayfire errors in its log", sorted(set(
        l.split(" - ", 1)[-1].strip() for l in open(WAYFIRE_LOG, errors="replace") if l.startswith("EE"))))

    # Last, because they end sessions. Logging out (Super+Shift+Escape) ends the session and
    # autologin starts a new one, twice; the old login must actually close (no session left
    # "closing", no Scottland watchers left over). Then a crashed compositor must leave a shell on
    # tty1 in that same login, with the session's units stopped and no restart loop.
    for cycle in (1, 2):
        old_pid = wayfire_pid()
        old_sid = session_of(old_pid)
        save_session_log(f"wayfire-before-logout-{cycle}.log")
        try:
            press("KEY_LEFTMETA", "KEY_LEFTSHIFT", "KEY_ESC")
        except OSError:
            pass  # Wayfire quit before the keys were released: the logout worked
        new_pid = wait_for(lambda: (lambda p: p if p and p != old_pid else None)(wayfire_pid()), timeout=30)
        note = ""
        if not new_pid and wayfire_pid() == old_pid:
            try:
                press("KEY_LEFTMETA", "KEY_LEFTSHIFT", "KEY_ESC")
            except OSError:
                pass
            new_pid = wait_for(lambda: (lambda p: p if p and p != old_pid else None)(wayfire_pid()), timeout=60)
            note = " (needed a second press)"
        check(f"logout {cycle}: Super+Shift+Escape ends the session and autologin starts a new one",
              new_pid, f"wayfire {old_pid} -> {new_pid}{note}")
        closed = wait_for(lambda: session_gone(old_sid), timeout=30)
        entered = new_pid and enter_session()
        # The new session starts its own watchers; exactly one set must be running.
        watchers = wait_for(lambda: (lambda w: w if w == [1, 1] else None)(
            [len(helpers("libexec/scottland-color-scheme")), len(helpers("libexec/scottland-solar-theme"))]),
            timeout=60) or [len(helpers("libexec/scottland-color-scheme")), len(helpers("libexec/scottland-solar-theme"))]
        check(f"logout {cycle}: the old login closes (no session left closing, one set of watchers)",
              closed and watchers == [1, 1],
              f"session {old_sid}: {'gone' if closed else session_state(old_sid)}; "
              f"color-scheme and solar watchers running: {watchers}; new session entered: {bool(entered)}")
    pid = wayfire_pid()
    sid = session_of(pid)
    save_session_log("wayfire-before-crash.log")
    time.sleep(3)
    os.kill(int(pid), signal.SIGSEGV)
    gone = wait_for(lambda: not wayfire_pid(), timeout=20)
    time.sleep(15)
    restarted = wayfire_pid()
    target = run("systemctl", "--user", "is-active", "scottland-session.target")
    leftovers = helpers("/usr/lib/scottland/", session=sid)
    check("a crashed session leaves a shell on tty1 in the same login (no restart loop)",
          gone and not restarted and session_state(sid) == "active" and target != "active" and not leftovers,
          f"session {sid}: {session_state(sid)}; restarted wayfire: {restarted or 'none'}; "
          f"scottland-session.target {target}; helpers left: {leftovers or 'none'}")


def finish():
    if screenshots_failed:
        check("screenshots are taken", False, screenshots_failed)
    else:
        check("screenshots are taken", True, len(glob.glob(os.path.join(OUT, "*.png"))))
    with open(os.path.join(OUT, "results.json"), "w") as f:
        json.dump({"failures": failures, "results": results, "observations": observations}, f, indent=1)
    log(f"{len(results) - failures}/{len(results)} checks passed")
    return 1 if failures else 0


def on_deadline(signum, frame):
    raise Deadline(f"the whole check took longer than {RUN_DEADLINE}s")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    signal.signal(signal.SIGALRM, on_deadline)
    signal.alarm(RUN_DEADLINE)
    try:
        main()
    except BaseException as error:  # a broken session must still leave results behind
        check("the check ran to the end", False, f"{type(error).__name__}: {error}")
    finally:
        signal.alarm(0)
        code = finish()
    sys.exit(code)
