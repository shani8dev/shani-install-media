#!/usr/bin/env bash
# release.sh – Update central release file (latest.txt)
#
# This script assumes build artifacts are stored in:
#   cache/output/<profile>/<BUILD_DATE>/
# It creates a central file in the OUTPUT_DIR root:
#   latest.txt containing the filename of the most recent base image.
#
# Usage:
#   ./release.sh -p <profile>
#
# The build process should have generated a latest.txt file in the build subdirectory.

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

usage() {
  echo "Usage: $(basename "$0") -p <profile>"
  echo "  -p <profile>         Profile name (e.g. gnome)"
  exit 1
}

PROFILE=""

while getopts "p:" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ -z "$PROFILE" ]] && usage

# BUILD_DATE must be set in config or passed via the environment.
if [[ -z "${BUILD_DATE:-}" ]]; then
  die "BUILD_DATE is not set. Please set BUILD_DATE in config or environment."
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

CENTRAL_LATEST="${OUTPUT_DIR}/${PROFILE}/latest.txt"
cp "${LOCAL_LATEST_FILE}" "${CENTRAL_LATEST}" || die "Failed to update central latest.txt"
log "Central latest.txt updated: $(cat "${CENTRAL_LATEST}")"

