#!/bin/sh
# common/install-core.sh — bake freedomnas-core + freedomnas-profiles +
# freedomnas-webui + freedomnas-docs into the target root, per
# ARCHITECTURE.md's "Installed Filesystem Layout"
# (/usr/lib/freedomnas/{core,profiles,webui,docs}).
#
# Expects freedomnas-core, freedomnas-profiles, and freedomnas-webui to be
# checked out as sibling directories of freedomnas-image-builder (same
# convention engine.py's dev-mode profile search path already uses), and
# freedomnas-docs too if the image is to carry the offline documentation.
set -eu

fnas_repo_version() {
    base="$(sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p' "$1/debian/changelog")"
    base="${base%-*}"
    if git -C "$1" describe --exact-match --tags --match 'v[0-9]*' >/dev/null 2>&1; then
        printf '%s\n' "$base"
    elif git -C "$1" rev-parse --git-dir >/dev/null 2>&1; then
        printf '%s+%s.%s\n' "$base" \
            "$(git -C "$1" log -1 --format=%cd --date=format:%Y%m%d%H%M%S)" \
            "$(git -C "$1" log -1 --format=%h)"
    else
        printf '%s\n' "$base"
    fi
}

fnas_channel() {
    case "${FNAS_CHANNEL:-}" in
        main|dev) printf '%s\n' "$FNAS_CHANNEL" ;;
        "") if [ "$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ]; then
                echo main
            else
                echo dev
            fi ;;
        *) echo "install-core.sh: FNAS_CHANNEL must be main or dev, not $FNAS_CHANNEL" >&2; return 1 ;;
    esac
}

fnas_build_docs() {
    src="$1"
    dest="$2"
    version="$(fnas_repo_version "$src")"
    if command -v mkdocs >/dev/null; then
        FREEDOMNAS_DOCS_VERSION="$version" mkdocs build --quiet \
            --config-file "$src/mkdocs.yml" --site-dir "$dest" && return 0
    fi
    venv="$(mktemp -d)"
    if python3 -m venv "$venv" \
        && "$venv/bin/pip" install --quiet -r "$src/requirements.txt" \
        && FREEDOMNAS_DOCS_VERSION="$version" "$venv/bin/mkdocs" build --quiet \
            --config-file "$src/mkdocs.yml" --site-dir "$dest"; then
        rm -rf "$venv"
        return 0
    fi
    rm -rf "$venv"
    if [ -f "$src/site/index.html" ]; then
        echo "install-core.sh: could not build freedomnas-docs, using the prebuilt $src/site" >&2
        rsync -a "$src/site/" "$dest/"
        return 0
    fi
    return 1
}

fnas_install_core() {
    root="$1"                # target root, e.g. /mnt
    repos_dir="$2"           # parent dir containing the sibling repo checkouts

    core_src="$repos_dir/freedomnas-core"
    profiles_src="$repos_dir/freedomnas-profiles"
    webui_src="$repos_dir/freedomnas-webui"
    docs_src="$repos_dir/freedomnas-docs"

    for d in "$core_src" "$profiles_src" "$webui_src"; do
        [ -d "$d" ] || { echo "install-core.sh: missing sibling repo: $d" >&2; exit 1; }
    done

    mkdir -p "$root/usr/lib/freedomnas/core/freedomnas"
    mkdir -p "$root/usr/lib/freedomnas/profiles"
    mkdir -p "$root/usr/lib/freedomnas/webui"

    rsync -a --chown=0:0 --exclude='.git' --exclude='__pycache__' --exclude='tests' --exclude='conftest.py' \
        "$core_src/" "$root/usr/lib/freedomnas/core/freedomnas/"

    rsync -a --chown=0:0 --exclude='.git' --exclude='debian' --exclude='PKGBUILD' --exclude='*.md' \
        "$profiles_src/" "$root/usr/lib/freedomnas/profiles/"

    rsync -a --chown=0:0 --exclude='.git' \
        "$webui_src/" "$root/usr/lib/freedomnas/webui/"
    fnas_repo_version "$webui_src" > "$root/usr/lib/freedomnas/webui/VERSION"

    if [ -f "$docs_src/mkdocs.yml" ]; then
        mkdir -p "$root/usr/lib/freedomnas/docs"
        fnas_build_docs "$docs_src" "$root/usr/lib/freedomnas/docs" \
            || echo "install-core.sh: WARNING: freedomnas-docs not built — no offline documentation in this image" >&2
    else
        echo "install-core.sh: WARNING: no freedomnas-docs checkout at $docs_src — no offline documentation in this image" >&2
    fi

    mkdir -p "$root/usr/lib/python3/dist-packages"
    echo "/usr/lib/freedomnas/core" > "$root/usr/lib/python3/dist-packages/freedomnas-core.pth"

    echo "install-core.sh: freedomnas-core/profiles/webui/docs installed under $root/usr/lib/freedomnas/" >&2
}
