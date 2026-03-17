#!/bin/bash
# repack-iso.sh – Repackage the ISO for Secure Boot (container-only)
# Renames the checksum file to <signed_iso>.sha256.

set -Eeuo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# Process options: use -p to override PROFILE (default: gnome)
PROFILE="${PROFILE:-gnome}"
while getopts ":p:" opt; do
  case ${opt} in
    p) PROFILE="${OPTARG}" ;;
    \?) error_exit "Invalid option: -$OPTARG" ;;
  esac
done

OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
mkdir -p "${OUTPUT_SUBDIR}"

# Get the latest ISO in the output subdirectory (excluding previously signed ones)
OUTPUT_ISO=$(find "${OUTPUT_SUBDIR}" -maxdepth 1 -type f -name '*.iso' ! -name '*signed*.iso' | sort | tail -n1)
[[ -n "$OUTPUT_ISO" ]] || error_exit "No ISO found to repack."

REPACK_DIR="${TEMP_DIR}/${PROFILE}/repack"
mkdir -p "${REPACK_DIR}"

log "Extracting EFI files from ISO: ${OUTPUT_ISO}"
rm -rf "${REPACK_DIR:?}"/*
osirrox -indev "$OUTPUT_ISO" -extract_boot_images "${REPACK_DIR}/" \
  -extract /EFI/BOOT/BOOTx64.EFI "${REPACK_DIR}/grubx64.efi" \
  -extract /shellx64.efi "${REPACK_DIR}/shellx64.efi" || error_exit "EFI extraction failed"
# Wait up to 30 seconds for the eltorito image to appear
eltorito_img="${REPACK_DIR}/eltorito_img1_uefi.img"
for i in {1..30}; do
    if [[ -f "$eltorito_img" ]]; then
        break
    else
        sleep 1
    fi
done
[[ -f "$eltorito_img" ]] || error_exit "Eltorito image not found."

mount_dir="${REPACK_DIR}/mnt/eltorito"
mkdir -p "$mount_dir"
mount -o loop "$eltorito_img" "$mount_dir" || error_exit "Mounting eltorito image failed"

# Copy the kernel image (vmlinuz-linux) from the mounted eltorito image.
# Note: The path uses the OS_NAME variable (set in config.sh) to locate the kernel.
cp "${mount_dir}/${OS_NAME}/boot/x86_64/vmlinuz-linux" "${REPACK_DIR}/vmlinuz-linux" || error_exit "Copy vmlinuz-linux failed"

umount "$mount_dir" || error_exit "Unmounting eltorito image failed"

# Make the extracted EFI binaries writable
chmod +w "${REPACK_DIR}/grubx64.efi" "${REPACK_DIR}/shellx64.efi" "${REPACK_DIR}/vmlinuz-linux"

log "Preparing Shim and MOK files for Secure Boot..."
cp "${TEMP_DIR}/${PROFILE}/x86_64/airootfs/usr/share/shim-signed/shimx64.efi" "${REPACK_DIR}/BOOTx64.EFI" || error_exit "Failed to copy shimx64.efi"
cp "${TEMP_DIR}/${PROFILE}/x86_64/airootfs/usr/share/shim-signed/mmx64.efi" "${REPACK_DIR}/" || error_exit "Failed to copy mmx64.efi"
cp "${MOK_DIR}/MOK.der" "${REPACK_DIR}/" || error_exit "Failed to copy MOK der"
log "Shim and MOK files prepared successfully for both architectures."

log "Signing EFI binaries..."
for file in grubx64.efi shellx64.efi vmlinuz-linux; do
  sbsign --key "${MOK_DIR}/MOK.key" --cert "${MOK_DIR}/MOK.crt" --output "${REPACK_DIR}/${file}" "${REPACK_DIR}/${file}" || error_exit "Signing failed for ${file}"
done

log "Updating eltorito image..."
mcopy -D oO -i "$eltorito_img" "${REPACK_DIR}/vmlinuz-linux" ::/"${OS_NAME}/boot/x86_64/vmlinuz-linux"
mcopy -D oO -i "$eltorito_img" "${MOK_DIR}/MOK.der" "${REPACK_DIR}/shellx64.efi" ::/
mcopy -D oO -i "$eltorito_img" "${REPACK_DIR}/BOOTx64.EFI" ::/EFI/BOOT/
mcopy -D oO -i "$eltorito_img" "${REPACK_DIR}/grubx64.efi" "${REPACK_DIR}/mmx64.efi" ::/EFI/BOOT/

final_iso="${OUTPUT_SUBDIR}/signed_$(basename "$OUTPUT_ISO")"
rm -f "$final_iso" || error_exit "Failed to remove old signed ISO"

log "Repacking the ISO with Secure Boot support..."
xorriso -indev "$OUTPUT_ISO" -outdev "$final_iso" \
  -map "${REPACK_DIR}/vmlinuz-linux" /${OS_NAME}/boot/x86_64/vmlinuz-linux \
  -map "${REPACK_DIR}/shellx64.efi" /shellx64.efi \
  -map "${REPACK_DIR}/MOK.der" /MOK.der \
  -map "${REPACK_DIR}/BOOTx64.EFI" /EFI/BOOT/BOOTX64.EFI \
  -map "${REPACK_DIR}/grubx64.efi" /EFI/BOOT/grubx64.efi \
  -map "${REPACK_DIR}/mmx64.efi" /EFI/BOOT/mmx64.efi \
  -boot_image any replay -append_partition 2 0xef "$eltorito_img" || error_exit "xorriso repack failed"

pushd "${OUTPUT_SUBDIR}" > /dev/null
sha256sum "$(basename "$final_iso")" > "$(basename "$final_iso").sha256" || error_exit "Checksum generation failed"
cat "$(basename "$final_iso").sha256"
popd > /dev/null

log "Signing ISO with GPG..."
gpg --batch --yes \
  --detach-sign --armor \
  --output "${final_iso}.asc" \
  "${final_iso}" || error_exit "GPG signing of ISO failed"
log "GPG signature created: ${final_iso}.asc"

# ---------------------------------------------------------------------------
# Generate torrent with R2 and SourceForge webseeds + public trackers
# ---------------------------------------------------------------------------
log "Generating torrent for $(basename "$final_iso")..."

ISO_FILENAME="$(basename "$final_iso")"
R2_WEBSEED="https://downloads.shani.dev/${PROFILE}/${BUILD_DATE}/${ISO_FILENAME}"
SF_WEBSEED="https://downloads.sourceforge.net/project/shanios/${PROFILE}/${BUILD_DATE}/${ISO_FILENAME}"

TORRENT_FILE="${OUTPUT_SUBDIR}/${ISO_FILENAME}.torrent"

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
  "${final_iso}" || error_exit "mktorrent failed"

log "Torrent created: ${TORRENT_FILE}"
log "  Webseeds:"
log "    R2 : ${R2_WEBSEED}"
log "    SF : ${SF_WEBSEED}"

log "ISO repackaging completed successfully!"
