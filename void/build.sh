#!/bin/sh
# void/build.sh — Void Linux disk image, installed by freedomnas-installer
# inside the live ISO (common/vm-install.sh), with the xbps bootstrap and
# the prebuilt OpenZFS modules from freedomnas-void that installer-void.json
# describes.
#
# Usage: void/build.sh [image-path] [size]
# Writes <image-path>.zst (default void/void.img.zst).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
REPOS_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

IMG_PATH="${1:-$SCRIPT_DIR/void.img}"
IMG_SIZE="${2:-10G}"

. "$COMMON_DIR/vm-install.sh"
. "$COMMON_DIR/compress.sh"

fnas_vm_install "$IMG_PATH" "$IMG_SIZE" void "" "$REPOS_DIR"
fnas_compress "$IMG_PATH"
echo "Done: ${IMG_PATH}.zst"
