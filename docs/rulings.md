# Package repository rulings

## Hosting (5A)

On 2026-10-06, Mike ruled `dr_99e159f0` as `A3-gooarchy-com-redirect` for
Gooarchy package repository rev 5. His words were: “gooarchy.com redirects
each file to those same GitHub Releases. Free storage, and the address is
Gooarchy's own, so storage can move later without touching any machine. It
needs a small redirect service picked later.”

The repository files live in GitHub Releases on a `clickety-clacks` repository.
The gooarchy.com address only redirects each requested file to the matching
asset; it does not cache, mirror, or store repository files. The redirect
service and DNS configuration remain a separate setup step.

## Signing key custody (5B)

On 2026-10-06, Mike ruled `dr_0e3dd8f9` as B2 with 1Password under his
delegation. His words were: “yes do it this way. rule for me”.

1Password holds the private signing key. One build machine fetches it when it
publishes, without an interactive signing step, and the same key can be
recovered onto a replacement machine. No additional custody mechanism is part
of this ruling.

## The kernel opt-in leaves the bootloader alone

2026-10-07, Mike (decision `dr_1d029059`).

A regenerated GRUB menu lists linux-gooarchy first and boots it by default. `./install.sh --kernel`
had been adding a commented `GRUB_TOP_LEVEL` line to `/etc/default/grub` to keep the stock kernel
the default. Mike chose "messages-only" over keeping that edit. The opt-in changes no bootloader
setting; on GRUB it says which `GRUB_TOP_LEVEL` line keeps the stock kernel the default, and the
user decides whether to add it.
