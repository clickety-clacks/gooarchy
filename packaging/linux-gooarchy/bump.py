#!/usr/bin/env python3
"""Move linux-gooarchy to an Omarchy kernel release, or refresh Gooarchy's own patch list.

  bump.py              pin Omarchy's newest linux-omarchy commit (omacom/omarchy-pkgs, default branch)
  bump.py COMMIT       pin that commit
  bump.py --refresh    keep the pin; re-list patches/ and their checksums (after adding, changing or
                       removing one of Gooarchy's patches)
  bump.py --accept COMMIT   pin COMMIT even though Omarchy's PKGBUILD changed beyond sources and
                       versions; only after porting those changes into ours (README.md, "Bumping")

What it does: reads Omarchy's linux-omarchy PKGBUILD at the target commit; copies its kernel
version, release number and kernel tarball checksums into the pinned block of our PKGBUILD;
resets Gooarchy's release to 1 when Omarchy's version or release changed (otherwise counts it up);
refreshes keys/pgp/ and LICENSE.omarchy-pkgs from Omarchy; and lists patches/ with checksums.
It compares Omarchy's PKGBUILD between the old and new pin with its source list, checksums and
version lines left out: anything else that changed (build or package steps, dependencies,
signing keys) is printed, and the bump stops (exit 3) until it has been ported and --accept used.
It never builds anything. Next steps are printed at the end.
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PKGBUILD = HERE / "PKGBUILD"
REPO = "https://github.com/omacom/omarchy-pkgs.git"
SUBDIR = "pkgbuilds/linux-omarchy"
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "gooarchy" / "omarchy-pkgs"


def git(*args, binary=False):
    out = subprocess.run(["git", "-C", str(CACHE), *args], capture_output=True, check=True).stdout
    return out if binary else out.decode()


def fetch():
    if (CACHE / ".git").exists():
        git("fetch", "--quiet", "origin")
    else:
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--quiet", REPO, str(CACHE)], check=True)


def pinned():
    text = PKGBUILD.read_text()
    get = lambda name: re.search(rf"^{name}=(\S+)", text, re.M).group(1)
    return {"commit": get("_omarchy_commit"), "pkgver": get("pkgver"), "pkgrel": get("_omarchy_pkgrel"),
            "rel": int(get("_gooarchy_rel")), "text": text}


def array(text, name):
    m = re.search(rf"^{name}=\((.*?)\)", text, re.S | re.M)
    return re.findall(r"'([^']*)'", m.group(1)) if m else []


def structure(text):
    """Omarchy's PKGBUILD without what a release changes: sources, checksums, version lines."""
    text = re.sub(r"^(source|source_x86_64|sha256sums|b2sums|sha256sums_x86_64|b2sums_x86_64)=\(.*?\)\n", "",
                  text, flags=re.S | re.M)
    text = re.sub(r"^(pkgver|pkgrel)=.*\n", "", text, flags=re.M)
    text = re.sub(r"^# https://www.kernel.org/pub/linux/kernel/.*\n", "", text, flags=re.M)
    return text


def digest(path, algorithm):
    h = hashlib.new(algorithm)
    h.update(path.read_bytes())
    return h.hexdigest()


def patches():
    files = sorted((HERE / "patches").glob("*.patch"))
    return files, [digest(f, "sha256") for f in files], [digest(f, "blake2b") for f in files]


def write_block(commit, pkgver, pkgrel, rel, kernel_sha, kernel_b2):
    files, sha, b2 = patches()
    quote = lambda xs: " ".join(f"'{x}'" for x in xs)
    block = (f"_omarchy_commit={commit}\npkgver={pkgver}\n_omarchy_pkgrel={pkgrel}\n_gooarchy_rel={rel}\n"
             "_gooarchy_patches=(\n" + "".join(f"  {f.name}\n" for f in files) + ")\n"
             f"_kernel_sha256sums=({quote(kernel_sha)})\n_kernel_b2sums=({quote(kernel_b2)})\n"
             f"_patch_sha256sums=({quote(sha)})\n_patch_b2sums=({quote(b2)})\n")
    text = PKGBUILD.read_text()
    text = re.sub(r"(# --- pinned by bump\.py -+\n).*?(# --- end of pinned block)", lambda m: m.group(1) + block + m.group(2),
                  text, flags=re.S)
    PKGBUILD.write_text(text)
    return files


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    refresh, accept = "--refresh" in sys.argv, "--accept" in sys.argv
    current = pinned()
    if refresh:
        files, sha, b2 = patches()
        old_sha = array(current["text"], "_patch_sha256sums")
        rel = current["rel"] + (1 if sha != old_sha else 0)
        files = write_block(current["commit"], current["pkgver"], current["pkgrel"], rel,
                            array(current["text"], "_kernel_sha256sums"), array(current["text"], "_kernel_b2sums"))
        print(f"Gooarchy's patches: {', '.join(f.name for f in files) or 'none'}; release {current['pkgver']}-"
              f"{current['pkgrel']}.{rel}{' (changed)' if sha != old_sha else ' (unchanged)'}")
        return 0

    fetch()
    branch = git("symbolic-ref", "--short", "refs/remotes/origin/HEAD").strip()
    target = git("rev-parse", args[0] if args else git("log", "-1", "--format=%H", branch, "--", SUBDIR).strip()).strip()
    theirs = git("show", f"{target}:{SUBDIR}/PKGBUILD")
    before = git("show", f"{current['commit']}:{SUBDIR}/PKGBUILD")
    pkgver = re.search(r"^pkgver=(\S+)", theirs, re.M).group(1)
    pkgrel = re.search(r"^pkgrel=(\S+)", theirs, re.M).group(1)
    print(f"Omarchy's linux-omarchy: {current['pkgver']}-{current['pkgrel']} at {current['commit'][:12]} -> "
          f"{pkgver}-{pkgrel} at {target[:12]}")
    print(git("log", "--oneline", f"{current['commit']}..{target}", "--", SUBDIR) or "(no new commits in linux-omarchy)",
          flush=True)

    if structure(before) != structure(theirs):
        old, new = Path("/tmp/linux-gooarchy-bump.old"), Path("/tmp/linux-gooarchy-bump.new")
        old.write_text(structure(before))
        new.write_text(structure(theirs))
        print("\nOmarchy changed its PKGBUILD beyond sources and versions:\n", flush=True)
        subprocess.run(["diff", "-u", str(old), str(new)])
        old.unlink()
        new.unlink()
        if not accept:
            print("\nPort what applies into our PKGBUILD (prepare/build/package, makedepends, keys), then run:\n"
                  f"  {sys.argv[0]} --accept {target}")
            return 3

    n = 4 if "rc" in pkgver else 2
    kernel_sha, kernel_b2 = array(theirs, "sha256sums")[:n], array(theirs, "b2sums")[:n]
    same = (pkgver, pkgrel) == (current["pkgver"], current["pkgrel"])
    rel = current["rel"] + 1 if same and target != current["commit"] else (current["rel"] if same else 1)

    # Omarchy's signing keys and license, as of the new pin.
    keys = HERE / "keys" / "pgp"
    shutil.rmtree(keys)
    keys.mkdir(parents=True)
    for name in git("ls-tree", "--name-only", f"{target}:{SUBDIR}/keys/pgp").split():
        (keys / name).write_bytes(git("show", f"{target}:{SUBDIR}/keys/pgp/{name}", binary=True))
    (HERE / "LICENSE.omarchy-pkgs").write_bytes(git("show", f"{target}:LICENSE", binary=True))

    files = write_block(target, pkgver, pkgrel, rel, kernel_sha, kernel_b2)
    print(f"\nPinned {target[:12]}: linux-gooarchy {pkgver}-{pkgrel}.{rel}, with Gooarchy's "
          f"{', '.join(f.name for f in files) or 'no patches'}.")
    print("Next (README.md, \"Bumping\"): packaging/linux-gooarchy/check-patches.sh on any machine with network;\n"
          "build.sh on an x86_64 build/test host; the VM test with the kernel; update NOTICE.md if a Gooarchy\n"
          "patch reached Omarchy's kernel (then drop it and run bump.py --refresh); commit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
