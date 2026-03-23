#!/bin/sh
# shanios-overlay-etc.sh — dracut pre-pivot hook: mount /etc OverlayFS before pivot_root.
#
# Install: /usr/lib/dracut/modules.d/99shanios/
#   hook-name: pre-pivot (runs after / is successfully mounted, before pivot_root)
#   priority:  50 (before shanios-boot-success-clear.sh at 90)
#
# Why in dracut and not fstab:
#   The /etc overlay must be in place before systemd PID 1 reads a single unit
#   file. If /etc is mounted read-only at pivot_root and the overlay is applied
#   later (via fstab), systemd has already cached stale paths and will silently
#   miss any changes in /data/overlay/etc/upper. Moving the mount here ensures
#   the overlay is live from the very first read of the new root's /etc.
#
# Layout expected on @data:
#   /data/overlay/etc/upper/   — writable layer (persists across reboots)
#   /data/overlay/etc/work/    — OverlayFS workdir (must be on same fs as upper)
#
# The lowerdir is the new root's /etc (${NEWROOT}/etc), which is the read-only
# /etc from the active @blue or @green subvolume.
#
# mount options:
#   index=off   — avoids inode index checks that break across subvolume mounts
#   metacopy=off — disables metadata-only copy-up; keeps behaviour simple and
#                  compatible with older kernels (< 5.15)

type getarg > /dev/null 2>&1 || return 0   # not in dracut environment

DATA_MNT="/run/shanios-data-tmp"
ROOT_LABEL="shani_root"
OVERLAY_UPPER="${DATA_MNT}/overlay/etc/upper"
OVERLAY_WORK="${DATA_MNT}/overlay/etc/work"
TARGET_ETC="${NEWROOT}/etc"

# @data must already be mounted (the pre-mount failure hook mounts it and
# unmounts it). Re-mount it now read-write for the duration of this hook.
DATA_DEV=$(blkid -L "$ROOT_LABEL" 2>/dev/null) || {
    warn "shanios-overlay-etc: cannot locate $ROOT_LABEL — /etc overlay not mounted"
    return 0
}

# Safety unmount in case a previous hook left the mountpoint occupied.
umount "$DATA_MNT" 2>/dev/null || true

mkdir -p "$DATA_MNT"
if ! mount -t btrfs -o subvol=@data,rw "$DATA_DEV" "$DATA_MNT" 2>/dev/null; then
    warn "shanios-overlay-etc: cannot mount @data — /etc overlay not mounted"
    rmdir "$DATA_MNT" 2>/dev/null || true
    return 0
fi

# Ensure the overlay directories exist. They should have been created by
# shani-deploy, but create them defensively so a fresh install doesn't panic.
if ! mkdir -p "$OVERLAY_UPPER" "$OVERLAY_WORK" 2>/dev/null; then
    warn "shanios-overlay-etc: cannot create overlay dirs in @data — /etc overlay not mounted"
    umount "$DATA_MNT" 2>/dev/null || true
    rmdir  "$DATA_MNT" 2>/dev/null || true
    return 0
fi

# Mount the OverlayFS directly onto the new root's /etc.
# $NEWROOT is set by dracut to the mountpoint of the new root filesystem.
if ! mount -t overlay overlay \
        -o "rw,lowerdir=${TARGET_ETC},upperdir=${OVERLAY_UPPER},workdir=${OVERLAY_WORK},index=off,metacopy=off" \
        "${TARGET_ETC}"; then
    warn "shanios-overlay-etc: overlay mount on ${TARGET_ETC} failed — /etc will be read-only"
    umount "$DATA_MNT" 2>/dev/null || true
    rmdir  "$DATA_MNT" 2>/dev/null || true
    return 0
fi

warn "shanios-overlay-etc: /etc overlay mounted (upper=${OVERLAY_UPPER})"

# @data must stay mounted: the overlay upper/work dirs live on it and the
# kernel holds them open. Do NOT unmount $DATA_MNT here.
# dracut's switch_root will move all mounts under /run into the new root's
# /run automatically, so $DATA_MNT will be visible at /run/shanios-data-tmp
# inside the booted system. A systemd mount unit or tmpfiles rule may clean
# it up after /data is mounted via fstab if desired.
