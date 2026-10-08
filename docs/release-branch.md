# Release branch rehearsal

`main` is the next install and pins released Scottland and gooarchy-flavorings tags. A `2026.11` branch is used only when testing the next distro release against an unreleased Scottland release branch. Cut it from current `main`, then merge `main` into it after each main change while the branches differ. Resolve and test the resulting branch tip before accepting another change or making a distro tag.

For every forward merge, record the source `main` SHA, the resulting `2026.11` SHA, the Scottland and flavorings pins, and the check results. Run the repository's full VM rehearsal on the resulting branch. Keep real-machine graphics and NVIDIA acceptance as separate evidence; the VM run does not establish either. If a merge or check fails, repair that branch and repeat the rehearsal at the corrected tip.

Before tagging the distro release, replace the temporary Scottland release-branch pin with its released tag, confirm that flavorings is pinned to a released tag, and rehearse the exact candidate again. Tag only the revision that passed the required reviews and release checks. The package repository builds from that tag.

The `fast-check` workflow is a quick source and host-safe test gate for pull requests and merge groups. It does not replace the full branch rehearsal or real-machine acceptance.
