#!/bin/bash
# 06-simulate-rollback.sh
#
# Run this FROM the slot you want to KEEP (i.e. after 05-simulate-reboot.sh
# has "booted" the new candidate and you've decided it's bad). It enters the
# current slot and runs `shani-update --rollback`, exactly the recovery path
# a real user (or the fallback-boot detection in shani-update.sh) would take.
set -euo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../../config/config.sh"

DATA_DIR="${SHANIOS_TEST_DATA:-${SCRIPT_DIR}/../disk}"
MNT="${SHANIOS_TEST_MNT:-/mnt/shanios-toplevel}"
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount -o subvolid=5 "/dev/disk/by-label/shani_root" "$MNT"

CURRENT_SLOT=$(tr -d '[:space:]' < "$MNT/@data/current-slot" 2>/dev/null || echo "")
[[ "$CURRENT_SLOT" =~ ^(blue|green)$ ]] || die "Couldn't read current-slot marker"

log "Rolling back FROM @${CURRENT_SLOT} (this restores the *other* slot and repoints boot at it)"
exec "${SCRIPT_DIR}/03-enter-slot.sh" "$CURRENT_SLOT" shani-update --rollback
