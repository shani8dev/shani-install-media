#!/bin/sh
# shanios-boot-failure-hook.sh — dracut pre-mount hook: write boot_hard_failure
# marker before root mount is attempted.
#
# Install: /usr/lib/dracut/modules.d/99shanios/
#   hook-name: pre-mount (runs after device discovery and LUKS unlock,
#              before / is mounted)
#
# Logic:
#   This hook writes /data/boot_hard_failure unconditionally before the root
#   Btrfs subvolume mount is attempted. A companion pre-pivot hook
#   (shanios-boot-success-clear.sh) deletes the marker if mount succeeds and
#   the system reaches pivot_root. If mount fails, pre-pivot is never reached,
#   the marker persists across reboot, and shani-update detects a hard failure.
#
#   This write-then-clear-on-success pattern is necessary because dracut has
#   no "on mount failure" hook — pre-mount runs unconditionally.
#
# The file persists across reboots intentionally: mark-boot-in-progress does
# NOT clear it. shani-update defers to shani-deploy --rollback when it sees
# boot_hard_failure, because automated recovery requires mounting the Btrfs
# root which itself failed — a human must act.

type getarg > /dev/null 2>&1 || return 0   # not in dracut environment

DATA_MNT="/run/shanios-data-tmp"
ROOT_LABEL="shani_root"

# Locate the @data subvolume device by filesystem label.
# At pre-mount 90 the crypt module has already run, so blkid -L finds the
# plaintext Btrfs device (or dm-crypt mapped device if LUKS is in use).
DATA_DEV=$(blkid -L "$ROOT_LABEL" 2>/dev/null) || {
    warn "shanios-hook: cannot locate $ROOT_LABEL device — skipping hard failure write"
    return 0
}

# Mount just the @data subvolume read-write so we can write the marker.
mkdir -p "$DATA_MNT"
if ! mount -t btrfs -o subvol=@data,rw "$DATA_DEV" "$DATA_MNT" 2>/dev/null; then
    warn "shanios-hook: cannot mount @data — hard failure marker not written"
    rmdir "$DATA_MNT" 2>/dev/null || true
    return 0
fi

# Record which slot was being attempted, then unmount immediately.
# Always overwrite — if a stale marker from a previous failed slot exists,
# it must reflect the current boot attempt. The clear hook removes it on
# success, so persistence only means the current attempt failed.
ATTEMPTED_SLOT=$(getarg rootflags | sed 's/.*subvol=@//;s/,.*//')
# Validate — if rootflags has no subvol=@ or sed returns garbage, use "unknown"
# as a sentinel. shani-update handles unknown gracefully via its fallback logic.
case "$ATTEMPTED_SLOT" in
    blue|green) ;;
    *) ATTEMPTED_SLOT="unknown" ;;
esac
printf '%s\n' "$ATTEMPTED_SLOT" > "$DATA_MNT/boot_hard_failure" 2>/dev/null && \
    warn "shanios-hook: boot_hard_failure written for slot '@${ATTEMPTED_SLOT}' (will be cleared on successful pivot)"

umount "$DATA_MNT" 2>/dev/null || true
rmdir  "$DATA_MNT" 2>/dev/null || true
