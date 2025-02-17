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
rm -rf "${TEMP_DIR}"  # Remove old directories
[[ -f "${OUTPUT_SUBDIR}/latest.txt" ]] || die "Latest base image not found. Run build-base-image.sh first."
base_image=$(<"${OUTPUT_SUBDIR}/latest.txt")
ISO_DIR="${TEMP_DIR}/iso/${OS_NAME}/x86_64"
mkdir -p "$ISO_DIR"

log "Copying base image (rootfs.zst)..."
cp "${OUTPUT_SUBDIR}/${base_image}" "${ISO_DIR}/rootfs.zst" || die "Failed to copy base image"

log "Copying Flatpak image (flatpakfs.zst)..."
[[ -f "${OUTPUT_SUBDIR}/flatpakfs.zst" ]] || die "Flatpak image not found. Run build-flatpak-image.sh first."
cp "${OUTPUT_SUBDIR}/flatpakfs.zst" "${ISO_DIR}/" || die "Failed to copy Flatpak image"

log "Running mkarchiso..."
mkarchiso -v -w "${TEMP_DIR}" -o "${OUTPUT_SUBDIR}" "${ISO_PROFILES_DIR}" || die "mkarchiso failed"
log "ISO build completed!"

