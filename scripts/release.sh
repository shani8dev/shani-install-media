#!/usr/bin/env bash
# release.sh – Update central release files (latest.txt or stable.txt)
#
# Assumes build artifacts in: cache/output/<profile>/<BUILD_DATE>/
# Writes central pointer files to:
#   cache/output/<profile>/latest.txt
#   cache/output/<profile>/stable.txt

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

usage() {
  echo "Usage: $(basename "$0") -p <profile> <type>"
  echo "  -p <profile>   Profile name (e.g. gnome, plasma)"
  echo "  type           Release type: 'latest' or 'stable'"
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

RELEASE_TYPE="${1:-}"

[[ -z "$PROFILE" ]]      && usage
[[ -z "$RELEASE_TYPE" ]] && usage

if [[ "$RELEASE_TYPE" != "latest" && "$RELEASE_TYPE" != "stable" ]]; then
  die "Invalid release type: '$RELEASE_TYPE'. Must be 'latest' or 'stable'."
fi

# ---------------------------------------------------------------------------
# Resolve build date via shared helper
# ---------------------------------------------------------------------------
RESOLVED_DATE="$(resolve_build_date "$PROFILE")"
RELEASE_DIR="${OUTPUT_DIR}/${PROFILE}/${RESOLVED_DATE}"

[[ -d "${RELEASE_DIR}" ]] \
    || die "Release directory ${RELEASE_DIR} does not exist. Build artifacts not found."

LOCAL_LATEST_FILE="${RELEASE_DIR}/latest.txt"
[[ -f "${LOCAL_LATEST_FILE}" ]] \
    || die "latest.txt not found in ${RELEASE_DIR}. Check your build process."

# ---------------------------------------------------------------------------
# Write central release pointer
# ---------------------------------------------------------------------------
PROFILE_DIR="${OUTPUT_DIR}/${PROFILE}"
mkdir -p "${PROFILE_DIR}"

CENTRAL_RELEASE="${PROFILE_DIR}/${RELEASE_TYPE}.txt"
cp "${LOCAL_LATEST_FILE}" "${CENTRAL_RELEASE}" \
    || die "Failed to update central ${RELEASE_TYPE}.txt"

log "Central ${RELEASE_TYPE}.txt updated: $(cat "${CENTRAL_RELEASE}")"
log "Release file updated successfully for profile: ${PROFILE}"
