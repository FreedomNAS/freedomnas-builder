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
`debian/build.sh` needs loop devices, mounts, and `chroot` — none of
which work on an unprivileged hosted runner. `build-images.yml`'s actual
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
these natively). On top of everything `debian/build.sh` needs, the
self-hosted runner also needs:

- `qemu-system-x86_64` and `expect` installed.
- `/dev/kvm` present and read/write-accessible to the runner user — the
  build still works without it (falls back to software emulation
  automatically) but a full `base.txz` fetch + `pkg install` under pure
  TCG emulation is considerably slower; budget CI time accordingly if
  KVM isn't available (e.g. a nested-virtualization-disabled cloud VM).
- Outbound network access from the runner (the QEMU guest fetches
  `base.txz`/`kernel.txz` and packages from FreeBSD's mirrors over the
  guest's usermode-NAT network, which rides on the runner's own
  connection).
