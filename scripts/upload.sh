#!/usr/bin/env bash
# upload.sh – Upload build artifacts to SourceForge FRS (container-only)
# Uploads:
#   - Base image files: *.zst, *.zst.sha256, *.zst.zsync, and latest.txt
#   - ISO: signed ISO and its .sha256 checksum
#   - Central release files: latest.txt and stable.txt

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
[[ -z "$PROFILE" ]] && PROFILE="$DEFAULT_PROFILE"

# Determine output subdirectory: OUTPUT_DIR/<profile>/<BUILD_DATE>
OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
if [[ ! -d "${OUTPUT_SUBDIR}" ]]; then
  die "Output directory ${OUTPUT_SUBDIR} does not exist. Build artifacts not found."
fi

REMOTE_PATH="librewish@frs.sourceforge.net:/home/frs/project/s/shanios/${PROFILE}/${BUILD_DATE}/"

log "Uploading base image artifacts from ${OUTPUT_SUBDIR}:"
rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/*.zst "${REMOTE_PATH}" || die "Upload of base image failed"
rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/*.zst.sha256 "${REMOTE_PATH}" || die "Upload of base image checksum failed"
rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}"/*.zst.zsync "${REMOTE_PATH}" || die "Upload of base image zsync failed"
rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}/latest.txt" "${REMOTE_PATH}" || die "Upload of latest.txt failed"

log "Uploading ISO artifacts (signed ISO and its checksum) from ${OUTPUT_SUBDIR}:"
rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}/signed_*.iso" "${REMOTE_PATH}" || die "Upload of signed ISO failed"
rsync -e ssh -avz --progress "${OUTPUT_SUBDIR}/signed_*.iso.sha256" "${REMOTE_PATH}" || die "Upload of ISO checksum failed"

log "Uploading central release files (latest.txt & stable.txt) from ${OUTPUT_DIR}:"
rsync -e ssh -avz --progress "${OUTPUT_DIR}/latest.txt" "${REMOTE_PATH}" || die "Upload of central latest.txt failed"
rsync -e ssh -avz --progress "${OUTPUT_DIR}/stable.txt" "${REMOTE_PATH}" || die "Upload of central stable.txt failed"

log "Upload completed successfully!"
