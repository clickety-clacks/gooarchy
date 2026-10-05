# Gooarchy

Pronounced "goo-ah-shee".

Gooarchy is a desktop Linux distribution built around [Scottland](https://github.com/clickety-clacks/scottland),
a spatial desktop on [Wayfire](https://wayfire.org/): no workspaces, windows scale down toward the
screen's edges, and a window dropped on a side rail becomes a widget. Gooarchy is patterned after
[Omarchy](https://omarchy.org/) (installer structure, package lists, update tooling) but starts
clean on plain Arch Linux. Nothing is borrowed to fill a gap: Gooarchy has no bar yet, so it has no
bar. Everything missing is listed in [DEFICIT.md](DEFICIT.md), found by using the built system.

## Current state: pre-alpha

There is an install script that turns a fresh, minimal Arch Linux install into a working Scottland
desktop, and a VM test that does this unattended and checks the result. There is no installer ISO,
no package repository, no update channel and no hardware support beyond what Arch and Mesa give.
It is for trying the desktop and for building the distro, not for daily use.

What you get:

| | |
|---|---|
| Desktop | Scottland on Wayfire 0.11, built from Scottland's repository as the `scottland` package |
| Session | log in on tty1 and Scottland starts (no display manager); `--autologin` skips the password |
| Terminal | Ghostty (Super+Enter) |
| Browser | Chromium (Super+Shift+B), with "Use system title bar and borders" on |
| Files | Strata (Super+Shift+F), the folder handler, from its AUR package |
| Theme | Watercolor Dream, light by default; `gooarchy-theme dark` switches the desktop, Ghostty, GTK apps and the wallpaper |
| Audio | PipeWire with WirePlumber; the volume keys work, with no on-screen indicator |
| Defaults | tmux titles read "session on host", mosh adds no title prefix, touchpad tap and tap-and-drag on, Claude Code and Codex ring the terminal bell (Scottland shows it as attention) |

## Trying it

### In a VM (recommended)

`tests/vm/run.sh` does the whole thing on any x86_64 Linux machine with KVM and QEMU: it boots the
official Arch Linux cloud image, runs the installer in it unattended, reboots into Scottland and
checks the desktop, saving screenshots and logs. Run it on a spare or test machine:

```sh
tests/vm/run.sh            # boot, install, reboot, check; artifacts in ~/.cache/gooarchy-vm-test/artifacts/
tests/vm/run.sh ssh        # a shell in the guest afterwards (the run leaves the VM stopped)
```

Without QEMU installed and without root, `tests/vm/fetch-qemu.sh` unpacks a private copy of QEMU
on an Arch-based machine. The guest's GPU uses virgl through the host's render node by default
(`GOOARCHY_VM_GPU=software` for llvmpipe). See the top of `tests/vm/run.sh` for all settings.

To look at the desktop yourself, boot the VM with a window instead: install it with
`tests/vm/run.sh boot && tests/vm/run.sh install`, stop it, then start QEMU on
`~/.cache/gooarchy-vm-test/run/disk.qcow2` with `-device virtio-vga-gl -display gtk,gl=on`.

### On a machine

On a fresh Arch Linux install (archinstall's minimal profile is fine), as your user, with sudo:

```sh
sudo pacman -S --needed git
git clone https://github.com/clickety-clacks/gooarchy.git
cd gooarchy
./install.sh
```

Then reboot, or log in on tty1. Super+Enter opens a terminal; Super+Shift+Escape logs out. Read
[DEFICIT.md](DEFICIT.md) first: there is no lock screen, no network or Bluetooth UI, no
notifications and no bar. [docs/uninstall.md](docs/uninstall.md) explains how to remove it.

## How it is put together

| Path | What |
|---|---|
| `install.sh`, `install/` | The installer, in ordered steps like Omarchy's: `preflight/` (checks), `packaging/` (Arch packages, then Scottland, Strata and Gooarchy's own packages), `user/` (per-user defaults), `login/` (tty1 session, optional autologin), `post-install/` |
| `install/gooarchy-base.packages` | The Arch packages Gooarchy is made of |
| `install/sources.conf` | Scottland and Strata, pinned to the versions tested together |
| `packaging/arch/PKGBUILD` | Builds `gooarchy` (the session start; depends on everything) and `gooarchy-flavorings` |
| `session/` | The tty1 session start (`/etc/profile.d/gooarchy-session.sh`) |
| `flavorings/` | The curated defaults: Scottland config fragment and hooks, theme, tmux, mosh, default apps, per-user defaults (`gooarchy-flavorings-apply`). They will move to [gooarchy-flavorings](https://github.com/clickety-clacks/gooarchy-flavorings), which Scottland's Omarchy adapter will also install |
| `tests/vm/` | The VM test |

Every file Gooarchy puts on the system comes from a package; the installer only builds and installs
packages, writes the optional autologin drop-in, and fills in per-user defaults that aren't set. A
setting you already have is never replaced silently: it is left alone and reported.

## Plan

In order:

1. **Standalone Scottland**: Scottland runs on plain Arch without Omarchy. Done for this install
   path; the Scottland changes it still needs are in DEFICIT.md.
2. **Install script**: a fresh Arch install becomes Gooarchy (this repository today).
3. **Package repository**: Gooarchy's own signed pacman repository with Scottland, Strata and
   Gooarchy's packages, so nothing is built on the user's machine and the AUR isn't needed.
4. **Defaults**: gooarchy-flavorings as its own package, and Gooarchy's own bar, notifications,
   launcher, lock screen and the rest of the deficit.
5. **Hardware**: a supported hardware matrix with GPU, firmware, power and laptop quirks.
6. **ISO**: an installer image (partitioning, encryption, accounts) instead of "install Arch first".
7. **Updates**: an update command with migrations for user and system configuration.
8. **First run**: onboarding that respects Scottland's attention model.
9. **Releases**: versioned releases, release channels and support commitments.
