# linux-gooarchy

Gooarchy's kernel: Omarchy's linux-omarchy (patches and config) at a pinned commit, tracking
Omarchy's kernel releases, with Gooarchy's own fixes on top ([NOTICE.md](NOTICE.md) says what and
from whom). It doesn't use Omarchy's package repository: it builds from Omarchy's public sources.

Status: **not Gooarchy's default kernel.** It becomes the default only after it passes the VM test
and real hardware. Until then it is opt-in, and nothing installs it without being asked.

| File | What |
|---|---|
| `PKGBUILD` | The package. Its pinned block (Omarchy commit, kernel version, Omarchy's release, Gooarchy's release, Gooarchy's patch list, checksums) is written by `bump.py`; the rest is Omarchy's build and package steps with a `prepare()` that checks and applies both patch sets |
| `patches/` | Gooarchy's patches, applied after Omarchy's in file-name order |
| `keys/pgp/` | Signing keys from omarchy-pkgs: kernel release signers and Omarchy's patch signer |
| `bump.py` | Moves the pin to an Omarchy release, or refreshes Gooarchy's patch list |
| `check-patches.sh` | Checks every source and applies the whole patch series, without building; runs on any Linux machine |
| `build.sh` | Builds the packages on an x86_64 build or test host; never installs |

Version: `<kernel>-<Omarchy release>.<Gooarchy release>`, e.g. `7.2.5-6.1`; the running kernel
reports `7.2.5-6.1-gooarchy`. Gooarchy's release starts at 1 for each Omarchy release and counts
up when Gooarchy's patches change.

## Bumping (each Omarchy kernel release)

An agent can run this whole procedure. Build and test only on designated build/test hosts, never
on a machine someone uses daily.

1. **See what Omarchy released.** `git log` of `pkgbuilds/linux-omarchy` in omacom/omarchy-pkgs;
   Omarchy's kernel releases are commits titled like "Update Linux kernel release to v7.2.5-6".
2. **Move the pin:** `packaging/linux-gooarchy/bump.py` (newest linux-omarchy commit) or
   `bump.py <commit>`. It prints Omarchy's commits since the old pin and updates the pinned block,
   keys and license.
   - If it stops with **exit 3**, Omarchy changed its PKGBUILD beyond sources and versions (the
     diff is printed). Port each change into our `PKGBUILD`: build/package steps as they are,
     `prepare()` changes into ours (ours checks Omarchy's pin and signatures and applies both patch
     sets; keep that), new `makedepends`, new signing keys in `validpgpkeys`. Then
     `bump.py --accept <commit>`.
3. **Review Gooarchy's patches** against the new kernel: if one is now in Omarchy's kernel (in
   the kernel release itself, or in one of Omarchy's patches), delete it from `patches/`, update
   the table in `NOTICE.md`, and run `bump.py --refresh`.
4. **Check the series:** `packaging/linux-gooarchy/check-patches.sh` (any Linux machine with
   network). If a Gooarchy patch no longer applies, rebase it onto the new tree (keep its header),
   or drop it if upstream solved the problem differently; then `bump.py --refresh` and check again.
5. **Build** on an x86_64 build/test host: `packaging/linux-gooarchy/build.sh`. A build failure in
   Gooarchy's code is fixed in `patches/`; one in Omarchy's is reported to Omarchy and the bump
   waits (or pins the previous commit).
6. **VM test** with the kernel (`tests/vm/run.sh` with the kernel opt-in, once wired), on the same
   host.
7. **Commit** `packaging/linux-gooarchy/` with a message naming Omarchy's release and commit and
   any patch added or dropped.

## Adding a fix

Put the patch in `patches/` with the next number (a `git format-patch`/mbox file with its author,
sign-offs and a `Link:` to where it was posted), add a row to `NOTICE.md`, run
`bump.py --refresh` (it lists the patch, adds its checksums and counts Gooarchy's release up),
then steps 4 to 7 above.
