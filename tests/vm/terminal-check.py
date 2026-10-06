#!/usr/bin/env python3
"""Check one terminal against what Gooarchy needs from its terminal, inside the guest's running
Scottland session (tests/vm/run.sh terminal-check runs it for foot and for Ghostty).

  terminal-check.py OUTDIR --terminal foot|ghostty

Input is real (Wayfire's virtual keyboard and pointer, stipc). What the terminal does is judged by
oracles that don't ask the terminal: Scottland's own model (scottland/layout-state: app-id,
title, focus, attention), the screen (grim pixels), the system clipboard (wl-paste) and /proc
(working directories, memory). Each terminal runs commands through a small shell loop fed by a
FIFO, so the check can make it print, ring, change title or copy while its window is in any state.

Covered: (1) bells become attention and clear on click: plain, inside tmux, over SSH, and the byte
Claude Code's and Codex's seeded settings make them send; (2) app-id, titles (OSC and tmux
set-titles), touch scrolling; (3) Watercolor Dream light/dark colors and live switching; (4) a
terminal in a folder (Super+Alt+Return, Strata's Ctrl+T); (5) text, Nerd Font symbols and color
emoji render; (6) paste, selection copy, OSC 52 directly and from tmux; (7) start time and memory.
Writes terminal-<name>.json (checks, observations, metrics) and screenshots to OUTDIR.
"""
import base64
import importlib.util
import json
import os
import secrets
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import time
import tomllib

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("guest_check", os.path.join(here, "guest-check.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

OUT = sys.argv[1]
TERMINAL = sys.argv[sys.argv.index("--terminal") + 1]
APP_ID = {"foot": "foot", "ghostty": "com.mitchellh.ghostty"}[TERMINAL]
HOME = os.path.expanduser("~")
TMP = f"/tmp/gooarchy-terminal-check/{TERMINAL}"
HOST = socket.gethostname()
results, observations, metrics = [], [], {}
procs = []


class HangDeadline(BaseException):
    """The overall hang deadline must escape scenario and observation exception handlers."""


def log(message):
    print(f"[{time.strftime('%H:%M:%S')}] [{TERMINAL}] {message}", flush=True)


def check(name, ok, detail=""):
    results.append({"check": name, "ok": bool(ok), "detail": detail})
    log(f"{'PASS' if ok else 'FAIL'} {name}{': ' + str(detail) if detail != '' else ''}")
    return ok


def observe(name, value):
    observations.append({"observation": name, "value": value})
    log(f"OBSERVED {name}: {value}")


def launch(argv=None, cwd=None, env=None):
    """Start the terminal (running ARGV, else a shell)."""
    if TERMINAL == "foot":
        command = ["foot"] + (argv or [])
    else:
        command = ["ghostty", "--gtk-single-instance=false"] + (["-e"] + argv if argv else [])
    p = subprocess.Popen(command, cwd=cwd or HOME, env=env, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    procs.append(p)
    return p


def window_of(pid, timeout=30):
    return g.wait_for(lambda: next((v for v in g.views() if v.get("pid") == pid), None), timeout=timeout)


def ids():
    return {v["id"] for v in g.views()}


class Pane:
    """A terminal window whose shell runs whatever lines the check writes to its FIFO."""
    count = 0

    def __init__(self, how="plain", session=None):
        Pane.count += 1
        self.name = f"{how}{Pane.count}"
        self.fifo = f"{TMP}/{self.name}.fifo"
        self.ready = f"{TMP}/{self.name}.ready"
        os.mkfifo(self.fifo)
        script = f"{TMP}/{self.name}.sh"
        with open(script, "w") as f:
            f.write(f"exec 3<>{self.fifo}\ntouch {self.ready}\nwhile read -r line <&3; do eval \"$line\"; done\n")
        loop = ["bash", script]
        if how == "tmux":
            self.session = session or f"t{Pane.count}"
            argv = ["tmux", "-L", "gooarchy-terminal-check", "-f", "/etc/tmux.conf", "new-session", "-s", self.session,
                    f"bash {script}"]
        elif how == "ssh":
            argv = ["ssh", "-t", "-o", "StrictHostKeyChecking=accept-new", "localhost", f"bash {script}"]
        else:
            argv = loop
        self.proc = launch(argv)
        self.view = window_of(self.proc.pid)
        self.ok = bool(self.view) and bool(g.wait_for(lambda: os.path.exists(self.ready), timeout=30))

    def send(self, line):
        if not self.ok or self.proc.poll() is not None:
            raise RuntimeError(f"{self.name}: test shell is not running")
        # A crashed terminal must not leave the harness blocked opening a FIFO with no reader.
        fd = os.open(self.fifo, os.O_WRONLY | os.O_NONBLOCK)
        try:
            os.write(fd, (line + "\n").encode())
        finally:
            os.close(fd)

    def completed(self, line):
        """Run a setup command once and wait until the fixture shell has completed it."""
        marker = f"{TMP}/{self.name}.{secrets.token_hex(6)}.done"
        self.send(f"{line}; touch {marker}")
        if not g.wait_for(lambda: os.path.exists(marker), timeout=30):
            raise RuntimeError(f"{self.name}: setup command did not complete: {line}")

    def state(self):
        return g.view(self.view["id"]) if self.view else None

    def present(self):
        g.ipc("scottland/present", {"window": self.view["id"]})
        return g.wait_for(lambda: (self.state() or {}).get("focused"), timeout=10)

    def frame(self):
        f = (self.state() or {}).get("scene_frame") or (self.state() or {}).get("frame")
        return {k: int(round(f[k])) for k in ("x", "y", "width", "height")}


# ---- screen helpers -------------------------------------------------------------------------

def ppm(frame):
    data = g.grab_ppm(frame["x"], frame["y"], frame["width"], frame["height"])
    magic, size, maxval, pixels = data.split(b"\n", 3)
    w, h = map(int, size.split())
    return w, h, pixels


def pixel(image, x, y):
    w, h, pixels = image
    i = (y * w + x) * 3
    return tuple(pixels[i:i + 3])


def settled_pixels(pane, previous=None):
    """Wait for captured client pixels to change (when requested), then agree across samples."""
    last, matching = None, 0
    def ready():
        nonlocal last, matching
        image = ppm(pane.frame())
        matching = matching + 1 if image == last else 1
        last = image
        return image if matching >= 3 and (previous is None or image[2] != previous) else None
    image = g.wait_for(ready, timeout=30, interval=.1)
    if image is None:
        raise RuntimeError(f"{pane.name}: captured pixels did not settle")
    return image


def near(a, b, tolerance=12):
    return all(abs(x - y) <= tolerance for x, y in zip(a, b))


def hex_rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def theme(mode):
    with open(f"/usr/share/gooarchy-flavorings/themes/watercolor-dream-{mode}/colors.toml", "rb") as f:
        return tomllib.load(f)


def click(frame, dx=None, dy=None, double=False):
    x = frame["x"] + (dx if dx is not None else frame["width"] // 2)
    y = frame["y"] + (dy if dy is not None else frame["height"] // 2)
    g.ipc("stipc/move_cursor", {"x": x, "y": y})
    time.sleep(0.15)
    for _ in range(2 if double else 1):
        g.ipc("stipc/feed_button", {"combo": "BTN_LEFT", "mode": "press"})
        time.sleep(0.05)
        g.ipc("stipc/feed_button", {"combo": "BTN_LEFT", "mode": "release"})
        time.sleep(0.08)


def clipboard():
    return g.run("wl-paste", "--no-newline", timeout=5)


def shells_under(pid):
    """(pid, cwd) of shell processes under PID, newest last."""
    shells = {os.path.realpath(l.strip()) for l in open("/etc/shells") if l.startswith("/")}
    found, todo = [], [pid]
    while todo:
        p = todo.pop(0)
        try:
            if os.path.realpath(f"/proc/{p}/exe") in shells:
                found.append((p, os.readlink(f"/proc/{p}/cwd")))
        except OSError:
            pass
        for c in os.listdir("/proc"):
            if c.isdigit():
                try:
                    if int(open(f"/proc/{c}/stat").read().rsplit(")", 1)[1].split()[1]) == p:
                        todo.append(int(c))
                except (OSError, ValueError, IndexError):
                    pass
    return found


def pss_kib(pid):
    try:
        for line in open(f"/proc/{pid}/smaps_rollup"):
            if line.startswith("Pss:"):
                return int(line.split()[1])
    except OSError:
        pass
    return None


# ---- the checks -----------------------------------------------------------------------------

def bells():
    holder = Pane()
    for how in ("plain", "tmux", "ssh"):
        pane = Pane(how)
        if not check(f"{how}: the terminal starts and runs the test shell", pane.ok, pane.view and pane.view.get("title")):
            continue
        holder.present()  # setup: another window has focus
        unfocused = g.wait_for(lambda: not (pane.state() or {}).get("focused"), timeout=10)
        pane.send("printf '\\a'")
        lit = g.wait_for(lambda: (pane.state() or {}).get("attention"), timeout=15)
        check(f"bell ({how}) in an unfocused window becomes Scottland attention", unfocused and lit,
              f"unfocused before the bell: {bool(unfocused)}")
        if lit:
            click(pane.frame())  # real input: click the lit window
            cleared = g.wait_for(lambda: (lambda s: s and s.get("focused") and not s.get("attention"))(pane.state()),
                                 timeout=10)
            check(f"attention ({how}) clears when you click the window", cleared,
                  f"focused {bool((pane.state() or {}).get('focused'))}, attention {(pane.state() or {}).get('attention')}")
        g.shot(f"{TERMINAL}-bell-{how}.png") if how == "plain" else None
        pane.proc.terminate()
    # The agents aren't installed (no credentials); what their seeded settings make them write when
    # they need you is a plain BEL, the same byte as above.
    claude = json.load(open(f"{HOME}/.claude.json")).get("preferredNotifChannel")
    codex = tomllib.load(open(f"{HOME}/.codex/config.toml", "rb")).get("tui", {})
    plain_results = [r for r in results if r["check"].startswith("bell (plain)")]
    plain_ok = len(plain_results) == 1 and plain_results[0]["ok"]
    check("Claude Code's and Codex's seeded settings select BEL, which lights the window (agents not run)",
          claude == "terminal_bell" and codex.get("notification_method") == "bel" and codex.get("notifications") is True
          and plain_ok, f"claude {claude}, codex {codex}")
    holder.proc.terminate()


def identity():
    pane = Pane()
    check("app-id as Scottland sees it", (pane.state() or {}).get("app_id") == APP_ID, (pane.state() or {}).get("app_id"))
    pane.send("printf '\\033]2;gooarchy-title-test\\007'")
    titled = g.wait_for(lambda: (pane.state() or {}).get("title") == "gooarchy-title-test", timeout=10)
    check("an OSC 2 title reaches Scottland", titled, (pane.state() or {}).get("title"))
    regex = g.ipc("wayfire/get-config-option", {"option": "scottland/touch_scroll_terminals"}).get("value", "")
    import re
    check("config: Scottland's touch scrolling lists this app-id", re.search(regex, APP_ID) is not None, regex)
    # Touch scrolling: a finger dragged down the window scrolls the scrollback (seen on screen).
    pane.present()
    before_output = ppm(pane.frame())[2]
    pane.completed("seq 1 4000")
    f = pane.frame()
    before = settled_pixels(pane, previous=before_output)[2]
    x, y = f["x"] + f["width"] // 2, f["y"] + f["height"] // 3
    probe = g.ipc("stipc/touch", {"finger": 0, "x": x, "y": y})
    if isinstance(probe, dict) and probe.get("error"):
        observe("touch scrolling", f"not testable here: {probe.get('error')}")
    else:
        try:
            for i in range(1, 21):
                g.ipc("stipc/touch", {"finger": 0, "x": x, "y": y + i * 20})
                time.sleep(0.02)  # gesture pacing
        finally:
            g.ipc("stipc/touch_release", {"finger": 0})
        changed = 0
        def scrolled_pixels():
            nonlocal changed
            after = ppm(pane.frame())[2]
            changed = sum(a != b for a, b in zip(before[::31], after[::31])) / max(1, len(before[::31]))
            return changed > 0.05
        check("a finger dragged down the window scrolls back (screen changes)",
              g.wait_for(scrolled_pixels, timeout=15), f"{changed:.1%} of samples changed")
        g.shot(f"{TERMINAL}-touch-scroll.png")
    pane.proc.terminate()
    # tmux set-titles: "session on host" as the window title.
    tp = Pane("tmux", session="gtitle")
    want = f"gtitle on {HOST}"
    titled = g.wait_for(lambda: (tp.state() or {}).get("title") == want, timeout=15)
    check("tmux set-titles reaches Scottland as \"session on host\"", titled, (tp.state() or {}).get("title"))
    tp.proc.terminate()
    observe("terminal-specific features keyed by app-id",
            "Scottland's touch scrolling (touch_scroll_terminals; Ghostty also gets wheel mode via touch_scroll_wheel). "
            "Nothing in Gooarchy or Scottland tags the clipboard by app-id.")


def colors():
    pane = Pane()
    pane.present()
    pane.completed("clear; printf '\\033[41m%60s\\033[0m\\n' ''")

    def sample():
        f = pane.frame()
        img = ppm(f)
        return pixel(img, f["width"] - 30, f["height"] - 30), pixel(img, 60, 10)

    def expect(mode, timeout):
        t = theme(mode)
        bg, red = hex_rgb(t["background"]), hex_rgb(t["red"])
        got = g.wait_for(lambda: (lambda s: s if near(s[0], bg) and near(s[1], red) else None)(sample()), timeout=timeout)
        return got, sample(), bg, red

    got, now, bg, red = expect("light", 5)
    check("Watercolor Dream light: background and red as the theme says", got, f"bg {now[0]} want {bg}; red {now[1]} want {red}")
    g.shot(f"{TERMINAL}-light.png")
    g.run("gooarchy-theme", "dark")
    got, now, bg, red = expect("dark", 8)
    check("switching to dark recolors the open window", got, f"bg {now[0]} want {bg}; red {now[1]} want {red}")
    g.shot(f"{TERMINAL}-dark.png")
    fresh = Pane()
    fresh.present()
    corner = None
    def dark_pixels():
        nonlocal corner
        f = fresh.frame()
        corner = pixel(ppm(f), f["width"] - 30, f["height"] - 30)
        return near(corner, hex_rgb(theme("dark")["background"]))
    check("a window opened in dark mode starts dark", g.wait_for(dark_pixels, timeout=10), f"bg {corner}")
    fresh.proc.terminate()
    pane.present()
    g.run("gooarchy-theme", "light")
    got, now, bg, red = expect("light", 8)
    check("switching back to light recolors the open window", got, f"bg {now[0]} want {bg}; red {now[1]} want {red}")
    pane.proc.terminate()


def folders():
    folder = f"{TMP}/cwd here"
    os.makedirs(folder, exist_ok=True)
    pane = Pane()
    pane.completed(f"cd '{folder}'")
    pane.present()
    before = ids()
    g.press("KEY_LEFTMETA", "KEY_LEFTALT", "KEY_ENTER")
    new = g.wait_for(lambda: [v for v in g.views() if v["id"] not in before and v.get("app_id") == APP_ID], timeout=20)
    cwds = []
    def correct_cwd():
        nonlocal cwds
        cwds = [c for _, c in shells_under(new[0]["pid"])]
        return folder in cwds
    cwd_ok = new and g.wait_for(correct_cwd, timeout=10)
    check("Super+Alt+Return opens a terminal of the same kind in the folder of the focused one",
          cwd_ok, f"new window: {bool(new)}, its shell's folder: {cwds}")
    for v in new or []:
        g.run("kill", str(v["pid"]))
    pane.proc.terminate()
    # Strata's Ctrl+T ("open a terminal here"), with TERMINAL naming this terminal.
    env = dict(os.environ, TERMINAL=TERMINAL)
    g.run("pkill", "-x", "strata")
    strata = subprocess.Popen(["strata", folder], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              start_new_session=True)
    procs.append(strata)
    sv = g.wait_for(lambda: next((v for v in g.views() if "strata" in (v.get("app_id") or "").lower()), None), timeout=30)
    if sv:
        g.ipc("scottland/present", {"window": sv["id"]})
        if not g.wait_for(lambda: (g.view(sv["id"]) or {}).get("focused"), timeout=10):
            raise RuntimeError("Strata did not receive focus before the folder shortcut")
        before = ids()
        g.press("KEY_LEFTCTRL", "KEY_T")
        new = g.wait_for(lambda: [v for v in g.views() if v["id"] not in before and v.get("app_id") == APP_ID], timeout=20)
        cwd_ok = new and g.wait_for(correct_cwd, timeout=10)
        check("Strata's Ctrl+T opens this terminal in the folder Strata shows", cwd_ok,
              f"new window: {bool(new)}, its shells' folders: {cwds}")
        for v in new or []:
            if v.get("pid") != sv.get("pid"):
                g.run("kill", str(v["pid"]))
    else:
        check("Strata's Ctrl+T opens this terminal in the folder Strata shows", False, "Strata didn't open")
    strata.terminate()


def glyphs():
    pane = Pane()
    pane.present()
    nerd, emoji, missing = "", "\U0001f642", "\U0010fffd"
    before = ppm(pane.frame())[2]
    pane.completed(f"clear; printf 'X MMMMMMMMMMMMMMMM\\n\\nX {nerd * 6}\\n\\nX {emoji * 6}\\n\\nX {missing * 12}\\n'")
    f = pane.frame()
    w, h, px = settled_pixels(pane, previous=before)
    bg = pixel((w, h, px), w - 20, h - 20)
    ink = lambda x, y: sum(abs(a - b) for a, b in zip(pixel((w, h, px), x, y), bg)) > 90
    rows = [y for y in range(h) if any(ink(x, y) for x in range(0, min(w, 400), 2))]
    bands, start = [], None
    for y in range(h + 1):
        on = y in rows
        if on and start is None:
            start = y
        if not on and start is not None:
            bands.append((start, y))
            start = None
    g.shot(f"{TERMINAL}-glyphs.png")
    if not check("four lines of text are on screen (X markers)", len(bands) >= 4, f"{len(bands)} bands: {bands[:6]}"):
        pane.proc.terminate()
        return
    # Where the glyphs start: the first ink after the X marker's gap, on the M line.
    y0, y1 = bands[0]
    cols = [x for x in range(w) if any(ink(x, y) for y in range(y0, y1))]
    gap = next(i for i in range(1, len(cols)) if cols[i] - cols[i - 1] > 3)
    x0 = cols[gap]

    def mask(band):
        return [(x, y) for y in range(*band) for x in range(x0, min(w, x0 + 300)) if ink(x, y)]

    def colored(band):
        n = 0
        for y in range(*band):
            for x in range(x0, min(w, x0 + 300)):
                p = pixel((w, h, px), x, y)
                n += max(p) - min(p) > 80
        return n

    m_text, m_nerd, m_emoji, m_missing = (mask(b) for b in bands[:4])
    rel = lambda m: {(x - x0, y - m[0][1]) for x, y in m} if m else set()
    differs = len(rel(m_nerd) ^ rel(m_missing)) > 0.2 * max(1, len(rel(m_nerd)))
    check("text renders", len(m_text) > 50, f"{len(m_text)} ink pixels")
    check("Nerd Font symbols render (not drawn like a missing glyph)", len(m_nerd) > 50 and differs,
          f"{len(m_nerd)} ink pixels vs {len(m_missing)} for a missing glyph")
    check("emoji render in color", colored(bands[2]) > 40, f"{colored(bands[2])} colored pixels")
    pane.proc.terminate()


def copy_paste():
    # Paste: the clipboard into the terminal with Ctrl+Shift+V.
    pane = Pane()
    token = "paste" + secrets.token_hex(6)
    out = f"{TMP}/pasted"
    # Keep the clipboard owner in an owned process group, instead of leaving wl-copy's daemon.
    copier = subprocess.Popen(["wl-copy", "--foreground", token], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, start_new_session=True)
    procs.append(copier)
    if not g.wait_for(lambda: clipboard() == token, timeout=10):
        raise RuntimeError("the clipboard owner did not publish the paste token")
    pane.present()
    pane.send(f"head -n1 > {out}")
    if not g.wait_for(lambda: os.path.exists(out), timeout=10):
        raise RuntimeError("the paste reader did not open its output file")
    before = ppm(pane.frame())[2]
    g.press("KEY_LEFTCTRL", "KEY_LEFTSHIFT", "KEY_V")
    settled_pixels(pane, previous=before)
    g.press("KEY_ENTER")
    got = g.wait_for(lambda: os.path.exists(out) and open(out).read().strip(), timeout=10)
    check("Ctrl+Shift+V pastes the clipboard", got == token, f"{got!r}")
    # Copy a selection: double-click a word, Ctrl+Shift+C.
    word = "copyme" + secrets.token_hex(8)
    before = ppm(pane.frame())[2]
    pane.completed(f"clear; printf '%s\\n' {word}")
    settled_pixels(pane, previous=before)
    click(pane.frame(), dx=40, dy=10, double=True)
    g.press("KEY_LEFTCTRL", "KEY_LEFTSHIFT", "KEY_C")
    copied = g.wait_for(lambda: clipboard() == word and word, timeout=5)
    check("double-click and Ctrl+Shift+C copy a word", copied, f"clipboard {clipboard()!r}")
    # OSC 52 from a program in the terminal.
    token = "osc" + secrets.token_hex(6)
    pane.send(f"printf '\\033]52;c;{base64.b64encode(token.encode()).decode()}\\007'")
    check("OSC 52 from a program sets the clipboard", g.wait_for(lambda: clipboard() == token, timeout=5), f"{clipboard()!r}")
    pane.proc.terminate()
    # Inside tmux: tmux's own copy (set-buffer -w sends OSC 52 to the terminal), and a program's OSC 52.
    tp = Pane("tmux", session="gclip")
    tp.present()
    token = "tmuxbuf" + secrets.token_hex(6)
    tp.send(f"tmux set-buffer -w {token}")
    check("tmux's copy reaches the clipboard (OSC 52 through the terminal)",
          g.wait_for(lambda: clipboard() == token, timeout=5), f"{clipboard()!r}")
    setting = g.run("tmux", "-L", "gooarchy-terminal-check", "show-options", "-s", "set-clipboard")
    token = "tmuxapp" + secrets.token_hex(6)
    tp.send(f"printf '\\033]52;c;{base64.b64encode(token.encode()).decode()}\\007'")
    ok = g.wait_for(lambda: clipboard() == token, timeout=5)
    check(f"OSC 52 from a program inside tmux reaches the clipboard (Gooarchy's tmux.conf: {setting})", ok, f"{clipboard()!r}")
    tp.proc.terminate()


def performance():
    # One warm-up launch (cold caches), then five measured: launch -> window in Scottland's model,
    # and the terminal process's proportional memory (PSS) two seconds later.
    times, mem, opened = [], [], []
    for i in range(6):
        t0 = time.monotonic()
        p = launch(["sleep", "30"])
        v = window_of(p.pid, timeout=30)
        opened.append(bool(v))
        dt = time.monotonic() - t0
        time.sleep(2)
        kib = pss_kib(p.pid)
        p.terminate()
        p.wait(timeout=10)
        if i and v:
            times.append(dt)
            if kib is not None:
                mem.append(kib)
    metrics["start_seconds"] = {"median": round(statistics.median(times), 3) if times else None,
                                "max": round(max(times), 3) if times else None, "runs": times}
    metrics["pss_mib"] = {"median": round(statistics.median(mem) / 1024, 1) if mem else None,
                          "max": round(max(mem) / 1024, 1) if mem else None, "samples": len(mem)}
    observe("start time (launch to window, s)", metrics["start_seconds"])
    observe("memory (PSS of the terminal process, MiB)", metrics["pss_mib"])
    check("starts and opens a window every time, including warm-up", all(opened), f"{sum(opened)}/6")


def main():
    shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(TMP)
    os.makedirs(OUT, exist_ok=True)
    if not g.enter_session():
        check("the session is reachable with virtual input", False)
        return
    observe("version", g.run(TERMINAL, "--version").splitlines()[0] if shutil.which(TERMINAL) else "not installed")
    for part in (bells, identity, colors, folders, glyphs, copy_paste, performance):
        try:
            part()
        except Exception as error:
            check(f"{part.__name__} ran to the end", False, f"{type(error).__name__}: {error}")


if __name__ == "__main__":
    signal.signal(signal.SIGALRM, lambda *a: (_ for _ in ()).throw(HangDeadline("terminal check deadline")))
    signal.alarm(1200)
    try:
        main()
    except BaseException as error:
        check("the terminal check ran to the end", False, f"{type(error).__name__}: {error}")
    finally:
        signal.alarm(0)
        for p in procs:
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
        g.run("gooarchy-theme", "light")
        g.run("tmux", "-L", "gooarchy-terminal-check", "kill-server")
        for p in procs:
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                p.wait(timeout=5)
        failed = sum(not r["ok"] for r in results)
        with open(os.path.join(OUT, f"terminal-{TERMINAL}.json"), "w") as f:
            json.dump({"terminal": TERMINAL, "failures": failed, "results": results, "observations": observations,
                       "metrics": metrics}, f, indent=1)
        log(f"{len(results) - failed}/{len(results)} checks passed")
    sys.exit(1 if failed else 0)
