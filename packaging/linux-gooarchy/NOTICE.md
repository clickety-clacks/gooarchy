# linux-gooarchy: where it comes from

linux-gooarchy is the Linux kernel (GPL-2.0-only, kernel.org) with two sets of patches:

1. **Omarchy's linux-omarchy patch set and kernel configuration**, from
   [omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs) (`pkgbuilds/linux-omarchy`), at
   the commit pinned in `PKGBUILD` (`_omarchy_commit`). The patches are taken unchanged from that
   commit and checked against the signatures and keys Omarchy publishes with them. Each patch
   keeps its own authorship and the kernel's license. The build and package steps of the PKGBUILD
   are Omarchy's ("Maintainer: The Omarchy Authors"), which Omarchy adopted from Arch Linux's
   `linux` package. omarchy-pkgs is published under the MIT license, copyright David Heinemeier
   Hansson; its text is in `LICENSE.omarchy-pkgs`, installed with the package.
2. **Gooarchy's own patches**, in `patches/`, applied after Omarchy's. Each carries its upstream
   author, sign-offs and links in its header.

Gooarchy carries no patches of its own at present. Dropped:

| Gooarchy patch | Author | Upstream | Dropped because |
|---|---|---|---|
| `0001-spi-cs42l43-workaround-for-wrong-speaker-id-on-dell-xps-13-dx13260.patch` (Dell XPS 13 DX13260 speaker ID; [kernel bug 221956](https://bugzilla.kernel.org/show_bug.cgi?id=221956)) | Richard Fitzgerald (Cirrus Logic) | [v2 on linux-spi](https://lore.kernel.org/linux-spi/20261001085830.4014291-1-rf@opensource.cirrus.com/) | Omarchy's 7.2.8-2 (`8d103ac`) carries the same v2 change in its `0528-asoc-fixes-4.patch` (identical `drivers/spi/spi-cs42l43.c` hunk), so linux-gooarchy gets it from Omarchy's patch set. |

`keys/pgp/` holds the public keys used to check the sources: the kernel release signers (Linus
Torvalds, Greg Kroah-Hartman) and Omarchy's patch signing key, all as published in
omarchy-pkgs.
