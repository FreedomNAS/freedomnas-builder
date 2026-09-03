#!/bin/sh
# void/build.sh -- STUB (Phase 3, not implemented, not wired into CI).
#
# Void is Linux + dracut-capable, so unlike FreeBSD it CAN reuse
# common/partition.sh, common/zfs-layout.sh, common/install-core.sh, and
# the Clover+UKI boot chain in ../freedomnas-profiles/assets/ exactly as
# debian/build.sh does. What actually differs:
#
#   - Base system bootstrap: xbps-install's static bootstrap
#     (xbps-install -S -R <mirror>/current -r $MNT base-voidstrap, per
#     Void's own "chroot install" documentation) instead of debootstrap.
#     There is no Void equivalent of `debootstrap <suite> <target> <mirror>`
#     as a single command -- it's a rootfs tarball extraction followed by
#     `xbps-reconfigure -a` inside the chroot.
#
#   - ZFS is not in Void's default repos (see the maintainer_note in
#     ../../freedomnas-profiles/void.json) -- building this image first
#     requires either a working community zfs xbps template added to the
#     chroot's repository list, or vendoring pre-built zfs .xbps packages
#     into this repo. Resolve that before writing the rest of this script.
#
#   - Package list: freedomnas-profiles/packages/*.json's "void" sections
#     (already added) give the package names; BASE_PACKAGES in this
#     script should mirror debian/build.sh's list but pulled from those
#     JSON files rather than hardcoded, to avoid the two drifting apart.
#
#   - runit service wiring: firstboot.sh's cron entry doesn't apply --
#     Void boots via runit directly. The equivalent is a runit service
#     directory under /etc/runit/sv/freedomnas-webui (or /etc/sv/, per
#     init/runit.json's convention) with a `run` script invoking
#     firstboot.sh, symlinked into /etc/runit/runsvdir/default/ instead
#     of the cron @reboot trick debian/build.sh uses.
#
# Until this is built out, `void` is deliberately excluded from
# .forgejo/workflows/build-images.yml's matrix.
set -eu
echo "void/build.sh is not implemented yet (Phase 3). See header comment." >&2
exit 1
