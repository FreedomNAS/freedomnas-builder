#!/bin/sh
# freebsd/mfsbsd.sh — sourced by freebsd/build.sh (the disk image) and
# freebsd/live.sh (the live installer ISO). Both do their FreeBSD work
# inside an mfsBSD guest, because gpart/zpool/pkg/makefs don't exist on
# Linux; this is the part they share: which mfsBSD, fetching it, and
# handing a seed directory plus the name of the script in it to the
# chosen backend. Expects SCRIPT_DIR (freebsd/) to be set.
#
# FREEBSD_BACKEND selects the driver: "virtualbox" (default) or "qemu".
# See vbox-driver.sh and qemu-driver.sh for what each needs installed.
#
# FREEBSD_RELEASE and MFSBSD_RELEASE are deliberately independent:
# FREEBSD_RELEASE is the base.txz/kernel.txz version that gets installed
# and should track whatever FreeBSD currently ships as a release;
# MFSBSD_RELEASE is just the environment doing the work and only needs to
# be able to partition, create pools, and fetch+extract the (possibly
# much newer) target release -- confirmed empirically that mfsbsd.vx.sk
# lags behind FreeBSD's own releases (14.2 is still the newest mfsBSD
# ISO, with FreeBSD at 15.1). Boot code, loader and image tools come
# from the extracted release, not from mfsBSD, so an older mfsBSD builds
# a newer release.
#
# The mfsBSD ISO URL follows the project's long-stable pattern, but pin
# and verify it for the release you target before relying on this in
# production; upstream filenames do change across releases.

FREEBSD_BACKEND="${FREEBSD_BACKEND:-virtualbox}"
FREEBSD_RELEASE="${FREEBSD_RELEASE:-15.1-RELEASE}"
MFSBSD_RELEASE="${MFSBSD_RELEASE:-14.2-RELEASE}"
MFSBSD_ISO_URL="${MFSBSD_ISO_URL:-https://mfsbsd.vx.sk/files/iso/14/amd64/mfsbsd-${MFSBSD_RELEASE}-amd64.iso}"
MFSBSD_ISO_CACHE="$SCRIPT_DIR/.cache/mfsbsd-${MFSBSD_RELEASE}-amd64.iso"

fnas_fetch_mfsbsd() {
    mkdir -p "$(dirname "$MFSBSD_ISO_CACHE")"
    [ -f "$MFSBSD_ISO_CACHE" ] && return 0
    curl -fL "$MFSBSD_ISO_URL" -o "$MFSBSD_ISO_CACHE.part" || {
        echo "mfsbsd.sh: could not fetch $MFSBSD_ISO_URL" >&2
        echo "mfsbsd.sh: verify/pin the correct mfsBSD ISO URL for $MFSBSD_RELEASE and set MFSBSD_ISO_URL" >&2
        return 1
    }
    mv -f "$MFSBSD_ISO_CACHE.part" "$MFSBSD_ISO_CACHE"
}

# fnas_run_guest <disk> <seed-dir> <guest-script>: boot mfsBSD with <disk>
# attached and run <seed-dir>/<guest-script> in it, until the guest powers
# off. Whether the script succeeded is for the caller to check on <disk>.
# The disk image is built inside FreeBSD's own VM image of the target
# release (FREEBSD_BUILD_ENV=vm, the default with QEMU): its pkg is the one
# the target gets, so the package database it writes is one the installed
# pkg can open. mfsBSD lags behind (14.2), and its older pkg wrote a
# database pkg 2.7 could not migrate. FREEBSD_BUILD_ENV=mfsbsd keeps the
# old path; the live ISO and VirtualBox still use mfsBSD.
FREEBSD_BUILD_ENV="${FREEBSD_BUILD_ENV:-vm}"
VM_IMAGE_URL="${VM_IMAGE_URL:-https://download.freebsd.org/releases/VM-IMAGES/${FREEBSD_RELEASE}/amd64/Latest/FreeBSD-${FREEBSD_RELEASE}-amd64-ufs.qcow2.xz}"
VM_IMAGE_CACHE="$SCRIPT_DIR/.cache/FreeBSD-${FREEBSD_RELEASE}-amd64-ufs.qcow2"

fnas_fetch_build_env() {
    if [ "$FREEBSD_BACKEND" != qemu ] || [ "$FREEBSD_BUILD_ENV" = mfsbsd ]; then
        fnas_fetch_mfsbsd
        return
    fi
    mkdir -p "$(dirname "$VM_IMAGE_CACHE")"
    [ -f "$VM_IMAGE_CACHE" ] && return 0
    curl -fL "$VM_IMAGE_URL" -o "$VM_IMAGE_CACHE.xz.part" || {
        echo "mfsbsd.sh: could not fetch $VM_IMAGE_URL" >&2
        return 1
    }
    xz -dc "$VM_IMAGE_CACHE.xz.part" > "$VM_IMAGE_CACHE.part" && rm -f "$VM_IMAGE_CACHE.xz.part" \
        && mv -f "$VM_IMAGE_CACHE.part" "$VM_IMAGE_CACHE"
}

fnas_build_env() {
    if [ "$FREEBSD_BACKEND" = qemu ] && [ "$FREEBSD_BUILD_ENV" != mfsbsd ]; then
        echo "$VM_IMAGE_CACHE"
    else
        echo "$MFSBSD_ISO_CACHE"
    fi
}

fnas_run_guest() {
    case "$FREEBSD_BACKEND" in
        virtualbox)
            command -v VBoxManage >/dev/null 2>&1 || {
                echo "mfsbsd.sh: VBoxManage not found — install VirtualBox or set FREEBSD_BACKEND=qemu" >&2
                return 1
            }
            command -v xorriso >/dev/null 2>&1 || {
                echo "mfsbsd.sh: xorriso not found — needed to build the seed ISO" >&2
                return 1
            }
            "$SCRIPT_DIR/vbox-driver.sh" "$1" "$2" "$MFSBSD_ISO_CACHE" "$3"
            ;;
        qemu)
            "$SCRIPT_DIR/qemu-driver.sh" "$1" "$2" "$(fnas_build_env)" "$3"
            ;;
        *)
            echo "mfsbsd.sh: unknown FREEBSD_BACKEND '$FREEBSD_BACKEND' (expected virtualbox|qemu)" >&2
            return 1
            ;;
    esac
}
