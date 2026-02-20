#!/usr/bin/env bash
# upload.sh – Upload build artifacts to SourceForge FRS and mirror to Cloudflare R2
#
# This script uploads:
#   - Base image artifacts: *.zst, *.zst.sha256, *.zst.zsync, *.zst.asc, and latest.txt from the build folder.
#   - Central release files: latest.txt and stable.txt from the OUTPUT_DIR root (if they exist).
#   - ISO artifacts (signed ISO and its .sha256 checksum) if in "all" mode.
#
# All uploads are mirrored to Cloudflare R2 if R2_BUCKET is set in the environment.
# After a successful upload, old dated build folders for the profile are deleted from R2,
# keeping only the 2 most recent dated folders and the folder pinned by stable.txt.
#
# Usage:
#   ./upload.sh -p <profile> [mode]
# where mode is either "image" (default) or "all".
#
set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# ---------------------------------------------------------------------------
# R2 mirror helper
# Mirrors a single file to Cloudflare R2 under the given remote subpath.
# Silently skipped if R2_BUCKET is not set (rclone config is written by
# run_in_container.sh at container startup from .env / GitHub secrets).
# Failures are non-fatal — SourceForge remains the authoritative upload.
# ---------------------------------------------------------------------------
r2_upload() {
  local src="$1"
  local dest_subpath="$2"

  if [[ -z "${R2_BUCKET:-}" ]]; then
    return 0
  fi

  log "R2: mirroring $(basename "${src}") → r2:${R2_BUCKET}/${dest_subpath}"
  rclone copy --progress "${src}" "r2:${R2_BUCKET}/${dest_subpath}" \
    || log "Warning: R2 mirror failed for ${src} (SourceForge upload unaffected)"
}

# ---------------------------------------------------------------------------
# R2 cleanup helper
# Deletes old dated build folders under <profile>/ in R2, keeping:
#   - The 2 most recent dated folders (by date, descending)
#   - The folder pinned by stable.txt (read from R2, may overlap with the 2 latest)
# Central files (latest.txt, stable.txt) at the profile root are untouched.
# Silently skipped if R2_BUCKET is not set.
# ---------------------------------------------------------------------------
r2_cleanup() {
  if [[ -z "${R2_BUCKET:-}" ]]; then
    return 0
  fi

  log "R2: cleaning up old build folders under ${PROFILE}/ (keeping 2 latest + stable)..."

  # Determine the stable date from stable.txt on R2 (if it exists)
  local stable_date=""
  local stable_content
  stable_content=$(rclone cat "r2:${R2_BUCKET}/${PROFILE}/stable.txt" 2>/dev/null || true)
  if [[ -n "$stable_content" ]]; then
    # stable.txt may contain a date string or filename — extract first 8-digit sequence
    stable_date=$(echo "$stable_content" | grep -oP '\d{8}' | head -n1 || true)
    [[ -n "$stable_date" ]] && log "R2: stable build pinned to: ${stable_date}"
  fi

  # Collect all dated folders (8-digit names) under <profile>/, sorted newest first
  local all_dates=()
  while IFS= read -r folder; do
    folder="${folder// /}"  # trim whitespace
    if [[ "$folder" =~ ^[0-9]{8}$ ]]; then
      all_dates+=("$folder")
    fi
  done < <(rclone lsd "r2:${R2_BUCKET}/${PROFILE}/" 2>/dev/null | awk '{print $NF}' | sort -r)

  if [[ ${#all_dates[@]} -eq 0 ]]; then
    log "R2: no dated build folders found, nothing to clean up."
    return 0
  fi

  # Build the keep set: 1 most recent dated folder (latest) + stable folder
  local keep=()
  if [[ ${#all_dates[@]} -gt 0 ]]; then
    keep+=("${all_dates[0]}")
  fi
  if [[ -n "$stable_date" ]] && [[ ! " ${keep[*]} " =~ " ${stable_date} " ]]; then
    keep+=("$stable_date")
  fi

  log "R2: keeping folders: ${keep[*]}"

  # Delete anything not in the keep set
  for d in "${all_dates[@]}"; do
    if [[ ! " ${keep[*]} " =~ " ${d} " ]]; then
      log "R2: deleting old build folder ${PROFILE}/${d}/"
      rclone purge "r2:${R2_BUCKET}/${PROFILE}/${d}" \
        || log "Warning: R2 cleanup failed for ${PROFILE}/${d} (non-fatal)"
    fi
  done

  log "R2: cleanup complete."
}

usage() {
  echo "Usage: $(basename "$0") -p <profile> [mode]"
  echo "  -p <profile>         Profile name (e.g. gnome, plasma)"
  echo "  mode                 Upload mode: 'image' (default) or 'all'"
  exit 1
}

# Parse profile option
PROFILE=""
while getopts "p:h" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    h) usage ;;
    *) die "Invalid option. Use -h for help.";;
  esac
done
shift $((OPTIND - 1))

# Capture additional argument, expected to be "image" or "all"
MODE="${1:-image}"  # default mode is image

[[ -z "$PROFILE" ]] && usage

# Validate MODE
if [[ "$MODE" != "image" && "$MODE" != "all" ]]; then
  die "Invalid mode: $MODE. Must be 'image' or 'all'."
fi

# Determine BUILD_DATE based on today's date or fallback to the most recent build folder.
today=$(date +%Y%m%d)
expected_dir="${OUTPUT_DIR}/${PROFILE}/${today}"

if [[ -d "${expected_dir}" ]]; then
  BUILD_DATE="${today}"
  log "Using today's build folder: ${BUILD_DATE}"
else
  # Find the most recent build folder
  BUILD_DATE=$(find "${OUTPUT_DIR}/${PROFILE}" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | sort -r | head -n1 | xargs basename 2>/dev/null || echo "")
  if [[ -z "$BUILD_DATE" ]]; then
    die "No build directory found under ${OUTPUT_DIR}/${PROFILE}"
  fi
  log "Today's build folder not found; using latest build folder: ${BUILD_DATE}"
fi

# Determine the output subdirectory: OUTPUT_DIR/<profile>/<BUILD_DATE>
OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
if [[ ! -d "${OUTPUT_SUBDIR}" ]]; then
  die "Output directory ${OUTPUT_SUBDIR} does not exist. Build artifacts not found."
fi

REMOTE_PATH="librewish@frs.sourceforge.net:/home/frs/project/shanios/${PROFILE}/"
REMOTE_SUBPATH="librewish@frs.sourceforge.net:/home/frs/project/shanios/${PROFILE}/${BUILD_DATE}/"

# R2 remote paths (mirrors SourceForge layout)
R2_SUBPATH="${PROFILE}/${BUILD_DATE}"
R2_PATH="${PROFILE}"

# Create remote directory if it doesn't exist
log "Ensuring remote directory exists: ${REMOTE_SUBPATH}"
ssh librewish@frs.sourceforge.net "mkdir -p /home/frs/project/shanios/${PROFILE}/${BUILD_DATE}" \
  || log "Warning: Could not create remote directory (may already exist)"

# ---------------------------------------------------------------------------
# Upload base image artifacts from the build folder
# ---------------------------------------------------------------------------
log "Uploading base image artifacts from ${OUTPUT_SUBDIR}:"

# .zst files (excluding flatpakfs.zst and snapfs.zst)
if ls "${OUTPUT_SUBDIR}"/*.zst 1>/dev/null 2>&1; then
  rsync -e ssh -avz --progress \
    --exclude="flatpakfs.zst" --exclude="snapfs.zst" \
    "${OUTPUT_SUBDIR}"/*.zst "${REMOTE_SUBPATH}" \
    || die "Upload of base image failed"
  for f in "${OUTPUT_SUBDIR}"/*.zst; do
    [[ "$f" == *flatpakfs.zst || "$f" == *snapfs.zst ]] && continue
    r2_upload "$f" "${R2_SUBPATH}"
  done
else
  log "Warning: No .zst files found in ${OUTPUT_SUBDIR}"
fi

# Signature files
if ls "${OUTPUT_SUBDIR}"/*.zst.asc 1>/dev/null 2>&1; then
  rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/*.zst.asc "${REMOTE_SUBPATH}" \
    || die "Upload of base image signatures failed"
  for f in "${OUTPUT_SUBDIR}"/*.zst.asc; do
    r2_upload "$f" "${R2_SUBPATH}"
  done
else
  log "Warning: No .zst.asc files found in ${OUTPUT_SUBDIR}"
fi

# Checksum files
if ls "${OUTPUT_SUBDIR}"/*.zst.sha256 1>/dev/null 2>&1; then
  rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/*.zst.sha256 "${REMOTE_SUBPATH}" \
    || die "Upload of base image checksums failed"
  for f in "${OUTPUT_SUBDIR}"/*.zst.sha256; do
    r2_upload "$f" "${R2_SUBPATH}"
  done
else
  log "Warning: No .zst.sha256 files found in ${OUTPUT_SUBDIR}"
fi

# zsync files
if ls "${OUTPUT_SUBDIR}"/*.zst.zsync 1>/dev/null 2>&1; then
  rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/*.zst.zsync "${REMOTE_SUBPATH}" \
    || die "Upload of base image zsync failed"
  for f in "${OUTPUT_SUBDIR}"/*.zst.zsync; do
    r2_upload "$f" "${R2_SUBPATH}"
  done
else
  log "Warning: No .zst.zsync files found in ${OUTPUT_SUBDIR}"
fi

# latest.txt from build folder
if [[ -f "${OUTPUT_SUBDIR}/latest.txt" ]]; then
  rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}/latest.txt" "${REMOTE_SUBPATH}" \
    || die "Upload of latest.txt failed"
  r2_upload "${OUTPUT_SUBDIR}/latest.txt" "${R2_SUBPATH}"
else
  log "Warning: No latest.txt found in ${OUTPUT_SUBDIR}"
fi

# ---------------------------------------------------------------------------
# Central release files
# ---------------------------------------------------------------------------

# central latest.txt
CENTRAL_LATEST="${OUTPUT_DIR}/${PROFILE}/latest.txt"
if [[ -f "${CENTRAL_LATEST}" ]]; then
  log "Uploading central release file (latest.txt) from ${OUTPUT_DIR}/${PROFILE}:"
  rsync -e ssh -avz --progress "${CENTRAL_LATEST}" "${REMOTE_PATH}" \
    || die "Upload of central latest.txt failed"
  r2_upload "${CENTRAL_LATEST}" "${R2_PATH}"
else
  log "No central latest.txt found to upload."
fi

# central stable.txt
CENTRAL_STABLE="${OUTPUT_DIR}/${PROFILE}/stable.txt"
if [[ -f "${CENTRAL_STABLE}" ]]; then
  log "Uploading central release file (stable.txt) from ${OUTPUT_DIR}/${PROFILE}:"
  rsync -e ssh -avz --progress "${CENTRAL_STABLE}" "${REMOTE_PATH}" \
    || die "Upload of central stable.txt failed"
  r2_upload "${CENTRAL_STABLE}" "${R2_PATH}"
else
  log "No central stable.txt found to upload."
fi

# ---------------------------------------------------------------------------
# ISO artifacts (all mode only)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "all" ]]; then
  log "All mode enabled: Uploading ISO artifacts from ${OUTPUT_SUBDIR}:"

  # Signed ISO files
  if ls "${OUTPUT_SUBDIR}"/signed_*.iso 1>/dev/null 2>&1; then
    rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/signed_*.iso "${REMOTE_SUBPATH}" \
      || die "Upload of signed ISO failed"
    for f in "${OUTPUT_SUBDIR}"/signed_*.iso; do
      r2_upload "$f" "${R2_SUBPATH}"
    done
  else
    log "Warning: No signed_*.iso files found in ${OUTPUT_SUBDIR}"
  fi

  # ISO checksums
  if ls "${OUTPUT_SUBDIR}"/signed_*.iso.sha256 1>/dev/null 2>&1; then
    rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/signed_*.iso.sha256 "${REMOTE_SUBPATH}" \
      || die "Upload of ISO checksum failed"
    for f in "${OUTPUT_SUBDIR}"/signed_*.iso.sha256; do
      r2_upload "$f" "${R2_SUBPATH}"
    done
  else
    log "Warning: No signed_*.iso.sha256 files found in ${OUTPUT_SUBDIR}"
  fi

  # ISO signature files
  if ls "${OUTPUT_SUBDIR}"/signed_*.iso.asc 1>/dev/null 2>&1; then
    rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/signed_*.iso.asc "${REMOTE_SUBPATH}" \
      || die "Upload of ISO signatures failed"
    for f in "${OUTPUT_SUBDIR}"/signed_*.iso.asc; do
      r2_upload "$f" "${R2_SUBPATH}"
    done
  else
    log "Warning: No signed_*.iso.asc files found in ${OUTPUT_SUBDIR}"
  fi
fi

# ---------------------------------------------------------------------------
# R2 cleanup — delete old dated build folders, keeping:
#   - The 2 most recent dated folders
#   - The folder pinned by stable.txt
# Run after all uploads are complete so we never delete before a successful upload.
# ---------------------------------------------------------------------------
r2_cleanup

log "Upload completed successfully!"
