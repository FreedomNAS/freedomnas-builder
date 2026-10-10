#!/bin/sh
# common/compress.sh — final build step: {edition}.img -> {edition}.img.zst
#
# zstd over xz: much faster to produce in CI, still trivially readable by
# the flashing tools we point users at (Raspberry Pi Imager and Rufus read
# .zst; `zstd -d` first for balenaEtcher, which does not; or zstd | dd).
set -eu

fnas_compress() {
    img_path="$1"
    zstd -f -19 --long=27 -T0 "$img_path" -o "${img_path}.zst"
    rm -f "$img_path"
    echo "compress.sh: wrote ${img_path}.zst" >&2
}
