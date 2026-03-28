#!/usr/bin/env bash
# build.sh – Dispatcher for build steps
#
# ============================================================
# FLOW OVERVIEW
# ============================================================
#
# image   (standalone)
#   └─ build-base-image.sh -p <profile>
#        writes: cache/output/<profile>/<date>/<os>-<date>-<profile>.zst
#                cache/output/<profile>/<date>/<os>-<date>-<profile>.zst.sha256
#                cache/output/<profile>/<date>/<os>-<date>-<profile>.zst.asc
#                cache/output/<profile>/<date>/latest.txt
#
# all     image → release latest → upload image
#   └─ build-base-image.sh
#   └─ release.sh -p <profile> latest
#        writes: cache/output/<profile>/latest.txt
#   └─ upload.sh -p <profile> image
#        uploads: .zst + .sha256 + .asc + dated latest.txt → SF + R2
#                 central latest.txt → SF + R2
#
# full    image → flatpak → snap → iso → repack → release latest → upload all
#   └─ build-base-image.sh
#   └─ build-flatpak-image.sh  (if flatpak-packages.txt exists)
#        writes: cache/output/<profile>/<date>/flatpakfs.zst
#   └─ build-snap-image.sh     (if snap-packages.txt exists)
#        writes: cache/output/<profile>/<date>/snapfs.zst
#   └─ build-iso.sh            (no --from-r2; uses local artifacts)
#        writes: cache/temp/<profile>/iso/<os>/x86_64/{rootfs,flatpakfs,snapfs}.zst
#                cache/output/<profile>/<date>/<os>-<date>-<profile>.iso
#   └─ repack-iso.sh
#        writes: cache/output/<profile>/<date>/signed_<os>-<date>-<profile>.iso
#                cache/output/<profile>/<date>/signed_*.iso.sha256
#                cache/output/<profile>/<date>/signed_*.iso.asc
#                cache/output/<profile>/<date>/signed_*.iso.torrent
#   └─ release.sh -p <profile> latest
#   └─ upload.sh -p <profile> all
#        uploads: image artifacts + ISO artifacts → SF + R2
#
# iso-only  (download from R2 → build ISO → repack → upload iso)
#   Three resume-safe entry points checked in order:
#   1. signed ISO exists  → skip to upload
#   2. unsigned ISO exists → repack → upload
#   3. nothing exists     → full pipeline below
#   └─ build-iso.sh --from-r2
#        fetches: latest.txt via rclone (authenticated)
#        downloads: base image + .sha256 + .asc via aria2c (fatal if missing)
#        verifies: sha256 + gpg signature (hard fail on mismatch)
#        downloads: flatpakfs.zst / snapfs.zst from R2 if present (non-fatal)
#        runs: mkarchiso
#        writes: cache/output/<profile>/<date>/<os>-<date>-<profile>.iso
#   └─ repack-iso.sh
#   └─ upload.sh -p <profile> iso
#        uploads: signed ISO + .sha256 + .asc + .torrent → SF + R2
#
# publish   release → upload all
#   └─ release.sh -p <profile> <latest|stable>
#   └─ upload.sh -p <profile> all
#
# promote-stable  (standalone, run after iso-only is live)
#   └─ downloads latest.txt from SF
#   └─ verifies artifact + .asc exist on SF
#   └─ writes stable.txt locally
#   └─ uploads stable.txt → SF + R2
#
# verify    (standalone)
#   └─ upload.sh -p <profile> --verify-only
#        fetches remote .sha256, compares to local artifact
#
# ============================================================
set -Eeuo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/config/config.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  image          Build base image (requires -p <profile>)
  flatpak        Build Flatpak image (requires -p <profile>)
  snap           Build Snap seed image (requires -p <profile>)
  iso            Build ISO (requires -p <profile>) [--from-r2]
  repack         Repackage ISO for Secure Boot (requires -p <profile>)
  upload         Upload build artifacts (requires -p <profile> [mode])
  promote-stable Promote current latest release to stable (requires -p <profile>)
  release        Create central release files (requires -p <profile> <type>)
  verify         Verify latest uploaded artifact on SourceForge (requires -p <profile>)
  all            image → release latest → upload image
  full           image → flatpak → snap → iso → repack → release latest → upload all
  iso-only       Download base image from R2, build ISO → repack → upload iso
  publish        release → upload (requires -p <profile> <type>)

Options:
  -p <profile>    Profile name (e.g. gnome, plasma)
  <type>          Release type: 'latest' or 'stable' (for release/publish)
  [mode]          Upload mode: 'image' (default), 'iso', or 'all' (for upload)
  --from-r2       Download base image from R2 instead of building locally (iso)
  --no-sf         Skip SourceForge uploads (for compound commands)
  --no-r2         Skip Cloudflare R2 uploads (for compound commands)

Examples:
  $(basename "$0") image -p gnome
  $(basename "$0") iso -p gnome --from-r2
  $(basename "$0") iso-only -p gnome
  $(basename "$0") iso-only -p gnome --no-sf
  $(basename "$0") all -p plasma
  $(basename "$0") full -p plasma
  $(basename "$0") full -p plasma --no-sf
  $(basename "$0") verify -p gnome
  $(basename "$0") release -p gnome latest
  $(basename "$0") publish -p gnome stable
  $(basename "$0") upload -p gnome all
  $(basename "$0") promote-stable -p gnome
EOF
  exit 1
}

[[ $# -lt 1 ]] && usage

COMMAND="$1"
shift

# ---------------------------------------------------------------------------
# Helper: extract -p <profile> value from an argument list
# ---------------------------------------------------------------------------
_get_profile() {
  local _prev="" _profile=""
  for _arg in "$@"; do
    [[ "${_prev}" == "-p" ]] && _profile="$_arg"
    _prev="$_arg"
  done
  echo "$_profile"
}

# ---------------------------------------------------------------------------
# Helper: split "$@" into build args and upload flags (--no-sf / --no-r2).
# Sets _BUILD_ARGS and _UPLOAD_FLAGS in the caller's scope.
# Usage: _split_args "$@"
# ---------------------------------------------------------------------------
_split_args() {
  _BUILD_ARGS=()
  _UPLOAD_FLAGS=()
  for _arg in "$@"; do
    case "$_arg" in
      --no-sf|--no-r2) _UPLOAD_FLAGS+=("$_arg") ;;
      *)               _BUILD_ARGS+=("$_arg") ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Pin BUILD_DATE for the entire session.
# Exporting here means every sub-script that sources config.sh inherits
# this value instead of re-evaluating `date`, so a midnight boundary
# during a long compound build never splits artifacts across two folders.
# ---------------------------------------------------------------------------
export BUILD_DATE="$(date +%Y%m%d)"

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
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

  # -------------------------------------------------------------------------
  # all: image → release latest → upload image
  # -------------------------------------------------------------------------
  all)
    _split_args "$@"
    _ALL_PROFILE="$(_get_profile "${_BUILD_ARGS[@]+"${_BUILD_ARGS[@]}"}")"
    [[ -z "$_ALL_PROFILE" ]] && die "Profile (-p) is required for the 'all' command."

    ./scripts/build-base-image.sh "${_BUILD_ARGS[@]}"
    ./scripts/release.sh          "${_BUILD_ARGS[@]}" latest
    ./scripts/upload.sh           "${_BUILD_ARGS[@]}" "${_UPLOAD_FLAGS[@]+"${_UPLOAD_FLAGS[@]}"}" image
    ;;

  # -------------------------------------------------------------------------
  # full: image → flatpak → snap → iso → repack → release latest → upload all
  # -------------------------------------------------------------------------
  full)
    _split_args "$@"
    _FULL_PROFILE="$(_get_profile "${_BUILD_ARGS[@]+"${_BUILD_ARGS[@]}"}")"
    [[ -z "$_FULL_PROFILE" ]] && die "Profile (-p) is required for the 'full' command."

    ./scripts/build-base-image.sh "${_BUILD_ARGS[@]}"

    if [[ -f "${IMAGE_PROFILES_DIR}/${_FULL_PROFILE}/flatpak-packages.txt" ]]; then
      log "flatpak-packages.txt found — building Flatpak image..."
      ./scripts/build-flatpak-image.sh "${_BUILD_ARGS[@]}"
    else
      log "No flatpak-packages.txt for profile '${_FULL_PROFILE}' — skipping Flatpak build."
    fi

    if [[ -f "${IMAGE_PROFILES_DIR}/${_FULL_PROFILE}/snap-packages.txt" ]]; then
      log "snap-packages.txt found — building Snap image..."
      ./scripts/build-snap-image.sh "${_BUILD_ARGS[@]}"
    else
      log "No snap-packages.txt for profile '${_FULL_PROFILE}' — skipping Snap build."
    fi

    ./scripts/build-iso.sh    "${_BUILD_ARGS[@]}"
    ./scripts/repack-iso.sh   "${_BUILD_ARGS[@]}"
    ./scripts/release.sh      "${_BUILD_ARGS[@]}" latest
    ./scripts/upload.sh       "${_BUILD_ARGS[@]}" "${_UPLOAD_FLAGS[@]+"${_UPLOAD_FLAGS[@]}"}" all
    ;;

  # -------------------------------------------------------------------------
  # iso-only: iso (--from-r2) → repack → upload iso
  #
  # Skips completed stages so a failed upload or repack can be retried
  # without rebuilding from scratch:
  #   - signed ISO exists → skip build-iso and repack, go straight to upload
  #   - unsigned ISO exists → skip build-iso, run repack then upload
  #   - nothing exists → full run: build-iso → repack → upload
  # -------------------------------------------------------------------------
  iso-only)
    _split_args "$@"
    _ISO_PROFILE="$(_get_profile "${_BUILD_ARGS[@]+"${_BUILD_ARGS[@]}"}")"
    [[ -z "$_ISO_PROFILE" ]] && die "Profile (-p) is required for the 'iso-only' command."

    _ISO_OUTDIR="${OUTPUT_DIR}/${_ISO_PROFILE}/${BUILD_DATE}"

    if ls "${_ISO_OUTDIR}"/signed_*.iso 1>/dev/null 2>&1; then
      log "Signed ISO already exists in ${_ISO_OUTDIR} — skipping build and repack, proceeding to upload."
    elif find "${_ISO_OUTDIR}" -maxdepth 1 -name '*.iso' ! -name 'signed_*.iso' 2>/dev/null | grep -q .; then
      log "Unsigned ISO found in ${_ISO_OUTDIR} — skipping build-iso, running repack then upload."
      ./scripts/repack-iso.sh "${_BUILD_ARGS[@]}"
    else
      log "No ISO found in ${_ISO_OUTDIR} — running full iso-only pipeline."
      ./scripts/build-iso.sh  "${_BUILD_ARGS[@]}" --from-r2
      ./scripts/repack-iso.sh "${_BUILD_ARGS[@]}"
    fi

    ./scripts/upload.sh "${_BUILD_ARGS[@]}" "${_UPLOAD_FLAGS[@]+"${_UPLOAD_FLAGS[@]}"}" iso
    ;;

  # -------------------------------------------------------------------------
  # publish: release → upload
  # -------------------------------------------------------------------------
  publish)
    _split_args "$@"
    _PUB_PROFILE="$(_get_profile "${_BUILD_ARGS[@]+"${_BUILD_ARGS[@]}"}")"
    [[ -z "$_PUB_PROFILE" ]] && die "Profile (-p) is required for the 'publish' command."

    # Extract the release type (latest|stable) from _BUILD_ARGS.
    # Build _RELEASE_ARGS with the type word removed so upload.sh never sees it.
    _PUB_TYPE=""
    _RELEASE_ARGS=()
    _prev=""
    for _arg in "${_BUILD_ARGS[@]+"${_BUILD_ARGS[@]}"}"; do
      if [[ "$_arg" == "latest" || "$_arg" == "stable" ]] && [[ "$_prev" != "-p" ]]; then
        _PUB_TYPE="$_arg"
      else
        _RELEASE_ARGS+=("$_arg")
      fi
      _prev="$_arg"
    done
    [[ -z "$_PUB_TYPE" ]] && die "Release type (latest|stable) is required for the 'publish' command."

    ./scripts/release.sh "${_RELEASE_ARGS[@]+"${_RELEASE_ARGS[@]}"}" "$_PUB_TYPE"
    ./scripts/upload.sh  "${_RELEASE_ARGS[@]+"${_RELEASE_ARGS[@]}"}" "${_UPLOAD_FLAGS[@]+"${_UPLOAD_FLAGS[@]}"}" all
    ;;

  *)
    echo "Error: Unknown command '${COMMAND}'"
    echo ""
    usage
    ;;
esac
