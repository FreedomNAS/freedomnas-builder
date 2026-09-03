#!/bin/sh
# common/zfs-layout.sh — dataset tree, ported from
# freedomnas-installer/lib/zfs_installer.py. Same rpool/ROOT/<edition>
# layout for every edition — only the ROOT dataset name changes.
set -eu

fnas_zfs_layout() {
    part2="$1"      # rpool partition device (from partition.sh's $PART2)
    edition="$2"    # "debian" | "freebsd" | "void" | "artix"
    mnt="$3"        # target mountpoint, e.g. /mnt
    pool="${4:-rpool}"

    zpool create \
        -o ashift=12 \
        -O acltype=posixacl \
        -O canmount=off \
        -O compression=lz4 \
        -O dnodesize=auto \
        -O normalization=formD \
        -O relatime=on \
        -O xattr=sa \
        -O mountpoint=/ \
        -R "$mnt" \
        "$pool" "$part2"

    zfs create -o canmount=off -o mountpoint=none                 "$pool/ROOT"
    zfs create -o canmount=noauto -o mountpoint=/                 "$pool/ROOT/$edition"
    zfs create -o setuid=off                                      "$pool/home"
    zfs create -o canmount=off -o mountpoint=/var                 "$pool/var"
    zfs create -o atime=on                                        "$pool/var/log"
    zfs create -o canmount=noauto -o mountpoint=/etc/freedomnas/state \
        "$pool/.freedomnas"

    zpool set "bootfs=$pool/ROOT/$edition" "$pool"

    zfs mount "$pool/ROOT/$edition"
    zfs mount --all

    echo "zfs-layout.sh: pool=$pool root=$pool/ROOT/$edition mounted at $mnt" >&2
}

fnas_zfs_layout_cleanup() {
    pool="${1:-rpool}"
    zfs umount -a 2>/dev/null || true
    zpool export "$pool" 2>/dev/null || true
}
