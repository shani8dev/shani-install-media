#!/usr/bin/env bash
# build.sh – Dispatcher for build steps (runs inside container or spawns container if needed)

set -Eeuo pipefail

# Check if running inside the container, if not, re-execute inside the container
if [[ -z "${IN_CONTAINER:-}" ]]; then
    SCRIPT_DIR="$(dirname "$(realpath "$0")")"
    exec "${SCRIPT_DIR}/run_in_container.sh" "$0" "$@"
fi

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/config/config.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]
Commands:
  image      Build base image (requires -p <profile>)
  flatpak    Build Flatpak image (requires -p <profile>)
  iso        Build ISO (requires -p <profile>)
  repack     Repackage ISO for Secure Boot (requires -p <profile>)
  upload     Upload build artifacts to SourceForge (requires -p <profile>)
  release    Create central release files (latest.txt & stable.txt)
  all        Run all steps (image, flatpak, iso, repack, upload, release)
  publish    Run release and upload 
EOF
  exit 1
}

[[ "$#" -lt 1 ]] && usage

COMMAND="$1"
shift

case "$COMMAND" in
  image)      ./scripts/build-base-image.sh "$@";;
  flatpak)    ./scripts/build-flatpak-image.sh "$@";;
  iso)        ./scripts/build-iso.sh "$@";;
  repack)     ./scripts/repack-iso.sh "$@";;
  release)    ./scripts/release.sh "$@";;
  upload)     ./scripts/upload.sh "$@";;
  all)        ./scripts/build-base-image.sh "$@"; \
              ./scripts/build-flatpak-image.sh "$@"; \
              ./scripts/build-iso.sh "$@"; \
              ./scripts/repack-iso.sh "$@";;
  publish)    ./scripts/release.sh "$@"; \
              ./scripts/upload.sh "$@";;
  *)          usage;;
esac

