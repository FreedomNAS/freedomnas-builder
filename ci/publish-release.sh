#!/bin/sh
# ci/publish-release.sh — put built images on the GitHub showcase repo.
#
# The images are built here, on the self-hosted runner; GitHub only hosts
# the downloads, as release assets: public, permanent, no bandwidth cap,
# where workflow artifacts expire and need a login to download.
#
# Usage: ci/publish-release.sh <file>...
# Environment:
#   GH_RELEASE_TOKEN  fine-grained token, Contents: read and write on GH_REPO
#   GH_REPO           owner/name (default FreedomNAS/freedomnas-image)
#   RELEASE_TAG       the release the files go to; created when missing
#   RELEASE_NAME      its title (default: the tag)
#   UPLOAD_TRIES      tries per file before giving up (default 3)
#   DRY_RUN=1         say what would happen, send nothing
#
# Every job of one workflow run calls this with the same tag: the first
# creates the release, the others find it. An asset already there under the
# same name is replaced. Each file goes up with its .sha256. A file over the
# 2 GiB a release asset may hold goes up in 1900 MiB parts (.part-aa, ...),
# to be joined with cat before decompressing.

set -eu

GH_REPO="${GH_REPO:-FreedomNAS/freedomnas-image}"
RELEASE_TAG="${RELEASE_TAG:?RELEASE_TAG is not set}"
RELEASE_NAME="${RELEASE_NAME:-$RELEASE_TAG}"
DRY_RUN="${DRY_RUN:-}"
API="https://api.github.com/repos/$GH_REPO"
UPLOADS="https://uploads.github.com/repos/$GH_REPO"
MAX_ASSET="${MAX_ASSET:-2147483647}"   # GitHub: each asset under 2 GiB
PART_SIZE="${PART_SIZE:-1900M}"
UPLOAD_TRIES="${UPLOAD_TRIES:-3}"

[ "$#" -gt 0 ] || { echo "publish-release.sh: no files given" >&2; exit 1; }
for tool in curl jq sha256sum split stat; do
    command -v "$tool" >/dev/null || { echo "publish-release.sh: $tool not found" >&2; exit 1; }
done
if [ -z "$DRY_RUN" ] && [ -z "${GH_RELEASE_TOKEN:-}" ]; then
    echo "publish-release.sh: GH_RELEASE_TOKEN is not set" >&2
    exit 1
fi

gh_api() {
    # gh_api METHOD URL [curl args...] — prints the body, fails on HTTP >= 400
    method=$1 url=$2
    shift 2
    curl -sS --fail-with-body -X "$method" \
        -H "Authorization: Bearer $GH_RELEASE_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$@" "$url"
}

release_id() {
    gh_api GET "$API/releases/tags/$RELEASE_TAG" 2>/dev/null | jq -r '.id // empty'
}

ensure_release() {
    id=$(release_id || true)
    [ -n "$id" ] && { echo "$id"; return; }
    body=$(jq -n --arg tag "$RELEASE_TAG" --arg name "$RELEASE_NAME" '{
        tag_name: $tag, name: $name, prerelease: true,
        body: "FreedomNAS disk images and live ISO.\n\nEach file has a `.sha256` next to it. `.img.zst` images are written to a disk with Raspberry Pi Imager or Rufus 4.7+, which read `.zst` directly, or `zstd -dc <image>.img.zst | sudo dd of=/dev/sdX bs=4M status=progress`; balenaEtcher needs the image decompressed first (`zstd -d`). A file split in `.part-aa`, `.part-ab`, ... is joined first: `cat <file>.part-* > <file>`."
    }')
    # Another job of the same run may create it between our GET and POST:
    # then the POST is refused and the release is there to be found.
    id=$(gh_api POST "$API/releases" -d "$body" 2>/dev/null | jq -r '.id // empty' || true)
    [ -n "$id" ] && { echo "$id"; return; }
    release_id || true
}

drop_asset() {
    rid=$1 name=$2
    old=$(gh_api GET "$API/releases/$rid/assets?per_page=100" \
          | jq -r --arg n "$name" '.[] | select(.name == $n) | .id')
    for asset in $old; do
        gh_api DELETE "$API/releases/assets/$asset" >/dev/null
    done
}

upload() {
    # upload RELEASE_ID FILE — replaces an asset of the same name
    rid=$1 file=$2
    name=$(basename "$file")
    try=1
    while :; do
        drop_asset "$rid" "$name" || true
        if out=$(gh_api POST "$UPLOADS/releases/$rid/assets?name=$name" \
                -H "Content-Type: application/octet-stream" \
                -T "$file"); then
            echo "$out" | jq -r '"uploaded " + .name + " (" + (.size | tostring) + " bytes)"'
            return
        fi
        echo "publish-release.sh: upload of $name failed (try $try of $UPLOAD_TRIES): $out" >&2
        [ "$try" -lt "$UPLOAD_TRIES" ] || return 1
        try=$((try + 1))
        sleep 30
    done
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

files=""
for file in "$@"; do
    [ -f "$file" ] || { echo "publish-release.sh: $file: no such file" >&2; exit 1; }
    name=$(basename "$file")
    (cd "$(dirname "$file")" && sha256sum "$name") > "$work/$name.sha256"
    size=$(stat -c %s "$file")
    if [ "$size" -gt "$MAX_ASSET" ]; then
        echo "publish-release.sh: $name is $size bytes, over 2 GiB: splitting into $PART_SIZE parts" >&2
        split -b "$PART_SIZE" "$file" "$work/$name.part-"
        files="$files $work/$name.part-*"
    else
        files="$files $file"
    fi
    files="$files $work/$name.sha256"
done

if [ -n "$DRY_RUN" ]; then
    echo "publish-release.sh: would publish to $GH_REPO, release $RELEASE_TAG ($RELEASE_NAME):"
    for file in $files; do
        echo "  $(basename "$file") ($(stat -c %s "$file") bytes)"
    done
    exit 0
fi

rid=$(ensure_release)
[ -n "$rid" ] || { echo "publish-release.sh: could not create or find release $RELEASE_TAG" >&2; exit 1; }
for file in $files; do
    upload "$rid" "$file"
done
echo "publish-release.sh: https://github.com/$GH_REPO/releases/tag/$RELEASE_TAG"
