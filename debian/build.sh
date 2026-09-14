#!/bin/sh
# debian/build.sh — produces debian.img.zst: a single image bootable on
# both UEFI and BIOS, with freedomnas-core/profiles/webui baked in.
#
# Ports freedomnas-installer/lib/{disk_installer,zfs_installer,
# system_installer,packages_installer,bootloader_installer}.py from
# "run interactively against a live disk" to "run non-interactively
# against a loopback image file in CI". See IMAGE-BASED-INSTALLATION.md
# and freedomnas-image-builder/README.md for why this exists.
#
# Dual-boot design note (deliberately different from the live installer):
# the live installer calls `efibootmgr` to register a UEFI NVRAM boot
# entry, which only makes sense against a real, currently-running
# machine's firmware -- there is no NVRAM to write to at image-build
# time. Instead this script *always* deploys the full Clover chain
# (boot0/boot1/boot7 + CLOVERX64.efi + BOOTX64.efi + config.plist).
# BOOTX64.efi at EFI/BOOT/ is the UEFI-spec-mandated fallback path that
# firmware boots automatically when no NVRAM entries exist -- which is
# exactly the state of a freshly flashed disk. Clover happily runs
# under real UEFI as well as its own BIOS-emulated-UEFI (DUET) path, so
# deploying it once, unconditionally, is sufficient to boot the same
# image under both firmware types. (A real UEFI NVRAM entry can still
# be registered manually after flashing, for a named boot-menu item --
# it's a nicety, not a requirement.)
#
# Requires root, loop devices, and a ZFS-capable kernel -- run on the
# self-hosted runner described in ../docs/ci-setup.md, or in a
# disposable VM with equivalent access.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
REPOS_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"     # sibling repo checkouts
ASSETS_DIR="$REPOS_DIR/freedomnas-profiles/assets"

EDITION="debian"
IMG_PATH="${1:-$SCRIPT_DIR/debian.img}"
IMG_SIZE="${2:-8G}"
MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
MNT="/mnt/fnas-build-$EDITION"
ROOT_DATASET="rpool/ROOT/$EDITION"

. "$COMMON_DIR/partition.sh"
. "$COMMON_DIR/zfs-layout.sh"
. "$COMMON_DIR/install-core.sh"
. "$COMMON_DIR/compress.sh"

# Core packages required on every FreedomNAS Debian image (ported verbatim
# from freedomnas-installer/lib/packages_installer.py's _BASE_PACKAGES).
BASE_PACKAGES="linux-image-amd64 linux-headers-amd64 zfsutils-linux zfs-dracut
zfs-zed dracut efibootmgr dosfstools python3 python3-pip python3-fastapi
python3-uvicorn python3-yaml python3-pam samba nfs-kernel-server topgrade
curl sudo locales"

cleanup() {
    umount -R "$MNT" 2>/dev/null || true
    fnas_zfs_layout_cleanup rpool
    fnas_partition_cleanup
}
trap cleanup EXIT

mkdir -p "$MNT"

echo "=== [1/9] Partitioning $IMG_PATH ($IMG_SIZE) ==="
fnas_partition "$IMG_PATH" "$IMG_SIZE"

echo "=== [2/9] Creating ZFS pool + datasets ==="
fnas_zfs_layout "$PART2" "$EDITION" "$MNT" rpool

echo "=== [3/9] debootstrap trixie ==="
debootstrap --arch=amd64 trixie "$MNT" "$MIRROR"

echo "=== [4/9] Base configuration (hostname/hosts/fstab/sources.list) ==="
echo "freedomnas" > "$MNT/etc/hostname"
cat > "$MNT/etc/hosts" <<EOF
127.0.0.1  localhost
127.0.1.1  freedomnas.local freedomnas

::1        localhost ip6-localhost ip6-loopback
ff02::1    ip6-allnodes
ff02::2    ip6-allrouters
EOF
mkdir -p "$MNT/boot/efi"
echo "$PART1  /boot/efi  vfat  defaults  0  2" >> "$MNT/etc/fstab"
cat > "$MNT/etc/apt/sources.list" <<EOF
deb $MIRROR trixie main contrib non-free non-free-firmware
deb $MIRROR trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

echo "=== [5/9] chroot bind mounts ==="
for m in dev dev/pts proc sys run; do
    mkdir -p "$MNT/$m"
    mount --bind "/$m" "$MNT/$m"
done
cp /etc/resolv.conf "$MNT/etc/resolv.conf"

echo "=== [6/9] Installing packages in chroot ==="
chroot "$MNT" apt-get update -qq
# shellcheck disable=SC2086
chroot "$MNT" apt-get install -y --no-install-recommends $BASE_PACKAGES

echo "=== [7/9] Installing freedomnas-core/profiles/webui ==="
fnas_install_core "$MNT" "$REPOS_DIR"

echo "=== [8/9] Boot chain (UKI + Clover, universal UEFI+BIOS) ==="
mount "$PART1" "$MNT/boot/efi"
mkdir -p "$MNT/boot/efi/EFI/Linux"
KERNEL_VERSION="$(ls "$MNT/lib/modules" | sort -V | tail -n1)"
chroot "$MNT" dracut --force --uefi \
    --kernel-cmdline "root=ZFS=$ROOT_DATASET rw" \
    /boot/efi/EFI/Linux/debian-uki.efi "$KERNEL_VERSION"
chroot "$MNT" dracut --force --uefi \
    --kernel-cmdline "root=ZFS=$ROOT_DATASET ro single" \
    /boot/efi/EFI/Linux/debian-recovery.efi "$KERNEL_VERSION"

mkdir -p "$MNT/etc/kernel/postinst.d"
cp "$ASSETS_DIR/zz-dracut-uki" "$MNT/etc/kernel/postinst.d/zz-dracut-uki"
chmod 755 "$MNT/etc/kernel/postinst.d/zz-dracut-uki"

# Clover deployment (pinned release -- see assets/clover/README.md,
# do not bump without hardware validation). boot0/boot1 are raw sector
# writes onto the loop device / ESP, same offsets as
# bootloader_installer.py's _write_boot0()/_write_boot1().
python3 - "$LOOP" "$PART1" "$ASSETS_DIR/clover" "$MNT/boot/efi" <<'PYEOF'
import sys
from pathlib import Path

loop, part1, clover_dir, esp_mount = sys.argv[1:5]
clover_dir = Path(clover_dir)
esp_mount = Path(esp_mount)

with open(loop, "r+b") as disk:
    disk.write(clover_dir.joinpath("boot0ss").read_bytes()[:440])

boot1 = bytearray(clover_dir.joinpath("boot1f32alt").read_bytes())
with open(part1, "r+b") as esp:
    original = esp.read(512)
    boot1[3:90] = original[3:90]
    esp.seek(0)
    esp.write(bytes(boot1))

for sub in ("boot", "EFI/CLOVER", "EFI/BOOT"):
    (esp_mount / sub).mkdir(parents=True, exist_ok=True)

import shutil
shutil.copy2(clover_dir / "boot7", esp_mount / "boot" / "boot7")
shutil.copy2(clover_dir / "CLOVERX64.efi", esp_mount / "EFI" / "CLOVER" / "CLOVERX64.efi")
shutil.copy2(clover_dir / "BOOTX64.efi", esp_mount / "EFI" / "BOOT" / "BOOTX64.efi")

(esp_mount / "EFI" / "CLOVER" / "config.plist").write_text("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Boot</key>
    <dict>
        <key>Timeout</key><integer>0</integer>
        <key>Fast</key><true/>
        <key>DefaultVolume</key><string>EFI</string>
        <key>DefaultLoader</key><string>\\EFI\\Linux\\debian-uki.efi</string>
        <key>IgnoreNVRAMBoot</key><true/>
    </dict>
    <key>GUI</key>
    <dict>
        <key>Scan</key><dict><key>Entries</key><true/><key>Legacy</key><false/><key>Tool</key><false/></dict>
        <key>Custom</key><dict><key>Entries</key><array><dict>
            <key>Volume</key><string>EFI</string>
            <key>Path</key><string>\\EFI\\Linux\\debian-uki.efi</string>
            <key>Type</key><string>Linux</string>
            <key>Title</key><string>FreedomNAS</string>
        </dict></array></dict>
    </dict>
    <key>Debug</key><false/>
</dict>
</plist>
""")
PYEOF

echo "=== [9/9] First-boot wiring + supervisor ==="
mkdir -p "$MNT/usr/lib/freedomnas/webui/bin"
# The same boot-time scripts freedomnas-installer deploys, from
# freedomnas-profiles/assets: firstboot.sh releases every pool it imported
# only to look for a .freedomnas dataset, and supervisor.sh serves the WebUI
# over TLS once firstboot has generated the certificate.
for script in firstboot.sh supervisor.sh; do
    install -m 755 "$ASSETS_DIR/$script" "$MNT/usr/lib/freedomnas/webui/bin/$script"
done

# cron now launches firstboot.sh (which execs into supervisor.sh itself)
# instead of supervisor.sh directly -- this is the literal ADR-002 hook.
echo "@reboot root /usr/lib/freedomnas/webui/bin/firstboot.sh >> /var/log/freedomnas-webui.log 2>&1" \
    > "$MNT/etc/cron.d/freedomnas-webui"

# Passwordless sudo for the administrators' group: the WebUI runs updates as
# the signed-in user, and topgrade calls sudo itself for the steps needing
# root. Same drop-in freedomnas-installer writes.
mkdir -p "$MNT/etc/sudoers.d"
printf '%s\n' \
    '# FreedomNAS: the WebUI runs updates as the signed-in user,' \
    '# and topgrade calls sudo itself for the steps that need root.' \
    '%sudo ALL=(ALL) NOPASSWD: ALL' \
    > "$MNT/etc/sudoers.d/freedomnas"
chmod 0440 "$MNT/etc/sudoers.d/freedomnas"

echo "=== Unmounting and compressing ==="
umount "$MNT/boot/efi"
for m in run sys proc dev/pts dev; do umount "$MNT/$m" 2>/dev/null || true; done
zpool export rpool
losetup -d "$LOOP"
trap - EXIT   # cleanup already done manually above, in the right order

fnas_compress "$IMG_PATH"
echo "Done: ${IMG_PATH}.zst"
