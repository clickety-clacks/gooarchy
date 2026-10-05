#!/usr/bin/env python3
"""Look for developer-network details in this repository: the whole reachable history by default.

  tools/privacy-check.py            every commit reachable from any ref: commit messages, file
                                    names, the text of every blob, and image metadata
  tools/privacy-check.py --tree     only the files in the working tree (before committing)

Two kinds of patterns:
  - generic ones, here: private and tailnet IPv4 ranges (except QEMU's own 10.0.2.x guest network
    and loopback), tailnet and .local DNS names, home directory paths, MAC addresses;
  - the names that are actually private (host names, user names, network names), from a deny list
    that is NOT in the repository: $GOOARCHY_PRIVACY_DENYLIST, else
    ~/.config/gooarchy/privacy-denylist (one case-insensitive regular expression per line, #
    comments). Matches of deny-list entries are reported by entry number, never echoed, so the
    output of this check can be shared.

Images are checked for embedded metadata (EXIF, XMP, PNG text chunks); what an image shows can't be
checked automatically and is listed for a person to look at. Commit author and committer
identities and Co-Authored-By trailers are attribution, not network details, and are skipped.
Exits 1 if anything is found.
"""
import os
import re
import subprocess
import sys

GENERIC = [
    ("private IPv4 (10.x, not QEMU's 10.0.2.x)", r"\b10\.(?!0\.2\.)\d{1,3}\.\d{1,3}\.\d{1,3}\b"),
    ("private IPv4 (172.16-31.x)", r"\b172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b"),
    ("private IPv4 (192.168.x)", r"\b192\.168\.\d{1,3}\.\d{1,3}\b"),
    ("tailnet/CGNAT IPv4 (100.64/10)", r"\b100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b"),
    ("tailnet DNS name", r"\b[\w-]+\.ts\.net\b"),
    ("tailnet IPv6", r"\bfd7a:115c:a1e0:"),
    (".local/.lan host name", r"\b[\w-]+\.(local|lan|home\.arpa)\b"),
    ("home directory path", r"(/home/[a-z_][\w-]*|/Users/[A-Za-z][\w-]*)"),
    ("MAC address", r"\b([0-9a-f]{2}:){5}[0-9a-f]{2}\b"),
]
# Generic matches that are known and fine (documentation placeholders).
ALLOWED = [r"/home/<user>", r"/home/user\b", r"example-host"]
IMAGE_EXT = (".png", ".webp", ".jpg", ".jpeg", ".gif")
TRAILER = re.compile(r"^(Co-Authored-By|Signed-off-by):", re.I | re.M)


def git(*args, binary=False):
    out = subprocess.run(["git", *args], capture_output=True, check=True).stdout
    return out if binary else out.decode(errors="replace")


def denylist():
    path = os.environ.get("GOOARCHY_PRIVACY_DENYLIST") or os.path.expanduser("~/.config/gooarchy/privacy-denylist")
    if not os.path.exists(path):
        print(f"note: no private deny list at {path}; checking generic patterns only", file=sys.stderr)
        return []
    entries = []
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#"):
            entries.append(re.compile(line, re.I))
    return entries


def scan_text(text, where, deny, findings):
    for label, pattern in GENERIC:
        for m in re.finditer(pattern, text, re.I):
            if any(re.search(a, text[max(0, m.start() - 5):m.end() + 5]) for a in ALLOWED):
                continue
            line = text.count("\n", 0, m.start()) + 1
            findings.append(f"{where}:{line}: {label}: {m.group(0)}")
    for number, pattern in enumerate(deny, 1):
        for m in pattern.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            findings.append(f"{where}:{line}: private deny-list entry #{number}")


def image_metadata(data):
    found = []
    if data.startswith(b"\x89PNG"):
        for chunk in (b"tEXt", b"iTXt", b"zTXt", b"eXIf"):
            if chunk in data:
                found.append(chunk.decode())
    elif data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        for chunk in (b"EXIF", b"XMP "):
            if chunk in data:
                found.append(chunk.decode().strip())
    elif data[:2] == b"\xff\xd8":
        if b"Exif\x00" in data:
            found.append("EXIF")
        if b"http://ns.adobe.com/xap" in data:
            found.append("XMP")
    return found


def main():
    os.chdir(git("rev-parse", "--show-toplevel").strip())
    deny = denylist()
    findings, images = [], set()
    if "--tree" in sys.argv:
        files = git("ls-files", "-co", "--exclude-standard", "-z").split("\0")
        for path in filter(None, files):
            if not os.path.isfile(path):
                continue
            data = open(path, "rb").read()
            scan_text(path, f"(file name) {path}", deny, findings)
            if path.lower().endswith(IMAGE_EXT):
                images.add(path)
                for meta in image_metadata(data):
                    findings.append(f"{path}: image metadata {meta}")
            elif b"\0" not in data[:8192]:
                scan_text(data.decode(errors="replace"), path, deny, findings)
    else:
        commits = git("rev-list", "--all").split()
        for commit in commits:
            message = git("log", "-1", "--format=%B", commit)
            message = TRAILER.sub("", message)
            scan_text(message, f"commit {commit[:12]} message", deny, findings)
        seen = set()
        for line in git("rev-list", "--objects", "--all").splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            sha, path = parts
            if git("cat-file", "-t", sha).strip() != "blob":
                continue
            scan_text(path, f"(file name) {path}", deny, findings)
            if sha in seen:
                continue
            seen.add(sha)
            data = git("cat-file", "-p", sha, binary=True)
            where = f"blob {sha[:12]} ({path})"
            first = git("log", "--all", "--format=%h", "--find-object", sha).split()
            if first:
                where += f", in commit {first[-1]}"
            if path.lower().endswith(IMAGE_EXT):
                images.add(f"{path} (blob {sha[:12]})")
                for meta in image_metadata(data):
                    findings.append(f"{where}: image metadata {meta}")
            elif b"\0" not in data[:8192]:
                scan_text(data.decode(errors="replace"), where, deny, findings)
        print(f"checked {len(commits)} commits and {len(seen)} blobs", file=sys.stderr)
    for f in dict.fromkeys(findings):
        print(f)
    if images:
        print(f"look at these images yourself (what they show isn't checked): {', '.join(sorted(images))}",
              file=sys.stderr)
    print(f"{len(set(findings))} finding(s)", file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
