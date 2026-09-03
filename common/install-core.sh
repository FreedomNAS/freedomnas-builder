#!/bin/sh
# common/install-core.sh — bake freedomnas-core + freedomnas-profiles +
# freedomnas-webui into the target root, per ARCHITECTURE.md's
# "Installed Filesystem Layout" (/usr/lib/freedomnas/{core,profiles,webui}).
#
# Expects freedomnas-core, freedomnas-profiles, and freedomnas-webui to be
# checked out as sibling directories of freedomnas-image-builder (same
# convention engine.py's dev-mode profile search path already uses).
set -eu

fnas_install_core() {
    root="$1"                # target root, e.g. /mnt
    repos_dir="$2"           # parent dir containing the sibling repo checkouts

    core_src="$repos_dir/freedomnas-core"
    profiles_src="$repos_dir/freedomnas-profiles"
    webui_src="$repos_dir/freedomnas-webui"

    for d in "$core_src" "$profiles_src" "$webui_src"; do
        [ -d "$d" ] || { echo "install-core.sh: missing sibling repo: $d" >&2; exit 1; }
    done

    mkdir -p "$root/usr/lib/freedomnas/core/freedomnas"
    mkdir -p "$root/usr/lib/freedomnas/profiles"
    mkdir -p "$root/usr/lib/freedomnas/webui"

    rsync -a --exclude='.git' --exclude='__pycache__' --exclude='tests' --exclude='conftest.py' \
        "$core_src/" "$root/usr/lib/freedomnas/core/freedomnas/"

    rsync -a --exclude='.git' --exclude='debian' --exclude='PKGBUILD' --exclude='*.md' \
        "$profiles_src/" "$root/usr/lib/freedomnas/profiles/"

    rsync -a --exclude='.git' \
        "$webui_src/" "$root/usr/lib/freedomnas/webui/"

    mkdir -p "$root/usr/lib/python3/dist-packages"
    echo "/usr/lib/freedomnas/core" > "$root/usr/lib/python3/dist-packages/freedomnas-core.pth"

    echo "install-core.sh: freedomnas-core/profiles/webui installed under $root/usr/lib/freedomnas/" >&2
}
