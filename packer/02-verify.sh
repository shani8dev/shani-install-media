#!/usr/bin/env bash
# 02-verify.sh — Stage 3: verify the ShaniOS AMI installation
#
# Checks:
#   - All expected Btrfs subvolumes are present
#   - Slot markers are correct
#   - /etc/fstab exists and references the expected subvolumes
#   - At least one kernel version is present in /usr/lib/modules
#   - Dracut UKI (.efi) files exist for both slots at the correct paths
#   - Boot entries use "efi" format (UKI), not "linux"+"initrd" (separate)
#   - loader.conf default entry is a glob matching the blue slot
#   - cloud-init AWS config is present
#   - SSH hardening config is present
#   - Swapfile exists on @swap

set -Eeuo pipefail

log()  { echo "[VERIFY][INFO]  $*"; }
warn() { echo "[VERIFY][WARN]  $*" >&2; }
fail() { echo "[VERIFY][FAIL]  $*" >&2; FAILED=1; }

# shellcheck source=/dev/null
source /tmp/shanios-env.sh

FAILED=0
OS_NAME="shanios"

# ─── Btrfs subvolumes ────────────────────────────────────────────────────────
log "--- Btrfs subvolumes ---"
SUBVOL_LIST=$(btrfs subvolume list "${SHANIOS_BTRFS_MOUNT}" 2>/dev/null \
    | awk '{print $NF}' | sort)
echo "${SUBVOL_LIST}"

REQUIRED_SUBVOLS=(
    @blue @green
    @root @home @data @nix @cache @log
    @flatpak @snapd @waydroid @containers @machines
    @lxc @lxd @libvirt @qemu @swap
)
for sv in "${REQUIRED_SUBVOLS[@]}"; do
    if echo "${SUBVOL_LIST}" | grep -qF "${sv}"; then
        log "  ✓ ${sv}"
    else
        fail "  ✗ ${sv} MISSING"
    fi
done

# ─── Slot markers ────────────────────────────────────────────────────────────
log "--- Slot markers ---"
CURRENT=$(cat  "${SHANIOS_BTRFS_MOUNT}/@data/current-slot"  2>/dev/null || echo "MISSING")
PREVIOUS=$(cat "${SHANIOS_BTRFS_MOUNT}/@data/previous-slot" 2>/dev/null || echo "MISSING")
log "  current-slot  : ${CURRENT}"
log "  previous-slot : ${PREVIOUS}"
[[ "${CURRENT}"  == "blue"  ]] || fail "current-slot should be 'blue', got '${CURRENT}'"
[[ "${PREVIOUS}" == "green" ]] || fail "previous-slot should be 'green', got '${PREVIOUS}'"
[[ -f "${SHANIOS_BTRFS_MOUNT}/@data/user-setup-needed" ]] \
    && log "  ✓ user-setup-needed marker present" \
    || fail "  ✗ user-setup-needed marker MISSING"

# ─── /etc/fstab ──────────────────────────────────────────────────────────────
log "--- /etc/fstab ---"
if [[ -f "${SHANIOS_MOUNT}/etc/fstab" ]]; then
    cat "${SHANIOS_MOUNT}/etc/fstab"
    grep -q "subvol=@blue"  "${SHANIOS_MOUNT}/etc/fstab" || fail "fstab: missing @blue root entry"
    grep -q "subvol=@swap"  "${SHANIOS_MOUNT}/etc/fstab" || fail "fstab: missing @swap entry"
    grep -q "/boot/efi"     "${SHANIOS_MOUNT}/etc/fstab" || fail "fstab: missing /boot/efi entry"
    log "  ✓ fstab OK"
else
    fail "/etc/fstab NOT FOUND"
fi

# ─── Kernel ──────────────────────────────────────────────────────────────────
log "--- Kernel ---"
KERNEL_VER=$(ls -1 "${SHANIOS_MOUNT}/usr/lib/modules/" 2>/dev/null \
    | grep -E '^[0-9]' | sort -V | tail -1 || true)
if [[ -n "${KERNEL_VER}" ]]; then
    log "  ✓ Kernel: ${KERNEL_VER}"
else
    fail "No kernel found in /usr/lib/modules/"
fi

# ─── Dracut UKI files ─────────────────────────────────────────────────────────
# ShaniOS uses dracut --uefi producing a single .efi PE binary per slot.
# Path matches configure.sh: /boot/efi/EFI/${OS_NAME}/${OS_NAME}-${slot}.efi
log "--- Dracut UKI files ---"
UKI_DIR="${SHANIOS_MOUNT}/boot/efi/EFI/${OS_NAME}"
for slot in blue green; do
    UKI="${UKI_DIR}/${OS_NAME}-${slot}.efi"
    if [[ -f "${UKI}" ]]; then
        SIZE=$(du -sh "${UKI}" | cut -f1)
        log "  ✓ ${OS_NAME}-${slot}.efi  (${SIZE})"
        # Confirm it is a PE/COFF binary (UKI) — first 2 bytes = 'MZ'
        MAGIC=$(xxd -l 2 -p "${UKI}" 2>/dev/null || true)
        if [[ "${MAGIC}" == "4d5a" ]]; then
            log "    ↳ PE/COFF magic OK (MZ header)"
        else
            warn "    ↳ PE/COFF magic not found (magic=${MAGIC}) — may not be a valid UKI"
        fi
    else
        fail "  ✗ ${OS_NAME}-${slot}.efi MISSING at ${UKI}"
    fi
done

# ─── Boot entries ─────────────────────────────────────────────────────────────
# UKI entries use "efi ..." not "linux ...". Verify both format and presence.
log "--- Boot entries ---"
ENTRIES_DIR="${SHANIOS_MOUNT}/boot/efi/loader/entries"
if [[ -d "${ENTRIES_DIR}" ]]; then
    ls -la "${ENTRIES_DIR}/" 2>/dev/null || true

    # Blue slot — should have a +3-0 tries entry
    BLUE_ENTRIES=$(ls "${ENTRIES_DIR}/${OS_NAME}-blue"*.conf 2>/dev/null || true)
    if [[ -n "${BLUE_ENTRIES}" ]]; then
        log "  ✓ blue slot entries: $(basename -a ${BLUE_ENTRIES} | tr '\n' ' ')"
        # Verify it uses "efi" format (UKI), not "linux" (separate kernel)
        for f in ${BLUE_ENTRIES}; do
            if grep -q "^efi " "${f}"; then
                log "    ↳ $(basename ${f}): UKI format (efi) ✓"
            elif grep -q "^linux " "${f}"; then
                fail "    ↳ $(basename ${f}): uses 'linux' format — expected 'efi' (UKI)"
            else
                warn "    ↳ $(basename ${f}): no 'efi' or 'linux' line found"
            fi
        done
        # Verify tries-counter suffix on active (blue) entry
        if echo "${BLUE_ENTRIES}" | grep -qE '\+[0-9]+-[0-9]+\.conf'; then
            log "  ✓ blue slot has tries-counter entry"
        else
            warn "  ~ blue slot missing tries-counter (+N-M) entry — systemd-boot auto-fallback disabled"
        fi
    else
        fail "  ✗ blue slot: no boot entries found in ${ENTRIES_DIR}"
    fi

    # Green slot — should have a plain .conf (no tries counter)
    GREEN_ENTRY="${ENTRIES_DIR}/${OS_NAME}-green.conf"
    if [[ -f "${GREEN_ENTRY}" ]]; then
        log "  ✓ green slot entry: $(basename "${GREEN_ENTRY}")"
        if grep -q "^efi " "${GREEN_ENTRY}"; then
            log "    ↳ UKI format (efi) ✓"
        else
            fail "    ↳ does not use 'efi' format — expected UKI entry"
        fi
    else
        fail "  ✗ green slot: ${OS_NAME}-green.conf MISSING"
    fi
else
    fail "EFI loader entries directory not found: ${ENTRIES_DIR}"
fi

# ─── loader.conf ─────────────────────────────────────────────────────────────
log "--- loader.conf ---"
LOADER_CONF="${SHANIOS_MOUNT}/boot/efi/loader/loader.conf"
if [[ -f "${LOADER_CONF}" ]]; then
    cat "${LOADER_CONF}"
    # Default must be a glob so it matches across tries-counter decrements
    if grep -qE "^default\s+${OS_NAME}-blue\*" "${LOADER_CONF}"; then
        log "  ✓ default entry uses glob (shanios-blue*)"
    else
        warn "  ~ default entry is not a glob — may not match after tries-counter decrements"
    fi
    log "  ✓ loader.conf present"
else
    fail "loader.conf NOT FOUND at ${LOADER_CONF}"
fi

# ─── Per-slot cmdline files ───────────────────────────────────────────────────
log "--- Kernel cmdline files ---"
for slot in blue green; do
    CMDLINE_FILE="${SHANIOS_MOUNT}/etc/kernel/install_cmdline_${slot}"
    if [[ -f "${CMDLINE_FILE}" ]]; then
        log "  ✓ install_cmdline_${slot}: $(cat "${CMDLINE_FILE}")"
    else
        warn "  ~ install_cmdline_${slot} not found (non-fatal — embedded in UKI)"
    fi
done

# ─── cloud-init ──────────────────────────────────────────────────────────────
log "--- cloud-init ---"
if [[ -f "${SHANIOS_MOUNT}/etc/cloud/cloud.cfg.d/10-shanios-aws.cfg" ]]; then
    log "  ✓ cloud-init AWS config present"
else
    warn "  ~ cloud-init AWS config missing (cloud-init may not be installed in this profile)"
fi

# ─── SSH ─────────────────────────────────────────────────────────────────────
log "--- SSH ---"
if [[ -f "${SHANIOS_MOUNT}/etc/ssh/sshd_config.d/10-aws.conf" ]]; then
    log "  ✓ SSH hardening config present"
else
    fail "SSH hardening config MISSING"
fi

# ─── Swapfile ────────────────────────────────────────────────────────────────
log "--- Swapfile ---"
SWAPFILE="${SHANIOS_BTRFS_MOUNT}/@swap/swapfile"
if [[ -f "${SWAPFILE}" ]]; then
    log "  ✓ Swapfile: $(du -sh "${SWAPFILE}" | cut -f1)"
else
    warn "  ~ Swapfile not found (non-fatal — zram available as fallback)"
fi

# ─── machine-id ──────────────────────────────────────────────────────────────
log "--- machine-id ---"
MACHINE_ID_FILE="${SHANIOS_MOUNT}/etc/machine-id"
if [[ -f "${MACHINE_ID_FILE}" ]]; then
    MACHINE_ID_CONTENT=$(cat "${MACHINE_ID_FILE}")
    if [[ -z "${MACHINE_ID_CONTENT}" ]]; then
        log "  ✓ machine-id is blank (will be allocated on first boot)"
    else
        warn "  ~ machine-id is set to '${MACHINE_ID_CONTENT}' — should be blank for AMIs"
    fi
else
    fail "  ✗ /etc/machine-id not found"
fi

# ─── Final result ─────────────────────────────────────────────────────────────
echo ""
if [[ "${FAILED}" -eq 0 ]]; then
    log "=== All verification checks passed ==="
else
    echo "[VERIFY][FAIL] === ${FAILED} check(s) FAILED — see output above ===" >&2
    exit 1
fi
