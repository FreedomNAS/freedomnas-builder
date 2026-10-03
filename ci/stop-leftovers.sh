#!/bin/sh
# ci/stop-leftovers.sh — stop what an image build left running, as root.
#
# The builds run on the runner's host as root through sudo, and the runner
# user cannot stop root's processes: a cancelled or failed job leaves its
# emerge, QEMU or zstd running, and the next job waits behind them or
# trips over them. build-images.yml runs this at the start of every job
# (a cancelled run may never reach its last steps) and at its end, always.
#
# Stopped: root's processes chrooted into the live ISO's build root, or
# naming a CI path on their command line (the runner's workspaces,
# /var/tmp/freedomnas-live, /var/tmp/freedomnas-ci), and all their
# descendants — TERM, then KILL after 5 seconds. Nothing else: other VMs and
# whatever else root runs on the machine are left alone. Then whatever is
# still mounted under the build root is unmounted.
#
# Usage: sudo sh ci/stop-leftovers.sh      (DRY_RUN=1: list, stop nothing)

set -u

LIVE_ROOT=/var/tmp/freedomnas-live/root
DRY_RUN="${DRY_RUN:-}"

[ "$(id -u)" -eq 0 ] || { echo "stop-leftovers.sh: must run as root" >&2; exit 1; }

ppid_of() {
    # Field 4 of /proc/<pid>/stat, read after the ")" closing the command
    # name, which may itself hold spaces.
    sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f2
}

# Never this script, nor what started it (sudo, the job's shell).
skip=" "
p=$$
while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    skip="$skip$p "
    p=$(ppid_of "$p")
done

matched=" "
for dir in /proc/[0-9]*; do
    pid=${dir#/proc/}
    case "$skip" in *" $pid "*) continue ;; esac
    [ "$(stat -c %u "$dir" 2>/dev/null)" = 0 ] || continue
    case "$(readlink "$dir/root" 2>/dev/null)" in
        "$LIVE_ROOT"|"$LIVE_ROOT"/*) matched="$matched$pid "; continue ;;
    esac
    case "$(tr '\0' ' ' < "$dir/cmdline" 2>/dev/null)" in
        */var/lib/forgejo-runner/.cache/act/*|*/var/tmp/freedomnas-live*|*/var/tmp/freedomnas-ci*)
            matched="$matched$pid " ;;
    esac
done

# Their descendants too, whatever they are called (zstd, qemu, make...).
grew=1
while [ "$grew" -eq 1 ]; do
    grew=0
    for dir in /proc/[0-9]*; do
        pid=${dir#/proc/}
        case "$matched$skip" in *" $pid "*) continue ;; esac
        case "$matched" in *" $(ppid_of "$pid") "*) matched="$matched$pid "; grew=1 ;; esac
    done
done

pids=$(echo $matched)
if [ -n "$pids" ]; then
    for pid in $pids; do
        echo "stop-leftovers.sh: $pid $(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-150)"
    done
    if [ -z "$DRY_RUN" ]; then
        kill -TERM $pids 2>/dev/null
        sleep 5
        alive=""
        for pid in $pids; do
            [ -d "/proc/$pid" ] && alive="$alive $pid"
        done
        [ -n "$alive" ] && kill -KILL $alive 2>/dev/null
    fi
else
    echo "stop-leftovers.sh: no build process left"
fi

# Deepest first, lazily: a mount still busy goes as soon as it is free.
mounts=$(findmnt -rn -o TARGET | grep -E "^$LIVE_ROOT(/|\$)" | sort -r)
for target in $mounts; do
    echo "stop-leftovers.sh: unmounting $target"
    [ -n "$DRY_RUN" ] || umount -l "$target" 2>/dev/null || true
done
exit 0
