#!/bin/sh
# shanios-boot-success-clear.sh — dracut pre-pivot hook: clear boot_hard_failure
# marker on successful root mount.
#
# Install: /usr/lib/dracut/modules.d/99shanios/
#   hook-name: pre-pivot (runs after / is successfully mounted, before pivot_root)
#
# This hook is the success counterpart to shanios-boot-failure-hook.sh.
# pre-pivot is only reached if dracut successfully mounted the root filesystem.
# If root mount failed, this hook never runs and the marker written by the
# pre-mount hook persists across reboot for shani-update to detect.

type getarg > /dev/null 2>&1 || return 0   # not in dracut environment

DATA_MNT="/run/shanios-data-tmp"
ROOT_LABEL="shani_root"

DATA_DEV=$(blkid -L "$ROOT_LABEL" 2>/dev/null) || {
    warn "shanios-hook: cannot locate $ROOT_LABEL device — hard failure marker not cleared"
    return 0
}

# Safety unmount in case the pre-mount hook left the mountpoint busy.
umount "$DATA_MNT" 2>/dev/null || true

mkdir -p "$DATA_MNT"
if ! mount -t btrfs -o subvol=@data,rw "$DATA_DEV" "$DATA_MNT" 2>/dev/null; then
    warn "shanios-hook: cannot mount @data — hard failure marker not cleared"
    rmdir "$DATA_MNT" 2>/dev/null || true
    return 0
fi

if [ -f "$DATA_MNT/boot_hard_failure" ]; then
    rm -f "$DATA_MNT/boot_hard_failure" 2>/dev/null && \
        warn "shanios-hook: boot_hard_failure cleared — root mount succeeded"
fi

umount "$DATA_MNT" 2>/dev/null || true
rmdir  "$DATA_MNT" 2>/dev/null || true
