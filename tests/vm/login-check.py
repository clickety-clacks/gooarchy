#!/usr/bin/env python3
"""Log in on the guest's consoles the way a person does, by typing at getty through QEMU's keyboard
(QMP send-key), and check what each login starts. Run by tests/vm/run.sh login-check, on the host.

  login-check.py QMP_SOCKET OUTDIR -- SSH-COMMAND...

The SSH command reaches the guest as its admin user (passwordless sudo), to set up accounts and to
observe. Covered: a password login on tty1 starts Scottland; root on tty1 stays a console; the
~/.config/gooarchy/no-session opt-out; a second user gets Scottland and Gooarchy's defaults; a login
on tty2 stays a console. Autologin is turned off for this and put back afterwards. Writes
login-check.json to OUTDIR; exits 1 if a check fails.
"""
import json
import os
import secrets
import socket
import subprocess
import sys
import time

QMP, OUT = sys.argv[1], sys.argv[2]
SSH = sys.argv[sys.argv.index("--") + 1:]
results = []


def log(message):
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


def check(name, ok, detail=""):
    results.append({"check": name, "ok": bool(ok), "detail": detail})
    log(f"{'PASS' if ok else 'FAIL'} {name}{': ' + str(detail) if detail else ''}")


def guest(command, timeout=60):
    r = subprocess.run(SSH + [command], capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip()


def wait_for(predicate, timeout=60, interval=1):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    return None


class Qmp:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(20)
        self.sock.connect(path)
        self.f = self.sock.makefile("rw")
        self.f.readline()
        self.call("qmp_capabilities")

    def call(self, command, arguments=None):
        self.f.write(json.dumps({"execute": command, **({"arguments": arguments} if arguments else {})}) + "\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise EOFError("QEMU closed QMP")
            reply = json.loads(line)
            if "event" not in reply:
                return reply

    def keys(self, *names):
        self.call("send-key", {"keys": [{"type": "qcode", "data": n} for n in names], "hold-time": 30})
        time.sleep(0.04)

    PLAIN = {" ": "spc", "-": "minus", ".": "dot", "/": "slash", "\n": "ret"}
    SHIFTED = {"_": "minus", "!": "1", "@": "2", "#": "3", "%": "5", "+": "equal", ":": "semicolon"}

    def type(self, text):
        for ch in text:
            if ch.isdigit() or (ch.isalpha() and ch.islower()):
                self.keys(ch)
            elif ch.isalpha():
                self.keys("shift", ch.lower())
            elif ch in self.SHIFTED:
                self.keys("shift", self.SHIFTED[ch])
            elif self.PLAIN.get(ch):
                self.keys(self.PLAIN[ch])
            else:
                raise ValueError(f"can't type {ch!r}")


def tty_sessions(tty):
    """(session, user) of the login sessions on a console."""
    out = guest("loginctl list-sessions --no-legend")
    return [(f[0], f[2]) for f in (l.split() for l in out.splitlines()) if tty in f]


def wayfire_for(user):
    return guest(f"pgrep -u {user} -x wayfire")


def at_login_prompt(tty):
    return guest(f"pgrep -t {tty} -x agetty")


def logout_console(tty):
    """End whatever login is on a console and get its getty prompt back."""
    for sid, _ in tty_sessions(tty):
        guest(f"sudo loginctl terminate-session {sid}")
    guest(f"sudo systemctl restart getty@{tty}")
    return wait_for(lambda: at_login_prompt(tty), timeout=30)


def login(qmp, tty, user, password):
    qmp.keys("ctrl", "alt", "f1" if tty == "tty1" else "f2")
    time.sleep(1)
    if not wait_for(lambda: at_login_prompt(tty), timeout=30):
        return False
    qmp.type(user + "\n")
    time.sleep(1.5)
    qmp.type(password + "\n")
    return wait_for(lambda: any(u == user for _, u in tty_sessions(tty)), timeout=30)


def main():
    os.makedirs(OUT, exist_ok=True)
    qmp = Qmp(QMP)
    # Throwaway passwords for this run's accounts (typed at the console, never stored in the repo).
    pw = {"arch": "Vm" + secrets.token_hex(6), "root": "Vm" + secrets.token_hex(6), "ada": "Vm" + secrets.token_hex(6)}
    guest("sudo useradd -m ada 2>/dev/null; "
          + "; ".join(f"echo '{u}:{p}' | sudo chpasswd" for u, p in pw.items()))
    dropin = "/etc/systemd/system/getty@tty1.service.d/gooarchy-autologin.conf"
    saved = guest(f"sudo cat {dropin} 2>/dev/null | base64 -w0")
    guest(f"sudo rm -f {dropin} && sudo systemctl daemon-reload")
    check("setup: autologin off, tty1 back at a login prompt", logout_console("tty1"))

    # 1. A password login on tty1 starts Scottland.
    ok = login(qmp, "tty1", "arch", pw["arch"])
    started = ok and wait_for(lambda: wayfire_for("arch"), timeout=90)
    check("a password login on tty1 starts Scottland", started, f"wayfire pid {started or 'none'}")
    if started:
        guest("pkill -u arch -x wayfire")  # what Super+Shift+Escape runs
        back = wait_for(lambda: at_login_prompt("tty1") and not tty_sessions("tty1"), timeout=30)
        check("logging out of that session returns tty1 to the login prompt", back)
    logout_console("tty1")

    # 2. root on tty1 stays a rescue console.
    ok = login(qmp, "tty1", "root", pw["root"])
    time.sleep(10)
    check("root logging in on tty1 gets a console, not Scottland", ok and not wayfire_for("root"),
          f"root session: {bool(ok)}, wayfire for root: {wayfire_for('root') or 'none'}")
    logout_console("tty1")

    # 3. The opt-out file.
    guest("mkdir -p ~/.config/gooarchy && touch ~/.config/gooarchy/no-session")
    ok = login(qmp, "tty1", "arch", pw["arch"])
    time.sleep(10)
    check("with ~/.config/gooarchy/no-session, tty1 stays a console", ok and not wayfire_for("arch"),
          f"session: {bool(ok)}, wayfire: {wayfire_for('arch') or 'none'}")
    guest("rm -f ~/.config/gooarchy/no-session")
    logout_console("tty1")

    # 4. A second user gets Scottland and Gooarchy's per-user defaults at their first login.
    ok = login(qmp, "tty1", "ada", pw["ada"])
    started = ok and wait_for(lambda: wayfire_for("ada"), timeout=90)
    defaults = started and wait_for(lambda: guest("sudo test -f ~ada/.config/ghostty/config && "
                                                  "sudo ls ~ada/.local/state/gooarchy/flavorings | wc -l"), timeout=60)
    check("a second user's tty1 login starts Scottland and fills in their defaults",
          started and defaults and int(defaults) >= 5, f"wayfire {started or 'none'}, defaults applied: {defaults}")
    guest("sudo pkill -u ada -x wayfire")
    logout_console("tty1")

    # 5. Another console stays a console.
    ok = login(qmp, "tty2", "arch", pw["arch"])
    time.sleep(10)
    check("a login on tty2 stays a console", ok and not wayfire_for("arch"),
          f"session: {bool(ok)}, wayfire: {wayfire_for('arch') or 'none'}")
    logout_console("tty2")
    qmp.keys("ctrl", "alt", "f1")

    # Put autologin back as it was, so the disk boots into the desktop again.
    if saved:
        guest(f"echo {saved} | base64 -d | sudo install -Dm644 /dev/stdin {dropin} && sudo systemctl daemon-reload")
        logout_console("tty1")
        check("autologin restored: tty1 is back in Scottland", wait_for(lambda: wayfire_for("arch"), timeout=90))

    failed = sum(not r["ok"] for r in results)
    with open(os.path.join(OUT, "login-check.json"), "w") as f:
        json.dump({"failures": failed, "results": results}, f, indent=1)
    log(f"{len(results) - failed}/{len(results)} login checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
