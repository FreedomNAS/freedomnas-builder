# freedomnas-image-builder

Builds the pre-built, flashable disk images that are FreedomNAS's primary
install path per [ADR-002](../freedomnas-specs/IMAGE-BASED-INSTALLATION.md) — "flash and go"
instead of running an interactive installer. Each image is bootable on
**both UEFI and BIOS from the same file**; see the header of
[`common/vm-install.sh`](common/vm-install.sh) for how that's achieved
without a live machine's UEFI NVRAM to register against.

This repo is the primary install path. `freedomnas-installer` is the
secondary one — rewritten profile-driven per ADR-002's 2026-09-04 follow-up
(clean install, or in-place onto a running system). The two are deliberately
separate: this repo keeps its own shell build scripts, and both produce the
same on-disk layout.

## Supported editions

| Edition | Status | Init | Notes |
|---------|--------|------|-------|
| Debian (trixie) | **Implemented** | systemd | Installed by freedomnas-installer inside the live ISO under QEMU (`common/vm-install.sh`); kernel and ZFS from linux-freedomnas |
| Artix Linux | **Implemented** | OpenRC, dinit, runit | Same as Debian, one image per init system |
| FreeBSD (14+) | **Phase 2 — implemented** | bsd_rc | Native boot chain (gptzfsboot/loader.efi, no UKI/Clover); build runs *inside* a QEMU-booted FreeBSD guest — see `freebsd/build.sh` header for why |
| Void Linux | **Implemented** | runit | Same as Debian; kernel from Void, OpenZFS modules prebuilt by freedomnas-void |

## Live installer ISO

`live/build.sh` builds `freedomnas-live.iso`, a Gentoo live system that runs
`freedomnas-install` and installs **every Linux edition** from one image. The
installer offers a native bootstrap method only when that method's tool is
present on the machine it runs on, so the ISO carries the tools:

| Edition | Bootstrap offered by the ISO |
|---------|------------------------------|
| Debian | `debootstrap` (+ `debian-archive-keyring`), or tarball |
| Void | `xbps-install` from Void's `xbps-static`, or tarball |
| Gentoo | stage3 tarball |
| Arch, Artix | `pacstrap` with `pacman` and the Arch/Artix keyrings from `freedomnas-overlay`, or tarball |

The same file boots on UEFI and BIOS, from optical media or written to a
USB stick with `dd`: `grub-mkrescue` produces a hybrid ISO (El Torito BIOS
and EFI images, plus the MBR/GPT a USB boot needs). The root filesystem is
a squashfs mounted by dracut's `dmsquash-live` with an overlayfs layer in
RAM. On boot, root is logged in on tty1 and the installer starts; `dhcpcd`
is enabled, `sshd` is installed but not started (root has no password).
`live/build-ssh.sh` builds the same system as `freedomnas-live-ssh.iso`,
for installing over the network a machine with no usable screen or
keyboard: root accepts one public key and `sshd` starts at boot, so
`ssh root@<address>` and then `freedomnas-install`. The key is the first
argument, else `FNAS_LIVE_SSH_KEY`, else the invoking user's
`~/.ssh/id_ed25519.pub`, `id_ecdsa.pub` or `id_rsa.pub`; root still has no
password, so there is no build without a key. (`build-ssh.sh` only sets
`FNAS_LIVE_SSH_KEY` for `build.sh`, which checks the key before building.)

How it is built:

1. The latest stage3 (`latest-stage3-amd64-openrc.txt`), verified with
   Gentoo's release key — `/usr/share/openpgp-keys/gentoo-release.asc`
   when present, otherwise downloaded from `qa-reports.gentoo.org`.
2. Portage configuration rendered from `installer-gentoo.json`'s
   `make_conf`, `binrepos_conf`, `package_use` and
   `package_accept_keywords`, so the live system resolves packages the way
   an installed Gentoo edition does. Packages come from the official
   binary host wherever the flags match.
3. `xbps-static`: the newest versioned tarball listed in Void's
   `sha256sums.txt`, checked against it. The `latest` line in that file
   has been seen lagging behind the file it names.
4. `freedomnas-overlay`, copied from the sibling checkout into the build
   root, for `sys-apps/pacman`, `sys-apps/arch-install-scripts` and the two
   keyrings.
5. Kernel (`gentoo-kernel-bin`), `linux-firmware`, ZFS, the installer,
   core, profiles and WebUI from the sibling checkouts.

```sh
sudo ./live/build.sh [output.iso]     # default: live/freedomnas-live.iso
sudo ./live/build-ssh.sh [key.pub] [output.iso]   # default: live/freedomnas-live-ssh.iso
```

Host requirements: `curl`, `gpg`/`gpgv`, `tar`, `xz`, `python3`, `rsync`
and `arch-chroot` (`sys-apps/arch-chroot` on Gentoo). GRUB with BIOS
support, xorriso and mksquashfs are installed and run *inside* the build
root, so the host needs none of them. Work happens under
`/var/tmp/freedomnas-live` (`FNAS_LIVE_WORK` to move it): `root/` is
recreated on every run, `cache/` keeps the stage3, distfiles, binary
packages and the Portage tree between runs. Allow about 15 GB.

## Layout

```
common/            Shared build-time function libraries (sourced by each
                    edition's build.sh). The boot-time scripts baked into
                    the images -- firstboot.sh and supervisor.sh -- come
                    from freedomnas-profiles/assets, the copies
                    freedomnas-installer deploys too: firstboot.sh imports
                    pools only to look for a .freedomnas dataset and
                    releases the ones it did not need, unlocks encrypted
                    pools (`python -m freedomnas unlock-pools`), then
                    reconciles or hands off to the WebUI's first-run wizard
                    per ADR-002
debian/build.sh     Debian image, through common/vm-install.sh
artix/build.sh      Artix image per init system, through common/vm-install.sh
freebsd/            Implemented — runs its FreeBSD work in a FreeBSD guest
  build.sh            Disk image: stages the payload, runs the guest
                      script, checks the pool property it sets on success
  live.sh             Live installer ISO for FreeBSD (UEFI + BIOS, CD + USB):
                      the guest builds it in RAM, writes it to a scratch
                      disk, live.sh cuts it back out by its volume size
  mfsbsd.sh           Shared: build environment (FreeBSD VM image or mfsBSD),
                      fetch, backend dispatch
  guest/build-in-guest.sh  Runs INSIDE the guest — gpart/zpool/pkg/boot chain
  guest/live-in-guest.sh   Runs INSIDE the guest — live tree, makefs + mkimg
  qemu-driver.sh      QEMU backend: seed ISO, keystrokes via the QEMU monitor
  vbox-driver.sh      VirtualBox backend, same approach through VBoxManage
live/build.sh       Live installer ISO for every Linux edition (UEFI + BIOS)
live/build-ssh.sh   The same ISO, reachable over SSH with one public key
void/build.sh       Void image, installed by freedomnas-installer in the live ISO
docs/ci-setup.md    Token + self-hosted runner setup for maintainers
.forgejo/workflows/ CI — see docs/ci-setup.md before expecting this to run
```

## Prerequisites for a local build

This repo expects `freedomnas-core`, `freedomnas-profiles`,
`freedomnas-webui`, `freedomnas-installer` and `freedomnas-docs` checked
out as **sibling directories** — the same
convention `engine.py` already uses for its dev-mode profile search path.
The boot-chain assets (Clover, `zz-dracut-uki`) live in
`../freedomnas-profiles/assets/`, not duplicated into this repo.

```
git-projects/freedomnas/
├── freedomnas-core
├── freedomnas-profiles     (assets/clover, assets/zz-dracut-uki live here)
├── freedomnas-webui
├── freedomnas-installer
└── freedomnas-image-builder
```

The Linux images need `qemu-system-x86_64`, `/dev/kvm`, `xorriso`,
`rsync`, `zstd` and a live ISO built by `live/build.sh` from the same
checkouts (`FNAS_LIVE_ISO` to point elsewhere). Nothing else runs on the
build host and no root is needed: the installer partitions, bootstraps and
installs inside the VM. Codeberg's hosted Forgejo Actions runners provide
none of this (see [docs/ci-setup.md](docs/ci-setup.md)); run locally or on
the self-hosted runner:

```sh
./debian/build.sh [output-path] [image-size]        # defaults: debian/debian.img, 12G
./artix/build.sh <openrc|dinit|runit> [output-path] [image-size]   # defaults: artix/artix-<init>.img, 10G
sudo ./freebsd/build.sh [output-path] [image-size]  # defaults: freebsd/freebsd.img, 8G
./freebsd/live.sh [output-path]                   # default: freebsd/freedomnas-live-freebsd.iso
```

`freebsd/build.sh` additionally needs `qemu-system-x86_64` (with
`FREEBSD_BACKEND=qemu`) or VirtualBox, plus `xorriso`, on the runner, and `/dev/kvm` for
reasonable build times — it boots a real FreeBSD environment under QEMU
to run gpart/zpool/pkg, since those don't exist on Linux; see the
header comment in `freebsd/build.sh` for why. With QEMU it downloads (and
caches under `freebsd/.cache/`) FreeBSD's own VM image of the target
release on first run, so the guest's `pkg` is the one the target gets;
VirtualBox, or `FREEBSD_BUILD_ENV=mfsbsd`, uses an mfsBSD live ISO
instead (`MFSBSD_ISO_URL`).

The images ship root locked and a default administrator for the WebUI
and the console: `admin` / `freedomnas`, set with
`FNAS_ADMIN_USER` and `FNAS_ADMIN_PASSWORD` at build time. Change the
password after the first sign-in.

`freebsd/live.sh` needs the same backend and build environment, and gives
the guest 6 GiB (`QEMU_MEM` / `VBOX_MEM`): the live tree and the ISO are
built in memory. CI builds it on dev runs only, for now (`freebsd-live-iso`
job).

Image output is `zstd`-compressed (`{edition}.img.zst`) — decompress with
`zstd -d {edition}.img.zst` before flashing, or point Balena Etcher at
the `.zst` file directly (it decompresses on the fly).

## How CI triggers a build

`freedomnas-core`, `freedomnas-profiles`, and `freedomnas-webui` each have
a `.forgejo/workflows/notify-image-builder.yml` that fires this repo's
`workflow_dispatch` on every push to `main`. See
[docs/ci-setup.md](docs/ci-setup.md) for the token and self-hosted runner
this requires.

## License

GPL-2.0-or-later: the GNU General Public License, version 2 or (at your
option) any later version. The text of version 2 is in `LICENSE`.

The images it produces contain software under many licenses, each
under its own.
