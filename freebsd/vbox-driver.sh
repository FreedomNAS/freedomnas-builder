#!/bin/sh
# freebsd/vbox-driver.sh — VirtualBox backend (primary/recommended).
#
# Empirically preferred over the QEMU backend (see qemu-driver.sh):
# qemu-system-x86_64 silently hung early in the FreeBSD kernel boot on
# the hardware this was developed/validated against (survived -vga
# none, -cpu qemu64, and an added virtio-rng device -- none of it
# changed the outcome; ruled out a reset/triple-fault too, since
# removing -no-reboot never produced a second BIOS banner). The exact
# QEMU root cause was not identified. The *identical* mfsBSD ISO booted
# to a full login prompt under VirtualBox (VBoxManage 7.2.14) with no
# special tuning, so that's the default backend; qemu-driver.sh stays
# as a documented, less-proven fallback for hosts where VirtualBox
# isn't a fit (e.g. containerized runners that can't load the vboxdrv
# kernel module the way some can pass through /dev/kvm).
#
# mfsBSD does NOT auto-login on the console (an assumption the first
# draft of this pipeline got wrong) -- it presents a normal `login:`
# prompt. Credentials are mfsBSD's well-known static default: root /
# mfsroot.
#
# Automation has no Guest Additions to lean on (mfsBSD doesn't ship
# them), so this drives the guest two ways, both already validated
# interactively against a real VM on real hardware:
#   - Input: VBoxManage controlvm keyboardputstring/keyboardputscancode
#     -- works against a headless VM with no GUI/X session needed.
#   - Payload delivery: the staged freedomnas-core/profiles/webui
#     tarball + firstboot.sh + build-in-guest.sh are burned onto a small
#     second ISO (via xorriso) and attached as a second optical drive,
#     since VirtualBox shared folders require Guest Additions that
#     mfsBSD doesn't have. build-in-guest.sh mounts it via cd9660.
#   - Completion signal: poll VM state for "poweroff" rather than
#     scanning console text -- build-in-guest.sh's fail()/success paths
#     both end in `poweroff -p`, and there is no serial console reliably
#     wired up (this ISO's loader defaults to the video console
#     regardless of whether a UART is present -- confirmed empirically:
#     a UART added and bridged to a host socket produced zero bytes over
#     a full boot+login cycle that the VGA-console screenshot path
#     captured cleanly in the same window).
#
# Login-sequence timing below (autoboot wait, boot-to-login wait) is
# calibrated from real observed timings on the validation hardware, not
# theoretical -- pad them further if this proves flaky on slower CI
# hardware, and prefer widening the timeout over shortening it.
#
# Disk format note: VirtualBox can't attach an arbitrary raw file as an
# HDD medium directly (`createrawvmdk`/`createmedium -rawdisk` need a
# real block device with a queryable sector size, confirmed empirically
# -- VERR_INVALID_FUNCTION against a plain file). So the VM's disk is a
# normal VDI, and it gets converted to the raw $IMG_PATH via
# `VBoxManage clonemedium ... --format RAW` after the guest powers off
# (also verified working). That conversion is a full-size copy, so
# budget disk I/O time for it on top of the build itself.
set -eu

IMG_PATH="$1"
SEED_DIR="$2"
MFSBSD_ISO="$3"

VM="fnas-image-builder-freebsd-$$"
VDI_PATH="$(dirname "$IMG_PATH")/.fnas-vbox-$$.vdi"
SEED_ISO="$(dirname "$IMG_PATH")/.fnas-seed-$$.iso"

log() { echo "vbox-driver: $*" >&2; }

cleanup() {
    VBoxManage controlvm "$VM" poweroff >/dev/null 2>&1 || true
    sleep 1
    VBoxManage unregistervm "$VM" --delete >/dev/null 2>&1 || true
    VBoxManage closemedium disk "$VDI_PATH" --delete >/dev/null 2>&1 || true
    rm -f "$SEED_ISO" "$VDI_PATH"
}
trap cleanup EXIT

# VBoxManage's media registry is independent of the filesystem -- a
# `clonemedium ... --format RAW` to this same $IMG_PATH in an earlier
# run (or a prior failed run that never reached cleanup) can leave a
# stale registration here even after the file itself was deleted,
# which makes the real clonemedium call below fail with "hard disk ...
# already exists". Confirmed empirically; unregister defensively before
# (re)using the path.
VBoxManage closemedium disk "$IMG_PATH" >/dev/null 2>&1 || true

log "Building seed ISO from staged payload"
xorriso -as mkisofs -V FNASSEED -o "$SEED_ISO" "$SEED_DIR" >/dev/null

# IMG_PATH was already truncate -s'd to the target size by build.sh;
# read that size back for the VDI instead of hardcoding it again.
IMG_SIZE_MB=$(( $(stat -c%s "$IMG_PATH") / 1024 / 1024 ))

log "Creating VM $VM"
VBoxManage createvm --name "$VM" --ostype FreeBSD_64 --register
VBoxManage modifyvm "$VM" --memory 2048 --cpus 2 --firmware bios \
    --nic1 nat --audio-driver none --usb-ohci off --usb-ehci off \
    --graphicscontroller vmsvga

VBoxManage storagectl "$VM" --name "IDE" --add ide
VBoxManage storageattach "$VM" --storagectl "IDE" --port 0 --device 0 --type dvddrive --medium "$MFSBSD_ISO"
# Secondary IDE channel -- seen enumerate as the guest's second optical
# drive (cd1) after the primary-channel boot ISO (cd0) in validation;
# verify this holds if FreeBSD's probe order ever surprises you.
VBoxManage storageattach "$VM" --storagectl "IDE" --port 1 --device 0 --type dvddrive --medium "$SEED_ISO"

VBoxManage createmedium disk --filename "$VDI_PATH" --size "$IMG_SIZE_MB" --format VDI
VBoxManage storagectl "$VM" --name "SATA" --add sata
VBoxManage storageattach "$VM" --storagectl "SATA" --port 0 --device 0 --type hdd --medium "$VDI_PATH"

VBoxManage modifyvm "$VM" --boot1 dvd --boot2 disk --boot3 none --boot4 none

log "Starting $VM headless"
VBoxManage startvm "$VM" --type headless >/dev/null

type_line() {
    # keyboardputstring can't send Enter itself; scancode 1c/9c is the
    # make/break pair for the Enter key.
    VBoxManage controlvm "$VM" keyboardputstring "$1" >/dev/null
    VBoxManage controlvm "$VM" keyboardputscancode 1c 9c >/dev/null
}

# Padded up from 55/3/3s after observing intermittent failures at those
# margins across repeated real runs on the validation hardware -- this
# is a fixed-delay keystroke sequence with no confirmation that each
# prompt actually appeared before typing into it (no Guest Additions to
# check via, see the header note on automation approach), so timing
# margin is the only real defense against a slow boot landing keystrokes
# on the wrong screen. Widen further, don't narrow, if this is still
# flaky on slower hardware.
log "Waiting for autoboot + multi-user boot to reach the login prompt (~75s)"
sleep 75
log "Sending login: root"
type_line "root"
sleep 6
log "Sending Password: mfsroot"
type_line "mfsroot"
sleep 6
log "Sending build command"
type_line "mkdir -p /fnas-seed && mount -t cd9660 /dev/cd1 /fnas-seed && sh /fnas-seed/build-in-guest.sh"

log "Waiting for guest to power off (build-in-guest.sh's completion signal)"
i=0
timeout=2400
while [ "$i" -lt "$timeout" ]; do
    state=$(VBoxManage showvminfo "$VM" --machinereadable 2>/dev/null | grep '^VMState=' | cut -d'"' -f2)
    if [ "$state" = "poweroff" ]; then
        log "Guest powered off after ${i}s"
        break
    fi
    sleep 5
    i=$((i+5))
done
if [ "$i" -ge "$timeout" ]; then
    log "TIMEOUT after ${timeout}s waiting for guest poweroff"
    exit 1
fi

log "Converting VDI -> raw image ($IMG_PATH)"
rm -f "$IMG_PATH"
VBoxManage clonemedium disk "$VDI_PATH" "$IMG_PATH" --format RAW

# A bare "VM stopped" can't tell success from build-in-guest.sh's
# fail() path -- both end in a plain `poweroff` (there's no serial
# console text to check here the way qemu-driver.sh's expect script
# can, see vbox-driver.sh's own header). So this isn't optional
# best-effort logging: it's the only actual pass/fail signal this
# backend has, gating the script's exit code. build-in-guest.sh sets
# fnas:build_complete=yes on the pool only on its success path, right
# before the final export.
command -v zpool >/dev/null 2>&1 || { log "FAIL: zpool not available on this host — can't verify the build"; exit 1; }

log "Verifying build success (importing the pool read-only from the host)"
LOOP=$(sudo losetup --find --show -P "$IMG_PATH")
# zpool's ZFS partition is always p3 in this fixed layout (freebsd-boot,
# efi, freebsd-zfs added in that order by build-in-guest.sh's gpart
# calls). Confirmed empirically that `-d "$LOOP"` (the whole loop
# device, no partition suffix) finds nothing at all -- `-d` needs to
# point at the actual partition (or a directory containing it), not the
# parent disk device.
POOL_PART="${LOOP}p3"
verify_failed=1

# Import by GUID, not by the name "rpool" -- confirmed on this
# validation host that importing by name is a real hazard, not just a
# theoretical one: `zpool import` (unscoped) found an actual pre-existing
# "rpool" on a real host NVMe partition, unrelated to this build entirely.
# It wasn't actually imported/active, so nothing was touched, but
# `-d ... rpool` matching by name is exactly the kind of ambiguity that
# either fails outright or -- worse -- could pick the wrong "rpool" on a
# host where the name collision candidate *is* currently mountable.
# `-d "$POOL_PART"` alone lists only what's actually visible on this
# specific partition, from which the GUID is unambiguous.
#
# Match on field content, not exact leading-whitespace count -- an
# earlier version anchored on exactly 3 leading spaces before "id:",
# which never matched (the real output has 4), so this ALWAYS returned
# empty and every build was reported as failed regardless of whether it
# actually succeeded. Confirmed by the user importing the same image by
# hand: the pool was there and fine. Whitespace-tolerant field match
# instead of a fragile anchored regex.
#
# `-o readonly=on` is required, not optional here: a plain `-N -f`
# import of this pool failed with "cannot import 'rpool': permission
# denied" on this host even though the pool itself is completely
# healthy (confirmed by hand) -- some ZFS feature FreeBSD's newer
# OpenZFS enables by default isn't in this host's read-write-import
# compatible set, but it *is* read-only-compatible, which is all
# verification needs anyway.
GUID=$(sudo zpool import -d "$POOL_PART" 2>/dev/null | awk '$1=="id:" {print $2; exit}')
if [ -n "$GUID" ] && sudo zpool import -o readonly=on -N -f -d "$POOL_PART" "$GUID" 2>/dev/null; then
    if [ "$(sudo zfs get -H -o value fnas:build_complete rpool 2>/dev/null)" = "yes" ]; then
        verify_failed=0
        log "Verified: fnas:build_complete=yes on rpool (GUID $GUID)"
    else
        log "FAIL: pool imported but fnas:build_complete is not set to yes -- build-in-guest.sh likely hit its fail() path"
    fi
    sudo zpool export rpool 2>/dev/null || true
else
    log "FAIL: could not import a pool from $POOL_PART at all -- build-in-guest.sh likely failed before zpool create"
fi
sudo losetup -d "$LOOP" 2>/dev/null || true

if [ "$verify_failed" -ne 0 ]; then
    exit 1
fi

log "Done"
