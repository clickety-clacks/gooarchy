# Software and web apps

The `gooarchy software` tool handles Arch packages, AUR packages and Gooarchy web-app launchers.
`gooarchy version` prints the installed Gooarchy package version and source commit alongside the
installed Scottland package version.

## Packages

```sh
gooarchy software pkg add PACKAGE...
gooarchy software pkg drop PACKAGE...
gooarchy software pkg present PACKAGE...
gooarchy software pkg missing PACKAGE...
gooarchy software pkg install
gooarchy software pkg remove
gooarchy software pkg aur add PACKAGE...
gooarchy software pkg aur install
gooarchy software pkg aur accessible
```

`present` exits successfully when every named package is installed. `missing` exits successfully
when at least one is absent. `pkg install`, `pkg remove` and `pkg aur install` show a terminal list;
enter one or more displayed numbers separated by spaces or commas, or press Return to cancel.

AUR packages are fetched from their AUR Git repository, built with `makepkg` and installed through
`pacman`, using the same build flags as Gooarchy's Strata package path. AUR commands need `curl`,
`git`, `jq`, `makepkg` and the build tools and dependencies required by the selected PKGBUILD. These
package-building tools are needed only when using AUR commands; Gooarchy itself does not need Rust
installed to run.

## Web apps

```sh
gooarchy software webapp install [NAME URL]
gooarchy software webapp launch [--focus ID] URL
gooarchy software webapp remove [NAME]
gooarchy software webapp remove-all
```

Without `NAME URL`, `webapp install` asks for them in the terminal. A missing URL scheme is treated
as `https`; explicit URLs must use HTTP or HTTPS. Launchers live in the user's XDG applications
directory and open Chromium in app mode. A focused launch brings the existing Scottland window for
that launcher forward. Remove operations act only on launchers created by Gooarchy.
