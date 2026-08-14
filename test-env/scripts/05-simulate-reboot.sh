#!/bin/bash
# 05-simulate-reboot.sh [command...]
#
# A real reboot re-reads the boot entry the bootloader picked (which
# finalize_boot_entries in shani-deploy.sh points at /data/current-slot after
# a successful deploy) and boots that subvolume. We don't have a bootloader
# here, so "rebooting" just means: read the current-slot marker again and
# enter whatever it now says — exactly the slot a real reboot would land you
# in after 04-simulate-upgrade.sh flips it.
set -euo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../../config/config.sh"

DATA_DIR="${SHANIOS_TEST_DATA:-${SCRIPT_DIR}/../disk}"
MNT="${SHANIOS_TEST_MNT:-/mnt/shanios-toplevel}"
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount -o subvolid=5 "/dev/disk/by-label/shani_root" "$MNT"

CURRENT_SLOT=$(tr -d '[:space:]' < "$MNT/@data/current-slot" 2>/dev/null || echo "")
[[ "$CURRENT_SLOT" =~ ^(blue|green)$ ]] || die "Couldn't read current-slot marker"

log "'Rebooting' into @${CURRENT_SLOT} (per /data/current-slot)"
exec "${SCRIPT_DIR}/03-enter-slot.sh" "$CURRENT_SLOT" "$@"
