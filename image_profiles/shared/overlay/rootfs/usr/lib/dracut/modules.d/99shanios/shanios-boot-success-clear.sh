#!/bin/sh
# shanios-boot-success-clear.sh — dracut pre-pivot hook: clear boot_hard_failure
# marker on successful root mount.
#
# Install: /usr/lib/dracut/modules.d/99shanios/
#   hook-name: pre-pivot (runs after / is successfully mounted, before pivot_root)
#   priority:  90
#
# This hook is the success counterpart to shanios-boot-failure-hook.sh.
# pre-pivot is only reached if dracut successfully mounted the root filesystem.
# If root mount failed, this hook never runs and the marker written by the
# pre-mount hook persists across reboot for shani-update to detect.
#
# Note: shanios-overlay-etc.sh has been removed. The /etc OverlayFS is now
# handled by fstab with x-initrd.mount, processed by systemd inside the
# initramfs. This hook no longer needs to coordinate with an overlay mount —
# it simply mounts @data, clears the marker, and unmounts.

type getarg > /dev/null 2>&1 || return 0   # not in dracut environment

DATA_MNT="/run/shanios-data-tmp"
ROOT_LABEL="shani_root"

# Mount @data so we can clear the failure marker.
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

# @data is no longer needed by this hook or any overlay mount after this point.
# Unmount cleanly. The real @data will be mounted post-pivot via fstab at /data.
umount "$DATA_MNT" 2>/dev/null || true
rmdir  "$DATA_MNT" 2>/dev/null || true
