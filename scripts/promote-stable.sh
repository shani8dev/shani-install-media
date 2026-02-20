#!/usr/bin/env bash
# promote-stable.sh – Promote current latest release to stable
#
# This script downloads the current latest.txt from SourceForge,
# uses it to create stable.txt locally, and uploads it back to
# SourceForge and mirrors it to Cloudflare R2.
#
# Usage:
#   ./promote-stable.sh -p <profile>
#
set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# ---------------------------------------------------------------------------
# R2 mirror helper
# Mirrors a single file to Cloudflare R2 under the given remote subpath.
# Silently skipped if R2_BUCKET is not set.
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

usage() {
  echo "Usage: $(basename "$0") -p <profile>"
  echo "  -p <profile>         Profile name (e.g. gnome, plasma)"
  echo ""
  echo "This script will:"
  echo "  1. Download the current latest.txt from SourceForge"
  echo "  2. Create stable.txt with the same content locally"
  echo "  3. Upload stable.txt to SourceForge"
  echo "  4. Mirror stable.txt to Cloudflare R2 (if R2_BUCKET is set)"
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

[[ -z "$PROFILE" ]] && usage

PROJECT_NAME="shanios"
PROFILE_DIR="${OUTPUT_DIR}/${PROFILE}"
LATEST_TXT="${PROFILE_DIR}/latest.txt"
STABLE_TXT="${PROFILE_DIR}/stable.txt"
REMOTE_PATH="librewish@frs.sourceforge.net:/home/frs/project/shanios/${PROFILE}/"

# Ensure profile directory exists
mkdir -p "${PROFILE_DIR}"

# Step 1: Download latest.txt from SourceForge
log "Step 1: Downloading current latest.txt from SourceForge..."
LATEST_URL="https://sourceforge.net/projects/${PROJECT_NAME}/files/${PROFILE}/latest.txt/download"

# Use curl with retry logic
CURL_RETRIES=3
CURL_RETRY_DELAY=2
NETWORK_TIMEOUT=30

if ! curl -fsSL \
    --retry "$CURL_RETRIES" \
    --retry-delay "$CURL_RETRY_DELAY" \
    --max-time "$NETWORK_TIMEOUT" \
    --connect-timeout 10 \
    --user-agent "shanios-promote/1.0" \
    --output "${LATEST_TXT}" \
    "${LATEST_URL}"; then
  die "Failed to download latest.txt from SourceForge. URL: ${LATEST_URL}"
fi

# Verify the file has content
if [[ ! -s "${LATEST_TXT}" ]]; then
  die "Downloaded latest.txt is empty"
fi

LATEST_RELEASE=$(cat "${LATEST_TXT}")
log "Current latest release: ${LATEST_RELEASE}"

# Step 2: Create stable.txt with the same content
log "Step 2: Creating stable.txt locally..."
cp "${LATEST_TXT}" "${STABLE_TXT}" || die "Failed to create stable.txt"
log "Created stable.txt with content: $(cat "${STABLE_TXT}")"

# Step 3: Upload stable.txt to SourceForge
log "Step 3: Uploading stable.txt to SourceForge..."
log "Uploading to: ${REMOTE_PATH}"
rsync -e ssh -avz --progress "${STABLE_TXT}" "${REMOTE_PATH}" || die "Upload of stable.txt failed"

# Step 4: Mirror stable.txt to R2
log "Step 4: Mirroring stable.txt to Cloudflare R2..."
r2_upload "${STABLE_TXT}" "${PROFILE}"

log ""
log "========================================="
log "SUCCESS: Promoted latest to stable!"
log "========================================="
log "Release: ${LATEST_RELEASE}"
log "Profile: ${PROFILE}"
