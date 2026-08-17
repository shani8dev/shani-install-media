#!/bin/sh
# shanios-boot-success-clear.sh — dracut pre-pivot hook: clear boot_hard_failure
# marker on successful root mount.
#
# Install: /usr/lib/dracut/modules.d/99shanios/
#   hook-name: pre-pivot (runs after / is successfully mounted, before pivot_root)
#   priority:  90 (after shanios-overlay-etc.sh at 50)
#
# This hook is the success counterpart to shanios-boot-failure-hook.sh.
# pre-pivot is only reached if dracut successfully mounted the root filesystem.
# If root mount failed, this hook never runs and the marker written by the
# pre-mount hook persists across reboot for shani-update to detect.
#
# Ordering note:
#   shanios-overlay-etc.sh (pre-pivot 50) runs before this hook and mounts
#   @data at $DATA_MNT, deliberately leaving it mounted so the /etc overlay
#   upper/work dirs remain accessible. This hook MUST NOT unmount $DATA_MNT
#   before or after operating on it — the overlay kernel state depends on it
#   staying mounted through pivot_root. We simply use the already-live mount.

type getarg > /dev/null 2>&1 || return 0   # not in dracut environment

DATA_MNT="/run/shanios-data-tmp"
ROOT_LABEL="shani_root"

# If @data is not already mounted (e.g. overlay-etc hook failed to mount it),
# mount it now so we can still clear the failure marker.
if ! mountpoint -q "$DATA_MNT" 2>/dev/null; then
    DATA_DEV=$(blkid -L "$ROOT_LABEL" 2>/dev/null) || {
        warn "shanios-hook: cannot locate $ROOT_LABEL device — hard failure marker not cleared"
        return 0
    }
    mkdir -p "$DATA_MNT"
    if ! mount -t btrfs -o subvol=@data,rw "$DATA_DEV" "$DATA_MNT" 2>/dev/null; then
        warn "shanios-hook: cannot mount @data — hard failure marker not cleared"
        rmdir "$DATA_MNT" 2>/dev/null || true
        return 0
    fi
fi

if [ -f "$DATA_MNT/boot_hard_failure" ]; then
    rm -f "$DATA_MNT/boot_hard_failure" 2>/dev/null && \
        warn "shanios-hook: boot_hard_failure cleared — root mount succeeded"
fi

# Do NOT unmount $DATA_MNT here. The /etc overlay (mounted by
# shanios-overlay-etc.sh at pre-pivot 50) has its upper and work dirs on
# this mount. Unmounting would break the overlay before pivot_root.
# dracut's switch_root moves /run into the new root automatically.
