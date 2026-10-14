# Gooarchy session lock

Run `gooarchy lock` to request a compositor-owned session lock. Gooarchy installs the adjacent
`/usr/bin/gooarchy-lock` client, and its Scottland configuration fragment binds Super+L to that
same command. The client shows an opaque Gooarchy password screen on each output and uses the
logged-in account's Unix password through its dedicated PAM service.

These surfaces all belong to the `gooarchy` package:

- `/usr/bin/gooarchy-lock`
- `/etc/pam.d/gooarchy-lock`
- `/usr/lib/scottland/config.d/35-gooarchy-lock`

Remove or replace the package to remove or change these installed surfaces. Do not delete the
PAM service while a lock is active: authentication then fails closed. The client does not start
automatically on idle, suspend, or lid close. A lock only protects the session when the compositor
supports `ext-session-lock-v1` and accepts the request; a failed request exits with an error.

After the compositor accepts a lock, a wrong or empty password cannot unlock it. Killing the
client leaves the compositor responsible for keeping the session locked, possibly requiring the
session to be ended for recovery. Gooarchy does not install a second locker or a restart service.
