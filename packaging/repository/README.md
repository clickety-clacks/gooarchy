# Publishing the Gooarchy pacman repository

Run `packaging/repository/publish.sh --all` for the first repository snapshot.
Later, pass package names to rebuild, or use `--all` to rebuild every recipe
discovered under `packaging/arch/`, `packaging/gooarchy-flavorings/`, and
`packaging/linux-gooarchy/`. Adding a recipe there makes its package available
to this command without changing the client address or signing key.

The command requires a clean `main` checkout on an x86_64 Arch build machine.
It builds in a private temporary directory, sets the package identity to
`Gooarchy`, signs packages with the committed repository key, and uses the
configured Arch `wayfire` version when building Scottland. Kernel publication
also requires 35 GiB free in the temporary build location.

The private key reference is supplied by machine configuration through
`GOOARCHY_SIGNING_KEY_REF` as a 1Password `op://` reference. The `op` CLI reads
the key into a temporary GnuPG home for that publish. GitHub authorization is
provided by the operator's existing `gh` setup. The public key and default
repository address remain unavailable until their approved setup is complete;
the install path fails clearly while either value is still a placeholder.

Each publish downloads the current release database and its listed package
files, builds requested packages, and compares versions with `vercmp`. A
package that is not newer is refused and left at its currently published
version. The updated database and all package files and signatures it lists,
including files listed by the previous database, are uploaded to a draft
release. The command verifies the uploaded asset names and publishes the draft
as latest only after those checks pass. If GitHub changes any asset name, the
draft stays unpublished and the prior latest release remains active.

`tests/repository-publish-test.sh` exercises this flow with a local
Releases-shaped stand-in, synthetic Arch packages, and a throwaway OpenPGP key.
It checks the initial six-package database, adding a seventh recipe, signing,
Scottland's exact Wayfire dependency, version refusal, package and signature
retention, lookup through a local redirect, and the filename guard. The real
1Password read, GitHub upload, and gooarchy.com redirect are separate setup and
publish steps.

After stage 1 is on Gooarchy main, run
`tests/repository-publish-test.sh --with-stage1-consumer` in the disposable Arch
guest to pass that signed release stand-in through stage 1's repository and
Gooarchy package scripts with the guest's real pacman client.
