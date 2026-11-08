# CI setup for freedomnas-image-builder

Two separate pieces of infrastructure are required for the "push to
`freedomnas-core`/`freedomnas-profiles`/`freedomnas-webui` → new images"
pipeline to actually run. Neither exists by default on a fresh Codeberg
org — both are one-time manual setup for a maintainer.

## 1. `IMAGE_BUILDER_TRIGGER_TOKEN` — lets core/profiles/webui trigger this repo's build

Each of `freedomnas-core`, `freedomnas-profiles`, and `freedomnas-webui`
has a `.forgejo/workflows/notify-image-builder.yml` that, on push to
`main`, calls the Forgejo API to fire `freedomnas-image-builder`'s
`workflow_dispatch` event. That API call needs a token scoped to trigger
workflows on `freedomnas-image-builder`.

**Generate the token** (as a maintainer with write access to
`freedomnas-image-builder`):

1. Codeberg → your avatar → **Settings** → **Applications**.
2. Under "Manage Access Tokens", create a new token.
   - Name: something identifiable, e.g. `image-builder-trigger`.
   - Scopes: `write:repository` is sufficient (this only needs to hit
     the Actions dispatch endpoint on one repo).
3. Copy the token immediately — Codeberg only shows it once.

**Store it** in each of the three triggering repos (`freedomnas-core`,
`freedomnas-profiles`, `freedomnas-webui`):

1. Repo → **Settings** → **Actions** → **Secrets**.
2. Add a secret named exactly `IMAGE_BUILDER_TRIGGER_TOKEN`, value = the
   token from above.

**Rotating it**: generate a new token the same way, update the secret in
all three repos, then revoke the old token from Settings → Applications.
There's no overlap window needed — the next push after the secret is
updated just uses the new value.

## 2. Self-hosted runner — required for the actual build job

Codeberg's hosted/shared Forgejo Actions runners do **not** support
privileged containers or Docker-in-Docker
([docs.codeberg.org/ci/actions](https://docs.codeberg.org/ci/actions/)).
The Linux images (`debian/build.sh`, `artix/build.sh`) boot the live ISO
under QEMU with KVM, and building that ISO (`live/build.sh`) needs root and
`arch-chroot` — none of which work on an unprivileged hosted runner. `build-images.yml`'s actual
build job therefore targets a self-hosted runner; only the lightweight
notify-trigger workflows in core/profiles/webui stay on Codeberg's
hosted pool.

**Register a runner** against `freedomnas-image-builder`:

1. Repo → **Settings** → **Actions** → **Runners** → **Create new
   Runner**. Copy the registration token shown.
2. On a machine where privileged containers are acceptable to run (this
   builds full disk images — treat it like any other CI build box, not
   a production host), install `forgejo-runner` per the [Forgejo runner
   installation docs](https://forgejo.org/docs/latest/admin/actions/)
   and register it with the token from step 1, giving it a
   distinguishing label (e.g. `image-builder`) so
   `build-images.yml` can target it specifically via `runs-on:`.
3. Repo → **Settings** → **Units** → confirm **Actions** is enabled
   (disabled by default on new repos).
4. Start the runner (`forgejo-runner daemon`, or as a system service).
   No public IP is needed — the runner connects out to Codeberg and
   waits for jobs.

**Rotating/re-registering**: registration tokens are one-time-use for
the initial `forgejo-runner register` step; if the runner's local state
is lost, just repeat step 1–2 with a freshly generated token.

## 3. Additional prerequisites for the FreeBSD build job

`freebsd/build.sh` boots a real FreeBSD environment under QEMU to run
`gpart`/`zpool`/`pkg` (see its header comment for why — Linux can't run
these natively). On top of what the Linux images need, the
self-hosted runner also needs:

- `qemu-system-x86_64` (run with `FREEBSD_BACKEND=qemu`) and `xorriso`
  installed.
- `/dev/kvm` present and read/write-accessible to the runner user — the
  build still works without it (falls back to software emulation
  automatically) but a full base system and package install under pure
  TCG emulation is considerably slower; budget CI time accordingly if
  KVM isn't available (e.g. a nested-virtualization-disabled cloud VM).
- Outbound network access from the runner (the QEMU guest fetches
  the base system (the FreeBSD-base pkg repository) and packages from
  FreeBSD's mirrors over the
  guest's usermode-NAT network, which rides on the runner's own
  connection).

## 4. `GH_RELEASE_TOKEN` — publishes the images on GitHub

The images are built here; GitHub only hosts the downloads, as releases of
the showcase repo [FreedomNAS/freedomnas-image](https://github.com/FreedomNAS/freedomnas-image):
release assets are public, permanent and have no bandwidth cap, where
workflow artifacts expire and need a login. Each run of `build-images.yml`
fills one prerelease, `images-<run number>`, through `ci/publish-release.sh`:
the live ISO (built once by the `live-iso` job, which the image jobs
then install from), every image and, on dev runs, the FreeBSD live ISO
(`freebsd-live-iso`), each with its `.sha256`. An asset may hold just under 2 GiB; a bigger file goes up in
1900 MiB parts, joined with `cat` (the release text says how). Files are
streamed from disk, not read into memory, and a failed upload is tried again
up to three times (`UPLOAD_TRIES`), the broken asset removed first. Without the
secret the step publishes nothing and the build still succeeds.

At the end the `changelog` job (`ci/changelog.sh`) writes what changed into
the release text: it finds the newest earlier release of the same channel
(dev, or a `vX.Y.Z`), reads the hidden `<!-- freedomnas-refs: ... -->`
line that names the commit of each repository that release was built from,
and lists every repository's commits since then (core, profiles, WebUI,
installer, the containers and proxy modules, the kernel, the FreeBSD
packages, this builder, the docs), with the kernel's and OpenZFS's version
change on top; then it writes the new line for the next run. The commits
are the branch or tag tips when the job runs. A release before the first
one with that line gets only the line. The same token is used; nothing
more to set up.

The token, from the GitHub account of an organization member:

1. **Settings → Developer settings → Personal access tokens → Fine-grained
   tokens → Generate new token.**
2. **Resource owner: FreedomNAS** (the organization, not the account).
3. **Repository access: Only select repositories → freedomnas-image.**
4. **Repository permissions → Contents: Read and write** (Metadata:
   read-only comes with it). Nothing else.
5. Copy the token: GitHub shows it once.

If FreedomNAS is not offered as the resource owner, or the token stays
pending, the organization must allow fine-grained tokens: organization
**Settings → Personal access tokens → Settings → Allow access via
fine-grained personal access tokens**, and approve it under **Pending
requests** if approval is required.

Then on Codeberg, in this repo: **Settings → Actions → Secrets → Add
secret**, name `GH_RELEASE_TOKEN`. When it expires, generate a new one and
replace the secret.

`build-ssh.sh`'s ISO is never published: it carries the builder's key.

## 5. Root processes of cancelled or failed jobs

The builds run as root through `sudo`, and the runner user cannot stop
root's processes: cancelling a run on Codeberg leaves its emerge, QEMU or
zstd running. Every job therefore starts and ends (always, even after a
failure) with `ci/stop-leftovers.sh`, which stops root's processes chrooted
into the live ISO's build root or naming a CI path (the runner's
workspaces, `/var/tmp/freedomnas-live`, `/var/tmp/freedomnas-ci`) together
with their descendants, and unmounts what is left under the build root.
Nothing else root runs is touched. `sudo env DRY_RUN=1 sh
ci/stop-leftovers.sh` only lists what it would stop.
