# freedomnas-image-builder

Builds the pre-built, flashable disk images that are FreedomNAS's primary
install path per [ADR-002](../IMAGE-BASED-INSTALLATION.md) — "flash and go"
instead of running an interactive installer. Each image is bootable on
**both UEFI and BIOS from the same file**; see the design note at the top
of [`debian/build.sh`](debian/build.sh) for how that's achieved without a
live machine's UEFI NVRAM to register against.

`freedomnas-installer` (the old dialog-TUI installer) is **parked**, not
removed — see its README for status. This repo is the new primary path.

## Supported editions

| Edition | Status | Init | Notes |
|---------|--------|------|-------|
| Debian (trixie) | **Phase 1 — implemented** | systemd | Ports the proven boot chain from the parked installer; runs directly on the Linux runner |
| FreeBSD (14+) | **Phase 2 — implemented** | bsd_rc | Native boot chain (gptzfsboot/loader.efi, no UKI/Clover); build runs *inside* a QEMU-booted FreeBSD guest — see `freebsd/build.sh` header for why |
| Void Linux | Phase 3 — stub | runit | "Exotic" edition — see `void/build.sh` header |
| Artix Linux | Phase 3 — stub | OpenRC | "Exotic" edition — see `artix/build.sh` header |

## Layout

```
common/            Shared build-time function libraries (sourced by each
                    edition's build.sh) + firstboot.sh, which gets baked
                    into the image itself and runs at boot time. On every
                    boot it imports pools, unlocks any encrypted ones
                    (`python -m freedomnas unlock-pools` — USB zero-touch
                    key, TTY passphrase fallback; see keymgmt.py in
                    freedomnas-core), then reconciles or hands off to the
                    WebUI's first-run wizard per ADR-002
debian/build.sh     Implemented — chroots directly on the Linux runner
freebsd/            Implemented — QEMU-driven (see build.sh header)
  build.sh            Host-side orchestrator: stages the payload, boots
                      mfsBSD under QEMU, hands off to the guest script
  guest/build-in-guest.sh  Runs INSIDE the FreeBSD guest — the actual
                      gpart/zpool/pkg/boot-chain provisioning logic
  expect-driver.exp  Minimal serial-console handoff (prompt -> one
                      command -> wait for completion marker)
void/build.sh       Stub — Phase 3
artix/build.sh      Stub — Phase 3
docs/ci-setup.md    Token + self-hosted runner setup for maintainers
.forgejo/workflows/ CI — see docs/ci-setup.md before expecting this to run
```

## Prerequisites for a local build

This repo expects `freedomnas-core`, `freedomnas-profiles`, and
`freedomnas-webui` checked out as **sibling directories** — the same
convention `engine.py` already uses for its dev-mode profile search path.
The boot-chain assets (Clover, `zz-dracut-uki`) live in
`../freedomnas-profiles/assets/`, not duplicated into this repo.

```
git-projects/freedomnas/
├── freedomnas-core
├── freedomnas-profiles     (assets/clover, assets/zz-dracut-uki live here)
├── freedomnas-webui
├── freedomnas-installer    (parked)
└── freedomnas-image-builder
```

Building requires root, loop devices, `sgdisk`, `mkfs.vfat`, ZFS
userspace tools, `debootstrap`, and `dracut` on the build host — none of
which Codeberg's hosted Forgejo Actions runners provide (see
[docs/ci-setup.md](docs/ci-setup.md)). Run locally as root, or on the
self-hosted runner:

```sh
sudo ./debian/build.sh [output-path] [image-size]   # defaults: debian/debian.img, 8G
sudo ./freebsd/build.sh [output-path] [image-size]  # defaults: freebsd/freebsd.img, 8G
```

`freebsd/build.sh` additionally needs `qemu-system-x86_64` and `expect`
on the runner (not required for `debian/build.sh`), and `/dev/kvm` for
reasonable build times — it boots a real FreeBSD environment under QEMU
to run gpart/zpool/pkg, since those don't exist on Linux; see the
header comment in `freebsd/build.sh` for why. It also downloads (and
caches under `freebsd/.cache/`) an mfsBSD live ISO on first run —
verify/pin `MFSBSD_ISO_URL` for the release you're targeting before
relying on this in CI, since upstream filenames change across releases.

Output is `zstd`-compressed (`{edition}.img.zst`) — decompress with
`zstd -d {edition}.img.zst` before flashing, or point Balena Etcher at
the `.zst` file directly (it decompresses on the fly).

## How CI triggers a build

`freedomnas-core`, `freedomnas-profiles`, and `freedomnas-webui` each have
a `.forgejo/workflows/notify-image-builder.yml` that fires this repo's
`workflow_dispatch` on every push to `main`. See
[docs/ci-setup.md](docs/ci-setup.md) for the token and self-hosted runner
this requires.
