#!/bin/sh
# freebsd/guest/build-in-guest.sh — runs INSIDE the mfsBSD live environment
# (under VirtualBox by default, or QEMU as a fallback -- see
# freebsd/build.sh), where real FreeBSD gpart/zpool/bectl-compatible
# tooling actually exists (see freebsd/build.sh's header for why this
# can't run on the Linux runner directly).
#
# Delivered into the guest already mounted at /fnas-seed before this
# script runs -- vbox-driver.sh's typed command mounts a cd9660 seed ISO
# there, qemu-driver.sh's expect script mounts a virtio-9p share at the
# same path instead. Either way this script finds fnas-payload.tar
# (freedomnas-core/profiles/webui, staged host-side by
# fnas_install_core() into a scratch dir and tarred up -- same target
# layout as the Debian image, just transported differently since there's
# no shared chroot between a Linux host and a FreeBSD guest).
#
# Target disk device name and network interface name both differ by
# backend (confirmed empirically -- an earlier version of this script
# hardcoded QEMU's virtio names, vtbd0/vtnet0, and failed outright under
# VirtualBox's AHCI/e1000 emulation: ada0/em0 there instead). Detected
# below rather than hardcoded so this script doesn't care which backend
# actually booted it.
#
# Must end by echoing FNAS_BUILD_MARKER_* and powering off -- the host
# side (expect driver for QEMU, VMState polling for VirtualBox) watches
# for that (see freebsd/qemu-driver.sh / freebsd/vbox-driver.sh).
set -eu

MNT=/mnt
POOL=rpool
BENAME=default          # bectl's conventional first boot-environment name
SEED=/fnas-seed

# build.sh's FREEBSD_RELEASE/FREEBSD_MIRROR don't reach this guest as
# real environment variables -- there's no such passthrough across the
# VM boundary (confirmed empirically: an earlier version of this script
# silently kept using its own hardcoded fallback here regardless of what
# build.sh was configured with). build.sh instead writes them to
# env.sh on the seed; source it if present.
[ -f "$SEED/env.sh" ] && . "$SEED/env.sh"
RELEASE="${FREEBSD_RELEASE:-14.4-RELEASE}"
MIRROR="${FREEBSD_MIRROR:-https://download.freebsd.org/ftp/releases/amd64/amd64/$RELEASE}"

log() { echo "guest-build: $*"; }

fail() {
    log "FAILED: $*"
    echo "FNAS_BUILD_MARKER_FAILED"
    poweroff
    exit 1
}

[ -n "${INSTALL_ROOT:-}" ] && [ -n "${CONFIG_DIR:-}" ] && [ -n "${PACKAGES:-}" ] || fail "env.sh names no INSTALL_ROOT/CONFIG_DIR/PACKAGES"

DISK=""
for candidate in /dev/vtbd0 /dev/ada0 /dev/da0; do
    [ -e "$candidate" ] && DISK="$candidate" && break
done
[ -n "$DISK" ] || fail "no target disk found (checked vtbd0 [QEMU virtio], ada0 [VirtualBox AHCI], da0)"
log "Target disk: $DISK"

log "=== [0/8] Bringing up networking (needed for base.txz/pkg fetch) ==="
# vtnet0 under QEMU (-device virtio-net-pci), em0 under VirtualBox's
# default e1000 emulation -- `ifconfig -l ether` finds whichever NIC is
# actually present instead of assuming one.
IFACE=$(ifconfig -l ether | awk '{print $1}')
[ -n "$IFACE" ] || fail "no ethernet interface found via 'ifconfig -l ether'"
log "Network interface: $IFACE"
# mfsBSD auto-configures this interface via DHCP at boot already
# (confirmed empirically -- an earlier version of this script called
# dhclient unconditionally and failed instantly with "dhclient already
# running, pid: N", since mfsBSD's own boot-time dhclient was still
# holding the interface). Only invoke it ourselves if that didn't happen.
if ifconfig "$IFACE" | grep -q 'inet '; then
    log "$IFACE already has an address (mfsBSD's boot-time dhclient)"
else
    dhclient "$IFACE" || fail "dhclient $IFACE (no network -- can't fetch base.txz/pkg)"
fi

log "=== [1/8] Partitioning $DISK (gpt: freebsd-boot + efi + freebsd-zfs) ==="
gpart create -s gpt "$DISK" || fail "gpart create"
gpart add -t freebsd-boot -s 512k -l bootfs0 "$DISK" || fail "gpart add freebsd-boot"
# 512MiB -- matches the Debian/Linux editions' ESP size elsewhere in
# this project. Growing this further doesn't reliably clear FAT32's
# 65525-cluster minimum on its own: newfs_msdos auto-scales
# sectors-per-cluster up alongside partition size, so cluster COUNT
# plateaus rather than growing (confirmed empirically across four
# rounds: 200MiB->25573, 512MiB->32751, 1024MiB->65503, 2048MiB->65519
# -- doubling 1GiB to 2GiB gained only 16 clusters). Forcing the
# smallest cluster size explicitly (-c 1, see below) fixes this
# properly instead of chasing the threshold with ever-bigger partitions.
gpart add -t efi -s 512m -l efiboot0 "$DISK" || fail "gpart add efi"
gpart add -t freebsd-zfs -l zfs0 "$DISK" || fail "gpart add freebsd-zfs"

log "=== [2/8] Formatting EFI partition ==="
newfs_msdos -F 32 -c 1 -L EFI "${DISK}p2" || fail "newfs_msdos"

log "=== [3/8] Creating ZFS pool + datasets ==="
zpool create \
    -o ashift=12 \
    -O acltype=nfsv4 \
    -O canmount=off \
    -O compression=lz4 \
    -O mountpoint=/ \
    -R "$MNT" \
    "$POOL" "${DISK}p3" || fail "zpool create"

# Root dataset mounted first, so home and var/log mount on top of it rather
# than underneath -- see common/zfs-layout.sh.
zfs create -o canmount=off -o mountpoint=none              "$POOL/ROOT"
zfs create -o canmount=noauto -o mountpoint=/               "$POOL/ROOT/$BENAME"
zpool set "bootfs=$POOL/ROOT/$BENAME" "$POOL"
zfs mount "$POOL/ROOT/$BENAME"

zfs create                                                   "$POOL/home"
zfs create -o canmount=off -o mountpoint=/var               "$POOL/var"
zfs create                                                   "$POOL/var/log"
zfs create -o canmount=noauto -o mountpoint="$CONFIG_DIR/state" \
    "$POOL/.freedomnas"
zfs mount -a

log "=== [4/8] Fetching + extracting base.txz/kernel.txz ($RELEASE) ==="
# Fetch to a file and check fetch's own exit status before extracting --
# `fetch ... | tar ...` looked right but isn't: `||` after a pipeline
# only sees the LAST command's status (tar's), so a 404 from fetch (empty
# stdin) silently "succeeded" as a no-op tar extraction, leaving $MNT
# empty and failing much later and far more confusingly. Confirmed
# empirically.
fetch -o /tmp/base.txz   "$MIRROR/base.txz"   || fail "fetch base.txz from $MIRROR"
fetch -o /tmp/kernel.txz "$MIRROR/kernel.txz" || fail "fetch kernel.txz from $MIRROR"
tar -xf /tmp/base.txz   -C "$MNT" || fail "extract base.txz"
tar -xf /tmp/kernel.txz -C "$MNT" || fail "extract kernel.txz"

# Boot code from the release just extracted, not from the live system: the
# mfsBSD running this can be older than the release it installs, and the
# loader has to understand that release's pool and kernel. Matches
# freedomnas-profiles' bootloader.install_gptzfsboot (part_num=1 -- the
# freebsd-boot partition).
gpart bootcode -b "$MNT/boot/pmbr" -p "$MNT/boot/gptzfsboot" -i 1 "$DISK" || fail "gpart bootcode"

log "=== [5/8] Base configuration ==="
echo "freedomnas" > "$MNT/etc/hostname"
cat >> "$MNT/etc/rc.conf" <<EOF
hostname="freedomnas"
zfs_enable="YES"
sshd_enable="YES"
cron_enable="YES"
EOF
mkdir -p "$MNT/boot/efi"
echo "${DISK}p2  /boot/efi  msdosfs  rw  2  2" >> "$MNT/etc/fstab"

log "=== [6/8] Boot chain (loader.efi -> ESP fallback path) ==="
mount -t msdosfs "${DISK}p2" "$MNT/boot/efi" || fail "mount efi"
mkdir -p "$MNT/boot/efi/EFI/BOOT"
# Matches freedomnas-profiles/freebsd.json's bootloader.install_efi_loader
# template -- same fallback-path trick debian/build.sh uses Clover for:
# EFI/BOOT/BOOTX64.efi is what UEFI firmware boots automatically when no
# NVRAM entry exists, i.e. exactly the state of a freshly flashed disk.
# FreeBSD just doesn't need a third-party shim to land there.
cp "$MNT/boot/loader.efi" "$MNT/boot/efi/EFI/BOOT/BOOTX64.efi" || fail "copy loader.efi"

log "=== [7/8] Installing freedomnas-core/profiles/webui + packages ==="
mkdir -p "$MNT$INSTALL_ROOT"
tar -xf "$SEED/fnas-payload.tar" -C "$MNT$INSTALL_ROOT/"

cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
mount -t devfs devfs "$MNT/dev" || fail "mount devfs"
pkg -c "$MNT" bootstrap -y || fail "pkg bootstrap"
# $PACKAGES is freedomnas-profiles' packages/core.json and samba-cifs.json
# "freebsd" lists, read by build.sh: the Python stack the core and the WebUI
# import comes from FreeBSD's own py3NN-* packages, as the installer
# installs it, not from pip.
# Retried: confirmed empirically that the repo-catalog fetch
# ("pkg: An error occured while fetching package: No error" /
# "Unable to update repository") intermittently fails transiently in
# this environment even though networking is otherwise fine (base.txz/
# kernel.txz fetch already succeeded by this point) -- looks like a
# DNS/NAT race rather than anything wrong with the package list itself.
pkg_install_ok=1
for attempt in 1 2 3; do
    # $PACKAGES is split into words on purpose: one package per word.
    # shellcheck disable=SC2086
    if pkg -c "$MNT" install -y $PACKAGES; then
        pkg_install_ok=0
        break
    fi
    log "pkg install attempt $attempt failed, retrying in 10s..."
    sleep 10
done
[ "$pkg_install_ok" -eq 0 ] || fail "pkg install (3 attempts)"
# The .pth goes where this python3 looks (/usr/local/lib/python3.X/site-packages
# on FreeBSD), for running `python3 -m freedomnas` by hand; firstboot.sh and
# supervisor.sh set PYTHONPATH themselves.
SITE_DIR="$(chroot "$MNT" python3 -c "import sysconfig; print(sysconfig.get_path('purelib'))")" \
    && [ -n "$SITE_DIR" ] \
    && echo "$INSTALL_ROOT/core" > "$MNT$SITE_DIR/freedomnas-core.pth" \
    || log "WARNING: could not place freedomnas-core.pth in the target's site-packages"
umount "$MNT/dev" || true

log "=== [8/8] First-boot wiring (cron @reboot -- FreeBSD ships cron by default) ==="
mkdir -p "$MNT$INSTALL_ROOT/webui/bin"
# Staged by freebsd/build.sh from freedomnas-profiles/assets -- the same
# scripts freedomnas-installer deploys.
for script in firstboot.sh supervisor.sh; do
    install -m 755 "$SEED/$script" "$MNT$INSTALL_ROOT/webui/bin/$script"
done

# FreeBSD's cron is vixie-cron heritage same as Debian's and supports the
# same @reboot macro -- but (unlike Debian) there's no /etc/cron.d/ drop-in
# directory in base, so this goes into the system crontab directly.
echo "@reboot root $INSTALL_ROOT/webui/bin/firstboot.sh >> /var/log/freedomnas-webui.log 2>&1" \
    >> "$MNT/etc/crontab"

# Passwordless sudo for the administrators' group: the WebUI runs updates as
# the signed-in user, and topgrade calls sudo itself for the steps needing
# root. FreeBSD keeps sudoers.d under /usr/local/etc, not /etc.
mkdir -p "$MNT/usr/local/etc/sudoers.d"
printf '%s\n' \
    '# FreedomNAS: the WebUI runs updates as the signed-in user,' \
    '# and topgrade calls sudo itself for the steps that need root.' \
    '%wheel ALL=(ALL) NOPASSWD: ALL' \
    > "$MNT/usr/local/etc/sudoers.d/freedomnas"
chmod 0440 "$MNT/usr/local/etc/sudoers.d/freedomnas"

log "=== Cleanup ==="
umount "$MNT/boot/efi" || true
# Marks the pool as a genuinely completed build. The VirtualBox backend
# (see vbox-driver.sh) has no console text to check for
# FNAS_BUILD_MARKER_SUCCESS/FAILED like the QEMU/expect path does --
# both success and fail() end in a plain `poweroff`, so a bare "VM
# stopped" signal can't tell the two apart. This property is what lets
# the host distinguish them after the fact: set only on this path, on
# the imported pool, before it's exported for the last time.
zfs set fnas:build_complete=yes "$POOL" || true
zfs umount -a || true
zpool export "$POOL" || true

echo "FNAS_BUILD_MARKER_SUCCESS"
poweroff
