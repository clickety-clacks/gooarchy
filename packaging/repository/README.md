# Building and publishing the Gooarchy package repository

The package repository uses separate builder, signer, and uploader operations. On x86_64 Arch, the
package builder creates package archives, an **unsigned** repository database, and an immutable
manifest-bound transfer. Its responsibility ends with that unsigned transfer: it does not read
signing credentials, create signatures, or upload files. A separately credentialed signer verifies
the transfer and creates a detached signature for every package and the database. An independently
qualified uploader verifies the complete signed transfer and uploads the full GitHub Release through
GitHub's Releases REST API. Signing authority does not grant upload authority. Never run the retired
`publish.sh` command on a package builder.

The installer defaults to the full database URL `https://gooarchy.com/gooarchy.db`; an explicit
`GOOARCHY_REPOSITORY_URL` may select another full database URL ending in `/gooarchy.db` or an
existing Pacman Server directory override. The installer resolves either form to the Pacman Server
directory, so the default requests the database at `https://gooarchy.com/gooarchy.db` and package
files beside it. The matching public key and fingerprint are committed at
`packaging/keys/gooarchy.asc` and `packaging/keys/gooarchy.fingerprint`. Package production
verifies that pair before using the key to validate any existing release. Private signing material
is not part of the source tree.

## Produce the transfer

From a clean Gooarchy `main` checkout on x86_64 Arch, the package builder runs:

```sh
packaging/repository/produce.sh --output /path/to/new-transfer --all
```

Pass package names instead of `--all` to rebuild a selected set. The command builds unsigned
packages, verifies the current public latest release and its detached signatures when one exists,
retains packages that were not rebuilt, and creates the next unsigned `gooarchy.db`. It reads only
the configured public key and fingerprint. It does not read signing credentials, make signatures,
or upload files.

The output directory is a complete immutable transfer with this layout:

```text
manifest.json
SHA256SUMS
payload/
  gooarchy.db
  <every package archive listed by gooarchy.db>
```

The command prints the SHA-256 of `manifest.json` separately. Carry that value with the transfer
and verify it through the chosen transfer channel. The manifest binds the clean source commit and
tree, signing fingerprint, exact base release and asset hashes, package names/versions/source
revisions, and the unsigned database. `SHA256SUMS` and the signer independently verify every
payload byte and database record before signing.

## Sign

The primary signer uses its configured 1Password key item. Select the separately credentialed
backup signer only after confirming that the primary signer is unavailable and that backup signing
is authorized for this exact transfer. Keep upload custody qualified independently; backup signing
does not grant upload permission. No automatic fallback occurs. Both roles require a clean `main`
checkout whose commit and tree exactly match the transfer manifest and whose configured public
fingerprint matches the transfer:

```sh
GOOARCHY_SIGNING_KEY_REF='op://<approved-vault>/<approved-item>/<field>' \
  packaging/repository/sign.sh --signer-role primary \
  --bundle /path/to/new-transfer \
  --output /path/to/new-signed-transfer \
  --manifest-sha256 <64-hex-manifest-sha256>
```

The explicit backup command reads a separate 1Password item and writes signatures only:

```sh
GOOARCHY_BACKUP_SIGNING_KEY_REF='op://<approved-vault>/<approved-backup-item>/<field>' \
  packaging/repository/sign.sh --signer-role backup \
  --bundle /path/to/new-transfer \
  --output /path/to/new-signed-transfer \
  --manifest-sha256 <64-hex-manifest-sha256>
```

The selected signer imports the key directly from 1Password into a private temporary GnuPG home;
the command never prints the key or token. It verifies the configured public fingerprint, immutable
manifest and payload hashes, and exact source identity. It creates and verifies one detached `.sig`
for each package and `gooarchy.db`, then writes a separate signature receipt binding those bytes to
the manifest SHA-256 and signer role. It never calls GitHub. A backup signature transfer still
requires the independently qualified primary uploader below to publish it.

## Upload

Only a separately qualified primary uploader runs this operation, regardless of which authorized
signer produced the signatures. Upload qualification and custody are separate from signing. The
uploader consumes the signed transfer; it does not read a private key or change the builder's
immutable manifest. Its repo-scoped GitHub token must be stored in the approved vault and granted
`Contents: write` for `clickety-clacks/gooarchy`; set only the vault item reference at execution time.
The reference is intentionally unset by default, so upload fails closed until the approved item is
provisioned and selected.
The uploader reads the token with `op read` and pipes it to the REST client on standard input. It does
not require GitHub CLI or SSH trust, and never places the token in a command argument or repository
file:

```sh
GOOARCHY_RELEASE_UPLOAD_TOKEN_REF='op://<approved-vault>/<repo-scoped-upload-token-item>/credential' \
packaging/repository/upload.sh --uploader-role primary \
  --signed-bundle /path/to/new-signed-transfer \
  --manifest-sha256 <64-hex-manifest-sha256>
```

The uploader verifies the configured public fingerprint, signature receipt, each detached package
and database signature, the exact source identity, and unchanged current latest release before it
reads the upload token. The REST client creates a release draft with `make_latest=false`, uploads the
complete package, signature, and database set, then checks the exact asset names, uploaded states,
sizes, and server SHA-256 digests when available. It downloads each draft asset through the release
asset API and compares its byte count and SHA-256 with the local file. Only after every asset passes
and the previous latest still matches the transfer base does one final API update mark the release
published and explicitly promote it to latest. It then reads back the release and latest record. A failed check leaves the
previous latest release in place; an incomplete draft remains unpublished. Backup signing alone does
not qualify an uploader, and backup signing does not confer upload custody.

The old `publish.sh` entry point now exits with a clear message directing operators to the two
role-specific commands. Do not restore the single-machine build/sign/upload flow.

## Checks and remaining acceptance

`tests/repository-config-source-test.sh` checks the default URL, explicit mirror override,
committed public-key fingerprint, and fail-closed empty Flavorings `_tag` without host or credential
access.
`tests/repository-publish-test.sh` exercises the transfer, primary and backup signing, role separation,
and upload behavior with synthetic package/database records, a throwaway OpenPGP key, and a local
Releases-shaped fixture. `tests/repository-release-api-test.py` exercises the production release
promotion policy against an in-process fake API without network access or credentials. The tests
cover complete initial contents, manifest and payload hashes,
source/database identity, retained package bytes, version advancement, detached signatures for every
package and the database, and refusal to advance latest after an incomplete upload or failed
readback. It does not exercise a real Arch build, 1Password, GitHub, the production signing key,
installer, or redirect. Those checks require their separately admitted release route and must be
reported against the exact source tree and transfer.
