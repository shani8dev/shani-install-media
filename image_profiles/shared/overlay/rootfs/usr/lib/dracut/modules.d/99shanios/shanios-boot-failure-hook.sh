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
#   the marker persists across reboot, and shani-auto-rollback.sh detects a
#   hard failure.
#
#   This write-then-clear-on-success pattern is necessary because dracut has
#   no "on mount failure" hook — pre-mount runs unconditionally.
#
# The file persists across reboots intentionally: mark-boot-in-progress does
# NOT clear it. The marker is the only evidence a hard failure happened, so
# it is what shani-auto-rollback.sh acts on (it runs unattended, with no
# session/display, and calls shani-deploy --rollback for the two confirmed
# failure shapes). A marker whose content is not a valid slot name is
# deliberately left for manual recovery rather than acted on.

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
# as a sentinel. shani-auto-rollback.sh refuses to guess on an unknown slot
# and leaves it for manual recovery (shani-health / shani-deploy --rollback).
case "$ATTEMPTED_SLOT" in
    blue|green) ;;
    *) ATTEMPTED_SLOT="unknown" ;;
esac
# ── If the PREVIOUS boot also failed, stop defaulting to the broken slot ────
#
# The gap this closes: boot_hard_failure is written by a boot that FAILS, but
# shani-auto-rollback acts on it from a boot that SUCCEEDS. That works, but only
# if the operator knows to pick the other slot — because the default still
# points at the candidate that cannot mount, and on systemd 261 systemd-boot
# does not decrement the +3-0 tries counter, so every automatic boot lands back
# in dracut. Observed on a machine that lost power mid-update: three
# "Failed to mount /sysroot", four minutes apart, then an emergency shell.
#
# So flip the default here, at pre-mount, where we still can — the boot entry
# for THIS boot was chosen before the kernel started and cannot be changed now,
# but the next one can.
#
# Deliberately narrow, and fails open (any doubt changes nothing):
#   * only when a pre-existing boot_hard_failure proves an earlier boot failed
#   * only when the current default is a tries-counted entry, which is exactly
#     how a deploy marks an unproven candidate
#   * only by rewriting the `default` line — no entry is ever deleted
#   * self-limiting: after the switch the default is a plain entry, which does
#     not match, so this cannot ping-pong between two broken slots
if [ -s "$DATA_MNT/boot_hard_failure" ]; then
    PRIOR_FAILURE=$(cat "$DATA_MNT/boot_hard_failure" 2>/dev/null)
    ESP_DEV=$(blkid -L shani_boot 2>/dev/null)
    ESP_MNT=/run/shanios-boot-esp-tmp
    # Every exit below is announced. The first firmware boot of this ran through
    # this whole block, changed nothing, and logged nothing — so a branch that
    # does not run and a branch that runs and succeeds are indistinguishable
    # from the console, and the only way to tell them apart is a boot. Silence
    # was the wrong trade for a safety mechanism.
    if [ -z "$ESP_DEV" ]; then
        warn "shanios-hook: prior failure (@${PRIOR_FAILURE}) but blkid -L shani_boot found no ESP device"
    elif ! mkdir -p "$ESP_MNT" 2>/dev/null; then
        warn "shanios-hook: cannot create ${ESP_MNT} for the ESP mountpoint"
    elif ! mount -t vfat -o rw "$ESP_DEV" "$ESP_MNT" 2>/dev/null; then
        warn "shanios-hook: prior failure (@${PRIOR_FAILURE}) but could not mount the ESP (${ESP_DEV})"
    else
        LOADER="$ESP_MNT/loader/loader.conf"
        ENTRIES="$ESP_MNT/loader/entries"
        if [ ! -f "$LOADER" ]; then
            warn "shanios-hook: prior failure (@${PRIOR_FAILURE}) but ${ESP_MNT}/loader/loader.conf is absent"
        else
            CUR=$(sed -n 's/^default[[:space:]]\+\([^[:space:]]*\).*/\1/p' "$LOADER" 2>/dev/null | head -1)
            case "$CUR" in
                *+*-*)
                    FALLBACK=""
                    for E in "$ENTRIES"/*.conf; do
                        [ -f "$E" ] || continue
                        N=$(basename "$E" .conf)
                        case "$N" in *+*-*) continue ;; esac
                        FALLBACK="$N"; break
                    done
                    if [ -z "$FALLBACK" ]; then
                        warn "shanios-hook: prior failure (@${PRIOR_FAILURE}) but no non-tries entry exists to fall back to (default=${CUR})"
                    elif [ "$FALLBACK" = "$CUR" ]; then
                        warn "shanios-hook: prior failure (@${PRIOR_FAILURE}) but the only plain entry is the current default (${CUR})"
                    else
                        cp "$LOADER" "$LOADER.shanios-bak" 2>/dev/null
                        if sed -i "s|^default[[:space:]]\+[^[:space:]]*|default $FALLBACK|" "$LOADER" 2>/dev/null; then
                            warn "shanios-hook: previous boot also failed (@${PRIOR_FAILURE}); boot default switched ${CUR} -> ${FALLBACK}"
                        else
                            warn "shanios-hook: sed failed rewriting the default in ${LOADER} (leaving ${CUR})"
                        fi
                    fi
                    ;;
                "")
                    warn "shanios-hook: prior failure (@${PRIOR_FAILURE}) but loader.conf has no default line" ;;
                *)
                    warn "shanios-hook: prior failure (@${PRIOR_FAILURE}) but default '${CUR}' carries no tries counter - not an unproven candidate, leaving it" ;;
            esac
        fi
        umount "$ESP_MNT" 2>/dev/null || true
    fi
    rmdir "$ESP_MNT" 2>/dev/null || true
fi

printf '%s\n' "$ATTEMPTED_SLOT" > "$DATA_MNT/boot_hard_failure" 2>/dev/null && \
    warn "shanios-hook: boot_hard_failure written for slot '@${ATTEMPTED_SLOT}' (will be cleared on successful pivot)"

umount "$DATA_MNT" 2>/dev/null || true
rmdir  "$DATA_MNT" 2>/dev/null || true
