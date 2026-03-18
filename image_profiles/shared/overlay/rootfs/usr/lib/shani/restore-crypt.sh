#!/bin/bash
# restore-crypt-state.sh — restore /etc crypttab + dracut config after @data wipe
#
# Unit: shani-restore-crypt.service
#
# Boot sequence (enforced by unit ordering):
#   data.mount
#     → shanios-tmpfiles-data.service   (creates /data/overlay/etc/upper + work)
#       → shani-restore-crypt.service   (this script — only on encrypted systems)
#         → etc-overlay.mount           (overlay goes live; /etc becomes writable)
#
# The unit has ConditionPathExists=/dev/mapper/shani_root so this script is
# skipped entirely on non-encrypted systems. The in-script guard below is a
# belt-and-suspenders check in case the script is ever invoked directly.
#
# By the time we run, shanios-tmpfiles-data.service has already created:
#   /data/overlay/etc/upper   (from shanios-data-structure.conf)
#   /data/overlay/etc/work    (from shanios-data-structure.conf)
# We must NOT recreate those — tmpfiles owns them.
# We only create subdirs inside upper that tmpfiles doesn't know about
# (e.g. cryptsetup-keys.d/, dracut.conf.d/).
#
# fstab context:
#   LABEL=shani_boot  /boot/efi  vfat  noauto   → "mount /boot/efi" works cleanly
#   overlay /etc overlay upperdir=/data/overlay/etc/upper,workdir=.../work,...
#     → etc-overlay.mount runs AFTER us; /etc is still the read-only root's /etc.
#     → All writes must go to OVERLAY_UPPER, not /etc.
#
# Keyfile recovery order:
#   1. Already present in overlay upper  → use as-is
#   2. Present on ESP (/boot/efi/crypto_keyfile.bin) → re-copy into overlay upper
#   3. Neither found                     → fall back to PIN/passphrase ("none")

set -euo pipefail

# ── Traps ─────────────────────────────────────────────────────────────────────
# ESP_WAS_MOUNTED is set later; declare it here so the trap can always read it.
ESP_WAS_MOUNTED=false

cleanup() {
    # Unmount ESP if this script mounted it — runs on every exit (success, error, or signal).
    if [[ "${ESP_WAS_MOUNTED}" == true ]]; then
        umount /boot/efi 2>/dev/null \
            && log_info "ESP unmounted." \
            || log_warn "Could not unmount ESP — manual cleanup may be needed."
    fi
}
trap 'log_error "Error at line ${LINENO}: ${BASH_COMMAND}"' ERR
trap cleanup EXIT

# ── Constants — must match fstab overlay options and install.sh exactly ───────
ROOTLABEL="shani_root"
BOOTLABEL="shani_boot"
OVERLAY_UPPER="/data/overlay/etc/upper"          # owned by tmpfiles — do not recreate
KEYFILE_DEST="${OVERLAY_UPPER}/cryptsetup-keys.d/${ROOTLABEL}.bin"
ESP_KEYFILE_SRC="/boot/efi/crypto_keyfile.bin"   # written by install.sh, moved by configure.sh

# ── Logging (mirrors configure.sh style) ─────────────────────────────────────
log_info()  { echo "[RESTORE][INFO] $*"; }
log_warn()  { echo "[RESTORE][WARN] $*" >&2; }
log_error() { echo "[RESTORE][ERROR] $*" >&2; }

# ── Guard: belt-and-suspenders (primary guard is ConditionPathExists= in unit) ─
if ! cryptsetup status "/dev/mapper/${ROOTLABEL}" &>/dev/null; then
    log_info "Mapper /dev/mapper/${ROOTLABEL} is not open — skipping (ConditionPathExists should have prevented this)."
    exit 0
fi

# ── Derive LUKS UUID from the open mapping (mirrors configure.sh) ────────────
UNDERLYING=$(cryptsetup status "/dev/mapper/${ROOTLABEL}" | awk '/device:/{print $2}')
if [[ -z "${UNDERLYING}" ]]; then
    log_error "Could not determine underlying device for /dev/mapper/${ROOTLABEL}"
    exit 1
fi

LUKS_UUID=$(cryptsetup luksUUID "${UNDERLYING}")
if [[ -z "${LUKS_UUID}" ]]; then
    log_error "Could not retrieve LUKS UUID from ${UNDERLYING}"
    exit 1
fi
log_info "LUKS UUID: ${LUKS_UUID}  (underlying: ${UNDERLYING})"

# ── Keyfile recovery ──────────────────────────────────────────────────────────
# OVERLAY_UPPER itself was created by tmpfiles (ExecStart step in our unit).
# We only need mkdir for the cryptsetup-keys.d/ subdir, which tmpfiles doesn't own.
KEYFILE_OPT="none"

if [[ -f "${KEYFILE_DEST}" ]]; then
    # Case 1: keyfile survived (normal run or partial @data wipe)
    log_info "Keyfile already present in overlay upper — no recovery needed."
    KEYFILE_OPT="/etc/cryptsetup-keys.d/${ROOTLABEL}.bin"
else
    # Case 2: keyfile gone (full @data wipe) — recover from ESP.
    # fstab has noauto on /boot/efi, so "mount /boot/efi" does a clean
    # label-based fstab mount without hardcoding any device path.
    if ! mountpoint -q /boot/efi 2>/dev/null; then
        log_info "ESP not mounted — attempting: mount /boot/efi  (fstab noauto entry)"
        if mount /boot/efi 2>/dev/null; then
            ESP_WAS_MOUNTED=true
            log_info "ESP mounted via fstab (LABEL=${BOOTLABEL})."
        else
            log_warn "mount /boot/efi failed — trying direct label mount as fallback."
            if mount "/dev/disk/by-label/${BOOTLABEL}" /boot/efi 2>/dev/null; then
                ESP_WAS_MOUNTED=true
                log_info "ESP mounted by label ${BOOTLABEL}."
            else
                log_warn "ESP mount failed entirely — keyfile recovery from ESP not possible."
            fi
        fi
    else
        log_info "ESP already mounted at /boot/efi."
    fi

    if [[ -f "${ESP_KEYFILE_SRC}" ]]; then
        log_info "Recovering keyfile from ESP: ${ESP_KEYFILE_SRC} → ${KEYFILE_DEST}"
        # cryptsetup-keys.d/ is not in shanios-data-structure.conf — we own this mkdir
        mkdir -p "$(dirname "${KEYFILE_DEST}")"
        cp "${ESP_KEYFILE_SRC}" "${KEYFILE_DEST}"
        chmod 0400 "${KEYFILE_DEST}"
        KEYFILE_OPT="/etc/cryptsetup-keys.d/${ROOTLABEL}.bin"
        log_info "Keyfile recovered successfully."
    else
        log_warn "No keyfile found at ${ESP_KEYFILE_SRC}. System will require PIN/passphrase at next boot."
    fi
    # ESP unmount is handled by the cleanup trap on EXIT — covers success, error, and signal.
fi

# ── 1. /etc/crypttab — written to overlay upper (mirrors generate_crypttab_target()) ──
# etc-overlay.mount has NOT run yet; /etc is still the read-only root.
# Writing to OVERLAY_UPPER means the file is visible under /etc once the overlay mounts.
if [[ ! -f "${OVERLAY_UPPER}/crypttab" ]]; then
    CRYPTTAB_ENTRY="${ROOTLABEL} UUID=${LUKS_UUID} ${KEYFILE_OPT} luks,discard"
    printf '%s\n' "${CRYPTTAB_ENTRY}" > "${OVERLAY_UPPER}/crypttab"
    chmod 0644 "${OVERLAY_UPPER}/crypttab"
    log_info "/etc/crypttab regenerated in overlay upper: ${CRYPTTAB_ENTRY}"
else
    log_info "/etc/crypttab already present in overlay upper — skipping."
fi

# ── 2. /etc/dracut.conf.d/99-crypt-key.conf — mirrors crypt_dracut_conf() ────
# dracut.conf.d/ inside upper is also not in shanios-data-structure.conf — we own this mkdir.
if [[ ! -f "${OVERLAY_UPPER}/dracut.conf.d/99-crypt-key.conf" ]]; then
    mkdir -p "${OVERLAY_UPPER}/dracut.conf.d"
    INSTALL_ITEMS="/etc/crypttab"
    [[ "${KEYFILE_OPT}" != "none" ]] && INSTALL_ITEMS+=" /etc/cryptsetup-keys.d/${ROOTLABEL}.bin"
    printf 'install_items+=" %s "\n' "${INSTALL_ITEMS}" > "${OVERLAY_UPPER}/dracut.conf.d/99-crypt-key.conf"
    log_info "dracut crypt config regenerated (install_items: ${INSTALL_ITEMS})"
else
    log_info "dracut crypt config already present in overlay upper — skipping."
fi

log_info "restore-crypt-state completed successfully."
exit 0
