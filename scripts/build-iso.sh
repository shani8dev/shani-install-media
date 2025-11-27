#!/usr/bin/env bash
# build-iso.sh – Build the bootable ISO image (container-only)
set -Eeuo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# Take profile from build.sh arguments or default to gnome
PROFILE="${PROFILE:-gnome}"
while getopts ":p:" opt; do
  case ${opt} in
    p) PROFILE="${OPTARG}" ;;
    \?) die "Invalid option: -$OPTARG" ;;
  esac
done

OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
mkdir -p "${OUTPUT_SUBDIR}"
rm -rf "${TEMP_DIR}/${PROFILE}"  # Remove old directories

[[ -f "${OUTPUT_SUBDIR}/latest.txt" ]] || die "Latest base image not found. Run build-base-image.sh first."
base_image=$(<"${OUTPUT_SUBDIR}/latest.txt")

ISO_DIR="${TEMP_DIR}/${PROFILE}/iso/${OS_NAME}/x86_64"
mkdir -p "$ISO_DIR"

log "Copying base image (rootfs.zst)..."
cp "${OUTPUT_SUBDIR}/${base_image}" "${ISO_DIR}/rootfs.zst" || die "Failed to copy base image"

# Copy Flatpak image if it exists
if [[ -f "${OUTPUT_SUBDIR}/flatpakfs.zst" ]]; then
    log "Copying Flatpak image (flatpakfs.zst)..."
    cp "${OUTPUT_SUBDIR}/flatpakfs.zst" "${ISO_DIR}/" || die "Failed to copy Flatpak image"
else
    warn "Flatpak image not found. Skipping flatpakfs.zst..."
fi

# Copy Snap image if it exists
if [[ -f "${OUTPUT_SUBDIR}/snapfs.zst" ]]; then
    log "Copying Snap image (snapfs.zst)..."
    cp "${OUTPUT_SUBDIR}/snapfs.zst" "${ISO_DIR}/" || die "Failed to copy Snap image"
else
    warn "Snap image not found. Skipping snapfs.zst..."
fi

log "Running mkarchiso..."
mkarchiso -v -w "${TEMP_DIR}/${PROFILE}" -o "${OUTPUT_SUBDIR}" "${ISO_PROFILES_DIR}/${PROFILE}" || die "mkarchiso failed"

log "ISO build completed!"
