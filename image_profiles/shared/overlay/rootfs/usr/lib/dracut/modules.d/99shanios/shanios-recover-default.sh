#!/bin/bash
# shanios-recover-default.sh — run inside the initramfs's emergency shell when
# the root mount failed, to put the machine back on a bootable entry in THIS
# boot rather than the next one.
#
# WHY THIS EXISTS. The `+3-0` tries counter is the mechanism Shanios relies on
# to fall back from an unproven candidate, and it is inert on systemd 261
# (systemd/systemd#40405 — boot counting does not rename entries, so
# `tries_left` never reaches 0). The dracut hook already rewrites `default`,
# but at `pre-mount` of the FAILING boot, so the next boot is committed to the
# same broken UKI: two black screens, then recovery on the third.
#
# dracut's emergency mode is a full systemd instance in the initramfs with the
# ESP mounted and writable. Arming a unit from `pre-mount` means the switch
# happens while we are still here, so the machine reboots ONCE into the good
# slot instead of twice into the broken one.
#
# SAFETY RULES, all of which exist because the failure mode is "reboots forever":
#   1. Only act when a PRIOR failure marker exists. A one-off mount failure with
#      no prior failure is not evidence of a bad slot, and rebooting on it would
#      turn a transient into a loop.
#   2. Only act when the current default is a tries-counted entry — i.e. the
#      shape a deploy writes for an unproven candidate. Never rewrite a plain
#      default: that is the self-limiting property that stops this ping-ponging
#      between two broken slots.
#   3. Only act if a non-tries entry actually exists to fall back to.
#   4. Verify the rewrite actually landed before rebooting. If the ESP is not
#      writable, rebooting achieves nothing but another failed boot.
#   5. Unconditionally clear the prior-failure marker before rebooting, so rule
#      1 cannot re-arm this on the next boot. The next boot's own pre-mount
#      hook re-writes it if it fails again, which is the correct behaviour.
set -u
MARKER="${SHANIOS_BOOT_FAILURE_MARKER:-/run/shanios-data-tmp/boot_hard_failure}"
ESP_MNT="${SHANIOS_ESP_MNT:-/run/shanios-esp-tmp}"
LOADER_CONF="$ESP_MNT/loader/loader.conf"

log() { warn "shanios-recover: $*" 2>/dev/null || echo "shanios-recover: $*" >&2; }

# --- rule 1: a prior failure is required ------------------------------------
# The marker lives on @data. The pre-mount hook mounts that subvolume at
# /run/shanios-data-tmp, but this unit runs from emergency.target, and dracut has
# torn the hook's mount down by then - so the unit cannot inherit it and has to
# make its own, exactly as it already does for the ESP a few lines below.
#
# Measured, in one boot: the hook logged
#   previous boot also failed (@@blue); boot default switched ...
# and this unit then logged
#   no prior failure marker - not acting
# Same marker, same boot, two different views of it. The unit's guard was
# correct and its input was invisible, which is the one combination that reads as
# "the mechanism is broken" rather than "the mechanism could not see".
if [ ! -s "$MARKER" ]; then
    DATA_MNT="${MARKER%/*}"
    DATA_DEV="$(blkid -L shani_root 2>/dev/null || true)"
    if [ -n "$DATA_DEV" ] && ! mountpoint -q "$DATA_MNT" 2>/dev/null; then
        mkdir -p "$DATA_MNT" 2>/dev/null
        mount -o subvol=@data,rw "$DATA_DEV" "$DATA_MNT" 2>/dev/null || DATA_DEV=""
    fi
    log "marker state: dev=${DATA_DEV:-none} mounted=$(mountpoint -q "$DATA_MNT" 2>/dev/null && echo yes || echo no) present=$([ -s "$MARKER" ] && echo yes || echo no)"
fi
if [ ! -s "$MARKER" ]; then
    log "no prior failure marker — not acting (a single failed mount is not evidence of a bad slot)"
    exit 0
fi

# --- the ESP must be mounted before anything else is even knowable ------------
ESP_DEV="$(blkid -L shani_boot 2>/dev/null || true)"
if [ -z "$ESP_DEV" ]; then
    log "no ESP device found — cannot act; leaving the emergency shell for the operator"
    exit 0
fi
if ! mountpoint -q "$ESP_MNT" 2>/dev/null; then
    mkdir -p "$ESP_MNT"
    mount "$ESP_DEV" "$ESP_MNT" 2>/dev/null || {
        log "could not mount the ESP ($ESP_DEV) — not rebooting, because a reboot cannot fix an unwritable ESP"
        exit 0
    }
fi
[ -f "$LOADER_CONF" ] || { log "no loader.conf on the ESP — nothing to rewrite"; exit 0; }

CUR="$(sed -n 's/^default[[:space:]]*//p' "$LOADER_CONF" | head -1)"
[ -n "$CUR" ] || { log "loader.conf has no default line — nothing to rewrite"; exit 0; }

# --- rule 2: only a tries-counted default qualifies --------------------------
# A plain default means either this slot is already proven or the hook has
# already switched once. Rewriting it either way is how a recovery turns into a
# two-slot ping-pong.
case "$CUR" in
    *+[0-9]*-[0-9]*) : ;;   # shanios-blue+3-0.conf -> an unproven candidate
    *) log "default '$CUR' carries no tries counter — it is not an unproven candidate; not acting"
       exit 0 ;;
esac

# --- rule 3: a fallback entry must actually exist ----------------------------
FALLBACK=""
for f in "$ESP_MNT"/loader/entries/*.conf; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in
        *+[0-9]*-[0-9]*) continue ;;      # still a tries entry, not a fallback
        *"$CUR"*)        continue ;;      # the same slot, plain-named
    esac
    FALLBACK="${b%.conf}.conf"
    break
done
[ -n "$FALLBACK" ] || { log "no non-tries fallback entry exists — not acting, there is nowhere safer to go"; exit 0; }

log "default '$CUR' is an unproven candidate; switching to '$FALLBACK' and rebooting once"

# --- rewrite, keeping a backup so a bad sed is recoverable -------------------
cp -f "$LOADER_CONF" "${LOADER_CONF}.shanios-recover.bak" 2>/dev/null || true
TMP="${LOADER_CONF}.recover.$$"
if ! { grep -v '^default[[:space:]]' "$LOADER_CONF" > "$TMP" && echo "default ${FALLBACK}" >> "$TMP" && sync; }; then
    rm -f "$TMP"
    log "could not stage the new loader.conf — not rebooting"
    exit 0
fi
mv -f "$TMP" "$LOADER_CONF" 2>/dev/null || { rm -f "$TMP"; log "could not install the new loader.conf — not rebooting"; exit 0; }
sync

# --- rule 4: verify the effect, because rc=0 is not evidence ----------------
NOW="$(sed -n 's/^default[[:space:]]*//p' "$LOADER_CONF" | head -1)"
if [ "$NOW" != "$FALLBACK" ]; then
    cp -f "${LOADER_CONF}.shanios-recover.bak" "$LOADER_CONF" 2>/dev/null || true
    log "rewrite did not take (default is now '$NOW') — restored the backup and leaving the shell alone"
    exit 0
fi

# --- rule 5: disarm, so this cannot re-arm on the next boot -----------------
rm -f "$MARKER" 2>/dev/null || true

log "default is now '$FALLBACK' — rebooting"
sleep 2
sync
# -f: do not ask initramfs systemd to run shutdown units that do not exist
# here; a clean reboot we do not get is a reboot we have to repeat.
exec /sbin/reboot -f -f 2>/dev/null || exec /usr/bin/systemctl reboot --force 2>/dev/null || {
    log "reboot failed — dropping to the emergency shell instead"
}