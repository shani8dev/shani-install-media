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
# Restores queued by `shani-etc-changes restore` (Shani Cassini, System
# Changes): each line of etc-restore-pending is a path under /etc whose own
# copy in the upper layer is removed here, so the slot's factory version shows
# through again (or, for a file the image does not have, the file goes; for a
# deleted file, its whiteout goes and the file is back). This is the only safe
# moment: the upper layer must not be changed under a mounted overlay. Files and
# whiteouts only, never a directory; a line that is absolute or climbs out with
# .. is refused. What was done is appended to etc-restore-done for the page.
PENDING="${DATA_MNT}/etc-restore-pending"
if [ -s "$PENDING" ]; then
    while IFS= read -r RLINE || [ -n "$RLINE" ]; do
        case "$RLINE" in
            ""|/*|..|../*|*/..|*/../*)
                warn "shanios-overlay-etc: refused restore line '${RLINE}'"; continue ;;
        esac
        RTARGET="${OVERLAY_UPPER}/${RLINE}"
        if [ -d "$RTARGET" ] && [ ! -L "$RTARGET" ]; then
            warn "shanios-overlay-etc: /etc/${RLINE} is a directory - not restored"
            continue
        fi
        if [ -e "$RTARGET" ] || [ -L "$RTARGET" ]; then
            if rm -f "$RTARGET" 2>/dev/null; then
                printf '%s restored %s\n' "$(date +%s 2>/dev/null)" "$RLINE" >> "${DATA_MNT}/etc-restore-done"
                warn "shanios-overlay-etc: restored /etc/${RLINE} to the factory version"
            else
                warn "shanios-overlay-etc: could not restore /etc/${RLINE}"
            fi
        fi
    done < "$PENDING"
    rm -f "$PENDING"
    sync
fi

# The lower layer is the booted slot's /etc, so it is a DIFFERENT tree after
# every deploy. The kernel allows offline changes to the lower layer only when
# none of index, metacopy, redirect_dir and xino was used (overlayfs.rst,
# "Changes to underlying filesystems"); otherwise the behaviour is undefined.
# Arch's kernel turns all four on (measured on 7.2.6-arch2-1: /sys/module/
# overlay/parameters redirect_dir=Y index=Y xino_auto=Y metacopy=Y), and this
# mount turned off only two. redirect_dir=follow creates no new redirects but
# still follows any an earlier mount made, so a directory someone renamed keeps
# its contents; renaming a shipped directory now copies it (mv does that by
# itself on EXDEV). Measured in a container: all three behaviours hold. xino is
# not used while both layers are on one filesystem - @data and the slot are
# subvolumes of the same btrfs, and the kernel does not even list xino then
# (measured) - so xino=off is explicit for the day they are not. The idea
# is Ananta OS's (an ESTALE /etc after an update, implementation-notes §6).
if ! mount -t overlay overlay \
        -o "rw,lowerdir=${TARGET_ETC},upperdir=${OVERLAY_UPPER},workdir=${OVERLAY_WORK},index=off,metacopy=off,redirect_dir=follow,xino=off" \
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
