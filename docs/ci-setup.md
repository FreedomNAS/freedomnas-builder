# CI setup for freedomnas-image-builder

The images are built on GitHub's hosted runners by the `build-images`
workflow of [FreedomNAS/freedomnas-image](https://github.com/FreedomNAS/freedomnas-image),
which clones this repository (on GitHub, `freedomnas-builder`) next to the
other FreedomNAS repositories and publishes every run as a release there,
`images-<n>`. This repository holds the scripts; it has no workflow of its own
on GitHub.

## Channels

- **dev**: every repository's `dev` branch, installing from the `dev`
  package repositories.
- **main**: the newest release tag `vX.Y.Z` of freedomnas-core, the same
  tag in every repository; the overlay is always `main`.

Start a run by hand from the Actions tab of freedomnas-image (input
`channel`). A push to `main` of core, profiles or webui starts the `main`
build through their `notify-image-builder` workflow, a
`repository_dispatch` of type `build-images` sent with the organization
secret `PACKAGES_DISPATCH_TOKEN`; that token must have access to
freedomnas-image as well as to the package repositories.

## Jobs

| Job | What | Time |
|-----|------|------|
| `live-iso` | the Linux live ISO (`live/build.sh`, work in `/mnt`) | about 35 min |
| `images` | the seven Linux images in parallel, installed by the live ISO in QEMU | 10–15 min each, Gentoo about 75 min |
| `freebsd-live-iso` | the FreeBSD installer ISO, in FreeBSD's own VM image (kept with `actions/cache`) | about 5 min |
| `freebsd-image` | the FreeBSD image, installed by that ISO | about 8 min |
| `changelog` | what changed since the previous release of the same channel (`ci/changelog.sh`) | |

The hosted runners have `/dev/kvm`, 4 vCPUs, 16 GB of RAM and about 80 GB
of disk; the builds run as root through `sudo`. Every job uploads its files
with `ci/publish-release.sh`, using the run's `GITHUB_TOKEN` (passed as
`GH_RELEASE_TOKEN`). Release numbers continue those of the earlier builds:
`images-<run number + 29>`.

Before installing its tools each job measures the official Ubuntu mirrors
and uses the fastest, since the default one is at times very slow.

## Building locally

Every build script runs on any Linux host with QEMU/KVM; see the README.
`ci/stop-leftovers.sh` stops what a cancelled build left running as root,
for a machine that builds repeatedly.
