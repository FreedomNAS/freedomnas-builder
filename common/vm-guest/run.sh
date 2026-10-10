#!/bin/sh
# common/vm-guest/run.sh — runs inside a FreedomNAS live ISO when
# common/vm-install.sh attaches the FNASSEED disc (see live/build.sh's
# .bash_profile and freebsd/guest/live-in-guest.sh's .profile). On the
# Linux ISO it puts the seed's repo checkouts in place of the ones baked
# into the ISO; the FreeBSD ISO's root is read-only, and its FreedomNAS was
# built from the same checkouts in the same run. Then it waits for the
# network and runs freedomnas-installer unattended onto the VM's disk. The
# host reads the outcome from the serial log: the last line is
# "vm-install: RESULT ok" or "vm-install: RESULT failed".
set -u
SEED="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH
set -a
. "$SEED/seed.env"
set +a

log() { echo "vm-install: $*"; }

case "$(uname -s)" in
FreeBSD)
    FNAS_INSTALL_ROOT=/usr/local/lib/freedomnas
    FNAS_TARGET_ROOT=/tmp/fnas-target
    FNAS_DISK="${FNAS_DISK_FREEBSD:-/dev/vtbd0}"
    ;;
*)
    FNAS_INSTALL_ROOT=/usr/lib/freedomnas
    FNAS_TARGET_ROOT=/mnt/fnas
    LIB="$FNAS_INSTALL_ROOT"
    for pair in core:core/freedomnas profiles:profiles webui:webui installer:installer docs:docs; do
        src="$SEED/repos/freedomnas-${pair%%:*}"
        dest="$LIB/${pair#*:}"
        if [ "${pair%%:*}" = docs ] && [ ! -f "$src/index.html" ]; then
            continue
        fi
        rm -rf "$dest"
        mkdir -p "$dest"
        cp -a "$src/." "$dest/"
    done
    chmod 755 "$LIB/installer/setup.py"
    ;;
esac
export FNAS_INSTALL_ROOT FNAS_TARGET_ROOT FNAS_DISK

log "edition=$FNAS_EDITION init=${FNAS_INIT:-default} disk=$FNAS_DISK"

has_route() {
    case "$(uname -s)" in
    FreeBSD) route -n get default >/dev/null 2>&1 ;;
    *) ip route show default | grep -q . ;;
    esac
}

tries=0
until has_route && getent hosts codeberg.org >/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 60 ]; then
        log "no network after 2 minutes"
        log "RESULT failed"
        exit 1
    fi
    sleep 2
done

if python3 "$SEED/drive_install.py"; then
    log "RESULT ok"
else
    tail -n 50 /var/log/freedomnas-install.log 2>/dev/null
    log "RESULT failed"
fi
