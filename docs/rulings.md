# Rulings

Product decisions that shape Gooarchy, newest first. Each says what was decided, why, and where it
came from. Mike may overrule any of them.

## The kernel opt-in leaves the bootloader alone

2026-10-07, Mike (decision `dr_1d029059`).

A regenerated GRUB menu lists linux-gooarchy first and boots it by default. `./install.sh --kernel`
had been adding a commented `GRUB_TOP_LEVEL` line to `/etc/default/grub` to keep the stock kernel
the default. Mike chose "messages-only" over keeping that edit. The opt-in changes no bootloader
setting; on GRUB it says which `GRUB_TOP_LEVEL` line keeps the stock kernel the default, and the
user decides whether to add it.
