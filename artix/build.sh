#!/bin/sh
# artix/build.sh -- STUB (Phase 3, not implemented, not wired into CI).
#
# Artix is Linux + dracut-capable, so like void/build.sh it CAN reuse
# common/partition.sh, common/zfs-layout.sh, common/install-core.sh, and
# the shared Clover+UKI boot chain exactly as debian/build.sh does. What
# actually differs:
#
#   - Base system bootstrap: `pacstrap` against Artix's own repos
#     (base + base-devel + openrc, using an Artix mirrorlist -- NOT
#     Arch's own repos, which assume systemd is present) instead of
#     debootstrap. Requires an Artix-flavored pacman.conf pointing at
#     Artix's repositories, not Arch's.
#
#   - Package list: freedomnas-profiles/packages/*.json's "artix"
#     sections (already added) give the package names; BASE_PACKAGES in
#     this script should mirror debian/build.sh's list but pulled from
#     those JSON files, same caveat as void/build.sh.
#
#   - OpenRC service wiring: firstboot.sh's cron entry doesn't apply --
#     OpenRC boots via /etc/init.d + runlevels. The equivalent is an
#     OpenRC init script at /etc/init.d/freedomnas-webui (following
#     init/openrc.json's rc-service/rc-update conventions) invoking
#     firstboot.sh, added to the default runlevel via
#     `rc-update add freedomnas-webui default` at build time instead of
#     the cron @reboot trick debian/build.sh uses.
#
# Until this is built out, `artix` is deliberately excluded from
# .forgejo/workflows/build-images.yml's matrix.
set -eu
echo "artix/build.sh is not implemented yet (Phase 3). See header comment." >&2
exit 1
