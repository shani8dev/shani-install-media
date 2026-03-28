#!/usr/bin/env bash
# upload.sh – Upload build artifacts to SourceForge FRS and mirror to Cloudflare R2
#
# Uploads:
#   image  *.zst, *.zst.sha256, *.zst.asc, latest.txt, central latest/stable.txt
#   iso    signed_*.iso, .sha256, .asc, .torrent
#   all    both of the above
#
# All uploads are mirrored to Cloudflare R2 if R2_BUCKET is set.
# After upload, old dated R2 folders are pruned (keeps 2 latest + stable pin).
#
# Usage:
#   ./upload.sh -p <profile> [--no-sf] [--no-r2] [--verify-only] [image|iso|all]

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
r2_upload() {
  local src="$1"
  local dest_subpath="$2"

  [[ "${NO_R2}" == "true" ]] && { log "R2: skipping $(basename "${src}") (--no-r2)"; return 0; }
  [[ -z "${R2_BUCKET:-}" ]]  && return 0

  log "R2: mirroring $(basename "${src}") → r2:${R2_BUCKET}/${dest_subpath}"
  rclone copy --progress --stats 5s --stats-one-line "${src}" "r2:${R2_BUCKET}/${dest_subpath}" \
    || log "Warning: R2 mirror failed for ${src} (SourceForge upload unaffected)"
}

# Prune old dated R2 folders, keeping the 2 most recent and the stable-pinned folder.
r2_cleanup() {
  [[ "${NO_R2}" == "true" ]] && { log "R2: skipping cleanup (--no-r2)"; return 0; }
  [[ -z "${R2_BUCKET:-}" ]]  && return 0

  log "R2: cleaning up old build folders under ${PROFILE}/ (keeping 2 latest + stable)..."

  local stable_date=""
  local stable_content
  stable_content=$(rclone cat "r2:${R2_BUCKET}/${PROFILE}/stable.txt" 2>/dev/null || true)
  if [[ -n "$stable_content" ]]; then
    stable_date=$(echo "$stable_content" | grep -oE '[0-9]{8}' | head -n1 || true)
    [[ -n "$stable_date" ]] && log "R2: stable build pinned to: ${stable_date}"
  fi

  local all_dates=()
  while IFS= read -r folder; do
    folder="${folder// /}"
    [[ "$folder" =~ ^[0-9]{8}$ ]] && all_dates+=("$folder")
  done < <(rclone lsd "r2:${R2_BUCKET}/${PROFILE}/" 2>/dev/null | awk '{print $NF}' | sort -r)

  if [[ ${#all_dates[@]} -eq 0 ]]; then
    log "R2: no dated build folders found, nothing to clean up."
    return 0
  fi

  local keep=()
  [[ ${#all_dates[@]} -gt 0 ]] && keep+=("${all_dates[0]}")
  [[ ${#all_dates[@]} -gt 1 ]] && keep+=("${all_dates[1]}")
  if [[ -n "$stable_date" && ! " ${keep[*]} " =~ " ${stable_date} " ]]; then
    keep+=("$stable_date")
  fi

  log "R2: keeping folders: ${keep[*]}"

  for d in "${all_dates[@]}"; do
    if [[ ! " ${keep[*]} " =~ " ${d} " ]]; then
      log "R2: deleting old build folder ${PROFILE}/${d}/"
      rclone purge "r2:${R2_BUCKET}/${PROFILE}/${d}" \
        || log "Warning: R2 cleanup failed for ${PROFILE}/${d} (non-fatal)"
    fi
  done

  log "R2: cleanup complete."
}

sf_upload() {
  local label="$1"; shift
  [[ "${NO_SF}" == "true" ]] && { log "SF: skipping ${label} (--no-sf)"; return 0; }
  rsync -e ssh -rvz --progress "$@" || die "Upload of ${label} failed"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") -p <profile> [--no-sf] [--no-r2] [--verify-only] [mode]

  -p <profile>     Profile name (e.g. gnome, plasma)
  --no-sf          Skip all SourceForge uploads (or set NO_SF=true)
  --no-r2          Skip all Cloudflare R2 uploads (or set NO_R2=true)
  --verify-only    Check remote SHA-256 without uploading anything

  Modes:
    image          Base image artifacts only (default)
    iso            Signed ISO, sha256, asc, torrent
    all            Both image and ISO artifacts
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PROFILE=""
NO_SF="${NO_SF:-false}"
NO_R2="${NO_R2:-false}"
VERIFY_ONLY=false

_CLEAN_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --no-sf)       NO_SF=true ;;
    --no-r2)       NO_R2=true ;;
    --verify-only) VERIFY_ONLY=true ;;
    *)             _CLEAN_ARGS+=("$arg") ;;
  esac
done
set -- "${_CLEAN_ARGS[@]+"${_CLEAN_ARGS[@]}"}"

while getopts "p:h" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    h) usage ;;
    *) die "Invalid option. Use -h for help." ;;
  esac
done
shift $((OPTIND - 1))

MODE="${1:-image}"

[[ -z "$PROFILE" ]] && usage

if [[ "$MODE" != "image" && "$MODE" != "iso" && "$MODE" != "all" ]]; then
  die "Invalid mode: '$MODE'. Must be 'image', 'iso', or 'all'."
fi

# ---------------------------------------------------------------------------
# Resolve build date via shared helper
# ---------------------------------------------------------------------------
RESOLVED_DATE="$(resolve_build_date "$PROFILE")"
OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${RESOLVED_DATE}"

[[ -d "${OUTPUT_SUBDIR}" ]] \
  || die "Output directory ${OUTPUT_SUBDIR} does not exist. Build artifacts not found."

REMOTE_PATH="librewish@frs.sourceforge.net:/home/frs/project/shanios/${PROFILE}/"
REMOTE_SUBPATH="librewish@frs.sourceforge.net:/home/frs/project/shanios/${PROFILE}/${RESOLVED_DATE}/"
R2_SUBPATH="${PROFILE}/${RESOLVED_DATE}"
R2_PATH="${PROFILE}"

# ---------------------------------------------------------------------------
# Ensure remote dated directory exists on SourceForge
# ---------------------------------------------------------------------------
if [[ "${NO_SF}" == "false" && "${VERIFY_ONLY}" != "true" ]]; then
  log "Ensuring remote directory exists: ${REMOTE_SUBPATH}"
  ssh librewish@frs.sourceforge.net \
    "mkdir -p /home/frs/project/shanios/${PROFILE}/${RESOLVED_DATE}" \
    || log "Warning: Could not create remote directory (may already exist)"
fi

# ---------------------------------------------------------------------------
# Uploads (skipped entirely in verify-only mode)
# ---------------------------------------------------------------------------
if [[ "${VERIFY_ONLY}" != "true" ]]; then

  # --- Base image artifacts (modes: image, all) ----------------------------
  if [[ "$MODE" == "image" || "$MODE" == "all" ]]; then
    log "--- Uploading base image artifacts from ${OUTPUT_SUBDIR} ---"

    if ls "${OUTPUT_SUBDIR}"/*.zst 1>/dev/null 2>&1; then
      sf_upload "base image" \
        --exclude="flatpakfs.zst" --exclude="snapfs.zst" \
        "${OUTPUT_SUBDIR}"/*.zst "${REMOTE_SUBPATH}"
      for f in "${OUTPUT_SUBDIR}"/*.zst; do
        [[ "$f" == *flatpakfs.zst || "$f" == *snapfs.zst ]] && continue
        r2_upload "$f" "${R2_SUBPATH}"
      done
    else
      log "Warning: No .zst files found in ${OUTPUT_SUBDIR}"
    fi

    if ls "${OUTPUT_SUBDIR}"/*.zst.asc 1>/dev/null 2>&1; then
      sf_upload "base image signatures" \
        --exclude="flatpakfs.zst.asc" --exclude="snapfs.zst.asc" \
        "${OUTPUT_SUBDIR}"/*.zst.asc "${REMOTE_SUBPATH}"
      for f in "${OUTPUT_SUBDIR}"/*.zst.asc; do
        [[ "$f" == *flatpakfs.zst.asc || "$f" == *snapfs.zst.asc ]] && continue
        r2_upload "$f" "${R2_SUBPATH}"
      done
    else
      log "Warning: No .zst.asc files found in ${OUTPUT_SUBDIR}"
    fi

    if ls "${OUTPUT_SUBDIR}"/*.zst.sha256 1>/dev/null 2>&1; then
      sf_upload "base image checksums" \
        --exclude="flatpakfs.zst.sha256" --exclude="snapfs.zst.sha256" \
        "${OUTPUT_SUBDIR}"/*.zst.sha256 "${REMOTE_SUBPATH}"
      for f in "${OUTPUT_SUBDIR}"/*.zst.sha256; do
        [[ "$f" == *flatpakfs.zst.sha256 || "$f" == *snapfs.zst.sha256 ]] && continue
        r2_upload "$f" "${R2_SUBPATH}"
      done
    else
      log "Warning: No .zst.sha256 files found in ${OUTPUT_SUBDIR}"
    fi

    if [[ -f "${OUTPUT_SUBDIR}/latest.txt" ]]; then
      sf_upload "dated latest.txt" "${OUTPUT_SUBDIR}/latest.txt" "${REMOTE_SUBPATH}"
      r2_upload "${OUTPUT_SUBDIR}/latest.txt" "${R2_SUBPATH}"
    else
      log "Warning: No latest.txt found in ${OUTPUT_SUBDIR}"
    fi

    CENTRAL_LATEST="${OUTPUT_DIR}/${PROFILE}/latest.txt"
    if [[ -f "${CENTRAL_LATEST}" ]]; then
      log "Uploading central latest.txt..."
      sf_upload "central latest.txt" "${CENTRAL_LATEST}" "${REMOTE_PATH}"
      r2_upload "${CENTRAL_LATEST}" "${R2_PATH}"
    fi

    CENTRAL_STABLE="${OUTPUT_DIR}/${PROFILE}/stable.txt"
    if [[ -f "${CENTRAL_STABLE}" ]]; then
      log "Uploading central stable.txt..."
      sf_upload "central stable.txt" "${CENTRAL_STABLE}" "${REMOTE_PATH}"
      r2_upload "${CENTRAL_STABLE}" "${R2_PATH}"
    fi
  fi

  # --- ISO artifacts (modes: iso, all) -------------------------------------
  if [[ "$MODE" == "iso" || "$MODE" == "all" ]]; then
    log "--- Uploading ISO artifacts from ${OUTPUT_SUBDIR} ---"

    if ls "${OUTPUT_SUBDIR}"/signed_*.iso 1>/dev/null 2>&1; then
      sf_upload "signed ISO" "${OUTPUT_SUBDIR}"/signed_*.iso "${REMOTE_SUBPATH}"
      for f in "${OUTPUT_SUBDIR}"/signed_*.iso; do r2_upload "$f" "${R2_SUBPATH}"; done
    else
      log "Warning: No signed_*.iso files found in ${OUTPUT_SUBDIR}"
    fi

    if ls "${OUTPUT_SUBDIR}"/signed_*.iso.sha256 1>/dev/null 2>&1; then
      sf_upload "ISO checksums" "${OUTPUT_SUBDIR}"/signed_*.iso.sha256 "${REMOTE_SUBPATH}"
      for f in "${OUTPUT_SUBDIR}"/signed_*.iso.sha256; do r2_upload "$f" "${R2_SUBPATH}"; done
    else
      log "Warning: No signed_*.iso.sha256 files found in ${OUTPUT_SUBDIR}"
    fi

    if ls "${OUTPUT_SUBDIR}"/signed_*.iso.asc 1>/dev/null 2>&1; then
      sf_upload "ISO signatures" "${OUTPUT_SUBDIR}"/signed_*.iso.asc "${REMOTE_SUBPATH}"
      for f in "${OUTPUT_SUBDIR}"/signed_*.iso.asc; do r2_upload "$f" "${R2_SUBPATH}"; done
    else
      log "Warning: No signed_*.iso.asc files found in ${OUTPUT_SUBDIR}"
    fi

    if ls "${OUTPUT_SUBDIR}"/signed_*.iso.torrent 1>/dev/null 2>&1; then
      sf_upload "ISO torrents" "${OUTPUT_SUBDIR}"/signed_*.iso.torrent "${REMOTE_SUBPATH}"
      for f in "${OUTPUT_SUBDIR}"/signed_*.iso.torrent; do r2_upload "$f" "${R2_SUBPATH}"; done
    else
      log "Warning: No signed_*.iso.torrent files found in ${OUTPUT_SUBDIR}"
    fi
  fi

fi  # end uploads

# ---------------------------------------------------------------------------
# R2 cleanup (always runs unless --no-r2, even in verify-only mode)
# ---------------------------------------------------------------------------
r2_cleanup

# ---------------------------------------------------------------------------
# Post-upload SourceForge verification (base image modes only)
# ---------------------------------------------------------------------------
if [[ "${NO_SF}" == "false" && "${VERIFY_ONLY}" != "true" && "$MODE" != "iso" ]]; then
  log "Verifying uploaded base image artifact on SourceForge..."
  BASE_ZST=$(ls "${OUTPUT_SUBDIR}"/*.zst 2>/dev/null \
    | grep -v flatpakfs | grep -v snapfs | head -1 || true)

  if [[ -n "$BASE_ZST" ]]; then
    REMOTE_SHA256_URL="https://downloads.sourceforge.net/project/shanios/${PROFILE}/${RESOLVED_DATE}/$(basename "${BASE_ZST}").sha256"
    REMOTE_SHA256=$(curl -fsSL --max-time 30 --connect-timeout 10 \
      --user-agent "shanios-verify/1.0" "${REMOTE_SHA256_URL}" 2>/dev/null || true)

    if [[ -z "$REMOTE_SHA256" ]]; then
      log "Warning: Could not fetch remote .sha256 — CDN propagation may still be in progress."
    else
      LOCAL_SHA256=$(sha256sum "${BASE_ZST}" | awk '{print $1}')
      REMOTE_HASH=$(echo "$REMOTE_SHA256" | awk '{print $1}')
      if [[ "$LOCAL_SHA256" == "$REMOTE_HASH" ]]; then
        log "✅ Verification passed: remote SHA-256 matches local artifact."
      else
        log "Warning: SHA-256 mismatch — local: ${LOCAL_SHA256}, remote: ${REMOTE_HASH}."
      fi
    fi
  fi
fi

log "Upload completed successfully!"
