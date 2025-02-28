#!/usr/bin/env bash
# release.sh – Create and update central release files (latest.txt and stable.txt)
#
# This script assumes build artifacts are stored in:
#   cache/output/<profile>/<BUILD_DATE>/
# It creates two central files in the OUTPUT_DIR root:
#   latest.txt  -- containing the filename of the most recent base image from the build subdir
#   stable.txt  -- containing the filename of the stable release (if specified, or defaults to latest)
#
# Usage:
#   ./release.sh -p <profile> [-s <stable_artifact>]

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

usage() {
  echo "Usage: $(basename "$0") -p <profile> [-s <stable_artifact>]"
  echo "  -p <profile>         Profile name (e.g. gnome)"
  echo "  -s <stable_artifact> (Optional) Artifact filename to mark as stable release"
  exit 1
}

PROFILE=""
STABLE_ARTIFACT=""

while getopts "p:s:" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    s) STABLE_ARTIFACT="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ -z "$PROFILE" ]] && usage

# Define release directory
RELEASE_DIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
if [[ ! -d "${RELEASE_DIR}" ]]; then
  die "Release directory ${RELEASE_DIR} does not exist. Build artifacts not found."
fi

# Use the latest.txt file from the build subdirectory
LOCAL_LATEST_FILE="${RELEASE_DIR}/latest.txt"
if [[ ! -f "${LOCAL_LATEST_FILE}" ]]; then
  die "Latest file ${LOCAL_LATEST_FILE} not found. Please check your build process."
fi

# Create central release files in OUTPUT_DIR root
CENTRAL_LATEST="${OUTPUT_DIR}/${PROFILE}/latest.txt"
cp "${LOCAL_LATEST_FILE}" "${CENTRAL_LATEST}" || die "Failed to update central latest.txt"
log "Central latest.txt updated: $(cat "${CENTRAL_LATEST}")"

# Determine stable artifact; if not provided, default to latest.
if [[ -z "$STABLE_ARTIFACT" ]]; then
  STABLE_ARTIFACT=$(cat "${LOCAL_LATEST_FILE}")
fi

CENTRAL_STABLE="${OUTPUT_DIR}/${PROFILE}/stable.txt"
echo "$STABLE_ARTIFACT" > "${CENTRAL_STABLE}" || die "Failed to create central stable.txt"
log "Central stable.txt created: $(cat "${CENTRAL_STABLE}")"
