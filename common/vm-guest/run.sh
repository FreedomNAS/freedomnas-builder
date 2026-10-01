#!/bin/sh
# common/vm-guest/run.sh — runs inside the FreedomNAS live ISO when
# common/vm-install.sh attaches the FNASSEED disc (see live/build.sh's
# .bash_profile). Puts the seed's repo checkouts in place of the ones baked
# into the ISO, waits for the network, then runs freedomnas-installer
# unattended onto the VM's disk. The host reads the outcome from the serial
# log: the last line is "vm-install: RESULT ok" or "vm-install: RESULT failed".
set -u
SEED=/run/fnas-seed
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH
set -a
. "$SEED/seed.env"
set +a

log() { echo "vm-install: $*"; }

log "edition=$FNAS_EDITION init=${FNAS_INIT:-default} disk=$FNAS_DISK"

LIB=/usr/lib/freedomnas
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

tries=0
until ip route show default | grep -q . && getent hosts codeberg.org >/dev/null; do
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
