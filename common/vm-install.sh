#!/bin/sh
# common/vm-install.sh — build a Linux edition's disk image by installing it
# for real: boot the FreedomNAS live ISO in QEMU with the image as its only
# disk, and let freedomnas-installer install onto it unattended.
#
# The image is then exactly what the installer produces on real hardware,
# and nothing runs on the build host but QEMU: no pool is imported here
# (the host may have its own rpool), no EFI variable is written, no
# pacman/debootstrap is needed.
#
# The VM boots with SeaBIOS, so the installer deploys the Clover chain as
# it does on BIOS machines (boot0/boot1 and boot7 as ESP/boot), and it puts
# the UKI at EFI/BOOT/BOOTX64.efi, which boots the same disk on UEFI
# firmware through the fallback path.
#
# Payload: a small ISO labelled FNASSEED with the repo checkouts, the
# documentation built from freedomnas-docs, seed.env and common/vm-guest/;
# the live ISO runs its run.sh instead of the menus.
# Outcome: run.sh's "vm-install: RESULT ..." line on the serial console.
#
# Requires qemu-system-x86_64, xorriso, rsync and a live ISO built by
# live/build.sh from the current checkouts' tree (FNAS_LIVE_ISO).
set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")/../common" && pwd)/install-core.sh"

fnas_vm_install() {
    img_path="$1"       # raw image to create
    img_size="$2"       # e.g. "10G"
    edition="$3"        # installer edition, e.g. "artix"
    init="$4"           # init system, "" for the edition's default
    repos_dir="$5"      # parent dir of the sibling repo checkouts

    here="$(CDPATH= cd -- "$(dirname -- "$0")/../common" && pwd)"
    live_iso="${FNAS_LIVE_ISO:-$here/../live/freedomnas-live.iso}"
    [ -f "$live_iso" ] || { echo "vm-install.sh: no live ISO at $live_iso (run live/build.sh)" >&2; return 1; }

    work="$(mktemp -d)"
    seed="$work/seed"
    serial_log="${img_path}.install.log"

    mkdir -p "$seed/repos"
    for repo in core profiles webui installer; do
        rsync -a --exclude='.git' --exclude='__pycache__' --exclude='tests' \
            "$repos_dir/freedomnas-$repo/" "$seed/repos/freedomnas-$repo/"
    done
    fnas_repo_version "$repos_dir/freedomnas-webui" > "$seed/repos/freedomnas-webui/VERSION"
    if [ -f "$repos_dir/freedomnas-docs/mkdocs.yml" ]; then
        mkdir -p "$seed/repos/freedomnas-docs"
        fnas_build_docs "$repos_dir/freedomnas-docs" "$seed/repos/freedomnas-docs" \
            || echo "vm-install.sh: WARNING: freedomnas-docs not built — the image keeps the live ISO's copy" >&2
    fi
    cp "$here/vm-guest/run.sh" "$here/vm-guest/drive_install.py" "$seed/"
    {
        echo "FNAS_EDITION=$edition"
        echo "FNAS_INIT=$init"
        echo "FNAS_DISK=/dev/vda"
        echo "FNAS_HOSTNAME=freedomnas"
        printf 'FNAS_ADMIN_USER=%s\n' "${FNAS_ADMIN_USER:-admin}"
        printf 'FNAS_ADMIN_PASSWORD=%s\n' "${FNAS_ADMIN_PASSWORD:-freedomnas}"
    } > "$seed/seed.env"
    xorriso -as mkisofs -quiet -R -J -V FNASSEED -o "$work/seed.iso" "$seed"

    rm -f "$img_path"
    truncate -s "$img_size" "$img_path"

    echo "vm-install.sh: installing $edition${init:+/$init} into $img_path (serial log: $serial_log)" >&2
    timeout "${FNAS_VM_TIMEOUT:-3h}" qemu-system-x86_64 \
        -enable-kvm -cpu host -smp "${FNAS_VM_CPUS:-4}" -m "${FNAS_VM_MEM:-4096}" \
        -drive "file=$img_path,format=raw,if=virtio" \
        -drive "file=$live_iso,media=cdrom,index=0" \
        -drive "file=$work/seed.iso,media=cdrom,index=1" \
        -boot d \
        -nic user,model=virtio-net-pci \
        -display none -serial "file:$serial_log" -no-reboot \
        || echo "vm-install.sh: QEMU exited with $?" >&2

    rm -rf "$work"
    if grep -q '^vm-install: RESULT ok' "$serial_log"; then
        echo "vm-install.sh: $edition${init:+/$init} installed" >&2
        return 0
    fi
    echo "vm-install.sh: FAIL: the installation did not complete — see $serial_log" >&2
    tail -n 30 "$serial_log" >&2
    return 1
}
