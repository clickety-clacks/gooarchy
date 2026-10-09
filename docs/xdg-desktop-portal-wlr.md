# xdg-desktop-portal-wlr: Gooarchy's build, from our own fork

Scottland sends screen sharing and screenshot requests to xdg-desktop-portal-wlr (its
`scottland-portals.conf`). Arch's xdg-desktop-portal-wlr 0.8.4 loses most shared streams under
Wayfire: in Scottland's portal test the stream froze after one frame or the portal was
disconnected in most runs (4 of 6 on 2026-10-06; Omarchy's package mirror then served 0.8.2,
which failed 3 of 6). Two small fixes remove both failures (20 of 20 runs with this package). We maintain them in our own
public fork, and Gooarchy builds its package `xdg-desktop-portal-wlr-gooarchy`
(`packaging/arch/xdg-desktop-portal-wlr/`) from the fork's tagged releases.

## The fork

- Repository: https://github.com/clickety-clacks/xdg-desktop-portal-wlr, a fork of
  https://github.com/emersion/xdg-desktop-portal-wlr. Upstream's MIT license and credit are kept.
- Branch `gooarchy` (the fork's default branch): upstream's v0.8.4 tag plus the fixes, and the
  fork's README and CONTRIBUTING.md. Both open with its contribution policy: AI-written
  submissions are welcome; every submission is adversarially reviewed; too many AI-written
  submissions that fail that review may result in a ban on having submissions accepted.
- Release: `v0.8.4-gooarchy.1`. The package builds the GitHub archive of that tag, checked by its
  sha512 in the PKGBUILD; its pacman version is `0.8.4.gooarchy.1`.
- The fixes are not sent upstream (ruling 2026-10-06, Scottland `docs/rulings.md`; it replaces
  the 10-05 plan to get them accepted upstream).

| Commit | What it fixes |
|---|---|
| 11cb9b2 screencast: keep an in-flight capture across a pause | the `duplicate_frame` protocol error and the stream frozen after its first frame |
| ebbbe6a screencast: don't destroy the process retry timer twice | a crash when a starved session closes |

A new fork release: tag it on `gooarchy` (`v<upstream version>-gooarchy.<n>`), then update
`_upstreamver`/`_tag`, `pkgver` and the tarball's sha512 in the PKGBUILD, and run Scottland's
`tests/portal-test.py` against the built package. The Omarchy adapter's setup pins this recipe
by Gooarchy commit and checksum, so it moves its pin too (below).

Upstream context, for reading upstream changes against the fork:

- The cause dates from #370, "drive the Pipewire graph by ourselves" (merged, in 0.8.3):
  https://github.com/emersion/xdg-desktop-portal-wlr/pull/370
- The duplicate-frame error: #380, a guard closed unmerged by its own author
  (https://github.com/emersion/xdg-desktop-portal-wlr/pull/380), and #340, an open guard the
  maintainer said leaves damage-tracking problems
  (https://github.com/emersion/xdg-desktop-portal-wlr/pull/340).
- The retry timer the second fix fixes came with #397 (merged, in 0.8.4):
  https://github.com/emersion/xdg-desktop-portal-wlr/pull/397
- Related, not the same fix: #400, "Screen sharing stopped working in 0.8.4"
  (https://github.com/emersion/xdg-desktop-portal-wlr/issues/400), and #403, a backport of master's
  wlr-screencopy fixes for a 0.8.5 (https://github.com/emersion/xdg-desktop-portal-wlr/pull/403).
  #403 changes only the wlr-screencopy path; Wayfire 0.11 is captured through
  ext-image-copy-capture, which the first fix fixes. Whether a 0.8.5 with #403 alone works under
  Wayfire is not tested.

## Delivery

- **Gooarchy:** `install/packaging/xdg-desktop-portal-wlr.sh` builds the package from this checkout
  and installs it before Scottland, whose package depends on `xdg-desktop-portal-wlr`; this
  package provides that name, so Scottland's dependency never pulls Arch's broken one. If Arch's
  is already installed, it is replaced in the same pacman transaction and the installer says so.
  `pacman -Syu` keeps Gooarchy's build: Arch's package doesn't declare that it replaces it.
  Running `./install.sh` again rebuilds it. Screen sharing also needs Scottland's
  `scottland-portals.conf`. The 2026.11 release line selects the unreleased Scottland `0.3` branch
  by name; its current remote head is `e5f0f439680af0efdcedc9ab7a5b014f12a79056`, where the config
  is blob `c6ac951050a7cdeecad5fdd34126c9c03c7e0343`, and the package recipe installs it as
  `/usr/share/xdg-desktop-portal/scottland-portals.conf`. Scottland main at
  `21273828a427885202f8b5dce1543994184867ee` has no such file, so the 0.3 source is confined to the
  2026.11 release line; replace the branch selector with Scottland's final version tag before the
  distro tag. The exact combined VM run must still verify the installed backend selection, portal
  version, request reaching capture, and clean exit before this candidate is accepted. This source
  eligibility does not establish adapter runtime or real-session acceptance.
- **Scottland on Omarchy (the adapter):** `scottland-omarchy-setup` builds and installs this
  package (ruling 2026-10-06). It fetches this recipe from Gooarchy's repository at a pinned commit,
  checks each file's sha256, builds it with makepkg and installs it with pacman. Whatever package
  provided `xdg-desktop-portal-wlr` before (Arch's) is replaced in the same transaction, and setup
  prints what it replaced, with what, and why. Re-running setup with the pinned version installed
  does nothing.

## Moving to a package repository

Gooarchy has no package repository yet (DEFICIT.md, "Package repository"), so both paths compile
this package on the user's machine. **Once a Gooarchy package repository exists, both must
migrate to installing `xdg-desktop-portal-wlr-gooarchy` from it** (ruling 2026-10-06): the
installer step and the Scottland Omarchy adapter's setup stop building it, and Omarchy-adapter
users get updates of it through pacman instead of re-running setup.
