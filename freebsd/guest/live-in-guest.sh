#!/bin/sh
# freebsd/guest/live-in-guest.sh — runs INSIDE the FreeBSD build
# environment (see freebsd/live.sh and freebsd/mfsbsd.sh: FreeBSD's own VM
# image of the target release with QEMU, mfsBSD otherwise) and builds the
# FreeBSD live installer ISO.
#
# The seed is mounted at /fnas-seed before this runs: env.sh (release,
# install root, packages, volume label) and fnas-payload.tar (core,
# profiles, webui and installer, laid out as <install_root>/).
#
# Everything is built in a tmpfs, not on disk: the only disk attached is
# the scratch disk the finished ISO is written to, from its first byte,
# for live.sh to cut back out. So this needs memory for the tree plus the
# ISO (live.sh gives the guest 6 GiB).
#
# makefs, mkimg, etdump and pkg run from the extracted release through
# chroot, not from the build environment: mfsBSD is older and doesn't
# necessarily ship them, and its pkg wrote a package database the live
# system's pkg could not open. The
# tree reaches the chroot as a read-only nullfs view of itself
# (/tmp/fnas-src), and the output goes to a tmpfs mounted inside it
# (/tmp/fnas-out): nullfs doesn't show mounts below it, so the ISO being
# written is never part of the tree being read.
#
# Ends with `poweroff` either way; on failure nothing is written to the
# scratch disk, and live.sh finds no volume there.
set -eu

SEED=/fnas-seed
WORK=/fnas-live
[ -f "$SEED/env.sh" ] && . "$SEED/env.sh"

log() { echo "guest-live: $*"; }

fail() {
    log "FAILED: $*"
    poweroff
    exit 1
}

[ -n "${FREEBSD_RELEASE:-}" ] && [ -n "${INSTALL_ROOT:-}" ] && [ -n "${PACKAGES:-}" ] && [ -n "${VOLID:-}" ] \
    || fail "env.sh names no FREEBSD_RELEASE/INSTALL_ROOT/PACKAGES/VOLID"
MIRROR="${FREEBSD_MIRROR:-https://download.freebsd.org/ftp/releases/amd64/amd64/$FREEBSD_RELEASE}"

DISK="${FNAS_TARGET_DISK:-}"
[ -n "$DISK" ] || for candidate in /dev/vtbd0 /dev/ada0 /dev/da0; do
    [ -e "$candidate" ] && DISK="$candidate" && break
done
[ -n "$DISK" ] || fail "no scratch disk found (checked vtbd0, ada0, da0)"
log "Scratch disk: $DISK"

IFACE=$(ifconfig -l ether | awk '{print $1}')
[ -n "$IFACE" ] || fail "no ethernet interface found via 'ifconfig -l ether'"
ifconfig "$IFACE" | grep -q 'inet ' || dhclient "$IFACE" || fail "dhclient $IFACE"

mkdir -p "$WORK"
mount -t tmpfs tmpfs "$WORK" || fail "mount tmpfs on $WORK"
ROOT="$WORK/root"
mkdir -p "$ROOT" "$WORK/dist"

log "=== [1/6] Fetching + extracting base.txz/kernel.txz ($FREEBSD_RELEASE) ==="
for set in base kernel; do
    fetch -o "$WORK/dist/$set.txz" "$MIRROR/$set.txz" || fail "fetch $set.txz from $MIRROR"
    tar -xf "$WORK/dist/$set.txz" -C "$ROOT" || fail "extract $set.txz"
    rm -f "$WORK/dist/$set.txz"
done

log "=== [2/6] Packages: $PACKAGES ==="
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
mount -t devfs devfs "$ROOT/dev" || fail "mount devfs"
chroot "$ROOT" env ASSUME_ALWAYS_YES=yes pkg bootstrap -f || fail "pkg bootstrap"
# Retried for the same transient catalogue-fetch failures build-in-guest.sh
# works around.
pkg_install_ok=1
for attempt in 1 2 3; do
    # shellcheck disable=SC2086
    if chroot "$ROOT" pkg install -y $PACKAGES; then
        pkg_install_ok=0
        break
    fi
    log "pkg install attempt $attempt failed, retrying in 10s..."
    sleep 10
done
[ "$pkg_install_ok" -eq 0 ] || fail "pkg install (3 attempts)"
chroot "$ROOT" pkg clean -ay >/dev/null 2>&1 || true
rm -rf "$ROOT/var/cache/pkg/"* "$ROOT/var/db/pkg/repos"
umount "$ROOT/dev" || true

log "=== [3/6] FreedomNAS core/profiles/webui/installer in $INSTALL_ROOT ==="
mkdir -p "$ROOT$INSTALL_ROOT"
tar -xf "$SEED/fnas-payload.tar" -C "$ROOT$INSTALL_ROOT/" || fail "extract the FreedomNAS payload"
SITE_DIR="$(chroot "$ROOT" python3 -c "import sysconfig; print(sysconfig.get_path('purelib'))")"
[ -n "$SITE_DIR" ] || fail "no site-packages in the live python3"
echo "$INSTALL_ROOT/core" > "$ROOT$SITE_DIR/freedomnas-core.pth"
ln -sf "$INSTALL_ROOT/installer/setup.py" "$ROOT/usr/local/bin/freedomnas-install"

log "=== [4/6] Live configuration ==="
cat > "$ROOT/etc/fstab" <<EOF
/dev/iso9660/$VOLID / cd9660 ro 0 0
EOF
# / stays read-only: rc builds /tmp and /var in memory by itself when they
# aren't writable, sized here for the installer's temporary files and logs.
cat > "$ROOT/etc/rc.conf" <<EOF
hostname="freedomnas-live"
ifconfig_DEFAULT="DHCP"
root_rw_mount="NO"
tmpmfs="YES"
tmpsize="512m"
varmfs="YES"
varsize="128m"
sendmail_enable="NONE"
hostid_enable="NO"
update_motd="NO"
entropy_file="NO"
dumpdev="NO"
EOF
# resolvconf writes where / is writable; /etc/resolv.conf points there.
echo 'resolv_conf="/tmp/resolv.conf"' > "$ROOT/etc/resolvconf.conf"
rm -f "$ROOT/etc/resolv.conf"
ln -s /tmp/resolv.conf "$ROOT/etc/resolv.conf"

# zfs.ko for the installer's zpool; both consoles, so a machine with only
# a serial line can install too.
cat > "$ROOT/boot/loader.conf" <<EOF
zfs_load="YES"
autoboot_delay="5"
boot_multicons="YES"
console="vidconsole,comconsole"
vfs.mountroot.timeout="10"
kernels_autodetect="NO"
EOF

# Root logs in by itself on the first virtual console and on the serial
# console; freedomnas-install starts on the first virtual console.
cat >> "$ROOT/etc/gettytab" <<'EOF'

fnas.autologin|FreedomNAS live console, root logged in:\
	:al=root:tc=Pc:
fnas.autologin.serial|FreedomNAS live serial console, root logged in:\
	:al=root:tc=3wire.115200:
EOF
sed -i '' \
    -e 's|^ttyv0[[:space:]].*|ttyv0	"/usr/libexec/getty fnas.autologin"	xterm	onifexists secure|' \
    -e 's|^ttyu0[[:space:]].*|ttyu0	"/usr/libexec/getty fnas.autologin.serial"	vt100	onifconsole secure|' \
    "$ROOT/etc/ttys"
grep -q '^ttyv0.*fnas.autologin' "$ROOT/etc/ttys" || fail "could not enable autologin on ttyv0"
cat >> "$ROOT/root/.profile" <<'EOF'

if [ "$(tty)" = /dev/ttyv0 ] && [ ! -e /tmp/freedomnas-install.started ]; then
    : > /tmp/freedomnas-install.started
    freedomnas-install
    echo
    echo "freedomnas-install exited. Run it again with: freedomnas-install"
fi
EOF

log "=== [5/6] Building the hybrid ISO ($VOLID) ==="
mkdir -p "$ROOT/tmp/fnas-src" "$ROOT/tmp/fnas-out"
mount -t nullfs -o ro "$ROOT" "$ROOT/tmp/fnas-src" || fail "nullfs view of the tree"
mount -t tmpfs tmpfs "$ROOT/tmp/fnas-out" || fail "tmpfs for the ISO"
OUT="$ROOT/tmp/fnas-out"

# The EFI system partition image El Torito points UEFI firmware at, as
# tools/boot/install-boot.sh's make_esp_file builds it.
mkdir -p "$OUT/esp/EFI/BOOT"
cp "$ROOT/boot/loader.efi" "$OUT/esp/EFI/BOOT/BOOTX64.efi"
chroot "$ROOT" makefs -t msdos -o fat_type=12 -o sectors_per_cluster=1 \
    -o volume_label=EFISYS -s 2048k /tmp/fnas-out/efiboot.img /tmp/fnas-out/esp \
    || fail "makefs the EFI system partition"

chroot "$ROOT" makefs -D -N /tmp/fnas-src/etc -t cd9660 \
    -o 'bootimage=i386;/tmp/fnas-src/boot/cdboot' -o no-emul-boot \
    -o 'bootimage=i386;/tmp/fnas-out/efiboot.img' -o no-emul-boot -o platformid=efi \
    -o rockridge -o label="$VOLID" -o publisher="FreedomNAS" \
    /tmp/fnas-out/live.iso /tmp/fnas-src || fail "makefs the ISO"

# Protective MBR + GPT with isoboot in the ISO's system area, and the ESP
# found through the El Torito catalogue, so the same file boots from USB.
ESP_PARAM=""
for entry in $(chroot "$ROOT" etdump --format shell /tmp/fnas-out/live.iso); do
    eval "$entry"
    if [ "${et_platform:-}" = "efi" ]; then
        ESP_PARAM="-p efi::$((et_sectors * 512)):$((et_lba * 2048))"
        break
    fi
done
[ -n "$ESP_PARAM" ] || fail "no EFI entry in the ISO's El Torito catalogue"
ISO_SIZE="$(stat -f %z "$OUT/live.iso")"
# shellcheck disable=SC2086
chroot "$ROOT" mkimg -s gpt --capacity "$ISO_SIZE" \
    -b /tmp/fnas-src/boot/pmbr -p freebsd-boot:=/tmp/fnas-src/boot/isoboot \
    $ESP_PARAM -o /tmp/fnas-out/hybrid.img || fail "mkimg the hybrid boot area"
dd if="$OUT/hybrid.img" of="$OUT/live.iso" bs=32k count=1 conv=notrunc 2>/dev/null \
    || fail "write the hybrid boot area"

log "=== [6/6] Writing the ISO ($((ISO_SIZE / 1048576)) MiB) to $DISK ==="
DISK_SIZE="$(diskinfo "$DISK" | awk '{print $3}')"
[ "$ISO_SIZE" -le "$DISK_SIZE" ] || fail "the ISO ($ISO_SIZE bytes) doesn't fit on $DISK ($DISK_SIZE bytes)"
dd if="$OUT/live.iso" of="$DISK" bs=1m || fail "write the ISO to $DISK"
sync

umount "$ROOT/tmp/fnas-out" "$ROOT/tmp/fnas-src" || true
log "done"
poweroff
