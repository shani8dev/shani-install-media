#!/usr/bin/env bash
# build.sh – Dispatcher for build steps (runs inside container or spawns container if needed)
set -Eeuo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/config/config.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  image          Build base image (requires -p <profile>)
  flatpak        Build Flatpak image (requires -p <profile>)
  snap           Build Snap seed image (requires -p <profile>; skipped if snap-packages.txt is absent)
  iso            Build ISO (requires -p <profile>)
  repack         Repackage ISO for Secure Boot (requires -p <profile>)
  upload         Upload build artifacts to SourceForge (requires -p <profile> [mode])
  promote-stable Promote current latest release to stable (requires -p <profile>)
  release        Create central release files (requires -p <profile> <type>)
  verify         Verify latest uploaded artifact on SourceForge (requires -p <profile>)
  all            Run image + release latest + upload image (requires -p <profile>)
  full           Run full pipeline incl. ISO + repack + upload all (requires -p <profile>)
  publish        Run release and upload (requires -p <profile> <type>)

Options:
  -p <profile>    Profile name (e.g. gnome, plasma)
  <type>          Release type: 'latest' or 'stable' (for release/publish commands)
  [mode]          Upload mode: 'image' (default) or 'all' (for upload command)

Examples:
  $(basename "$0") image -p gnome
  $(basename "$0") flatpak -p gnome
  $(basename "$0") snap -p gnome
  $(basename "$0") all -p plasma                    # Builds image, releases latest, uploads image
  $(basename "$0") full -p plasma                   # Full pipeline: image → iso → repack → upload all
  $(basename "$0") verify -p gnome                  # Verify latest artifact on SourceForge
  $(basename "$0") release -p gnome latest
  $(basename "$0") release -p gnome stable
  $(basename "$0") publish -p gnome stable
  $(basename "$0") upload -p gnome all
  $(basename "$0") promote-stable -p gnome          # Promote latest to stable
EOF
  exit 1
}

# Must provide at least one command
[[ $# -lt 1 ]] && usage

COMMAND="$1"
shift

# ---------------------------------------------------------------------------
# Helper: extract profile from remaining args (used by all/full)
# ---------------------------------------------------------------------------
_get_profile() {
  local _prev=""
  local _profile=""
  for _arg in "$@"; do
    if [[ "${_prev}" == "-p" ]]; then
      _profile="$_arg"
    fi
    _prev="$_arg"
  done
  echo "$_profile"
}

# Run appropriate subcommand
case "$COMMAND" in
  image)
    exec ./scripts/build-base-image.sh "$@"
    ;;
  flatpak)
    exec ./scripts/build-flatpak-image.sh "$@"
    ;;
  snap)
    exec ./scripts/build-snap-image.sh "$@"
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
  promote-stable)
    exec ./scripts/promote-stable.sh "$@"
    ;;
  verify)
    exec ./scripts/upload.sh "$@" --verify-only
    ;;
  all)
    # Runs: image → release latest → upload image
    _ALL_PROFILE="$(_get_profile "$@")"
    [[ -z "$_ALL_PROFILE" ]] && die "Profile (-p) is required for the 'all' command."

    ./scripts/build-base-image.sh "$@"
    ./scripts/release.sh "$@" latest
    ./scripts/upload.sh "$@" image
    ;;
  full)
    # Runs: image → flatpak → snap → iso → repack → release latest → upload all
    _FULL_PROFILE="$(_get_profile "$@")"
    [[ -z "$_FULL_PROFILE" ]] && die "Profile (-p) is required for the 'full' command."

    ./scripts/build-base-image.sh "$@"

    if [[ -f "${IMAGE_PROFILES_DIR}/${_FULL_PROFILE}/flatpak-packages.txt" ]]; then
      log "flatpak-packages.txt found — building Flatpak image..."
      ./scripts/build-flatpak-image.sh "$@"
    else
      log "No flatpak-packages.txt for profile '${_FULL_PROFILE}' — skipping Flatpak build."
    fi

    if [[ -f "${IMAGE_PROFILES_DIR}/${_FULL_PROFILE}/snap-packages.txt" ]]; then
      log "snap-packages.txt found — building Snap image..."
      ./scripts/build-snap-image.sh "$@"
    else
      log "No snap-packages.txt for profile '${_FULL_PROFILE}' — skipping Snap build."
    fi

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
