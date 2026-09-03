#!/bin/sh
# freebsd/qemu-driver.sh — QEMU backend (documented fallback; NOT the
# default -- see vbox-driver.sh's header for why).
#
# qemu-system-x86_64 silently hung early in the FreeBSD kernel boot on
# the hardware this pipeline was developed/validated against: past the
# BIOS/loader stage, past module loading, right around
# "can't find '/boot/entropy'" / "can't find '/etc/hostid'" (both
# ordinary, benign messages) and then nothing -- no crash, no reset (a
# QEMU run with -no-reboot removed never produced a second BIOS banner,
# ruling out a silent triple fault), CPU sitting in HLT with a valid
# kernel RIP (`info registers` via the QEMU monitor -- not itself proof
# of a problem, since HLT is normal CPU-idle behaviour, but combined
# with zero further console output for 30+ minutes across repeated
# attempts it wasn't just slow). Tried and ruled out: -vga none
# (loader's "Consoles: internal video/keyboard" banner turned out to be
# static/unconditional, not a live probe), a virtio-rng device
# (entropy-gate theory), -cpu qemu64 in place of -cpu host (rules out
# CPU-passthrough/KVM feature mismatches specifically). Root cause not
# identified -- the identical ISO booted cleanly to a login prompt
# under VirtualBox with no special tuning, so effort went there instead
# of continuing to chase this.
#
# Kept as a fallback for hosts where VirtualBox isn't a fit (e.g. a
# containerized runner that can pass through /dev/kvm but can't load
# the vboxdrv kernel module VirtualBox needs). If you pick this backend
# up again: try -smp 1 next (SMP/AP-startup hangs are a known class of
# QEMU/KVM guest issue and hadn't been ruled out yet), and get a serial
# console working end-to-end on a *simpler* guest first to separate
# "QEMU is fine, this ISO/config is the problem" from the reverse.
set -eu

IMG_PATH="$1"
SEED_DIR="$2"
MFSBSD_ISO="$3"

# No FIFO/stdin plumbing needed here: expect-driver.exp's `spawn`
# creates its own pty and drives qemu's stdin/stdout directly via
# send/expect -- it does not inherit this script's own stdin.
KVM_ARGS=""
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM_ARGS="-enable-kvm -cpu host"
else
    echo "qemu-driver.sh: /dev/kvm not usable -- falling back to slow TCG emulation" >&2
fi

QEMU_CMD="qemu-system-x86_64 \
    $KVM_ARGS \
    -m ${QEMU_MEM:-2048} -smp ${QEMU_SMP:-2} \
    -no-reboot -nographic -serial stdio -monitor none \
    -drive file=$IMG_PATH,if=virtio,format=raw \
    -cdrom $MFSBSD_ISO -boot d \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -fsdev local,path=$SEED_DIR,security_model=mapped,id=seed \
    -device virtio-9p-pci,fsdev=seed,mount_tag=fnas_seed"

if ! command -v expect >/dev/null 2>&1; then
    echo "qemu-driver.sh: 'expect' is required to drive the guest console — see docs/ci-setup.md" >&2
    exit 1
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
"$SCRIPT_DIR/expect-driver.exp" "$QEMU_CMD"
