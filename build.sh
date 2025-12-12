#!/usr/bin/env bash
# build.sh – Dispatcher for build steps (runs inside container or spawns container if needed)
set -Eeuo pipefail

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
  upload     Upload build artifacts to SourceForge (requires -p <profile> [mode])
  release    Create central release files (requires -p <profile> <type>)
  all        Run all steps + release latest (requires -p <profile>)
  publish    Run release and upload (requires -p <profile> <type>)

Options:
  -p <profile>    Profile name (e.g. gnome, plasma)
  <type>          Release type: 'latest' or 'stable' (for release/publish commands)
  [mode]          Upload mode: 'image' (default) or 'all' (for upload command)

Examples:
  $(basename "$0") image -p gnome
  $(basename "$0") flatpak -p gnome
  $(basename "$0") all -p plasma                    # Builds everything + creates latest release
  $(basename "$0") release -p gnome latest
  $(basename "$0") release -p gnome stable
  $(basename "$0") publish -p gnome stable
  $(basename "$0") upload -p gnome all
EOF
  exit 1
}

# Must provide at least one command
[[ $# -lt 1 ]] && usage

COMMAND="$1"
shift

# Run appropriate subcommand
case "$COMMAND" in
  image)
    exec ./scripts/build-base-image.sh "$@"
    ;;
  flatpak)
    exec ./scripts/build-flatpak-image.sh "$@"
    ;;
  iso)
    exec ./scripts/build-iso.sh "$@"
    ;;
  repack)
    exec ./scripts/repack-iso.sh "$@"
    ;;
  release)
    exec ./scripts/release.sh "$@"
    ;;
  upload)
    exec ./scripts/upload.sh "$@"
    ;;
  all)
    ./scripts/build-base-image.sh "$@"
    ./scripts/build-flatpak-image.sh "$@"
    ./scripts/build-iso.sh "$@"
    ./scripts/repack-iso.sh "$@"
    ./scripts/release.sh "$@" latest
    ./scripts/upload.sh "$@" all
    ;;
  publish)
    ./scripts/release.sh "$@"
    ./scripts/upload.sh "$@"
    ;;
  *)
    echo "Error: Unknown command '$COMMAND'"
    echo ""
    usage
    ;;
esac
