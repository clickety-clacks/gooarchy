# Btrfs snapshots

Use `gooarchy boot snapshot take [LABEL]` to snapshot the current Btrfs root, `gooarchy boot
snapshot list` to list Gooarchy snapshots, and `gooarchy boot snapshot restore ID` to select one for
the next boot. `gooarchy update` takes a snapshot before updating packages when the root uses
Btrfs.

Snapshots require `/` to be a Btrfs subvolume and an existing same-filesystem subvolume mounted at
`/.snapshots`. Gooarchy does not create or rearrange subvolumes. On other filesystems, `take`
explains that snapshots need a Btrfs root and does nothing. `list` and `restore` report that Btrfs is
required.

Restore asks for confirmation, saves the current root as a safety snapshot, then changes Btrfs's
default root for the next boot. It does not edit bootloader files. If the current system selects its
root subvolume explicitly in `/etc/fstab` or the kernel command line, restore stops and leaves the
boot setup unchanged. Restart to use the selected snapshot. Before restarting, run `gooarchy boot
snapshot list` and restore the safety snapshot ID shown by the command to undo the selection.
