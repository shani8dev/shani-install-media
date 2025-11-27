#!/usr/bin/env bash
# upload.sh – Upload build artifacts to SourceForge FRS (container-only)
#
# This script uploads:
#   - Base image artifacts: *.zst, *.zst.sha256, *.zst.zsync, and latest.txt from the build folder.
#   - Central release files: latest.txt and stable.txt from the OUTPUT_DIR root (if they exist).
#   - ISO artifacts (signed ISO and its .sha256 checksum) if in "all" mode.
#
# Usage:
#   ./upload.sh -p <profile> [mode]
# where mode is either "image" (default) or "all".
#
set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

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

# Create remote directory if it doesn't exist
log "Ensuring remote directory exists: ${REMOTE_SUBPATH}"
ssh librewish@frs.sourceforge.net "mkdir -p /home/frs/project/shanios/${PROFILE}/${BUILD_DATE}" || log "Warning: Could not create remote directory (may already exist)"

# Upload base image artifacts from the build folder
log "Uploading base image artifacts from ${OUTPUT_SUBDIR}:"

# Check and upload .zst files (excluding flatpakfs.zst and snapfs.zst)
if ls "${OUTPUT_SUBDIR}"/*.zst 1> /dev/null 2>&1; then
  rsync -e ssh -avz --progress --exclude="flatpakfs.zst" --exclude="snapfs.zst" "${OUTPUT_SUBDIR}"/*.zst "${REMOTE_SUBPATH}" || die "Upload of base image failed"
else
  log "Warning: No .zst files found in ${OUTPUT_SUBDIR}"
fi

# Check and upload signature files
if ls "${OUTPUT_SUBDIR}"/*.zst.asc 1> /dev/null 2>&1; then
  rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/*.zst.asc "${REMOTE_SUBPATH}" || die "Upload of base image signatures failed"
else
  log "Warning: No .zst.asc files found in ${OUTPUT_SUBDIR}"
fi

# Check and upload checksum files
if ls "${OUTPUT_SUBDIR}"/*.zst.sha256 1> /dev/null 2>&1; then
  rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/*.zst.sha256 "${REMOTE_SUBPATH}" || die "Upload of base image checksums failed"
else
  log "Warning: No .zst.sha256 files found in ${OUTPUT_SUBDIR}"
fi

# Check and upload zsync files
if ls "${OUTPUT_SUBDIR}"/*.zst.zsync 1> /dev/null 2>&1; then
  rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/*.zst.zsync "${REMOTE_SUBPATH}" || die "Upload of base image zsync failed"
else
  log "Warning: No .zst.zsync files found in ${OUTPUT_SUBDIR}"
fi

# Upload latest.txt from build folder
if [[ -f "${OUTPUT_SUBDIR}/latest.txt" ]]; then
  rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}/latest.txt" "${REMOTE_SUBPATH}" || die "Upload of latest.txt failed"
else
  log "Warning: No latest.txt found in ${OUTPUT_SUBDIR}"
fi

# Upload central release file (latest.txt) if it exists
CENTRAL_LATEST="${OUTPUT_DIR}/${PROFILE}/latest.txt"
if [[ -f "${CENTRAL_LATEST}" ]]; then
  log "Uploading central release file (latest.txt) from ${OUTPUT_DIR}/${PROFILE}:"
  rsync -e ssh -avz --progress "${CENTRAL_LATEST}" "${REMOTE_PATH}" || die "Upload of central latest.txt failed"
else
  log "No central latest.txt found to upload."
fi

# Upload central release file (stable.txt) if it exists
CENTRAL_STABLE="${OUTPUT_DIR}/${PROFILE}/stable.txt"
if [[ -f "${CENTRAL_STABLE}" ]]; then
  log "Uploading central release file (stable.txt) from ${OUTPUT_DIR}/${PROFILE}:"
  rsync -e ssh -avz --progress "${CENTRAL_STABLE}" "${REMOTE_PATH}" || die "Upload of central stable.txt failed"
else
  log "No central stable.txt found to upload."
fi

# In "all" mode, also upload ISO artifacts
if [[ "$MODE" == "all" ]]; then
  log "All mode enabled: Uploading ISO artifacts from ${OUTPUT_SUBDIR}:"
  
  # Check and upload signed ISO files
  if ls "${OUTPUT_SUBDIR}"/signed_*.iso 1> /dev/null 2>&1; then
    rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/signed_*.iso "${REMOTE_SUBPATH}" || die "Upload of signed ISO failed"
  else
    log "Warning: No signed_*.iso files found in ${OUTPUT_SUBDIR}"
  fi
  
  # Check and upload ISO checksums
  if ls "${OUTPUT_SUBDIR}"/signed_*.iso.sha256 1> /dev/null 2>&1; then
    rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/signed_*.iso.sha256 "${REMOTE_SUBPATH}" || die "Upload of ISO checksum failed"
  else
    log "Warning: No signed_*.iso.sha256 files found in ${OUTPUT_SUBDIR}"
  fi
fi

log "Upload completed successfully!"
