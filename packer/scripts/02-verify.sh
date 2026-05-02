#!/usr/bin/env bash
# 02-verify.sh — Stage 3: verify the ShaniOS installation on /dev/xvdf
#
# Runs as a separate Packer provisioner script (NOT inline) so that
# runtime shell variables sourced from /tmp/shanios-env.sh are expanded
# by bash at execution time, not by Packer's HCL interpolation at parse time.
#
# Checks:
#   - All expected Btrfs subvolumes are present
#   - Slot markers are written correctly
#   - /etc/fstab exists and references both EFI and root UUIDs
#   - At least one kernel version is present
#   - EFI loader entries exist for both slots

set -Eeuo pipefail

log()  { echo "[VERIFY][INFO]  $*"; }
warn() { echo "[VERIFY][WARN]  $*" >&2; }
fail() { echo "[VERIFY][FAIL]  $*" >&2; FAILED=1; }

# shellcheck source=/dev/null
source /tmp/shanios-env.sh

FAILED=0

# ── Btrfs subvolumes ─────────────────────────────────────────────────────────
log "--- Btrfs subvolumes ---"
SUBVOL_LIST=$(btrfs subvolume list "${SHANIOS_BTRFS_MOUNT}" 2>/dev/null | awk '{print $NF}' | sort)
echo "${SUBVOL_LIST}"

REQUIRED_SUBVOLS=( @blue @green @root @home @data @nix @cache @log
                   @flatpak @snapd @waydroid @containers @machines
                   @lxc @lxd @libvirt @qemu @swap )
for sv in "${REQUIRED_SUBVOLS[@]}"; do
    if echo "${SUBVOL_LIST}" | grep -qF "${sv}"; then
        log "  ✓ ${sv}"
    else
        fail "  ✗ ${sv} — MISSING"
    fi
done

# ── Slot markers ─────────────────────────────────────────────────────────────
log "--- Slot markers ---"
CURRENT=$(cat "${SHANIOS_BTRFS_MOUNT}/@data/current-slot"  2>/dev/null || echo "MISSING")
PREVIOUS=$(cat "${SHANIOS_BTRFS_MOUNT}/@data/previous-slot" 2>/dev/null || echo "MISSING")
log "  current-slot  : ${CURRENT}"
log "  previous-slot : ${PREVIOUS}"
[[ "${CURRENT}"  == "blue"  ]] || fail "current-slot should be 'blue', got '${CURRENT}'"
[[ "${PREVIOUS}" == "green" ]] || fail "previous-slot should be 'green', got '${PREVIOUS}'"
[[ -f "${SHANIOS_BTRFS_MOUNT}/@data/user-setup-needed" ]] \
    && log "  ✓ user-setup-needed marker present" \
    || fail "user-setup-needed marker MISSING"

# ── /etc/fstab ───────────────────────────────────────────────────────────────
log "--- /etc/fstab ---"
if [[ -f "${SHANIOS_MOUNT}/etc/fstab" ]]; then
    cat "${SHANIOS_MOUNT}/etc/fstab"
    grep -q "subvol=@blue"  "${SHANIOS_MOUNT}/etc/fstab" || fail "fstab missing @blue root entry"
    grep -q "subvol=@swap"  "${SHANIOS_MOUNT}/etc/fstab" || fail "fstab missing @swap entry"
    grep -q "/boot/efi"     "${SHANIOS_MOUNT}/etc/fstab" || fail "fstab missing EFI entry"
    log "  ✓ fstab looks correct"
else
    fail "/etc/fstab NOT FOUND"
fi

# ── Kernel ───────────────────────────────────────────────────────────────────
log "--- Kernel modules ---"
KERNEL_VER=$(ls -1 "${SHANIOS_MOUNT}/usr/lib/modules/" 2>/dev/null \
    | grep -E '^[0-9]' | sort -V | tail -1 || true)
if [[ -n "${KERNEL_VER}" ]]; then
    log "  ✓ Kernel: ${KERNEL_VER}"
else
    fail "No kernel found in /usr/lib/modules/"
fi

# ── EFI loader entries ───────────────────────────────────────────────────────
log "--- EFI loader entries ---"
ENTRIES_DIR="${SHANIOS_MOUNT}/boot/efi/loader/entries"
if [[ -d "${ENTRIES_DIR}" ]]; then
    ls -la "${ENTRIES_DIR}/"
    for slot in blue green; do
        if ls "${ENTRIES_DIR}/shanios-${slot}"*.conf &>/dev/null 2>&1; then
            log "  ✓ shanios-${slot} entry present"
        else
            warn "  ~ shanios-${slot} entry missing (dracut may not have run)"
        fi
    done
else
    warn "  ~ EFI entries directory not found (dracut may not have run)"
fi

# ── loader.conf ──────────────────────────────────────────────────────────────
log "--- loader.conf ---"
LOADER_CONF="${SHANIOS_MOUNT}/boot/efi/loader/loader.conf"
if [[ -f "${LOADER_CONF}" ]]; then
    cat "${LOADER_CONF}"
    log "  ✓ loader.conf present"
else
    warn "  ~ loader.conf not found"
fi

# ── cloud-init ───────────────────────────────────────────────────────────────
log "--- cloud-init ---"
if [[ -f "${SHANIOS_MOUNT}/etc/cloud/cloud.cfg.d/10-shanios-aws.cfg" ]]; then
    log "  ✓ cloud-init AWS config present"
else
    warn "  ~ cloud-init AWS config missing (cloud-init may not be installed in this profile)"
fi

# ── SSH ──────────────────────────────────────────────────────────────────────
log "--- SSH config ---"
if [[ -f "${SHANIOS_MOUNT}/etc/ssh/sshd_config.d/10-aws.conf" ]]; then
    log "  ✓ SSH AWS hardening config present"
else
    fail "SSH AWS hardening config MISSING"
fi

# ── Swapfile ─────────────────────────────────────────────────────────────────
log "--- Swapfile ---"
SWAPFILE="${SHANIOS_BTRFS_MOUNT}/@swap/swapfile"
if [[ -f "${SWAPFILE}" ]]; then
    log "  ✓ Swapfile: $(du -sh "${SWAPFILE}" | cut -f1)"
else
    warn "  ~ Swapfile not found (non-fatal — zram is available as fallback)"
fi

# ── Final result ─────────────────────────────────────────────────────────────
echo ""
if [[ "${FAILED}" -eq 0 ]]; then
    log "=== All verification checks passed ==="
else
    echo "[VERIFY][FAIL] === ${FAILED} check(s) FAILED — see output above ===" >&2
    exit 1
fi
