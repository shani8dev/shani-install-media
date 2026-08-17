#!/bin/bash
# 04-simulate-upgrade.sh [-- extra shani-update args]
#
# Runs from the HOST side of the container (not inside a slot): figures out
# which slot is currently marked current (/data/current-slot on the real
# disk), enters it via 03-enter-slot.sh, and runs shani-update there.
#
# No mirror env var to set: downloads.shani.dev resolves to this container
# (run_in_container.sh's --add-host) and the test CA is already trusted inside
# the slot (01-bootstrap-rootfs.sh), so the real, unmodified shani-update /
# shani-deploy binaries just hit "https://downloads.shani.dev" as they would
# in production and land on 02-serve-update.sh instead.
#
# Requires 02-serve-update.sh running (in another session) first.
set -euo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../../config/config.sh"

DATA_DIR="${SHANIOS_TEST_DATA:-${SCRIPT_DIR}/../disk}"
MNT="${SHANIOS_TEST_MNT:-/mnt/shanios-toplevel}"
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount -o subvolid=5 "/dev/disk/by-label/shani_root" "$MNT"

CURRENT_SLOT=$(tr -d '[:space:]' < "$MNT/@data/current-slot" 2>/dev/null || echo "")
[[ "$CURRENT_SLOT" =~ ^(blue|green)$ ]] || die "Couldn't read current-slot marker — run 01-bootstrap-rootfs.sh first"

log "Current slot marker: @${CURRENT_SLOT}"
log "Running: shani-update --force --skip-self-update $* (inside @${CURRENT_SLOT})"

exec "${SCRIPT_DIR}/03-enter-slot.sh" "$CURRENT_SLOT" \
    shani-update --force --skip-self-update "$@"
