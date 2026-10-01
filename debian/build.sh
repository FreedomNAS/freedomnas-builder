#!/bin/sh
# debian/build.sh — Debian disk image, installed by freedomnas-installer
# inside the live ISO (common/vm-install.sh).
#
# Usage: debian/build.sh [image-path] [size]
# Writes <image-path>.zst (default debian/debian.img.zst).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
REPOS_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

IMG_PATH="${1:-$SCRIPT_DIR/debian.img}"
IMG_SIZE="${2:-12G}"

. "$COMMON_DIR/vm-install.sh"
. "$COMMON_DIR/compress.sh"

fnas_vm_install "$IMG_PATH" "$IMG_SIZE" debian "" "$REPOS_DIR"
fnas_compress "$IMG_PATH"
echo "Done: ${IMG_PATH}.zst"
