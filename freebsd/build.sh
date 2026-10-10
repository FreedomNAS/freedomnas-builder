#!/bin/sh
# freebsd/build.sh — FreeBSD disk image, installed by freedomnas-installer
# inside the FreeBSD live ISO (freebsd/live.sh) with common/vm-install.sh,
# as the Linux images are inside theirs: the image is exactly what the
# installer produces on real hardware, and FreedomNAS comes from the
# freedomnas-freebsd pkg repository of the installer's channel.
#
# Usage: freebsd/build.sh [image-path] [size]
# Writes <image-path>.zst (default freebsd/freebsd.img.zst). The ISO is
# FNAS_FREEBSD_LIVE_ISO (default freebsd/freedomnas-live-freebsd.iso).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
REPOS_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

IMG_PATH="${1:-$SCRIPT_DIR/freebsd.img}"
IMG_SIZE="${2:-8G}"
FNAS_LIVE_ISO="${FNAS_FREEBSD_LIVE_ISO:-$SCRIPT_DIR/freedomnas-live-freebsd.iso}"
export FNAS_LIVE_ISO

. "$COMMON_DIR/vm-install.sh"
. "$COMMON_DIR/compress.sh"

fnas_vm_install "$IMG_PATH" "$IMG_SIZE" freebsd "" "$REPOS_DIR"
fnas_compress "$IMG_PATH"
echo "Done: ${IMG_PATH}.zst"
