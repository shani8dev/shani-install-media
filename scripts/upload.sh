#!/usr/bin/env bash
# upload.sh – Upload build artifacts to SourceForge FRS (container-only)
#
# This script uploads:
#   - Base image artifacts: *.zst, *.zst.sha256, *.zst.zsync, and latest.txt from the build folder.
#   - Central release file: latest.txt from the OUTPUT_DIR root (if it exists).
#   - ISO artifacts (signed ISO and its .sha256 checksum) if in "all" mode.
#
# Usage:
#   ./upload.sh -p <profile> [mode]
# where mode is either "image" (default) or "all".
#
set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# Parse profile option
PROFILE=""
while getopts "p:" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    *) die "Invalid option";;
  esac
done
shift $((OPTIND - 1))

# Capture additional argument, expected to be "image" or "all"
MODE="${1:-image}"  # default mode is image

[[ -z "$PROFILE" ]] && PROFILE="$DEFAULT_PROFILE"

# Determine BUILD_DATE based on today's date or fallback to the most recent build folder.
today=$(date +%Y%m%d)
expected_dir="${OUTPUT_DIR}/${PROFILE}/${today}"

if [[ -d "${expected_dir}" ]]; then
  BUILD_DATE="${today}"
  log "Using today's build folder: ${BUILD_DATE}"
else
  BUILD_DATE=$(ls -1dt "${OUTPUT_DIR}/${PROFILE}"/*/ 2>/dev/null | head -n1 | xargs basename)
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

# Upload base image artifacts from the build folder
log "Uploading base image artifacts from ${OUTPUT_SUBDIR}:"
rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/*.zst "${REMOTE_SUBPATH}" || die "Upload of base image failed"
rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/*.zst.asc "${REMOTE_SUBPATH}" || die "Upload of base image key failed"
rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/*.zst.sha256 "${REMOTE_SUBPATH}" || die "Upload of base image checksum failed"
rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/*.zst.zsync "${REMOTE_SUBPATH}" || die "Upload of base image zsync failed"
rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}/latest.txt" "${REMOTE_SUBPATH}" || die "Upload of latest.txt failed"

# Upload central release file (latest.txt) if it exists
CENTRAL_LATEST="${OUTPUT_DIR}/${PROFILE}/latest.txt"
if [[ -f "${CENTRAL_LATEST}" ]]; then
  log "Uploading central release file (latest.txt) from ${OUTPUT_DIR}/${PROFILE}:"
  rsync -e ssh -avz --progress "${CENTRAL_LATEST}" "${REMOTE_PATH}" || die "Upload of central latest.txt failed"
else
  log "No central latest.txt found to upload."
fi

# In "all" mode, also upload ISO artifacts
if [[ "$MODE" == "all" ]]; then
  log "All mode enabled: Uploading ISO artifacts from ${OUTPUT_SUBDIR}:"
  rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}/signed_*.iso" "${REMOTE_SUBPATH}" || die "Upload of signed ISO failed"
  rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}/signed_*.iso.sha256" "${REMOTE_SUBPATH}" || die "Upload of ISO checksum failed"
fi

log "Upload completed successfully!"

