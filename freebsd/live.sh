#!/bin/sh
# freebsd/live.sh — produces freedomnas-live-freebsd.iso: a FreeBSD live
# system that boots on UEFI and BIOS, from optical media or dd'd to USB,
# and starts freedomnas-install on the first console.
#
# The FreeBSD counterpart of live/build.sh. It is a separate ISO because
# the installer only offers targets of its host's own family (a FreeBSD
# target needs gpart, pkg and FreeBSD's zpool), so FreeBSD installs have
# to run from FreeBSD.
#
# Built the way the FreeBSD release builds disc1: the ISO's cd9660 file
# system is the read-only root (the loader finds it through /etc/fstab,
# by volume label), rc puts /tmp and /var in memory because / isn't
# writable, and the hybrid boot area -- protective MBR + GPT with isoboot
# for BIOS from USB, an El Torito EFI system partition for UEFI -- is
# what release/amd64/mkisoimages.sh writes.
#
# Like freebsd/build.sh, the FreeBSD-only tools (pkg, makefs, mkimg,
# etdump) run inside a FreeBSD guest (freebsd/mfsbsd.sh: FreeBSD's own VM
# image of the target release with QEMU, mfsBSD otherwise), which runs
# freebsd/guest/live-in-guest.sh. The guest builds the ISO in memory and
# writes it to the start of a scratch disk; this script cuts the ISO back
# out of that disk at the size its primary volume descriptor records, and
# a volume descriptor with the expected label is what tells a finished
# build from a failed one.
#
# Host tools: curl, python3, rsync, tar, sha256sum, plus the backend's
# (see freebsd/mfsbsd.sh). The guest needs more memory than an image
# build, for the tree and the ISO it holds in RAM: QEMU_MEM / VBOX_MEM
# default to 6144 here.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
REPOS_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

ISO_PATH="${1:-$SCRIPT_DIR/freedomnas-live-freebsd.iso}"
DISK_SIZE="${FNAS_LIVE_DISK_SIZE:-4G}"
VOLID="FNAS_BSD_LIVE"

QEMU_MEM="${QEMU_MEM:-6144}"
VBOX_MEM="${VBOX_MEM:-6144}"
export QEMU_MEM VBOX_MEM

. "$SCRIPT_DIR/mfsbsd.sh"
. "$COMMON_DIR/install-core.sh"

for tool in curl python3 rsync tar sha256sum; do
    command -v "$tool" >/dev/null || { echo "live.sh: $tool not found" >&2; exit 1; }
done

SEED_DIR="$(mktemp -d)"
STAGE_DIR="$(mktemp -d)"
DISK="$(dirname "$ISO_PATH")/.fnas-live-disk-$$.img"
cleanup() {
    rm -rf "$SEED_DIR" "$STAGE_DIR"
    rm -f "$DISK"
}
trap cleanup EXIT

echo "=== [1/4] Staging freedomnas-core/profiles/webui/installer ==="
fnas_install_core "$STAGE_DIR" "$REPOS_DIR"
mkdir -p "$STAGE_DIR/usr/lib/freedomnas/installer"
rsync -a --exclude='.git' --exclude='__pycache__' --exclude='tests' \
    --exclude='debian' --exclude='PKGBUILD' --exclude='*.md' \
    "$REPOS_DIR/freedomnas-installer/" "$STAGE_DIR/usr/lib/freedomnas/installer/"
chmod 755 "$STAGE_DIR/usr/lib/freedomnas/installer/setup.py"
fnas_channel "$REPOS_DIR/freedomnas-installer" > "$STAGE_DIR/usr/lib/freedomnas/installer/CHANNEL"
tar -cf "$SEED_DIR/fnas-payload.tar" --owner=0 --group=0 -C "$STAGE_DIR/usr/lib/freedomnas" .
cp "$SCRIPT_DIR/guest/live-in-guest.sh" "$SEED_DIR/live-in-guest.sh"

# Where FreeBSD keeps FreedomNAS, and the Python stack the core imports,
# are freedomnas-profiles' data (os/os-freebsd.json, packages/core.json).
# cdialog is the live environment's own need: the installer's dialogs.
INSTALL_ROOT="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["paths"]["install_root"])' \
    "$REPOS_DIR/freedomnas-profiles/os/os-freebsd.json")"
PACKAGES="$(python3 -c 'import json, sys; print(" ".join(p for p in json.load(open(sys.argv[1]))["freebsd"]["packages"] if not p.startswith("freedomnas-")))' \
    "$REPOS_DIR/freedomnas-profiles/packages/core.json") cdialog"
cat > "$SEED_DIR/env.sh" <<EOF
FREEBSD_RELEASE="$FREEBSD_RELEASE"
INSTALL_ROOT="$INSTALL_ROOT"
PACKAGES="$PACKAGES"
VOLID="$VOLID"
EOF

echo "=== [2/4] Preparing the scratch disk ($DISK_SIZE) ==="
rm -f "$DISK"
truncate -s "$DISK_SIZE" "$DISK"

echo "=== [3/4] Fetching the build environment (cached under freebsd/.cache/) ==="
fnas_fetch_build_env

echo "=== [4/4] Booting $(basename "$(fnas_build_env)") (backend: $FREEBSD_BACKEND) and running live-in-guest.sh ==="
fnas_run_guest "$DISK" "$SEED_DIR" live-in-guest.sh

echo "=== Extracting the ISO from the scratch disk ==="
mkdir -p "$(dirname "$ISO_PATH")"
python3 - "$DISK" "$ISO_PATH" "$VOLID" <<'PYEOF'
import shutil
import struct
import sys

disk, iso, volid = sys.argv[1:4]
with open(disk, "rb") as src:
    src.seek(-2 * 1048576, 2)
    tail = src.read()
    if tail.startswith(b"FNAS-GUEST-LOG\n"):
        print("=== live-in-guest.sh log ===", file=sys.stderr)
        print(tail[15:].split(b"\0", 1)[0].decode("utf-8", "replace"), file=sys.stderr)
        print("=== end of the log ===", file=sys.stderr)
    else:
        print("live.sh: the guest wrote no log", file=sys.stderr)
    src.seek(16 * 2048)
    pvd = src.read(2048)
    if pvd[0] != 1 or pvd[1:6] != b"CD001":
        sys.exit("live.sh: no ISO 9660 volume on the scratch disk -- live-in-guest.sh failed")
    label = pvd[40:72].decode("ascii", "replace").strip()
    if label != volid:
        sys.exit(f"live.sh: the scratch disk holds volume {label!r}, not {volid!r}")
    blocks = struct.unpack("<I", pvd[80:84])[0]
    block_size = struct.unpack("<H", pvd[128:130])[0]
    size = blocks * block_size
    src.seek(0)
    with open(iso, "wb") as dst:
        remaining = size
        while remaining:
            chunk = src.read(min(remaining, 1 << 20))
            if not chunk:
                sys.exit("live.sh: the scratch disk is shorter than the ISO it records")
            dst.write(chunk)
            remaining -= len(chunk)
print(f"live.sh: {volid}, {size // (1 << 20)} MiB")
PYEOF
( cd "$(dirname "$ISO_PATH")" && sha256sum "$(basename "$ISO_PATH")" > "$(basename "$ISO_PATH").sha256" )
echo "live.sh: wrote $ISO_PATH"
