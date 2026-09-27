#!/bin/sh
# common/zfs-layout.sh — dataset tree, ported from
# freedomnas-installer/lib/zfs_installer.py. Same rpool/ROOT/<edition>
# layout for every edition — only the ROOT dataset name changes.
#
# The pool is written as "rpool" on disk, but the build host sees it under a
# temporary in-core name (zpool create -t), set in $FNAS_POOL: the host may
# have its own pool called rpool, and every zfs/zpool command run here on the
# image's pool must use $FNAS_POOL so it can never touch that one. Names that
# end up inside the image (root=ZFS=rpool/ROOT/<edition>) keep the on-disk name.
set -eu

fnas_zfs_layout() {
    part2="$1"      # rpool partition device (from partition.sh's $PART2)
    edition="$2"    # "debian" | "freebsd" | "void" | "artix"
    mnt="$3"        # target mountpoint, e.g. /mnt
    disk_pool="${4:-rpool}"
    FNAS_POOL="fnasbuild-$edition-$$"
    pool="$FNAS_POOL"

    if zpool list -H -o name "$pool" >/dev/null 2>&1; then
        echo "zfs-layout.sh: a pool named $pool is already imported" >&2
        return 1
    fi

    # -t also leaves cachefile=none, so the host's zpool.cache never records
    # the image's pool.
    zpool create -t "$pool" \
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
        "$disk_pool" "$part2"

    # The root dataset is mounted before the others exist: zfs create mounts
    # home and var/log at once, and a root dataset mounted afterwards would
    # cover them, so everything written to /home and /var/log would land in
    # the root dataset and be hidden at boot.
    zfs create -o canmount=off -o mountpoint=none                 "$pool/ROOT"
    zfs create -o canmount=noauto -o mountpoint=/                 "$pool/ROOT/$edition"
    zpool set "bootfs=$pool/ROOT/$edition" "$pool"
    zfs mount "$pool/ROOT/$edition"

    zfs create -o setuid=off                                      "$pool/home"
    zfs create -o canmount=off -o mountpoint=/var                 "$pool/var"
    zfs create -o atime=on                                        "$pool/var/log"
    zfs create -o canmount=noauto -o mountpoint=/etc/freedomnas/state \
        "$pool/.freedomnas"

    # zfs create has already mounted home and var/log; the state dataset is
    # canmount=noauto on purpose. No zfs mount -a: it would mount the
    # host's other pools too.
    echo "zfs-layout.sh: pool=$disk_pool (on the host: $pool) root=$pool/ROOT/$edition mounted at $mnt" >&2
}

fnas_zfs_layout_cleanup() {
    pool="${1:-${FNAS_POOL:-}}"
    [ -n "$pool" ] || return 0
    # export unmounts this pool's datasets; zfs umount -a would unmount every
    # pool on the build host.
    zpool export "$pool" 2>/dev/null || true
}
