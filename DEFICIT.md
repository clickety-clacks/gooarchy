# What Gooarchy is missing

Gooarchy starts clean: what it doesn't have yet stays visibly missing instead of being covered by
borrowed parts. This is the list, from using the built system: a fresh Arch Linux install turned
into Gooarchy by `install.sh`, booted into Scottland and driven through `tests/vm/run.sh`, which
also records most of these facts in its `results.json` observations. It was cross-checked against
Scottland's inventory of what Omarchy defines (`docs/distro-gaps.md` on Scottland's `distro-gaps`
branch).

Snapshot: 2026-10-04, Gooarchy `main`, Scottland `f325ab1`, Arch Linux cloud image 2026-10-01,
QEMU/KVM guest with virgl graphics.

**Severity** is about a person using Gooarchy as their desktop on real hardware:

- **Blocker**: unsafe, or makes daily use on a laptop impractical.
- **High**: a common task can't be done without a terminal workaround, or a whole category of apps
  fails.
- **Medium**: works, with friction most people will hit.
- **Low**: polish, or rarely hit.

## The desktop session

| Missing | Severity | What a user hits |
|---|---|---|
| Lock screen | Blocker | There is no way to lock the screen. Wayfire's session-lock plugin is loaded but no locker is installed; `loginctl lock-session` does nothing. With `--autologin`, anyone at the machine gets the desktop at boot. |
| Idle and suspend behavior | Blocker | Nothing dims, blanks or suspends on idle (Wayfire's `idle/dpms_timeout` is -1; its screensaver timeout has nothing to show). Closing a laptop lid suspends (systemd's default), and the machine resumes straight into the unlocked desktop. |
| Bar / status | High | No clock, date, battery, network, volume or tray anywhere. Apps that put an icon in the tray (StatusNotifierItem) have nowhere to put it (no StatusNotifierWatcher on the bus). |
| Notifications | High | No notification daemon: `org.freedesktop.Notifications` is not on the bus, so desktop notifications from apps (Chromium, chat apps, `notify-send`) fail or vanish. Terminal bells still reach Scottland's attention (checked in the VM test); Scottland's own attention sources still work. Full-screen do-not-disturb (`focus.d`) has nothing to hold. |
| Launcher | High | No app launcher. Apps start from three keys (Super+Enter terminal, Super+Shift+F Strata, Super+Shift+B Chromium) or by typing their command in a terminal. Desktop entries are never shown anywhere. |
| Power and session menu | Medium | No shutdown/reboot/suspend UI. Super+Shift+Escape logs out (and `--autologin` logs straight back in); everything else is `systemctl poweroff`/`reboot`/`suspend` in a terminal. |
| Polkit authentication agent | Medium | Nothing can ask for your password graphically. Anything that needs authorization (mounting an internal disk in Strata, changing system settings from an app) fails with "not authorized" or silently. `pkexec` works only from a terminal. |
| Keyring / secret service | Medium | No `org.freedesktop.secrets` provider. Chromium has no keyring to encrypt saved passwords with (it falls back to its basic store); apps that keep tokens in the keyring can't sign in or forget the login. |
| Keybinding help | Medium | No cheatsheet; Scottland's and Gooarchy's keys are only in the config files. |
| Display manager / greeter, boot polish | Low | Boot shows kernel and systemd text, then a console login on tty1 (or autologin). That is the chosen design for now (see README); there is no graphical greeter, boot splash or branding. |
| Logout leaves the old login behind | Low | After logging out, the old tty1 login lingers as "closing" with Scottland's color-scheme and solar watchers still running; each login adds another set (see "Needs a Scottland change"). |

## Input, display, sound

| Missing | Severity | What a user hits |
|---|---|---|
| Volume and brightness OSD | Medium | The volume keys work (wpctl; checked in the VM test) and the brightness keys call brightnessctl, but nothing on screen shows the level or mute state. |
| Display configuration | Medium | No display settings UI and no hotplug profiles. Resolution, scale, position and arrangement of monitors are set by hand in `~/.config/scottland/overrides.ini` (`[output:NAME]` sections), and the output names come from Wayfire's log. |
| Media keys | Low | Play/pause/next keys are not bound (no MPRIS control). |
| Night light | Low | No screen color temperature control. (Scottland's Sunlight setting switches light/dark only.) |
| Input methods | Low | Compose is on Caps Lock (Scottland's default); there's no input-method framework for CJK and other complex scripts, and no layout switcher. |

## Connectivity and system services

| Missing | Severity | What a user hits |
|---|---|---|
| Network management and UI | Blocker (laptops) | Gooarchy doesn't pick a network stack: it keeps whatever the Arch install set up (the VM's was systemd-networkd on Ethernet). There is no Wi-Fi UI or indicator; on a laptop, joining a network means `iwctl` or `nmcli` in a terminal, if the base install included one. Gooarchy installs neither NetworkManager nor iwd. |
| Bluetooth | High | BlueZ isn't installed: no Bluetooth at all (WirePlumber logs "BlueZ system service is not available"). No pairing UI. |
| Battery and power | High (laptops) | No UPower, no power-profiles-daemon: no battery level anywhere, no low-battery warning before the machine dies, no power profiles. |
| Screen sharing and screenshots through portals | High | The portal has Settings and FileChooser (xdg-desktop-portal-gtk) but no ScreenCast, Screenshot or RemoteDesktop backend, so screen sharing in Chromium (video calls) doesn't work. The Print key does save a screenshot to `~/Pictures` (grim; checked in the VM test), with no feedback, no region-to-clipboard and no editor. |
| X11 apps | High | Xwayland isn't installed, so X11-only apps (many games, Steam, older Electron and Java apps) don't start. Wayfire logs that it can't find `/usr/bin/Xwayland`. |
| Clipboard history | Low | Copy and paste work between running apps; nothing keeps the clipboard after the source app closes, and there's no history. |
| Printing | Medium | No CUPS: nothing can print. |
| Removable media | Medium | udisks2 and gvfs are present (Strata's dependencies), but nothing automounts drives or offers to open them, and without a polkit agent some mounts are refused. |
| Firewall | Medium | No firewall is set up (Arch's default). |
| Time and location | Low | Time sync is whatever the base install enabled; no location service, so Scottland's Sunlight schedule needs coordinates set by hand. |

## Apps and defaults

| Missing | Severity | What a user hits |
|---|---|---|
| Chromium's first run | Medium | Arch's Chromium opens a placeholder "Additional Terms of Service" dialog ("This Space Intentionally Blank") on first launch. Accept continues; Cancel quits Chromium and discards the new profile, including Gooarchy's title-bar preference (it is applied again only after removing `~/.local/state/gooarchy/flavorings/chromium`). |
| Theme engine | Medium | Watercolor Dream is wired into each app by hand (Scottland's halo palette, Ghostty, the wallpaper, GTK through the color-scheme preference). Strata ignores it: it follows only Omarchy's theme state and otherwise stays on its own dark default, even in light mode. Chromium follows light/dark but not the theme's colors. There is no theme catalogue or picker beyond `gooarchy-theme light|dark`. |
| App widgets | Medium | Only Scottland's default card widget exists; no app ships a widget form yet (gooarchy-flavorings is meant to carry them). |
| agentd as an attention source | Medium | The distro notes call for agentd wired into Scottland's attention (agents anywhere light up their terminal). Not done: agentd isn't packaged for Arch. Bells from local and remote terminals still work. |
| Coding agents | Low | Claude Code and Codex are configured to ring the bell if they're installed, but neither is installed by Gooarchy. |
| Strata as FileManager1 | Low | Strata opens folders (the default handler in a Scottland session), but isn't registered as `org.freedesktop.FileManager1`, so "Show in folder" from some apps falls back to opening the folder rather than selecting the file. |
| Accessibility | Medium | No screen reader, magnifier settings or high-contrast theme are set up. (Wayfire's zoom plugin is on Super+scroll.) |
| A first-run guide | Low | Nothing explains the spatial model, the keys or this list on first login. |

## The distribution itself

| Missing | Severity | What a user hits |
|---|---|---|
| Installer ISO | High | You install Arch Linux first (partitioning, encryption, accounts, bootloader are all archinstall's or yours), then run `install.sh`. |
| Package repository | High | Scottland and Gooarchy's packages are compiled on your machine during install (needs base-devel, takes minutes); Strata comes from the AUR. There's no signed Gooarchy repository. |
| Updates and migrations | High | `pacman -Syu` updates Arch's packages, but nothing updates Scottland, Strata or Gooarchy's own packages: they change only when you pull this repository and run `install.sh` again, and there are no migrations for configuration. A Wayfire update in Arch can break the locally built Scottland plugin until it's rebuilt. |
| Hardware support | High | Only tested in a QEMU/KVM VM with virgl. Gooarchy doesn't install firmware (`linux-firmware`), microcode, GPU drivers beyond Mesa, or anything for NVIDIA, and has no laptop quirks or supported-hardware list. |
| Snapshots and rollback | Medium | No snapshot before install or update, no boot-time rollback. [docs/uninstall.md](docs/uninstall.md) removes Gooarchy's packages and settings. |
| Releases, support | Medium | No versions, release channels, changelog or support and bug-reporting channels. Package versions are `0.0.1.r<commits>.g<hash>`. |
| Other architectures | Low | x86_64 only (Scottland's package is x86_64). |

## Needs a Scottland change

Gooarchy runs Scottland's `core` alone, without the Omarchy adapter, and it works: the plugin
loads, goo renders with GL (virgl), windows scale in the periphery, rails widgetize, settings and
attention work. These are the Scottland changes a clean distro wants:

1. **Package the Omarchy adapter separately.** `packaging/arch/PKGBUILD` always builds
   `scottland-omarchy` along with `scottland`, so a standalone build also produces a package that
   depends on `omarchy` and `sddm`. A separate PKGBUILD (or an option to build only `scottland`)
   would let a distro build exactly the core.
2. **Move the Watercolor Dream themes out of `omarchy/`.** Gooarchy's default themes live in
   `omarchy/themes/` (the adapter's directory, marked as generated by Aether for Omarchy). Gooarchy
   takes `colors.toml` and the wallpaper from there at a pinned commit. A neutral place (or
   gooarchy-flavorings) fits the "nothing under core knows Omarchy" rule from the other side.
3. **Drop or neutralize adapter-only bindings in the shipped config.** `scottland.ini` binds
   Super+Escape to `scottland-switch`, which only the adapter provides; on a standalone install
   the key does nothing.
4. **Silence the warnings every session logs.** Wayfire's animate plugin reports
   `Unknown animation type: ""` at startup, and the goo shaders log
   `Uniform uBackgroundMap/uShine/uHints not found in program`. Harmless, but they bury real errors
   in `wayfire.log`.
5. **Stop the session's watchers when the compositor exits.** After logout, the old tty1 login
   stays "closing" because `scottland-color-scheme watch` and `scottland-solar-theme watch` (from
   `autostart.d/07-*`) and their `gsettings monitor`, `gdbus monitor` and `inotifywait` children
   keep running without Wayfire; each new login adds another set. They should exit when their
   Wayfire socket goes away (or run under `scottland-session.target`, which `start-scottland`
   already stops). Gooarchy's own wallpaper hook had the same flaw and now exits with the
   compositor.
6. **A portal configuration for the Scottland desktop.** The portal currently picks backends
   through Wayfire's `wayfire-portals.conf` (Scottland sets `XDG_CURRENT_DESKTOP=Scottland:Wayfire:wlroots`).
   When Gooarchy adds screen sharing, a `scottland-portals.conf` naming the backends belongs with
   the desktop, so behavior doesn't depend on Wayfire's choices.

## Cross-check with Scottland's inventory

`docs/distro-gaps.md` lists 59 decision areas. Beyond the items above, these are still open for
Gooarchy and not yet visible as something a user hits in this build:

- Disk layout, encryption, accounts, locale and timezone (the ISO's job, item "Installer ISO").
- Deferred ownership and factory reset; personal backups and sync.
- Fingerprint and FIDO2; privileged helpers and device-access policy; trust for third-party
  themes, widgets and extensions.
- GPU and firmware policy, model quirks, hibernation and memory pressure (part of "Hardware
  support").
- Optional network and cloud services, web apps, developer runtimes and editors, games and
  controllers: Gooarchy ships no app catalogue beyond the selected apps.
- Learning, support, diagnostics and crash reporting; publishing and release ownership.

Covered by this build, so not in the list: the graphical session and its lifecycle (Scottland's
session contract, started from tty1), the window model (Scottland's), terminal window identity
(tmux "#S on #h", mosh without prefix), touchpad tapping and tap-and-drag, the light/dark
palette for Scottland's halos, PipeWire audio, default handlers for folders and the web, and
coding agents ringing the bell.
