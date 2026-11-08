# System updates

Run `gooarchy update` to update Arch packages, installed AUR packages, and Gooarchy from its
configured package repository. The command asks once before it changes packages, holds a sleep
inhibitor during the update, refreshes `archlinux-keyring`, then performs a full `pacman -Syu`
transaction. It rebuilds installed AUR packages whose versions changed and refreshes AUR packages
built from Git or another VCS. Foreign packages that are not published in the AUR are left
unchanged. AUR info requests are split into small batches.

When Wayfire changes, Gooarchy keeps Scottland on its configured source. With the normal repository
package, it selects `gooarchy/scottland` in the same pacman transaction as Wayfire. With an explicit
local Scottland source pin, pacman temporarily skips dependency checks so the old exact Wayfire
dependency does not block the system update; Gooarchy then rebuilds and installs Scottland from that
same pin for the installed Wayfire version. Before changing packages, it requires archives matching
both installed versions in pacman's configured cache or the local Scottland build directory, and
copies them into its update recovery cache so a failed clone or clean build cannot remove them.
If either archive is missing, the update stops without changing packages and names the missing
version. On an Arch transaction or Scottland rebuild/install failure, it restores both archives
in one pacman transaction and checks the installed versions before reporting recovery. This works
on non-Btrfs roots too. Other packages already upgraded are not rolled back. If recovery itself
fails, it reports that separately with the archive paths and tells you not to log out or restart.
The local Scottland package is excluded from repository and AUR replacement. A
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
