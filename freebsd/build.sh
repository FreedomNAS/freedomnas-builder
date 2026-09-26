#!/bin/sh
# freebsd/build.sh — FreeBSD ZFS image build (Phase 2).
#
# Unlike debian/build.sh, this can't chroot straight into a mounted
# target on the Linux runner: FreeBSD's own gpart, ZFS tooling, and
# bectl-compatible boot-environment layout don't exist on Linux, and
# Linux's zpool/zfs aren't a substitute (different userland, no
# guarantee the resulting pool is bootable by FreeBSD's loader). So
# this script instead:
#
#   1. Stages freedomnas-core/profiles/webui into a tarball (reusing
#      the same install-core.sh logic conceptually, just packaged for
#      transport instead of rsynced into a shared chroot).
#   2. Boots an mfsBSD live image under a real backend (VirtualBox by
#      default, QEMU as a documented fallback -- see FREEBSD_BACKEND
#      below and each driver's own header for why), with the target
#      raw image attached as a disk and the staged payload delivered
#      in.
#   3. Hands off to freebsd/guest/build-in-guest.sh, which runs INSIDE
#      the FreeBSD guest where gpart/zpool/pkg/bectl-equivalent tooling
#      is real, and does the actual partitioning, ZFS layout, base.txz
#      bootstrap, boot chain, and package install.
#   4. Waits for the guest to signal completion, then compresses the
#      resulting raw image with zstd.
#
# FREEBSD_BACKEND selects the driver: "virtualbox" (default) or "qemu".
# See vbox-driver.sh and qemu-driver.sh for what each needs installed
# and why VirtualBox is the default (short version: the identical
# mfsBSD ISO booted cleanly under VirtualBox with no tuning, but hung
# early in the FreeBSD kernel on qemu-system-x86_64 on the hardware
# this was validated against, for a root cause that was never pinned
# down -- see qemu-driver.sh's header for everything that was ruled
# out).
#
# mfsBSD ISO source and FreeBSD release/mirror below are parameterized
# with what are, at the time of writing, the standard, long-stable URL
# patterns for both projects — but pin/verify the exact filename for the
# release you target before relying on this in production; upstream
# filenames do change across releases.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
ASSETS_DIR="$SCRIPT_DIR/../../freedomnas-profiles/assets"
REPOS_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

IMG_PATH="${1:-$SCRIPT_DIR/freebsd.img}"
IMG_SIZE="${2:-8G}"

FREEBSD_BACKEND="${FREEBSD_BACKEND:-virtualbox}"
# These are deliberately independent: FREEBSD_RELEASE is the *installed*
# system's base.txz/kernel.txz version and should track whatever FreeBSD
# currently ships as a release; MFSBSD_RELEASE is just the live/bootstrap
# environment's version and only needs to be able to partition, create
# the pool, and fetch+extract the (possibly much newer) target release --
# confirmed empirically that mfsbsd.vx.sk lags behind FreeBSD's own
# releases (14.2 is still the newest mfsBSD ISO, with FreeBSD at 15.1).
# The target's boot code and loader come from the extracted target, not
# from the live environment, so an older mfsBSD installs a newer release.
FREEBSD_RELEASE="${FREEBSD_RELEASE:-15.1-RELEASE}"
MFSBSD_RELEASE="${MFSBSD_RELEASE:-14.2-RELEASE}"
MFSBSD_ISO_URL="${MFSBSD_ISO_URL:-https://mfsbsd.vx.sk/files/iso/14/amd64/mfsbsd-${MFSBSD_RELEASE}-amd64.iso}"
MFSBSD_ISO_CACHE="$SCRIPT_DIR/.cache/mfsbsd-${MFSBSD_RELEASE}-amd64.iso"

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
# The packages too: core and samba-cifs, as freedomnas-profiles lists them
# for FreeBSD.
fnas_packages() {
    python3 -c 'import json, sys; print(" ".join(p for c in sys.argv[2:] for p in json.load(open(f"{sys.argv[1]}/{c}.json"))["freebsd"]["packages"]))' \
        "$REPOS_DIR/freedomnas-profiles/packages" core samba-cifs
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
ADMIN_PASSWORD=$(python3 -c 'import shlex, sys; print(shlex.quote(sys.argv[1]))' "$ADMIN_PASSWORD")
$(fnas_user_commands)
EOF

echo "=== [2/4] Preparing target raw image ($IMG_PATH, $IMG_SIZE) ==="
truncate -s "$IMG_SIZE" "$IMG_PATH"

echo "=== [3/4] Fetching mfsBSD live ISO (cached under freebsd/.cache/) ==="
mkdir -p "$(dirname "$MFSBSD_ISO_CACHE")"
if [ ! -f "$MFSBSD_ISO_CACHE" ]; then
    curl -fL "$MFSBSD_ISO_URL" -o "$MFSBSD_ISO_CACHE" || {
        echo "build.sh: could not fetch $MFSBSD_ISO_URL" >&2
        echo "build.sh: verify/pin the correct mfsBSD ISO URL for $MFSBSD_RELEASE and set MFSBSD_ISO_URL" >&2
        exit 1
    }
fi

echo "=== [4/4] Booting mfsBSD (backend: $FREEBSD_BACKEND) and running build-in-guest.sh ==="
case "$FREEBSD_BACKEND" in
    virtualbox)
        command -v VBoxManage >/dev/null 2>&1 || {
            echo "build.sh: VBoxManage not found — install VirtualBox or set FREEBSD_BACKEND=qemu" >&2
            exit 1
        }
        command -v xorriso >/dev/null 2>&1 || {
            echo "build.sh: xorriso not found — needed to build the seed ISO for the VirtualBox backend" >&2
            exit 1
        }
        "$SCRIPT_DIR/vbox-driver.sh" "$IMG_PATH" "$SEED_DIR" "$MFSBSD_ISO_CACHE"
        ;;
    qemu)
        "$SCRIPT_DIR/qemu-driver.sh" "$IMG_PATH" "$SEED_DIR" "$MFSBSD_ISO_CACHE"
        ;;
    *)
        echo "build.sh: unknown FREEBSD_BACKEND '$FREEBSD_BACKEND' (expected virtualbox|qemu)" >&2
        exit 1
        ;;
esac

echo "=== Compressing image ==="
. "$COMMON_DIR/compress.sh"
fnas_compress "$IMG_PATH"
echo "Done: ${IMG_PATH}.zst"
