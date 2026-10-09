#!/bin/sh
# gentoo/build.sh — Gentoo disk image, installed by freedomnas-installer
# inside the live ISO (common/vm-install.sh).
#
# Usage: gentoo/build.sh [image-path] [size]
# Writes <image-path>.zst (default gentoo/gentoo.img.zst).
#
# Gentoo installs from a stage3 whose filename is date-stamped, so the
# installer asks for its URL (installer-gentoo.json leaves
# rootfs_tarball_url empty). The newest openrc stage3 named by Gentoo's
# autobuilds pointer is passed as FNAS_ROOTFS_URL unless one is set.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
REPOS_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

IMG_PATH="${1:-$SCRIPT_DIR/gentoo.img}"
IMG_SIZE="${2:-16G}"

AUTOBUILDS="https://distfiles.gentoo.org/releases/amd64/autobuilds"

. "$COMMON_DIR/vm-install.sh"
. "$COMMON_DIR/compress.sh"

if [ -z "${FNAS_ROOTFS_URL:-}" ]; then
    stage3="$(curl -fsSL "$AUTOBUILDS/latest-stage3-amd64-openrc.txt" \
        | awk '/^[0-9].*stage3-amd64-openrc-.*\.tar\.xz/ {print $1; exit}')"
    [ -n "$stage3" ] || { echo "gentoo/build.sh: no stage3 in $AUTOBUILDS/latest-stage3-amd64-openrc.txt" >&2; exit 1; }
    FNAS_ROOTFS_URL="$AUTOBUILDS/$stage3"
fi
export FNAS_ROOTFS_URL
echo "gentoo/build.sh: stage3 $FNAS_ROOTFS_URL"

fnas_vm_install "$IMG_PATH" "$IMG_SIZE" gentoo "" "$REPOS_DIR"
fnas_compress "$IMG_PATH"
echo "Done: ${IMG_PATH}.zst"
