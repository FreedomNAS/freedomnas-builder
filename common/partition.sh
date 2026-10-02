#!/bin/sh
# common/partition.sh — unified ESP+rpool layout on a loopback image file.
#
# Generalized from freedomnas-installer/lib/disk_installer.py: same
# 2-partition scheme (1 GiB ESP EF00 + rest BF00 rpool), same for
# every edition and both firmware types. The only difference from the
# live installer is the target: a loop device backed by a sparse image
# file instead of a real /dev/sdX.
#
# This file is meant to be `.`-sourced by an edition's build.sh, which
# needs the resulting IMG/LOOP/PART1/PART2 variables for later steps
# (ZFS layout, bootloader deploy). It defines fnas_partition() rather
# than running at source time.
set -eu

fnas_partition() {
    img_path="$1"
    img_size="$2"   # e.g. "8G"

    truncate -s "$img_size" "$img_path"

    LOOP=$(losetup --find --show --partscan "$img_path")
    IMG="$img_path"

    sgdisk --zap-all --clear "$LOOP"
    sgdisk -n 1:0:+1GiB   -t 1:EF00 "$LOOP"
    sgdisk -n 2:0:-0      -t 2:BF00 "$LOOP"
    partprobe "$LOOP" || true
    udevadm settle

    PART1="${LOOP}p1"
    PART2="${LOOP}p2"

    mkfs.vfat -F 32 -n EFI "$PART1"

    echo "partition.sh: LOOP=$LOOP PART1=$PART1 PART2=$PART2" >&2
}

fnas_partition_cleanup() {
    # Call once at the very end of build.sh (success or failure) to detach
    # the loop device — losetup -d fails harmlessly if never attached.
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
}
