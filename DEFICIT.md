# What Gooarchy is missing

Gooarchy starts clean: what it doesn't have yet stays visibly missing instead of being covered by
borrowed parts. This is the list. It comes from using the built system (a fresh Arch Linux cloud
image turned into Gooarchy by `install.sh` and driven through `tests/vm/run.sh`), from reading what
the packages ship, and from Scottland's inventory of what Omarchy defines (`docs/distro-gaps.md` on
Scottland's `distro-gaps` branch). It is a list of what users lack and what is still undecided,
not a promise to copy every Omarchy feature.

Snapshot: 2026-10-05, Gooarchy `main`, Scottland `f325ab1`, Arch Linux cloud image 2026-10-01,
QEMU/KVM guest with virgl and with software graphics.

**Basis** says how each entry is known:

- **VM**: seen in the VM test (most are recorded in its `results.json` observations).
- **Config**: read from what Gooarchy and its packages ship, not exercised.
- **Inferred**: what the defaults imply; not exercised (no real hardware was used).
- **Undecided**: a decision Gooarchy hasn't made; nothing is shipped for it.

**Severity** is about a person using Gooarchy as their desktop on real hardware. "For those who
need it" means the severity applies to the people who depend on the feature.

- **Blocker**: unsafe, or makes daily use impractical.
- **High**: a common task can't be done without a terminal workaround, or a whole category of apps
  or users is shut out.
- **Medium**: works, with friction most people will hit.
- **Low**: polish, or rarely hit.

## Session safety and the shell

| Missing | Severity | Basis | What a user hits |
|---|---|---|---|
| Lock screen | Blocker | VM | There is no way to lock the screen. Wayfire's session-lock plugin is loaded but no locker is installed; `loginctl lock-session` does nothing. With `--autologin`, anyone at the machine gets the desktop at boot; after a crash, tty1 is left at the logged-in shell. |
| Idle, suspend and lid | Blocker | VM, Inferred | Nothing dims, blanks or locks on idle (Wayfire's `idle/dpms_timeout` is -1; seen). With systemd's defaults, closing a laptop lid suspends and the machine resumes into the unlocked desktop (inferred: not tried on a laptop; docking, inhibitors and the base install's logind settings can change it). |
| Bar / status | High | VM | No clock, date, battery, network, volume or tray anywhere. Apps that put an icon in the tray (StatusNotifierItem) have nowhere to put it (no StatusNotifierWatcher on the bus). |
| Notifications | High | VM | No notification daemon: `org.freedesktop.Notifications` isn't on the bus, so desktop notifications from apps (Chromium, chat apps, `notify-send`) fail or vanish. Terminal bells still become Scottland attention (VM). Full-screen do-not-disturb (`focus.d`) has nothing to hold. |
| Launcher | High | VM | No app launcher. Apps start from three keys (Super+Enter terminal, Super+Shift+F Strata, Super+Shift+B Chromium) or from a terminal. Desktop entries are never shown anywhere. |
| Graphical authorization (polkit agent) | High for those who need it | VM | Nothing can ask for a password graphically, so anything that needs authorization from an app (mounting an internal disk in Strata, changing system settings) fails with "not authorized" or silently. `pkexec` and `sudo` work in a terminal. |
| Saved credentials (keyring) | High for those who need it | VM | No `org.freedesktop.secrets` provider. Chromium has no keyring to encrypt saved passwords with (it falls back to its basic store); apps that keep tokens in the keyring can't sign in, or forget the login. |
| Power and session menu | Medium | VM | No shutdown/reboot/suspend UI. Super+Shift+Escape logs out (and `--autologin` logs straight back in); the rest is `systemctl poweroff`/`reboot`/`suspend` in a terminal. |
| Keybinding help | Medium | Config | No cheatsheet; Scottland's and Gooarchy's keys are only in the config files. |
| Greeter, boot polish | Low | VM | Boot shows kernel and systemd text, then a console login on tty1 (or autologin). That is the chosen design for now; no graphical greeter, boot splash or branding. |

## Input, display, sound

| Missing | Severity | Basis | What a user hits |
|---|---|---|---|
| Input methods | High for those who need it | Config | No input-method framework (fcitx5, IBus): Chinese, Japanese, Korean and other scripts that need one can't be typed. |
| Keyboard layouts | Medium | VM | The system's layout carries into the desktop (Gooarchy's config fragment; VM: `localectl set-x11-keymap de` reached the session). Not covered: a console keymap with no X11 equivalent in systemd's table falls back to Scottland's `us`; there is no layout switcher or per-device layout. |
| Audio devices and mixer | Medium | VM | PipeWire runs and the volume keys work (VM), but there is no output/input selector or per-app mixer: switching to a headset or picking a microphone for a call means `wpctl` in a terminal. Audible playback, capture and Bluetooth audio weren't tested. |
| Volume and brightness OSD | Medium | VM | Nothing on screen shows the level or mute state when the volume or brightness keys are used. |
| Display configuration | Medium | Config | No display settings UI and no hotplug profiles. Resolution, scale, position and arrangement are set by hand in `~/.config/scottland/overrides.ini` (`[output:NAME]` sections), with output names from Wayfire's log. |
| Text size | Medium | Config | No global text-size or scaling setting beyond per-output scale in `overrides.ini`. |
| Pointer and touchpad settings | Medium | Config | Tap, tap-and-drag and drag lock are on (flavorings); speed, acceleration, natural scrolling and per-device options exist only as Wayfire options in `overrides.ini`. |
| Fonts for other scripts | High for those who need it | VM | Noto (Latin, Greek, Cyrillic and more) and emoji are installed; CJK fonts are not (`noto-fonts-cjk` absent), so Chinese, Japanese and Korean text shows as boxes. |
| Media keys | Low | Config | Play/pause/next keys are not bound (no MPRIS control). |
| Night light | Low | Config | No screen color temperature control. (Scottland's Sunlight switches light/dark only.) |

## Connectivity and system services

| Missing | Severity | Basis | What a user hits |
|---|---|---|---|
| Network management and UI | Blocker for laptops | VM | Gooarchy doesn't pick a network stack: it keeps what the Arch install set up (the VM's was systemd-networkd on Ethernet). No Wi-Fi UI or indicator; joining a network means `iwctl` or `nmcli` in a terminal, if the base install has one. Gooarchy installs neither NetworkManager nor iwd. |
| Bluetooth | High | VM | BlueZ isn't installed: no Bluetooth at all (WirePlumber logs "BlueZ system service is not available"). No pairing UI. |
| Battery and power | High for laptops | VM | No UPower, no power-profiles-daemon: no battery level anywhere, no low-battery warning before the machine dies, no power profiles. |
| Screen sharing and screen recording | High | VM | The portal has a Settings backend and a file chooser (both exercised in the VM) but no ScreenCast, Screenshot or RemoteDesktop backend, so screen sharing in Chromium (video calls) and screen recording don't work. |
| Screenshot tools | Medium | VM | Print saves the whole screen into the Pictures folder, following a moved or localized folder (VM), and Shift+Print a selected region (Scottland's binding). No feedback that it happened, no copy to the clipboard, no annotation. |
| X11 apps | High | VM | Xwayland isn't installed, so X11-only apps (many games, Steam, older Electron and Java apps) don't start. Wayfire logs that it can't find `/usr/bin/Xwayland`. |
| Memory pressure | Medium | VM | No swap, zram or out-of-memory policy of Gooarchy's own: whatever the base install has (the VM had a 512 MiB swap file, no zram, systemd-oomd not enabled). A loaded desktop can freeze before the kernel's OOM killer acts. |
| Printing | Medium | Config | No printer support (CUPS isn't installed), so nothing reaches a printer. Chromium's "Save as PDF" doesn't need it. |
| Removable media | Medium | Config | udisks2 and gvfs are present (Strata's dependencies), but nothing automounts drives or offers to open them, and without a polkit agent some mounts are refused. |
| Firewall | Medium | Config | No firewall is set up (Arch's default). |
| Network shares, phones | Low | Undecided | No choice of network-share browsing (SMB is only an optional Strata dependency) or phone integration. |
| Clipboard from tmux | Medium for those who need it | VM | With Ghostty, the default terminal, tmux's own copy did not reach the system clipboard ("Nothing is copied") in software and virgl VM comparisons; the cause isn't established. Applications' OSC 52 copies inside tmux are blocked by tmux's default `set-clipboard external`, which Gooarchy's `/etc/tmux.conf` leaves as it is ([upstream behavior](https://github.com/tmux/tmux/wiki/Clipboard)). Ordinary paste, selection copy and direct OSC 52 outside tmux passed. |
| Clipboard history | Low | Config | Copy and paste work between running apps; nothing keeps the clipboard after the source app closes. |
| Time and location | Low | Config | Time sync is whatever the base install enabled. There's no GeoClue; Scottland's Sunlight schedule finds the location by an IP lookup instead (next section). |

## Apps and defaults

| Missing | Severity | Basis | What a user hits |
|---|---|---|---|
| Light/dark policy | Medium | VM | Gooarchy sets Watercolor Dream light, but Scottland's Sunlight schedule is on by default: once it knows the location (GeoClue, saved coordinates, or an IP lookup to a public service), it sets light or dark for the time of day every 10 seconds. On a connected machine at night the desktop turns dark right away, and `gooarchy-theme light` lasts only until the next check (VM, with coordinates set). Turning Sunlight off in Scottland Settings keeps a chosen mode. `gooarchy-theme` and the installer say so. Whether Gooarchy keeps this inherited behavior is an open decision. |
| App catalogue | Medium | Undecided | Gooarchy ships a terminal, a browser and a file manager, nothing else: no text editor, image viewer, media player or document viewer, and no default apps beyond folders and the web. Chromium opens PDFs, images and most media; anything else is installed and associated by hand. |
| Chromium's first run | Medium | VM | Arch's Chromium opens a placeholder "Additional Terms of Service" dialog on first launch. Accept continues; Cancel quits Chromium and discards the new profile, including Gooarchy's title-bar preference (applied again only after removing `~/.local/state/gooarchy/flavorings/chromium`). |
| Theme engine | Medium | VM | Watercolor Dream is wired into each app by hand (Scottland's halo palette, Ghostty, the wallpaper, GTK through the color-scheme preference). Strata ignores it: it follows only Omarchy's theme state and stays on its own dark default even in light mode. Chromium follows light/dark but not the theme's colors. No theme catalogue or picker beyond `gooarchy-theme light|dark`. |
| App widgets | Medium | VM | Only Scottland's default card widget exists; no app ships a widget form yet (gooarchy-flavorings is meant to carry them). |
| agentd as an attention source | Medium | Config | The distro notes call for agentd wired into Scottland's attention. Not done: agentd isn't packaged for Arch. A bell from a terminal (local or over SSH/mosh) still becomes attention (VM). |
| Accessibility | High for those who need it | Config | No screen reader, high-contrast theme or accessibility settings. (Wayfire's zoom is on Super+scroll.) |
| Coding agents | Low | Config | Claude Code and Codex are set to ring the bell if they get installed (their configuration is seeded; neither agent was run), but Gooarchy installs neither. |
| A first-run guide | Low | VM | Nothing explains the spatial model, the keys or this list on first login. |

## The distribution itself

| Missing | Severity | Basis | What a user hits |
|---|---|---|---|
| License and asset provenance | High for public distribution | Config | Gooarchy has no license yet (the packages say `LicenseRef-unlicensed`), and the Watercolor Dream color files and wallpapers copied from Scottland's repository carry no license or attribution notice in the package. Fine for trying it; not yet a redistributable baseline. |
| Installer ISO | High (release gap) | Config | You install Arch Linux first (partitioning, encryption, accounts, bootloader are archinstall's or yours), then run `install.sh`. |
| Package repository | High (release gap) | Config | Scottland and Gooarchy's packages are compiled on your machine during install (needs base-devel; minutes); Strata's AUR recipe runs with your user's rights. No signed Gooarchy repository. |
| Updates and migrations | High | VM | `pacman -Syu` updates Arch's packages; Scottland, Strata and Gooarchy's packages change only when you pull this repository and run `install.sh` again, and there are no configuration migrations. When Arch moves Wayfire on, `pacman -Syu` stops with "wayfire=… required by scottland" (VM) until `install.sh` rebuilds Scottland for the new Wayfire. |
| Release reproducibility and trust | Medium | Config | Pins are full commits (and Strata's binary is checksummed), but official Arch packages roll, builds aren't reproducible or done in a clean chroot, and nothing is signed by Gooarchy. |
| Recovery from a failed install | Medium | VM | A failed step stops the install, says what completed, keeps that attempt's log and before/after package manifests, and a rerun recovers (VM). Nothing is rolled back: the Arch upgrade and packages already installed stay ([docs/uninstall.md](docs/uninstall.md)). |
| Snapshots and rollback | Medium | Config | No snapshot before install or update, no boot-time rollback. |
| Offline install | Medium | Config | Everything is downloaded during install; there's no offline path. |
| Boot and recovery | Medium | Undecided | No rescue boot entry or recovery tooling of Gooarchy's own. (Root logging in on tty1 gets a plain console, VM.) |
| Firmware updates | Low | Undecided | No fwupd or firmware update path. |
| Hardware support | High | VM / Config | Only tested in a QEMU/KVM VM. Gooarchy doesn't install firmware (`linux-firmware`), microcode, GPU drivers beyond Mesa, or anything for NVIDIA, and has no supported-hardware list. The base kernel remains the default. Experimental `linux-gooarchy` 7.2.8-2.1 (Omarchy's patch set, which now includes the upstream Cirrus v2 speaker-ID workaround) is opt-in through `./install.sh --kernel`. A fresh VM install with it passed all checks, including a module built against its headers and the ordinary kernel staying GRUB's default after the menu is regenerated. Real-hardware audio and bootloader integration remain unvalidated. |
| Releases, support | Medium | Config | No versions, release channels, changelog, or support and bug-reporting channels. Package versions are `0.0.1.r<commits>.g<hash>`. |
| Other architectures | Low | Config | x86_64 only (Scottland's package is x86_64). |

## Needs a Scottland change

Gooarchy runs Scottland's `core` alone, without the Omarchy adapter, and it works: the plugin
loads, goo renders with GL (virgl and llvmpipe), windows scale in the periphery, rails widgetize,
settings and attention work (VM). These are the Scottland changes a clean distro wants, most
important first. None blocks the desktop today; Gooarchy works around the ones marked so.

1. **Session watchers outlive the compositor** (Medium; Gooarchy works around it). After logout or
   a crash, `scottland-color-scheme watch` and `scottland-solar-theme watch` (from
   `autostart.d/07-*`) and their `gsettings monitor`, `gdbus monitor` and `inotifywait` children
   keep running without Wayfire. That held the old login open ("closing") and added a set of
   watchers per login, competing to write the same preference and palette state. Gooarchy's tty1
   hook now stops this login's leftover Scottland helpers after the session, which the VM verifies
   across two logouts and a crash. The real fix belongs in Scottland: tie each hook's process tree to
   the session (run them under `scottland-session.target`, which `start-scottland` already stops, or
   exit when the Wayfire socket goes away). Acceptance: repeated logout/login and crash cycles leave
   no session closing and no stale monitors, each new session has the right environment, and
   remote terminals and the user's own processes are untouched.
2. **Package version identity** (Medium; Gooarchy works around it). The PKGBUILD's fixed
   `pkgver=0.1.0`/`pkgrel=1` makes every build look the same to pacman, and the plugin depends
   only on `wayfire`, though it is built for one Wayfire ABI. Gooarchy sets the version of its build
   copy to `0.1.0.r<count>.g<commit>.wf<wayfire>` and pins `wayfire=<version>`. Upstream: a `pkgver()`
   from git and the Wayfire build dependency in the package. Acceptance: builds from two commits get
   different versions; a Wayfire upgrade doesn't install over a plugin built for the old one.
3. **Light/dark: automatic versus manual** (Medium). Sunlight is on by default with an IP lookup
   (`read_config()`: `enabled` and `allow_ip` default to true, per an earlier ruling), while the
   function's comment says lookup needs opt-in, and a manual mode is reverted within 10 seconds. A
   persistent, explicit choice between "follow the sun" and "keep this mode", shared by Scottland
   Settings and command-line tools, would let distros offer both honestly. Acceptance: a manual
   choice sticks until the user goes back to automatic; offline, no location, and both solar
   modes behave as documented.
4. **A portal configuration for the Scottland desktop** (Medium once screen sharing ships). The
   portal now picks backends through Wayfire's `wayfire-portals.conf` (`XDG_CURRENT_DESKTOP` is
   `Scottland:Wayfire:wlroots`). A file name alone creates no backend: Scottland could own a
   desktop fallback contract (which interfaces, preference order, user overrides) while the distro
   chooses the backends it ships. Acceptance: Settings, open/save, screenshot and screencast requests
   work with the intended backends, also after relogin.
5. **Silence or fix the warnings every session logs** (Low if cosmetic). Wayfire's animate plugin
   reports `Unknown animation type: ""` (a configuration value), and the goo shaders log
   `Uniform uBackgroundMap/uShine/uHints not found in program`. Whether the uniforms are optimized
   out or needed hasn't been shown. Acceptance: no invalid animation setting, correct visuals on GL
   and software rendering, and real shader failures still reported.
6. **A core-only build** (Low). `packaging/arch/PKGBUILD` always builds `scottland-omarchy` too.
   Only `scottland` is installed, so nothing of Omarchy reaches the system, but the build does
   unneeded work and needs the adapter's inputs. Acceptance: a supported way to build and install
   only the core in a clean builder, with the adapter built separately.
7. **Move the Watercolor Dream themes out of `omarchy/`** (Low; tied to provenance). Gooarchy's
   default themes live in the adapter's directory (marked as generated by Aether for Omarchy);
   Gooarchy copies `colors.toml` and the wallpapers at a pinned commit. Acceptance: one owner
   (gooarchy-flavorings or a neutral asset package) with a license and attribution, the same
   palettes and wallpapers, and both the distro and the adapter using it.
8. **Screenshots into the real Pictures folder** (Low; Gooarchy overrides it). Print and Shift+Print
   write to a fixed `~/Pictures`, which fails for a localized or moved folder. Gooarchy's flavorings
   bind them to `xdg-user-dir PICTURES`; the shipped config could do the same.
9. **The adapter-only Super+Escape binding** (Low). The shipped config binds Super+Escape to
   `scottland-switch`, guarded so it does nothing without the adapter. The binding belongs in the
   adapter's own config contribution.

Not Scottland changes: keyboard-layout inheritance (Gooarchy does it in its own config fragment),
Strata's theming and FileManager1 registration (Strata and its packaging).

## Decisions not made yet

From the 59 areas in `docs/distro-gaps.md`, these are open for Gooarchy and show up in this build
only as absence:

- Disk layout, encryption, accounts, locale and timezone (the ISO's job).
- Deferred ownership and factory reset; personal backups and sync.
- Fingerprint and FIDO2; privileged helpers and device-access policy; trust for third-party themes,
  widgets and extensions.
- GPU and firmware policy, model quirks, hibernation.
- Optional network and cloud services, web apps, developer runtimes and editors, games and
  controllers.
- Learning, support, diagnostics and crash reporting; publishing and release ownership.

## What this build covers

So not listed above, with how far it was checked:

- The graphical session, started from tty1 (password or autologin, VM), with logout, relogin and
  crash handled (VM, including no login left behind), though the watcher cleanup is Gooarchy's
  workaround for a Scottland defect (above).
- Scottland's window model: periphery scaling and rail widgets (VM).
- Terminal window identity: tmux `set-titles on` with "#S on #h", and mosh without its prefix
  (configuration checked; titles not observed in a running tmux).
- Touchpad tap, tap-and-drag and drag lock (configuration checked; no physical touchpad).
- Light/dark palette for Scottland's halos, Ghostty and GTK apps (VM), subject to the Sunlight
  policy above.
- PipeWire audio services and volume keys (VM; nothing audible tested).
- Default apps for folders and the web, and Strata as `org.freedesktop.FileManager1` (VM: "show
  in folder" opens Strata; whether it selects the file wasn't checked).
- A terminal bell becoming Scottland attention (VM); Claude Code and Codex configured to ring it.
