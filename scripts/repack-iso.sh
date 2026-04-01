#!/usr/bin/env bash
# repack-iso.sh – Repackage the ISO for Secure Boot (container-only)

set -Eeuo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

PROFILE="${PROFILE:-gnome}"
while getopts ":p:" opt; do
  case ${opt} in
    p) PROFILE="${OPTARG}" ;;
    \?) die "Invalid option: -$OPTARG" ;;
  esac
done

# Use resolve_build_date so standalone re-runs find the correct dated folder
# even when invoked on a different day than the original build.
RESOLVED_DATE="$(resolve_build_date "$PROFILE")"
OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${RESOLVED_DATE}"
mkdir -p "${OUTPUT_SUBDIR}"

# Find the unsigned ISO produced by build-iso.sh
OUTPUT_ISO=$(find "${OUTPUT_SUBDIR}" -maxdepth 1 -type f -name '*.iso' ! -name '*signed*.iso' \
    | sort | tail -n1)
[[ -n "$OUTPUT_ISO" ]] || die "No unsigned ISO found in ${OUTPUT_SUBDIR}."

REPACK_DIR="${TEMP_DIR}/${PROFILE}/repack"
mkdir -p "${REPACK_DIR}"

# ---------------------------------------------------------------------------
# Extract EFI binaries and eltorito image from the unsigned ISO
# ---------------------------------------------------------------------------
log "Extracting EFI files from ISO: ${OUTPUT_ISO}"
rm -rf "${REPACK_DIR:?}"/*
osirrox -indev "$OUTPUT_ISO" \
    -extract_boot_images "${REPACK_DIR}/" \
    -extract /EFI/BOOT/BOOTx64.EFI "${REPACK_DIR}/grubx64.efi" \
    -extract /shellx64.efi "${REPACK_DIR}/shellx64.efi" \
    || die "EFI extraction failed"

# osirrox writes the eltorito image asynchronously — wait up to 30 s
eltorito_img="${REPACK_DIR}/eltorito_img1_uefi.img"
for i in {1..30}; do
    if [[ -f "$eltorito_img" ]]; then
        break
    else
        sleep 1
    fi
done
[[ -f "$eltorito_img" ]] || die "Eltorito image not found after 30 s."

# Mount eltorito image and extract the kernel.
# Register a trap so the mount is always cleaned up on exit.
mount_dir="${REPACK_DIR}/mnt/eltorito"
mkdir -p "$mount_dir"
mount -o loop "$eltorito_img" "$mount_dir" || die "Mounting eltorito image failed"
trap 'mountpoint -q "$mount_dir" && umount "$mount_dir" 2>/dev/null || true' EXIT

cp "${mount_dir}/${OS_NAME}/boot/x86_64/vmlinuz-linux" "${REPACK_DIR}/vmlinuz-linux" \
    || die "Copy vmlinuz-linux failed"

umount "$mount_dir" || die "Unmounting eltorito image failed"

# ---------------------------------------------------------------------------
# Prepare Shim and MOK files
# ---------------------------------------------------------------------------
chmod +w "${REPACK_DIR}/grubx64.efi" "${REPACK_DIR}/shellx64.efi" "${REPACK_DIR}/vmlinuz-linux"

log "Preparing Shim and MOK files for Secure Boot..."
cp "${TEMP_DIR}/${PROFILE}/x86_64/airootfs/usr/share/shim-signed/shimx64.efi" \
    "${REPACK_DIR}/BOOTx64.EFI" || die "Failed to copy shimx64.efi"
cp "${TEMP_DIR}/${PROFILE}/x86_64/airootfs/usr/share/shim-signed/mmx64.efi" \
    "${REPACK_DIR}/" || die "Failed to copy mmx64.efi"
cp "${MOK_DIR}/MOK.der" "${REPACK_DIR}/" || die "Failed to copy MOK.der"

# ---------------------------------------------------------------------------
# Sign EFI binaries with MOK key (Secure Boot)
# ---------------------------------------------------------------------------
log "Signing EFI binaries with MOK key..."
for file in grubx64.efi shellx64.efi vmlinuz-linux; do
    sbsign \
        --key "${MOK_DIR}/MOK.key" \
        --cert "${MOK_DIR}/MOK.crt" \
        --output "${REPACK_DIR}/${file}" \
        "${REPACK_DIR}/${file}" \
        || die "MOK signing failed for ${file}"
done

# ---------------------------------------------------------------------------
# Inject signed binaries into the eltorito image
# ---------------------------------------------------------------------------
log "Updating eltorito image..."
mcopy -D oO -i "$eltorito_img" "${REPACK_DIR}/vmlinuz-linux" \
    ::/"${OS_NAME}/boot/x86_64/vmlinuz-linux"
mcopy -D oO -i "$eltorito_img" "${MOK_DIR}/MOK.der" "${REPACK_DIR}/shellx64.efi" ::/
mcopy -D oO -i "$eltorito_img" "${REPACK_DIR}/BOOTx64.EFI" ::/EFI/BOOT/
mcopy -D oO -i "$eltorito_img" "${REPACK_DIR}/grubx64.efi" "${REPACK_DIR}/mmx64.efi" ::/EFI/BOOT/

# ---------------------------------------------------------------------------
# Repack ISO — write to temp file, mv on success
# ---------------------------------------------------------------------------
final_iso="${OUTPUT_SUBDIR}/signed_$(basename "$OUTPUT_ISO")"
tmp_iso="${final_iso}.tmp"
rm -f "$tmp_iso"

log "Repacking ISO with Secure Boot support..."
xorriso -indev "$OUTPUT_ISO" -outdev "$tmp_iso" \
    -map "${REPACK_DIR}/vmlinuz-linux" "/${OS_NAME}/boot/x86_64/vmlinuz-linux" \
    -map "${REPACK_DIR}/shellx64.efi" /shellx64.efi \
    -map "${REPACK_DIR}/MOK.der" /MOK.der \
    -map "${REPACK_DIR}/BOOTx64.EFI" /EFI/BOOT/BOOTX64.EFI \
    -map "${REPACK_DIR}/grubx64.efi" /EFI/BOOT/grubx64.efi \
    -map "${REPACK_DIR}/mmx64.efi" /EFI/BOOT/mmx64.efi \
    -boot_image any replay \
    -append_partition 2 0xef "$eltorito_img" \
    || { rm -f "$tmp_iso"; die "xorriso repack failed"; }

mv "$tmp_iso" "$final_iso"

# ---------------------------------------------------------------------------
# Checksum
# ---------------------------------------------------------------------------
pushd "${OUTPUT_SUBDIR}" > /dev/null
sha256sum "$(basename "$final_iso")" > "$(basename "$final_iso").sha256" \
    || die "Checksum generation failed"
cat "$(basename "$final_iso").sha256"
popd > /dev/null

# ---------------------------------------------------------------------------
# GPG sign the ISO
# ---------------------------------------------------------------------------
gpg_prepare_keyring
gpg_sign_file "${final_iso}"

# ---------------------------------------------------------------------------
# Generate torrent with R2 and SourceForge webseeds + public trackers
# ---------------------------------------------------------------------------
ISO_FILENAME="$(basename "$final_iso")"
# Extract the 8-digit build date embedded in the ISO filename so the webseed
# URLs are correct even when repack runs on a different calendar day than the build.
ISO_DATE=$(echo "$ISO_FILENAME" | grep -oE '[0-9]{8}' | head -1 || true)
[[ -z "$ISO_DATE" ]] && ISO_DATE="$BUILD_DATE"
R2_WEBSEED="https://downloads.shani.dev/${PROFILE}/${ISO_DATE}/${ISO_FILENAME}"
SF_WEBSEED="https://downloads.sourceforge.net/project/shanios/${PROFILE}/${ISO_DATE}/${ISO_FILENAME}"
TORRENT_FILE="${OUTPUT_SUBDIR}/${ISO_FILENAME}.torrent"

log "Generating torrent for ${ISO_FILENAME}..."
mktorrent \
    -a "udp://open.demonii.com:1337/announce" \
    -a "udp://tracker.openbittorrent.com:6969/announce" \
    -a "udp://opentracker.i2p.rocks:6969/announce" \
    -a "udp://tracker.opentrackr.org:1337/announce" \
    -a "udp://tracker.bt4g.com:2095/announce" \
    -a "udp://tracker.torrent.eu.org:451/announce" \
    -w "${R2_WEBSEED}" \
    -w "${SF_WEBSEED}" \
    -l 22 \
    -o "${TORRENT_FILE}" \
    "${final_iso}" \
    || die "mktorrent failed"

log "Torrent created: ${TORRENT_FILE}"
log "  Webseeds:"
log "    R2 : ${R2_WEBSEED}"
log "    SF : ${SF_WEBSEED}"

log "ISO repackaging completed successfully!"
