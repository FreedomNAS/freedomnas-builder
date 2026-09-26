#!/bin/sh
# freebsd/qemu-driver.sh — QEMU backend.
#
# Drives the mfsBSD guest the same way vbox-driver.sh does, because the
# two things an earlier version of this driver relied on don't hold:
#   - mfsBSD's loader keeps the console on video, so a serial console
#     (and an expect script watching it) sees nothing -- see
#     vbox-driver.sh's header.
#   - The seed was a virtio-9p share mounted with Linux's 9p syntax,
#     which FreeBSD doesn't have, and QEMU builds without virtfs (e.g.
#     Gentoo's default USE) don't offer virtio-9p-pci at all.
#
# So:
#   - Payload delivery: the seed directory is burned onto a small ISO
#     labelled FNASSEED and attached as a second optical drive; the
#     guest mounts it by label (/dev/iso9660/FNASSEED), which doesn't
#     depend on how the drives enumerate.
#   - Input: keystrokes through the QEMU monitor's `sendkey`, over a
#     unix socket, on the same fixed timings vbox-driver.sh uses.
#   - Completion signal: build-in-guest.sh ends in `poweroff` either
#     way, and with -no-reboot QEMU exits when the guest powers off.
#   - Pass/fail: the fnas:build_complete property build-in-guest.sh sets
#     on the pool only on its success path, read back from the host.
#     The pool is imported read-only by GUID, as rpool unless the host
#     already has a pool of that name imported, then under a temporary
#     name, so the export afterwards can't touch the host's own pool.
#
# Requires qemu-system-x86_64, xorriso, python3, zpool, losetup and sudo.
set -eu

IMG_PATH="$1"
SEED_DIR="$2"
MFSBSD_ISO="$3"

WORK="$(mktemp -d)"
SEED_ISO="$WORK/seed.iso"
MON_SOCK="$WORK/monitor.sock"
VERIFY_POOL="fnasverify$$"

log() { echo "qemu-driver: $*" >&2; }

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

for tool in qemu-system-x86_64 xorriso python3 zpool losetup; do
    command -v "$tool" >/dev/null 2>&1 || { log "$tool not found"; exit 1; }
done

log "Building seed ISO from staged payload"
xorriso -as mkisofs -V FNASSEED -o "$SEED_ISO" "$SEED_DIR" >/dev/null 2>&1

KVM_ARGS=""
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM_ARGS="-enable-kvm -cpu host"
else
    log "/dev/kvm not usable -- falling back to slow TCG emulation"
fi

log "Starting QEMU (monitor: $MON_SOCK)"
# shellcheck disable=SC2086
qemu-system-x86_64 \
    $KVM_ARGS \
    -m "${QEMU_MEM:-2048}" -smp "${QEMU_SMP:-2}" \
    -no-reboot -display none -serial null \
    -monitor "unix:$MON_SOCK,server,nowait" \
    -drive "file=$IMG_PATH,if=virtio,format=raw" \
    -drive "file=$MFSBSD_ISO,media=cdrom,index=0,readonly=on" \
    -drive "file=$SEED_ISO,media=cdrom,index=1,readonly=on" \
    -boot d \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 &
QEMU_PID=$!

type_line() {
    python3 - "$MON_SOCK" "$1" <<'PYEOF'
import socket
import sys
import time

sock_path, text = sys.argv[1], sys.argv[2]
names = {" ": "spc", "-": "minus", "/": "slash", ".": "dot", "=": "equal",
         ",": "comma", ";": "semicolon", "'": "apostrophe"}
shifted = {"&": "7", "|": "backslash", ":": "semicolon", "_": "minus",
           '"': "apostrophe", ">": "dot", "<": "comma", "!": "1"}

def key(c):
    if c.isdigit() or "a" <= c <= "z":
        return c
    if "A" <= c <= "Z":
        return "shift-" + c.lower()
    if c in names:
        return names[c]
    if c in shifted:
        return "shift-" + shifted[c]
    raise SystemExit(f"qemu-driver: no key for {c!r}")

s = socket.socket(socket.AF_UNIX)
s.connect(sock_path)
for k in [key(c) for c in text] + ["ret"]:
    s.sendall(f"sendkey {k}\n".encode())
    time.sleep(0.05)
time.sleep(0.5)
s.close()
PYEOF
}

log "Waiting for autoboot + multi-user boot to reach the login prompt (~75s)"
sleep 75
kill -0 "$QEMU_PID" 2>/dev/null || { log "QEMU exited before the login prompt"; QEMU_PID=""; exit 1; }
log "Sending login: root"
type_line "root"
sleep 6
log "Sending Password: mfsroot"
type_line "mfsroot"
sleep 6
log "Sending build command"
type_line "mkdir -p /fnas-seed && mount -t cd9660 /dev/iso9660/FNASSEED /fnas-seed && sh /fnas-seed/build-in-guest.sh"

log "Waiting for guest to power off (build-in-guest.sh's completion signal)"
i=0
timeout=2400
while kill -0 "$QEMU_PID" 2>/dev/null; do
    if [ "$i" -ge "$timeout" ]; then
        log "TIMEOUT after ${timeout}s waiting for guest poweroff"
        exit 1
    fi
    sleep 5
    i=$((i+5))
done
wait "$QEMU_PID" || true
QEMU_PID=""
log "Guest powered off after ${i}s"

log "Verifying build success (importing the pool read-only from the host)"
LOOP=$(sudo losetup --find --show -P -r "$IMG_PATH")
POOL_PART="${LOOP}p3"
verify_failed=1
if sudo zpool list -H -o name 2>/dev/null | grep -qx rpool; then
    log "The host already has a pool named rpool -- importing the image's as $VERIFY_POOL"
else
    VERIFY_POOL=rpool
fi
GUID=$(sudo zpool import -d "$POOL_PART" 2>/dev/null | awk '$1=="id:" {print $2; exit}')
if [ -n "$GUID" ] && sudo zpool import -o readonly=on -N -f -d "$POOL_PART" -t "$GUID" "$VERIFY_POOL" 2>/dev/null; then
    if [ "$(sudo zfs get -H -o value fnas:build_complete "$VERIFY_POOL" 2>/dev/null)" = "yes" ]; then
        verify_failed=0
        log "Verified: fnas:build_complete=yes (pool GUID $GUID)"
    else
        log "FAIL: pool imported but fnas:build_complete is not set to yes -- build-in-guest.sh likely hit its fail() path"
    fi
    sudo zpool export "$VERIFY_POOL" 2>/dev/null || true
else
    log "FAIL: could not import a pool from $POOL_PART at all -- build-in-guest.sh likely failed before zpool create"
fi
sudo losetup -d "$LOOP" 2>/dev/null || true

[ "$verify_failed" -eq 0 ] || exit 1
log "Done"
