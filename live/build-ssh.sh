#!/bin/sh
# live/build-ssh.sh — freedomnas-live-ssh.iso: the same live system as
# build.sh, reachable over the network. root accepts one public key and
# sshd starts at boot, so a machine with no usable screen or keyboard can
# be installed from another one: ssh root@<address>, then freedomnas-install.
#
# Usage: live/build-ssh.sh [public key file] [iso path]
# The key defaults to $FNAS_LIVE_SSH_KEY, then to the invoking user's
# ~/.ssh/id_ed25519.pub, id_ecdsa.pub or id_rsa.pub (under sudo, the user
# who ran sudo). root keeps no password: without a key there is no build.
#
# Everything else — environment, requirements, output — is build.sh's.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

key="${1:-${FNAS_LIVE_SSH_KEY:-}}"
if [ -z "$key" ]; then
    user="${SUDO_USER:-$(id -un)}"
    home="$(getent passwd "$user" | cut -d: -f6)"
    for candidate in id_ed25519.pub id_ecdsa.pub id_rsa.pub; do
        if [ -r "$home/.ssh/$candidate" ]; then
            key="$home/.ssh/$candidate"
            break
        fi
    done
fi
[ -n "$key" ] || { echo "live/build-ssh.sh: no public key given and none in ~/.ssh" >&2; exit 1; }

echo "live/build-ssh.sh: root will accept $key"
FNAS_LIVE_SSH_KEY="$key" exec sh "$SCRIPT_DIR/build.sh" "${2:-$SCRIPT_DIR/freedomnas-live-ssh.iso}"
