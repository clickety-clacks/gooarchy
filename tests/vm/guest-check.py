#!/usr/bin/env python3
"""Check a Gooarchy session from inside the guest (tests/vm/run.sh copies and runs this).

  guest-check.py OUTDIR

Waits for the Scottland session the boot started on tty1, enters its environment, then uses it
the way a person would, through Wayfire's virtual input (stipc): Super+Enter for a terminal, the
flavorings' keys for Strata and Chromium, Super+drag to move windows into the periphery and onto
a rail. Each step is checked against Scottland's own model (scottland/layout-state) and
screenshotted with grim. Writes results.json and screenshots to OUTDIR; exits 1 if a check fails.
"""
import glob
import json
import os
import socket
import struct
import subprocess
import sys
import time

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/gooarchy-check/out"
os.makedirs(OUT, exist_ok=True)
RUNTIME = f"/run/user/{os.getuid()}"
results = []
observations = []
failures = 0


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


def wait_for(predicate, timeout=30, interval=0.25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except Exception:
            pass
        time.sleep(interval)
    return None


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
                with socket.socket(socket.AF_UNIX) as s:
                    s.settimeout(1)
                    s.connect(sock)
                return env
            except OSError:
                pass
    return None


def ipc(method, data=None):
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(os.environ["WAYFIRE_SOCKET"])
        body = json.dumps({"method": method, "data": data or {}}).encode()
        s.sendall(struct.pack("<I", len(body)) + body)
        header = b""
        while len(header) < 4:
            header += s.recv(4 - len(header))
        size, reply = struct.unpack("<I", header)[0], b""
        while len(reply) < size:
            reply += s.recv(size - len(reply))
    return json.loads(reply)


def shot(name):
    path = os.path.join(OUT, name)
    subprocess.run(["grim", path], check=False, timeout=20)
    log(f"screenshot {path}")
    return path


def views():
    return ipc("scottland/layout-state").get("views", [])


def find(app_id_part):
    for v in views():
        if app_id_part.lower() in (v.get("app_id") or "").lower():
            return v
    return None


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
    view = wait_for(lambda: find(app_id), timeout=timeout)
    if view:
        return view, ""
    press(*keys)
    view = wait_for(lambda: find(app_id), timeout=timeout)
    return view, " (needed a second press)" if view else ""


def toplevel_bbox(view_id):
    for v in ipc("window-rules/list-views"):
        if v.get("id") == view_id:
            return v.get("bbox") or v.get("geometry")
    return None


def super_drag(view, x2, y2=None, steps=30):
    """Super+left-drag a window from its center (Scottland's move binding) to (x2, y2)."""
    box = toplevel_bbox(view["id"]) or view["frame"]
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


def main():
    log("waiting for the Scottland session on tty1")
    env = wait_for(session_env, timeout=180, interval=2)
    if not check("a Scottland session is running (autologin on tty1 -> start-scottland)", env):
        return finish()
    os.environ.update(env)
    state = wait_for(lambda: ipc("scottland/layout-state"), timeout=60)
    check("the Scottland plugin answers (scottland/layout-state)", state and "views" in state)
    output = ipc("wayfire/get-config-option", {"option": "core/plugins"})
    plugins = output.get("value", "")
    check("Wayfire runs Scottland's config with the scottland plugin", "scottland" in plugins.split(), plugins)
    try:
        outputs = ipc("window-rules/list-outputs")
        screen = outputs[0]["geometry"]
    except Exception:
        screen = {"x": 0, "y": 0, "width": 1920, "height": 1080}
    log(f"screen {screen}")

    # Renderer and session basics.
    with open(os.path.expanduser("~/.local/state/scottland/wayfire.log"), errors="replace") as f:
        wlog = f.read()
    renderer = [l for l in wlog.splitlines() if "GL_RENDERER" in l or "Renderer:" in l or "EGL vendor" in l]
    check("Wayfire renders with GL", renderer, " | ".join(l.strip()[-120:] for l in renderer[:3]))

    # Test-only: Wayfire's virtual input plugin, loaded into the running session (not into
    # Gooarchy's config).
    if "stipc" not in plugins.split():
        ipc("wayfire/set-config-options", {"core/plugins": plugins + " stipc"})
    check("virtual input (stipc) loaded for the test",
          wait_for(lambda: "error" not in ipc("stipc/move_cursor", {"x": 10, "y": 10}), timeout=15))

    time.sleep(3)  # let the wallpaper and the session's autostart settle
    shot("01-desktop.png")
    check("the wallpaper (swaybg) is drawn", subprocess.run(["pgrep", "-x", "swaybg"]).returncode == 0)

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

    # Chromium: Super+Shift+B (flavorings).
    # Arch's Chromium opens a placeholder "Additional Terms of Service" dialog (no app-id) on its
    # first run; accept it with Enter as a user would.
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
    time.sleep(5)
    shot("04-chromium.png")
    prefs = os.path.expanduser("~/.config/chromium/Default/Preferences")
    frame = wait_for(lambda: json.load(open(prefs)).get("browser", {}).get("custom_chrome_frame", "unset") is False
                     and "false", timeout=15)
    check("Chromium uses the system title bar (browser.custom_chrome_frame = false)", frame)

    # The periphery: windows away from the center are scaled down.
    log("layout: " + json.dumps([{k: v.get(k) for k in ("app_id", "zone", "applied_scale", "widgetized")}
                                 for v in views()]))
    term = find("ghostty")
    if term:
        super_drag(term, screen["x"] + screen["width"] * 0.80)
        time.sleep(1.5)
    side = wait_for(lambda: [v for v in views() if (v.get("applied_scale") or 1) < 0.95 and not v.get("widgetized")],
                    timeout=10)
    check("windows scale down in the periphery", side,
          side and [(v.get("app_id"), v.get("zone"), round(v.get("applied_scale", 0), 3)) for v in side])
    shot("05-periphery.png")

    # A rail: dragging a window to the screen's edge turns it into a widget.
    strata = find("strata")
    if strata:
        super_drag(strata, screen["x"] + screen["width"] - 4, screen["y"] + screen["height"] * 0.4, steps=40)
    widget = wait_for(lambda: [v for v in views() if v.get("widgetized")], timeout=15)
    check("a window dragged to the edge widgetizes on the rail", widget,
          widget and [(v.get("app_id"), v.get("rail")) for v in widget])
    time.sleep(2)
    shot("06-rail-widget.png")

    with open(os.path.join(OUT, "layout-state.json"), "w") as f:
        json.dump(ipc("scottland/layout-state"), f, indent=1)

    # Defaults the session should carry.
    env_wayfire = open(f"/proc/{subprocess.check_output(['pgrep', '-xo', 'wayfire']).decode().strip()}/environ",
                       "rb").read().split(b"\0")
    check("MOSH_TITLE_NOPREFIX=1 in the session", b"MOSH_TITLE_NOPREFIX=1" in env_wayfire)
    tmux = subprocess.run(["tmux", "-L", "gooarchy-check", "-f", "/etc/tmux.conf", "start-server", ";",
                           "show-options", "-g", "set-titles-string"], capture_output=True, text=True)
    subprocess.run(["tmux", "-L", "gooarchy-check", "kill-server"], capture_output=True)
    check("tmux titles read \"session on host\"", "#S on #h" in tmux.stdout, tmux.stdout.strip())
    for option in ("input/tap_to_click", "input/tap_and_drag", "input/drag_lock"):
        value = ipc("wayfire/get-config-option", {"option": option}).get("value")
        check(f"touchpad {option} on", str(value).lower() in ("true", "1"), value)
    scheme = subprocess.run(["busctl", "--user", "call", "org.freedesktop.portal.Desktop",
                             "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "ReadOne",
                             "ss", "org.freedesktop.appearance", "color-scheme"], capture_output=True, text=True)
    check("the settings portal reports the color scheme (2 = light)", scheme.stdout.strip().endswith("2"),
          scheme.stdout.strip() or scheme.stderr.strip())
    folder = subprocess.run(["xdg-mime", "query", "default", "inode/directory"], capture_output=True, text=True)
    check("folders open in Strata", "Strata" in folder.stdout, folder.stdout.strip())
    claude = json.load(open(os.path.expanduser("~/.claude.json"))).get("preferredNotifChannel")
    check("Claude Code rings the terminal bell", claude == "terminal_bell", claude)
    codex = open(os.path.expanduser("~/.codex/config.toml")).read()
    check("Codex rings the terminal bell", 'notification_method = "bel"' in codex)
    for scope, unit in (("--user", "pipewire"), ("--user", "wireplumber"), ("--user", "pipewire-pulse.socket"),
                        ("--system", "rtkit-daemon")):
        active = subprocess.run(["systemctl", scope, "is-active", unit], capture_output=True, text=True).stdout.strip()
        check(f"{unit} running", active == "active", active)
    sinks = subprocess.run(["wpctl", "status"], capture_output=True, text=True).stdout
    check("PipeWire sees an audio sink", "Sinks:" in sinks and "Audio" in sinks)

    # Keys Scottland's shipped config binds.
    before = run("wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@")
    press("KEY_VOLUMEUP")
    time.sleep(1)
    after = run("wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@")
    check("the volume-up key raises the volume", before != after, f"{before} -> {after}")
    pictures = os.path.expanduser("~/Pictures")
    shots_before = set(os.listdir(pictures)) if os.path.isdir(pictures) else set()
    press("KEY_PRINT")
    new = wait_for(lambda: set(os.listdir(pictures)) - shots_before, timeout=10)
    check("Print saves a screenshot in ~/Pictures", new, sorted(new or []))
    # Scottland Settings is a layer-shell overlay, not a window in Scottland's model.
    press("KEY_LEFTMETA", "KEY_COMMA")
    settings = wait_for(lambda: [v for v in ipc("window-rules/list-views")
                                 if v.get("app-id") == "scottland-settings" and v.get("mapped")], timeout=30)
    check("Super+comma opens Scottland Settings", settings, settings and settings[0].get("app-id"))
    time.sleep(2)
    shot("07-scottland-settings.png")
    subprocess.run(["pkill", "-f", "qs -n -p /usr/share/scottland/settings"])

    # A terminal bell in a window you're not using becomes Scottland attention (what coding agents
    # ring when they need you).
    subprocess.Popen(["ghostty", "--gtk-single-instance=false", "--title=bell-check", "-e", "sh", "-c",
                      "sleep 6; printf '\\a'; sleep 120"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    bell = wait_for(lambda: next((v for v in views() if "bell-check" in (v.get("title") or "")), None), timeout=20)
    other = find("chromium")
    if bell and other:
        ipc("scottland/present", {"window": other["id"]})
    lit = wait_for(lambda: next((v for v in views() if "bell-check" in (v.get("title") or "") and v.get("attention")),
                                None), timeout=20)
    check("a bell in an unfocused terminal lights it up (Scottland attention)", lit, lit and lit.get("title"))
    time.sleep(1)
    shot("08-bell-attention.png")

    # What isn't there (DEFICIT.md), recorded from the running system.
    observe("desktop notifications", run("gdbus", "call", "--session", "--dest", "org.freedesktop.Notifications",
                                         "--object-path", "/org/freedesktop/Notifications", "--method",
                                         "org.freedesktop.Notifications.GetServerInformation"))
    observe("status tray (StatusNotifierWatcher)", "present" if "StatusNotifierWatcher" in run(
        "busctl", "--user", "list") else "absent")
    observe("secret service (keyring)", "present" if "org.freedesktop.secrets" in run("busctl", "--user", "list")
            else "absent")
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
                                                   "gnome-keyring")
                                       if subprocess.run(["pacman", "-Q", p], capture_output=True).returncode])
    observe("launcher, bar, notification daemon processes",
            run("sh", "-c", "pgrep -a -x 'waybar|wofi|fuzzel|rofi|mako|dunst|swaync|walker' || echo none"))
    observe("Wayfire errors in its log", sorted(set(
        l.split(" - ", 1)[-1] for l in open(os.path.expanduser("~/.local/state/scottland/wayfire.log"), errors="replace")
        if l.startswith("EE"))))

    # Last, because they end the session: logging out (Super+Shift+Escape) ends it and autologin
    # starts a new one; a crashed compositor leaves a shell on tty1 instead of a restart loop.
    old = run("pgrep", "-xo", "wayfire")
    try:
        press("KEY_LEFTMETA", "KEY_LEFTSHIFT", "KEY_ESC")
    except OSError:
        pass  # Wayfire quit before the keys were released: the logout worked
    new = wait_for(lambda: (lambda p: p if p and p != old else None)(run("pgrep", "-xo", "wayfire")), timeout=40)
    check("Super+Shift+Escape logs out, and autologin starts a new session", new, f"wayfire {old} -> {new}")
    if new:
        time.sleep(5)
        os.kill(int(new), 11)
        time.sleep(15)
        after = run("pgrep", "-x", "wayfire")
        tty1 = run("loginctl", "list-sessions", "--no-legend")
        check("a crashed session leaves a shell on tty1 (no restart loop)", not after and "tty1" in tty1,
              f"wayfire after crash: {after or 'none'}")
    return finish()


def finish():
    with open(os.path.join(OUT, "results.json"), "w") as f:
        json.dump({"failures": failures, "results": results, "observations": observations}, f, indent=1)
    log(f"{len(results) - failures}/{len(results)} checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
