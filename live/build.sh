#!/bin/sh
# live/build.sh — produces freedomnas-live.iso: a Gentoo live system that
# boots on UEFI and BIOS, from optical media or dd'd to USB, and starts
# freedomnas-install on tty1.
#
# One image for every Linux edition. The installer offers a native
# bootstrap method only when that method's tool exists on the machine it
# runs on (context.py, bootstrap_methods), so this image carries the
# tools itself: debootstrap for Debian, xbps-static for Void, and pacman
# with pacstrap and both keyrings for Arch and Artix, built from
# freedomnas-overlay. Gentoo needs nothing but tar.
#
# Built from the official stage3, verified against Gentoo's release key.
# The Portage configuration comes from installer-gentoo.json, so the live
# system and an installed Gentoo edition resolve packages the same way.
#
# Boot: grub-mkrescue writes a hybrid ISO (El Torito BIOS + EFI, plus the
# MBR/GPT that makes the same file bootable from a USB stick). The kernel
# mounts LiveOS/squashfs.img through dracut's dmsquash-live with an
# overlayfs upper layer in RAM.
#
# Requires root. Host tools: curl, gpgv, gpg, tar, xz, python3, rsync,
# sha256sum, arch-chroot (sys-apps/arch-chroot, which mounts and unmounts
# the API filesystems around every command). grub, xorriso and mksquashfs
# run inside the build root, so the host needs neither a BIOS-capable grub
# nor squashfs-tools.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
REPOS_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
PROFILE="$REPOS_DIR/freedomnas-profiles/installer/installer-gentoo.json"

ISO_PATH="${1:-$SCRIPT_DIR/freedomnas-live.iso}"
WORK="${FNAS_LIVE_WORK:-/var/tmp/freedomnas-live}"
MIRROR="${GENTOO_MIRROR:-https://distfiles.gentoo.org}"
RELEASE_KEY="${GENTOO_RELEASE_KEY:-/usr/share/openpgp-keys/gentoo-release.asc}"
RELEASE_KEY_URL="https://qa-reports.gentoo.org/output/service-keys.gpg"
XBPS_STATIC="https://repo-default.voidlinux.org/static"
VOLID="FNAS_LIVE"
# A public key file: root accepts it over SSH and sshd starts at boot, for
# machines with no usable screen or keyboard.
SSH_KEY="${FNAS_LIVE_SSH_KEY:-}"

ROOT="$WORK/root"
CACHE="$WORK/cache"
STAGING="/var/tmp/iso"

LIVE_PACKAGES="
sys-kernel/gentoo-kernel-bin sys-kernel/linux-firmware sys-fs/zfs
sys-kernel/dracut sys-fs/lvm2 sys-fs/squashfs-tools sys-boot/grub
dev-libs/libisoburn sys-fs/mtools
dev-util/dialog dev-python/pyyaml dev-python/cryptography
sys-apps/gptfdisk sys-block/parted sys-fs/dosfstools sys-boot/efibootmgr
net-misc/curl net-misc/dhcpcd net-misc/openssh app-misc/tmux
dev-util/debootstrap app-crypt/debian-archive-keyring
sys-apps/arch-install-scripts app-crypt/archlinux-keyring app-crypt/artix-keyring
"

. "$COMMON_DIR/install-core.sh"

for tool in curl gpg gpgv tar xz python3 rsync sha256sum arch-chroot mount mountpoint; do
    command -v "$tool" >/dev/null || { echo "live/build.sh: $tool not found" >&2; exit 1; }
done
[ "$(id -u)" -eq 0 ] || { echo "live/build.sh: must run as root" >&2; exit 1; }
[ -f "$PROFILE" ] || { echo "live/build.sh: missing $PROFILE" >&2; exit 1; }
# Checked now, not when the root is already built: a typo would cost a whole build.
if [ -n "$SSH_KEY" ]; then
    grep -Eq '^(ssh-|ecdsa-|sk-)' "$SSH_KEY" 2>/dev/null || {
        echo "live/build.sh: $SSH_KEY is not a readable SSH public key" >&2; exit 1; }
fi
case "$WORK" in
    /?*) ;;
    *) echo "live/build.sh: FNAS_LIVE_WORK must be an absolute path other than /" >&2; exit 1 ;;
esac

in_root() {
    arch-chroot "$ROOT" /usr/bin/env -i HOME=/root TERM="${TERM:-linux}" \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        LC_ALL=C.UTF-8 LANG=C.UTF-8 "$@"
}

under_root_mounted() {
    awk -v r="$ROOT" '$2 == r || index($2, r "/") == 1 { found = 1 } END { exit !found }' /proc/mounts
}

unmount_root() {
    for m in var/cache/binpkgs var/cache/distfiles var/db/repos/gentoo; do
        mountpoint -q "$ROOT/$m" && umount -R -l "$ROOT/$m"
    done
    mountpoint -q "$ROOT" && umount -l "$ROOT"
    return 0
}
trap unmount_root EXIT

if under_root_mounted; then
    echo "live/build.sh: something is still mounted under $ROOT — refusing to delete it" >&2
    exit 1
fi
rm -rf "$ROOT"
mkdir -p "$ROOT" "$CACHE/stage3" "$CACHE/distfiles" "$CACHE/binpkgs" "$CACHE/repos-gentoo" "$CACHE/xbps"

echo "=== [1/9] Fetching and verifying the latest stage3 ==="
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
KEYRING="$GNUPGHOME/gentoo.gpg"
if [ -f "$RELEASE_KEY" ]; then
    gpg --dearmor < "$RELEASE_KEY" > "$KEYRING"
else
    curl -fsSL "$RELEASE_KEY_URL" | gpg --dearmor > "$KEYRING"
fi

AUTOBUILDS="$MIRROR/releases/amd64/autobuilds"
POINTER="$CACHE/stage3/latest-stage3-amd64-openrc.txt"
curl -fsSL -o "$POINTER" "$AUTOBUILDS/latest-stage3-amd64-openrc.txt"
gpgv --keyring "$KEYRING" "$POINTER"
STAGE3_PATH="$(sed -n '/^-----BEGIN PGP SIGNATURE/q;/^[0-9]/p' "$POINTER" | awk 'NR == 1 { print $1 }')"
[ -n "$STAGE3_PATH" ] || { echo "live/build.sh: no stage3 listed in $POINTER" >&2; exit 1; }
STAGE3="$CACHE/stage3/$(basename "$STAGE3_PATH")"
if [ ! -f "$STAGE3" ]; then
    curl -fL --retry 3 -o "$STAGE3.part" "$AUTOBUILDS/$STAGE3_PATH"
    mv -f "$STAGE3.part" "$STAGE3"
fi
curl -fsSL -o "$STAGE3.asc" "$AUTOBUILDS/$STAGE3_PATH.asc"
gpgv --keyring "$KEYRING" "$STAGE3.asc" "$STAGE3"
rm -rf "$GNUPGHOME"

echo "=== [2/9] Unpacking $(basename "$STAGE3") ==="
tar -xpf "$STAGE3" -C "$ROOT" --xattrs-include='*.*' --numeric-owner
# arch-chroot binds the host's resolv.conf only over a file that exists.
: > "$ROOT/etc/resolv.conf"

echo "=== [3/9] Portage configuration and freedomnas-overlay ==="
python3 - "$PROFILE" "$ROOT" "$MIRROR" <<'PYEOF'
import json
import sys
from pathlib import Path

profile, root, mirror = sys.argv[1:4]
files = json.loads(Path(profile).read_text())["files"]
values = {"mirror": mirror, "arch": "amd64"}
for key in ("make_conf", "binrepos_conf", "package_use", "package_accept_keywords"):
    entry = files[key]
    path = Path(root) / entry["path"].lstrip("/")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(entry["content"].format(**values))
PYEOF
# For this build only, not for an installed Gentoo (installer-gentoo.json's
# make.conf stays as it is): every core of the build host, and what is
# compiled kept in the binpkgs cache, bind-mounted from $CACHE. The binhost
# has no ZFS, so without buildpkg every build compiled it again. Packages
# built here carry no signature, which binpkg-request-signature refuses even
# for them: the binhost's signatures stay mandatory through binrepos.conf's
# verify-signature instead, which leaves local packages alone.
cat >> "$ROOT/etc/portage/make.conf" <<EOF

# live/build.sh
MAKEOPTS="-j$(nproc)"
FEATURES="\${FEATURES} buildpkg -binpkg-request-signature"
EOF
for conf in "$ROOT"/etc/portage/binrepos.conf/*.conf; do
    printf 'verify-signature = true\n' >> "$conf"
done
cat > "$ROOT/etc/portage/package.use/freedomnas-live" <<'EOF'
# The live initramfs is built by this script with dmsquash-live, not by
# the kernel package's own hook.
sys-kernel/gentoo-kernel-bin -initramfs
sys-boot/grub grub_platforms_pc grub_platforms_efi-64
sys-fs/squashfs-tools lzma
EOF
cat > "$ROOT/etc/portage/package.accept_keywords/freedomnas-live" <<'EOF'
sys-apps/pacman ~amd64
sys-apps/arch-install-scripts ~amd64
app-crypt/archlinux-keyring ~amd64
app-crypt/artix-keyring ~amd64
EOF
mkdir -p "$ROOT/etc/portage/repos.conf" "$ROOT/var/db/repos/freedomnas"
cat > "$ROOT/etc/portage/repos.conf/freedomnas.conf" <<'EOF'
[freedomnas]
location = /var/db/repos/freedomnas
masters = gentoo
auto-sync = no
EOF
rsync -a --chown=0:0 --exclude='.git' "$REPOS_DIR/freedomnas-overlay/" "$ROOT/var/db/repos/freedomnas/"

echo "=== [4/9] Mounts ==="
mount --bind "$ROOT" "$ROOT"
for c in distfiles binpkgs; do
    mkdir -p "$ROOT/var/cache/$c"
    mount --bind "$CACHE/$c" "$ROOT/var/cache/$c"
done
mkdir -p "$ROOT/var/db/repos/gentoo"
mount --bind "$CACHE/repos-gentoo" "$ROOT/var/db/repos/gentoo"

echo "=== [5/9] Installing packages ==="
in_root emerge-webrsync --quiet
# shellcheck disable=SC2086
in_root emerge --quiet --noreplace $LIVE_PACKAGES

echo "=== [6/9] Bootstrap tools for the other editions ==="
# The "latest" line in sha256sums.txt can lag behind the file it names, so
# take the newest versioned tarball instead.
curl -fsSL -o "$CACHE/xbps/sha256sums.txt" "$XBPS_STATIC/sha256sums.txt"
XBPS_NAME="$(awk '{ print $2 }' "$CACHE/xbps/sha256sums.txt" \
    | grep '^xbps-static-static-[0-9][^ ]*\.x86_64-musl\.tar\.xz$' | sort -V | tail -n1)"
[ -n "$XBPS_NAME" ] || { echo "live/build.sh: no xbps-static tarball listed" >&2; exit 1; }
XBPS_TARBALL="$CACHE/xbps/$XBPS_NAME"
[ -f "$XBPS_TARBALL" ] || curl -fsSL -o "$XBPS_TARBALL" "$XBPS_STATIC/$XBPS_NAME"
XBPS_SUM="$(sha256sum "$XBPS_TARBALL" | awk '{ print $1 }')"
grep -qx "$XBPS_SUM  $XBPS_NAME" "$CACHE/xbps/sha256sums.txt" \
    || { rm -f "$XBPS_TARBALL"; echo "live/build.sh: $XBPS_NAME checksum mismatch" >&2; exit 1; }
tar -xJf "$XBPS_TARBALL" -C "$ROOT" --no-same-owner ./usr/bin ./var/db/xbps/keys

echo "=== [7/9] FreedomNAS installer and live configuration ==="
fnas_install_core "$ROOT" "$REPOS_DIR"
mkdir -p "$ROOT/usr/lib/freedomnas/installer"
rsync -a --chown=0:0 --exclude='.git' --exclude='__pycache__' --exclude='tests' \
    --exclude='debian' --exclude='PKGBUILD' --exclude='*.md' \
    "$REPOS_DIR/freedomnas-installer/" "$ROOT/usr/lib/freedomnas/installer/"
chmod 755 "$ROOT/usr/lib/freedomnas/installer/setup.py"
ln -sf ../lib/freedomnas/installer/setup.py "$ROOT/usr/bin/freedomnas-install"

echo 'hostname="freedomnas-live"' > "$ROOT/etc/conf.d/hostname"
sed -i 's|^\(c1:.*agetty\) |\1 --autologin root |' "$ROOT/etc/inittab"
grep -q '^c1:.*--autologin root' "$ROOT/etc/inittab" \
    || { echo "live/build.sh: could not enable autologin on tty1" >&2; exit 1; }
cat > "$ROOT/root/.bash_profile" <<'EOF'
[ -f ~/.bashrc ] && . ~/.bashrc
if [ "$(tty)" = /dev/tty1 ] && [ ! -e /run/freedomnas-install.started ]; then
    : > /run/freedomnas-install.started
    # An image build (common/vm-install.sh) attaches a disc labelled
    # FNASSEED: run its script unattended instead of the menus.
    seed="$(blkid -L FNASSEED 2>/dev/null || true)"
    if [ -n "$seed" ]; then
        mkdir -p /run/fnas-seed
        mount -o ro "$seed" /run/fnas-seed
        sh /run/fnas-seed/run.sh 2>&1 | tee /dev/ttyS0
        poweroff
    fi
    freedomnas-install
    echo
    echo "freedomnas-install exited. Run it again with: freedomnas-install"
fi
EOF
in_root rc-update add dhcpcd default
if [ -n "$SSH_KEY" ]; then
    install -d -m 700 "$ROOT/root/.ssh"
    install -m 600 "$SSH_KEY" "$ROOT/root/.ssh/authorized_keys"
    in_root rc-update add sshd default
fi

echo "=== [8/9] initramfs and squashfs ==="
KV="$(ls "$ROOT/lib/modules" | sort -V | tail -n1)"
KERNEL=""
for candidate in "boot/vmlinuz-$KV" "lib/modules/$KV/vmlinuz" "usr/src/linux-$KV/arch/x86/boot/bzImage"; do
    [ -f "$ROOT/$candidate" ] && { KERNEL="$candidate"; break; }
done
[ -n "$KERNEL" ] || { echo "live/build.sh: no kernel image found for $KV" >&2; exit 1; }

rm -rf "$ROOT$STAGING"
mkdir -p "$ROOT$STAGING/boot/grub" "$ROOT$STAGING/LiveOS" "$ROOT/var/tmp/out"
cp "$ROOT/$KERNEL" "$ROOT$STAGING/boot/vmlinuz"
in_root dracut --force --no-hostonly --add dmsquash-live --omit zfs \
    "$STAGING/boot/initramfs.img" "$KV"

in_root mksquashfs / "$STAGING/LiveOS/squashfs.img" \
    -noappend -comp xz -Xbcj x86 -b 1M -wildcards \
    -e 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*' 'var/tmp/*' 'etc/resolv.conf' \
       'var/cache/distfiles/*' 'var/cache/binpkgs/*' 'var/db/repos/gentoo/*' \
       'var/db/repos/freedomnas/*' 'usr/src/*'

echo "=== [9/9] Hybrid UEFI + BIOS ISO ==="
CMDLINE="root=live:CDLABEL=$VOLID rd.live.image rd.live.overlay.overlayfs=1"
cat > "$ROOT$STAGING/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0

menuentry "FreedomNAS installer" {
    linux /boot/vmlinuz $CMDLINE
    initrd /boot/initramfs.img
}

menuentry "FreedomNAS installer (serial console)" {
    linux /boot/vmlinuz $CMDLINE console=tty0 console=ttyS0,115200
    initrd /boot/initramfs.img
}
EOF
in_root grub-mkrescue -o /var/tmp/out/freedomnas-live.iso "$STAGING" -- -volid "$VOLID"

mkdir -p "$(dirname "$ISO_PATH")"
mv -f "$ROOT/var/tmp/out/freedomnas-live.iso" "$ISO_PATH"
( cd "$(dirname "$ISO_PATH")" && sha256sum "$(basename "$ISO_PATH")" > "$(basename "$ISO_PATH").sha256" )
echo "live/build.sh: wrote $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1))" >&2
