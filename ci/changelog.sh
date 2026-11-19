#!/bin/sh
# ci/changelog.sh — write what changed since the previous release into the
# text of this run's release on the GitHub showcase repo.
#
# The release text ends with a hidden line naming the commit of every
# repository it was built from. The next run finds the newest earlier
# release of the same channel (dev, or a vX.Y.Z), reads that line, and
# lists each repository's commits from there to the commit it builds now,
# with the kernel's version change on top. A first release, or one after a
# release without that line, gets only the line.
#
# Usage: ci/changelog.sh
# Environment:
#   GH_RELEASE_TOKEN  as for ci/publish-release.sh
#   GH_REPO           owner/name (default FreedomNAS/freedomnas-image)
#   RELEASE_TAG       this run's release (nothing done when it does not exist)
#   SRC_REF           what the run builds: refs/heads/dev or refs/tags/vX.Y.Z
#   FNAS_CHANNEL      dev or main
#   DRY_RUN=1         print the text instead of sending it
#   PREVIOUS_REFS     "repo=commit ..." instead of the previous release's line (tests)

set -eu

GH_REPO="${GH_REPO:-FreedomNAS/freedomnas-image}"
RELEASE_TAG="${RELEASE_TAG:?RELEASE_TAG is not set}"
SRC_REF="${SRC_REF:?SRC_REF is not set}"
FNAS_CHANNEL="${FNAS_CHANNEL:-dev}"
DRY_RUN="${DRY_RUN:-}"
API="https://api.github.com/repos/$GH_REPO"
FORGE="https://github.com/FreedomNAS"
MARKER="freedomnas-refs:"
MAX_LINES="${MAX_LINES:-40}"

REPOS="freedomnas-core:Core
freedomnas-profiles:Profiles
freedomnas-webui:WebUI
freedomnas-installer:Installer
freedomnas-containers:Containers module
freedomnas-proxy:Reverse proxy module
linux-freedomnas:Kernel
freedomnas-freebsd:FreeBSD packages
freedomnas-image-builder:Image builder
freedomnas-docs:Documentation"

for tool in curl git jq; do
    command -v "$tool" >/dev/null || { echo "changelog.sh: $tool not found" >&2; exit 1; }
done

gh_api() {
    method=$1 url=$2
    shift 2
    [ -z "${GH_RELEASE_TOKEN:-}" ] || set -- -H "Authorization: Bearer $GH_RELEASE_TOKEN" "$@"
    curl -sS --fail-with-body -X "$method" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$@" "$url"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

gh_api GET "$API/releases?per_page=50" > "$work/releases.json"
current=$(jq -c --arg t "$RELEASE_TAG" '.[] | select(.tag_name == $t)' "$work/releases.json")
if [ -z "$current" ]; then
    echo "changelog.sh: no release $RELEASE_TAG: nothing published, nothing to write"
    exit 0
fi
rid=$(printf '%s' "$current" | jq -r '.id')
created=$(printf '%s' "$current" | jq -r '.published_at // .created_at')
if [ "$FNAS_CHANNEL" = dev ]; then same='endswith("(dev)")'; else same='endswith("(dev)") | not'; fi
previous=$(jq -c --arg c "$created" --arg t "$RELEASE_TAG" \
    "[.[] | select(.tag_name != \$t and (.published_at // .created_at) < \$c and (.name | $same))] | sort_by(.published_at // .created_at) | last // empty" \
    "$work/releases.json")
previous_tag=$(printf '%s' "$previous" | jq -r '.tag_name // empty' 2>/dev/null || true)
old_refs="${PREVIOUS_REFS:-$(printf '%s' "$previous" | jq -r '.body // ""' 2>/dev/null \
    | sed -n "s/.*<!-- $MARKER \(.*\) -->.*/\1/p" | tail -n 1)}"

ref_name="${SRC_REF#refs/*/}"
fallback=dev
[ "$FNAS_CHANNEL" = dev ] || fallback=main

refs=""
changes=""
kernel_line=""
printf '%s\n' "$REPOS" > "$work/repos"
while IFS=: read -r repo title; do
    dir="$work/$repo"
    repo_url="$FORGE/$repo"
    [ "$repo" != freedomnas-image-builder ] || repo_url="$FORGE/freedomnas-builder"
    if ! git clone -q --bare --filter=blob:none --single-branch --branch "$ref_name" "$repo_url.git" "$dir" 2>/dev/null; then
        git clone -q --bare --filter=blob:none --single-branch --branch "$fallback" "$repo_url.git" "$dir" 2>/dev/null || continue
    fi
    head=$(git -C "$dir" rev-parse HEAD)
    refs="$refs $repo=$head"
    old=$(printf '%s\n' $old_refs | sed -n "s/^$repo=//p")
    [ -n "$old" ] && [ "$old" != "$head" ] || continue
    if ! git -C "$dir" cat-file -e "$old^{commit}" 2>/dev/null; then
        git -C "$dir" fetch -q --filter=blob:none origin "$old" 2>/dev/null || true
    fi
    git -C "$dir" cat-file -e "$old^{commit}" 2>/dev/null || continue
    log=$(git -C "$dir" log --no-merges --format='- %s (`%h`)' "$old..$head")
    [ -n "$log" ] || continue
    count=$(printf '%s\n' "$log" | wc -l)
    shown=$(printf '%s\n' "$log" | head -n "$MAX_LINES")
    [ "$count" -le "$MAX_LINES" ] || shown="$shown
- … and $((count - MAX_LINES)) more: $repo_url/compare/$old...$head"
    changes="$changes
### $title

$shown
"
    if [ "$repo" = linux-freedomnas ]; then
        was=$(git -C "$dir" show "$old:PKGBUILD" 2>/dev/null | sed -n 's/^pkgver=//p')
        now=$(git -C "$dir" show "$head:PKGBUILD" 2>/dev/null | sed -n 's/^pkgver=//p')
        zwas=$(git -C "$dir" show "$old:PKGBUILD" 2>/dev/null | sed -n 's/^_zfsver=//p')
        znow=$(git -C "$dir" show "$head:PKGBUILD" 2>/dev/null | sed -n 's/^_zfsver=//p')
        [ "$was" = "$now" ] || kernel_line="Linux $was → $now"
        [ "$zwas" = "$znow" ] || kernel_line="${kernel_line:+$kernel_line, }OpenZFS $zwas → $znow"
    fi
done < "$work/repos"

intro=$(printf '%s' "$current" | jq -r '.body // ""' | sed '/^## Changes/,$d' | sed "/<!-- $MARKER/d")
{
    printf '%s\n\n' "$intro"
    if [ -n "$changes" ]; then
        printf '## Changes since %s\n\n' "${previous_tag:-the previous release}"
        [ -z "$kernel_line" ] || printf '**%s**\n' "$kernel_line"
        printf '%s\n' "$changes"
    elif [ -n "$old_refs" ]; then
        printf '## Changes since %s\n\nNo change in the sources.\n\n' "${previous_tag:-the previous release}"
    fi
    printf '<!-- %s%s -->\n' "$MARKER" "$refs"
} > "$work/body.md"

if [ -n "$DRY_RUN" ]; then
    cat "$work/body.md"
    exit 0
fi
jq -n --rawfile body "$work/body.md" '{body: $body}' > "$work/patch.json"
gh_api PATCH "$API/releases/$rid" --data-binary "@$work/patch.json" >/dev/null
echo "changelog.sh: changes written into $RELEASE_TAG${previous_tag:+ (since $previous_tag)}"
