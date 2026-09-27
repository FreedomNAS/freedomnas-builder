#!/bin/sh
# artix/build.sh — Artix disk image, one per init system, installed by
# freedomnas-installer inside the live ISO (common/vm-install.sh).
#
# Usage: artix/build.sh <openrc|dinit|runit> [image-path] [size]
# Writes <image-path>.zst (default artix/artix-<init>.img.zst). The init
# systems offered are installer-artix.json's installer_meta.init_systems.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
REPOS_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

INIT="${1:?usage: artix/build.sh <openrc|dinit|runit> [image-path] [size]}"
IMG_PATH="${2:-$SCRIPT_DIR/artix-$INIT.img}"
IMG_SIZE="${3:-10G}"

. "$COMMON_DIR/vm-install.sh"
. "$COMMON_DIR/compress.sh"

fnas_vm_install "$IMG_PATH" "$IMG_SIZE" artix "$INIT" "$REPOS_DIR"
fnas_compress "$IMG_PATH"
echo "Done: ${IMG_PATH}.zst"
