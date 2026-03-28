#!/usr/bin/env bash
# build-iso.sh – Build the bootable ISO image (container-only)
#
# By default expects a locally built base image in cache/output/<profile>/<BUILD_DATE>/.
#
# Pass --from-r2 to instead download the latest artifacts from Cloudflare R2
# (requires R2_BUCKET to be set and rclone to be configured):
#   ./build-iso.sh -p gnome --from-r2
#
# The script downloads:
#   - The base image named in <profile>/latest.txt on R2
#   - flatpakfs.zst and snapfs.zst from the same dated folder (if present)

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# Take profile from build.sh arguments or default to gnome
PROFILE="${PROFILE:-gnome}"
FROM_R2=false

# Strip --from-r2 before getopts so it doesn't confuse the parser
_CLEAN_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --from-r2) FROM_R2=true ;;
    *)         _CLEAN_ARGS+=("$arg") ;;
  esac
done
set -- "${_CLEAN_ARGS[@]+"${_CLEAN_ARGS[@]}"}"

while getopts ":p:" opt; do
  case ${opt} in
    p) PROFILE="${OPTARG}" ;;
    \?) die "Invalid option: -$OPTARG" ;;
  esac
done

OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
mkdir -p "${OUTPUT_SUBDIR}"

# ---------------------------------------------------------------------------
# --from-r2: download latest artifacts from Cloudflare R2
# ---------------------------------------------------------------------------
if [[ "$FROM_R2" == "true" ]]; then
  [[ -z "${R2_BUCKET:-}" ]] && die "--from-r2 requires R2_BUCKET to be set."
  command -v rclone >/dev/null 2>&1 || die "--from-r2 requires rclone to be installed and configured."

  log "Fetching latest.txt from R2 (r2:${R2_BUCKET}/${PROFILE}/latest.txt)..."
  rclone copyto "r2:${R2_BUCKET}/${PROFILE}/latest.txt" "${OUTPUT_SUBDIR}/latest.txt" \
    || die "Failed to download latest.txt from R2. Has an image been uploaded yet?"

  [[ -s "${OUTPUT_SUBDIR}/latest.txt" ]] || die "Downloaded latest.txt is empty."
  r2_base_image=$(<"${OUTPUT_SUBDIR}/latest.txt")

  # Extract the dated folder from the filename (8-digit sequence)
  r2_date=$(echo "${r2_base_image}" | grep -oP '\d{8}' | head -1)
  [[ -z "$r2_date" ]] && die "Could not extract build date from R2 latest image name: ${r2_base_image}"

  R2_DATED_PATH="${PROFILE}/${r2_date}"
  log "Downloading base image from r2:${R2_BUCKET}/${R2_DATED_PATH}/${r2_base_image}..."
  rclone copyto "r2:${R2_BUCKET}/${R2_DATED_PATH}/${r2_base_image}" "${OUTPUT_SUBDIR}/${r2_base_image}" \
    || die "Failed to download base image from R2."

  # Optionally resolve flatpakfs.zst — local build takes priority over R2
  if [[ -f "${OUTPUT_SUBDIR}/flatpakfs.zst" ]]; then
    log "flatpakfs.zst found locally — using local copy."
  elif rclone lsf "r2:${R2_BUCKET}/${R2_DATED_PATH}/flatpakfs.zst" &>/dev/null; then
    log "Downloading flatpakfs.zst from R2..."
    rclone copyto "r2:${R2_BUCKET}/${R2_DATED_PATH}/flatpakfs.zst" "${OUTPUT_SUBDIR}/flatpakfs.zst" \
      || log "Warning: flatpakfs.zst download failed — skipping."
  else
    log "No flatpakfs.zst found locally or on R2 — skipping."
  fi

  # Optionally resolve snapfs.zst — local build takes priority over R2
  if [[ -f "${OUTPUT_SUBDIR}/snapfs.zst" ]]; then
    log "snapfs.zst found locally — using local copy."
  elif rclone lsf "r2:${R2_BUCKET}/${R2_DATED_PATH}/snapfs.zst" &>/dev/null; then
    log "Downloading snapfs.zst from R2..."
    rclone copyto "r2:${R2_BUCKET}/${R2_DATED_PATH}/snapfs.zst" "${OUTPUT_SUBDIR}/snapfs.zst" \
      || log "Warning: snapfs.zst download failed — skipping."
  else
    log "No snapfs.zst found locally or on R2 — skipping."
  fi

  log "R2 artifacts downloaded to ${OUTPUT_SUBDIR}."
fi

# ---------------------------------------------------------------------------
# Proceed with ISO build (same for local and R2 paths)
# ---------------------------------------------------------------------------
rm -rf "${TEMP_DIR}/${PROFILE}"  # Remove old temp directories

[[ -f "${OUTPUT_SUBDIR}/latest.txt" ]] \
  || die "Latest base image not found. Run build-base-image.sh first, or pass --from-r2."
base_image=$(<"${OUTPUT_SUBDIR}/latest.txt")

[[ -f "${OUTPUT_SUBDIR}/${base_image}" ]] \
  || die "Base image file not found: ${OUTPUT_SUBDIR}/${base_image}"

ISO_DIR="${TEMP_DIR}/${PROFILE}/iso/${OS_NAME}/x86_64"
mkdir -p "$ISO_DIR"

log "Copying base image (rootfs.zst)..."
cp "${OUTPUT_SUBDIR}/${base_image}" "${ISO_DIR}/rootfs.zst" || die "Failed to copy base image"

# Copy Flatpak image if it exists
if [[ -f "${OUTPUT_SUBDIR}/flatpakfs.zst" ]]; then
    log "Copying Flatpak image (flatpakfs.zst)..."
    cp "${OUTPUT_SUBDIR}/flatpakfs.zst" "${ISO_DIR}/" || die "Failed to copy Flatpak image"
else
    log "No flatpakfs.zst found for profile '${PROFILE}' — skipping."
fi

# Copy Snap image if it exists
if [[ -f "${OUTPUT_SUBDIR}/snapfs.zst" ]]; then
    log "Copying Snap image (snapfs.zst)..."
    cp "${OUTPUT_SUBDIR}/snapfs.zst" "${ISO_DIR}/" || die "Failed to copy Snap image"
else
    log "No snapfs.zst found for profile '${PROFILE}' — skipping."
fi

# Inject profile marker so customize_airootfs.sh can detect the profile at
# chroot time. The script reads and deletes it immediately, so it never ends
# up in the final ISO squashfs.
log "Injecting profile marker for customize_airootfs.sh..."
AIROOTFS_ETC="${ISO_PROFILES_DIR}/${PROFILE}/airootfs/etc"
mkdir -p "$AIROOTFS_ETC"
echo "${PROFILE}" > "${AIROOTFS_ETC}/shani-build-profile"

log "Running mkarchiso..."
mkarchiso -v -w "${TEMP_DIR}/${PROFILE}" -o "${OUTPUT_SUBDIR}" "${ISO_PROFILES_DIR}/${PROFILE}" \
    || die "mkarchiso failed"

log "ISO build completed!"
