# System updates

Run `gooarchy update` to update Arch packages, installed AUR packages, and Gooarchy from its
configured package repository. The command asks once before it changes packages, holds a sleep
inhibitor during the update, refreshes `archlinux-keyring`, then runs a full `pacman -Syu`. It
rebuilds installed AUR packages whose versions changed and refreshes AUR packages built from Git or
another VCS. Foreign packages that are not published in the AUR are left unchanged.

When Wayfire changes, Gooarchy rebuilds an AUR Scottland package if one is installed. The signed
package repository supplies a matching Scottland build when that package is available there. A
pacman hook blocks a Wayfire upgrade started outside `gooarchy update` and explains why the paired
update is needed.

Before package changes, Gooarchy checks that `/` has at least 10 GiB free. On a Btrfs root it takes
a snapshot first using the existing same-filesystem `/.snapshots` subvolume; if that layout is
missing, the update stops without changing packages. On another filesystem it explains that no
Btrfs snapshot was taken and continues after confirmation. The output gives the snapshot ID and
restore command when available. If the kernel changes, restart to use it. If Wayfire or Scottland
changes, log out of Wayfire and back in. Gooarchy also warns when it finds an initramfs error in the
new pacman log entries.

`gooarchy update` also runs `gooarchy-source update`, which uses Scottland's adopted on-machine
source mechanism and preserves local edits according to that tool's behavior.
