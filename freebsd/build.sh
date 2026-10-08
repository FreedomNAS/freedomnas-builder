#!/bin/sh
# freebsd/build.sh — FreeBSD ZFS image build (Phase 2).
#
# Unlike the Linux images, this can't let freedomnas-installer install
# it from the Linux live ISO: FreeBSD's own gpart, ZFS tooling, and
# bectl-compatible boot-environment layout don't exist on Linux, and
# Linux's zpool/zfs aren't a substitute (different userland, no
# guarantee the resulting pool is bootable by FreeBSD's loader). So
# this script instead:
#
#   1. Stages freedomnas-core/profiles/webui into a tarball (reusing
#      the same install-core.sh logic conceptually, just packaged for
#      transport instead of rsynced into a shared chroot).
#   2. Boots an mfsBSD live image under a real backend (see
#      freebsd/mfsbsd.sh and each driver's own header), with the target
#      raw image attached as a disk and the staged payload delivered in.
#   3. Hands off to freebsd/guest/build-in-guest.sh, which runs INSIDE
#      the FreeBSD guest where gpart/zpool/pkg/bectl-equivalent tooling
#      is real, and does the actual partitioning, ZFS layout, base.txz
#      bootstrap, boot chain, and package install.
#   4. Waits for the guest to power off, checks the pool property the
#      guest sets only on success, then compresses the resulting raw
#      image with zstd.
#
# FREEBSD_BACKEND selects the driver: "virtualbox" (default) or "qemu".
# An earlier QEMU driver hung early in the FreeBSD kernel on the
# hardware this was first validated against; the current one has built
# and verified images on a Gentoo host with KVM (2026-09-26).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
ASSETS_DIR="$SCRIPT_DIR/../../freedomnas-profiles/assets"
REPOS_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

IMG_PATH="${1:-$SCRIPT_DIR/freebsd.img}"
IMG_SIZE="${2:-8G}"

. "$SCRIPT_DIR/mfsbsd.sh"
. "$COMMON_DIR/install-core.sh"

SEED_DIR="$(mktemp -d)"
STAGE_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$SEED_DIR" "$STAGE_DIR"
}
trap cleanup EXIT

echo "=== [1/4] Staging freedomnas-core/profiles/webui payload ==="
fnas_install_core "$STAGE_DIR" "$REPOS_DIR"
tar -cf "$SEED_DIR/fnas-payload.tar" -C "$STAGE_DIR/usr/lib/freedomnas" .
cp "$ASSETS_DIR/firstboot.sh" "$ASSETS_DIR/supervisor.sh" "$SEED_DIR/"
cp "$SCRIPT_DIR/guest/build-in-guest.sh" "$SEED_DIR/build-in-guest.sh"
# Env vars don't cross the VM boundary -- build-in-guest.sh sources this
# instead of inheriting FREEBSD_RELEASE/FREEBSD_MIRROR directly.
# Where FreeBSD keeps FreedomNAS is freedomnas-profiles' data, not this
# script's: os/os-freebsd.json's `paths`.
fnas_path() {
    python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["paths"][sys.argv[2]])' \
        "$REPOS_DIR/freedomnas-profiles/os/os-freebsd.json" "$1"
}
# The packages too: core, samba-cifs and nfs, as freedomnas-profiles lists
# them for FreeBSD -- the features the Linux images install as well.
fnas_packages() {
    python3 -c 'import json, sys; print(" ".join(p for c in sys.argv[2:] for p in json.load(open(f"{sys.argv[1]}/{c}.json"))["freebsd"]["packages"]))' \
        "$REPOS_DIR/freedomnas-profiles/packages" core samba-cifs nfs
}
# And their services, enabled as freedomnas-installer enables them: without
# this Samba was installed but never started, and NFS neither.
fnas_services() {
    python3 -c 'import json, sys; print(" ".join(s for c in sys.argv[2:] for k in ("early_services", "services") for s in json.load(open(f"{sys.argv[1]}/{c}.json"))["freebsd"].get(k, [])))' \
        "$REPOS_DIR/freedomnas-profiles/packages" core samba-cifs nfs
}
# And the accounts: base.txz ships root with an empty password, and the
# WebUI signs in only administrators of the profile's sudo_group, so the
# image locks root and ships a default administrator instead, with the
# commands freedomnas-installer uses (users/users-freebsd.json).
fnas_user_commands() {
    python3 - "$REPOS_DIR/freedomnas-profiles/users/users-freebsd.json" "$ADMIN_USER" <<'PYEOF'
import json, shlex, sys
users = json.load(open(sys.argv[1]))["users"]
name = sys.argv[2]
for var, cmd in (("ADMIN_CREATE", users["create"].format(username=name, groups=users["sudo_group"])),
                 ("ADMIN_SET_PASSWORD", users["set_password_stdin"].format(username=name)),
                 ("LOCK_ROOT", users["lock_root"])):
    print(f"{var}={shlex.quote(cmd)}")
PYEOF
}
ADMIN_USER="${FNAS_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${FNAS_ADMIN_PASSWORD:-freedomnas}"
cat > "$SEED_DIR/env.sh" <<EOF
FREEBSD_RELEASE="$FREEBSD_RELEASE"
INSTALL_ROOT="$(fnas_path install_root)"
CONFIG_DIR="$(fnas_path config_dir)"
PACKAGES="$(fnas_packages)"
SERVICES="$(fnas_services)"
ADMIN_PASSWORD=$(python3 -c 'import shlex, sys; print(shlex.quote(sys.argv[1]))' "$ADMIN_PASSWORD")
$(fnas_user_commands)
EOF

echo "=== [2/4] Preparing target raw image ($IMG_PATH, $IMG_SIZE) ==="
# A fresh file, never one left from an earlier build: truncate keeps the old
# contents, the guest then fails on the pool already there, and the check
# below reads the old pool's fnas:build_complete=yes as this build's success.
rm -f "$IMG_PATH"
truncate -s "$IMG_SIZE" "$IMG_PATH"

echo "=== [3/4] Fetching the build environment (cached under freebsd/.cache/) ==="
fnas_fetch_build_env

echo "=== [4/4] Booting $(basename "$(fnas_build_env)") (backend: $FREEBSD_BACKEND) and running build-in-guest.sh ==="
fnas_run_guest "$IMG_PATH" "$SEED_DIR" build-in-guest.sh

fnas_verify_pool() {
    # A bare "VM stopped" can't tell success from build-in-guest.sh's
    # fail() path -- both end in a plain `poweroff` (neither backend has console
    # text to check, see vbox-driver.sh's header). So this isn't optional
    # best-effort logging: it's the only actual pass/fail signal a
    # build has, gating build.sh's exit code. build-in-guest.sh sets
    # fnas:build_complete=yes on the pool only on its success path, right
    # before the final export.
    command -v zpool >/dev/null 2>&1 || { echo "build.sh: FAIL: zpool not available on this host — can't verify the build" >&2; return 1; }

    LOOP=$(sudo losetup --find --show -P -r "$IMG_PATH")
    # zpool's ZFS partition is always p3 in this fixed layout (freebsd-boot,
    # efi, freebsd-zfs added in that order by build-in-guest.sh's gpart
    # calls). Confirmed empirically that `-d "$LOOP"` (the whole loop
    # device, no partition suffix) finds nothing at all -- `-d` needs to
    # point at the actual partition (or a directory containing it), not the
    # parent disk device.
    POOL_PART="${LOOP}p3"
    verify_failed=1

    # Import by GUID, not by the name "rpool" -- confirmed on this
    # validation host that importing by name is a real hazard, not just a
    # theoretical one: `zpool import` (unscoped) found an actual pre-existing
    # "rpool" on a real host NVMe partition, unrelated to this build entirely.
    # It wasn't actually imported/active, so nothing was touched, but
    # `-d ... rpool` matching by name is exactly the kind of ambiguity that
    # either fails outright or -- worse -- could pick the wrong "rpool" on a
    # host where the name collision candidate *is* currently mountable.
    # `-d "$POOL_PART"` alone lists only what's actually visible on this
    # specific partition, from which the GUID is unambiguous.
    #
    # Match on field content, not exact leading-whitespace count -- an
    # earlier version anchored on exactly 3 leading spaces before "id:",
    # which never matched (the real output has 4), so this ALWAYS returned
    # empty and every build was reported as failed regardless of whether it
    # actually succeeded. Confirmed by the user importing the same image by
    # hand: the pool was there and fine. Whitespace-tolerant field match
    # instead of a fragile anchored regex.
    #
    # `-o readonly=on` is required, not optional here: a plain `-N -f`
    # import of this pool failed with "cannot import 'rpool': permission
    # denied" on this host even though the pool itself is completely
    # healthy (confirmed by hand) -- some ZFS feature FreeBSD's newer
    # OpenZFS enables by default isn't in this host's read-write-import
    # compatible set, but it *is* read-only-compatible, which is all
    # verification needs anyway.
    #
    # The GUID keeps the import unambiguous, but the imported pool still takes
    # a name: if the host already has a pool called rpool imported (its own
    # root pool, say), this one is imported under a temporary name instead,
    # so neither the import nor the export below can touch the host's pool.
    VERIFY_POOL=rpool
    if sudo zpool list -H -o name 2>/dev/null | grep -qx rpool; then
        VERIFY_POOL="fnasverify$$"
        echo "build.sh: The host already has a pool named rpool -- importing the image's as $VERIFY_POOL"
    fi
    GUID=$(sudo zpool import -d "$POOL_PART" 2>/dev/null | awk '$1=="id:" {print $2; exit}')
    if [ -n "$GUID" ] && sudo zpool import -o readonly=on -N -f -d "$POOL_PART" -t "$GUID" "$VERIFY_POOL" 2>/dev/null; then
        if [ "$(sudo zfs get -H -o value fnas:build_complete "$VERIFY_POOL" 2>/dev/null)" = "yes" ]; then
            verify_failed=0
            echo "build.sh: Verified: fnas:build_complete=yes on $VERIFY_POOL (GUID $GUID)"
        else
            echo "build.sh: FAIL: pool imported but fnas:build_complete is not set to yes -- build-in-guest.sh likely hit its fail() path"
        fi
        sudo zpool export "$VERIFY_POOL" 2>/dev/null || true
    else
        echo "build.sh: FAIL: could not import a pool from $POOL_PART at all -- build-in-guest.sh likely failed before zpool create"
    fi
    sudo losetup -d "$LOOP" 2>/dev/null || true

    return "$verify_failed"
}

echo "=== Verifying the build (importing the pool read-only) ==="
fnas_verify_pool || { echo "build.sh: the image did not build" >&2; exit 1; }

echo "=== Compressing image ==="
. "$COMMON_DIR/compress.sh"
fnas_compress "$IMG_PATH"
echo "Done: ${IMG_PATH}.zst"
