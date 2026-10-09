# Removing Gooarchy (rollback)

Gooarchy's installer changes packages, the pacman repository configuration and trusted key, user
settings, and (with `--autologin`) a systemd drop-in. Each comes off separately, and none of
it touches your files beyond the few settings listed below.

Nothing the installer does is rolled back automatically: the Arch upgrade (`pacman -Syu`) and every
package transaction that completed stay done.

## If an install failed partway

The installer stops at the failing step and says which step last completed. Each attempt keeps its
log and two package manifests (installed packages, versions and install reasons, from before and
after the attempt) in `~/.local/state/gooarchy/logs/<time>/`;
`~/.local/state/gooarchy/install.log` points at the latest attempt's log.
Usually the right thing is to fix the cause (often the network) and run
`./install.sh` again: completed steps are safe to repeat.

To back out instead:

- **The failure came before the Gooarchy packages were installed** (preflight, `packaging/base.sh`,
  Scottland or Strata). `gooarchy` and `gooarchy-flavorings` don't exist yet, so section 1 doesn't
  apply. Compare the manifests to see what the attempt added:

  ```sh
  cd ~/.local/state/gooarchy/logs/<time>
  comm -13 <(cut -d' ' -f1 packages-before.txt) <(cut -d' ' -f1 packages-after.txt)
  ```

  Remove what you don't want with `sudo pacman -Rns ...`. Don't remove every orphan package
  (`pacman -Qdtq`) wholesale: some may have been there before Gooarchy. Packages that only changed
  version came from the Arch upgrade and stay upgraded.
- **The failure came after them** (the per-user defaults, autologin, the summary). Everything below
  applies, as for a complete install.

## 1. Packages

Everything the installer added from packages hangs off two packages, `gooarchy` and
`gooarchy-flavorings`. The Arch packages from `install/gooarchy-base.packages` and the repository's
`scottland` and locally built `strata-bin` packages went in as their dependencies. Remove those two
packages from a console, not from inside Scottland:

```sh
sudo pacman -Rns gooarchy gooarchy-flavorings
```

That also removes their dependencies that nothing else needs. A package you had installed
yourself before Gooarchy stays: the installer never changes the install reason of a package
that was already there. `git` and `base-devel` (installed to build Strata, and Scottland when its
pin is overridden) stay;
remove them yourself if you don't want them. To see what would go first, run
`pacman -Rns --print gooarchy gooarchy-flavorings`.

Removing the packages also removes what they own: `/etc/profile.d/gooarchy-session.sh` (the
tty1 session start), `/etc/profile.d/gooarchy-flavorings.sh`, `/etc/tmux.conf`,
`/etc/xdg/scottland-mimeapps.list`, `/usr/lib/gooarchy/`, `/usr/share/gooarchy/` and the Gooarchy
hooks and config fragments under `/usr/lib/scottland/`.
If you edited `/etc/tmux.conf`, pacman keeps your edited copy as `/etc/tmux.conf.pacsave`.

## 2. The package repository and key

If the installer added the repository, remove its `[gooarchy]` section from `/etc/pacman.conf`.
The install report records the key fingerprint; remove that trust with:

```sh
sudo pacman-key --delete <fingerprint-from-the-install-report>
```

## 3. The autologin setting (only with `--autologin`)

Running the installer again without `--autologin` does not remove it; delete the drop-in:

```sh
sudo rm /etc/systemd/system/getty@tty1.service.d/gooarchy-autologin.conf
sudo rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null
sudo systemctl daemon-reload
```

## 4. Settings in your home directory

`gooarchy-flavorings-apply` only filled settings that weren't set, once each. A setting it found
already set was left alone and logged in `~/.local/state/gooarchy/reports.log`. To undo what it
set, edit or remove:

| Setting | Where |
|---|---|
| Chromium "Use system title bar and borders" | Chromium settings > Appearance, or `browser.custom_chrome_frame` in `~/.config/chromium/Default/Preferences` |
| Ghostty theme | the `theme = ...` line in `~/.config/ghostty/config` (the file was created by Gooarchy if you had none) |
| Claude Code bell | `preferredNotifChannel` in `~/.claude.json` |
| Codex bell | `notifications` and `notification_method` under `[tui]` in `~/.codex/config.toml` |
| Light/dark preference | `gsettings reset org.gnome.desktop.interface color-scheme` |
| Standard folders | `~/Desktop`, `~/Documents`, `~/Downloads`, ... (created by `xdg-user-dirs-update`; empty ones can go) |

## 5. The experimental kernel (only with `--kernel`)

`linux-gooarchy` and `linux-gooarchy-headers` are installed alongside your kernel, not as
dependencies of `gooarchy`, so section 1 leaves them. Boot your ordinary kernel, then:

```sh
sudo pacman -Rns linux-gooarchy linux-gooarchy-headers
```

The installer did not change your bootloader. If you added a `GRUB_TOP_LEVEL` line to
`/etc/default/grub` as it suggested, you may keep it or remove it. If you had regenerated GRUB's
menu to add linux-gooarchy, regenerate it again (`sudo grub-mkconfig -o /boot/grub/grub.cfg`).
The kernel's built packages and downloaded sources stay in `~/.cache/gooarchy/build/linux-gooarchy`.

Gooarchy's own state lives in `~/.local/state/gooarchy` (install logs and manifests, build records,
reports, markers of applied defaults) and its build checkouts in `~/.cache/gooarchy`. Both can be
deleted. Scottland keeps its own state in `~/.local/state/scottland` and `~/.config/scottland`.

## Going back to a previous system state

Gooarchy has no snapshots or rollback of its own yet (see [DEFICIT.md](../DEFICIT.md)). On a
Btrfs root with snapshots (snapper, timeshift), take a snapshot before installing. That snapshot
is the real way back.
