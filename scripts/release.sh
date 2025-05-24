#!/usr/bin/env bash
# release.sh – Update central release files (latest.txt or stable.txt)
#
# This script assumes build artifacts are stored in:
#   cache/output/<profile>/<BUILD_DATE>/
# It creates central files in the OUTPUT_DIR root:
#   - latest.txt containing the filename of the most recent base image
#   - stable.txt containing the filename of the stable base image
#
# Usage:
#   ./release.sh -p <profile> <type>
# where type is either "latest" or "stable"
#
# The build process should have generated a latest.txt file in the build subdirectory.

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

usage() {
  echo "Usage: $(basename "$0") -p <profile> <type>"
  echo "  -p <profile>         Profile name (e.g. gnome, plasma)"
  echo "  type                 Release type: 'latest' or 'stable'"
  exit 1
}

PROFILE=""

while getopts "p:" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

# Get release type from remaining arguments
RELEASE_TYPE="${1:-}"

[[ -z "$PROFILE" ]] && usage
[[ -z "$RELEASE_TYPE" ]] && usage

# Validate release type
if [[ "$RELEASE_TYPE" != "latest" && "$RELEASE_TYPE" != "stable" ]]; then
  die "Invalid release type: $RELEASE_TYPE. Must be 'latest' or 'stable'."
fi

# BUILD_DATE: Use today's date or find the most recent build folder
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

# Define the release directory (build output folder)
RELEASE_DIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
if [[ ! -d "${RELEASE_DIR}" ]]; then
  die "Release directory ${RELEASE_DIR} does not exist. Build artifacts not found."
fi

LOCAL_LATEST_FILE="${RELEASE_DIR}/latest.txt"
if [[ ! -f "${LOCAL_LATEST_FILE}" ]]; then
  die "Latest file ${LOCAL_LATEST_FILE} not found. Please check your build process."
fi

# Ensure the profile directory exists
PROFILE_DIR="${OUTPUT_DIR}/${PROFILE}"
mkdir -p "${PROFILE_DIR}"

# Update the specified release file
CENTRAL_RELEASE="${PROFILE_DIR}/${RELEASE_TYPE}.txt"
cp "${LOCAL_LATEST_FILE}" "${CENTRAL_RELEASE}" || die "Failed to update central ${RELEASE_TYPE}.txt"
log "Central ${RELEASE_TYPE}.txt updated: $(cat "${CENTRAL_RELEASE}")"

log "Release file ${RELEASE_TYPE}.txt updated successfully for profile: ${PROFILE}"
