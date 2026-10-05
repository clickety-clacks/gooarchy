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

| Gooarchy patch | Author | Upstream | Why Gooarchy carries it |
|---|---|---|---|
| `0001-spi-cs42l43-workaround-for-wrong-speaker-id-on-dell-xps-13-dx13260.patch` | Richard Fitzgerald (Cirrus Logic) | [v2 on linux-spi](https://lore.kernel.org/linux-spi/20261001085830.4014291-1-rf@opensource.cirrus.com/) (2026-10-01, reviewed), superseding [v1](https://lore.kernel.org/linux-spi/20260919134730.895381-1-rf@opensource.cirrus.com/); [kernel bug 221956](https://bugzilla.kernel.org/show_bug.cgi?id=221956) | Dell XPS 13 DX13260: the amplifiers read the wrong speaker ID, so the speakers stay silent or get the wrong amp tuning. Context: [omacom/omarchy#9687](https://github.com/omacom/omarchy/issues/9687). Drop it once the kernel Omarchy ships contains it. |

`keys/pgp/` holds the public keys used to check the sources: the kernel release signers (Linus
Torvalds, Greg Kroah-Hartman) and Omarchy's patch signing key, all as published in
omarchy-pkgs.
