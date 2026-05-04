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

# Prune old dated R2 folders, keeping the 2 most recent and any folder
# pinned by latest.txt, stable.txt, or containing a signed ISO.
r2_cleanup() {
  [[ "${NO_R2}" == "true" ]] && { log "R2: skipping cleanup (--no-r2)"; return 0; }
  [[ -z "${R2_BUCKET:-}" ]]  && return 0

  log "R2: cleaning up old build folders under ${PROFILE}/ (keeping 2 latest + pinned by latest/stable + ISO folders)..."

  # Helper: extract 8-digit build date from a pointer file on R2
  _pin_from_pointer() {
    local file="$1"
    local content
    content=$(rclone cat "r2:${R2_BUCKET}/${PROFILE}/${file}" 2>/dev/null || true)
    if [[ -n "$content" ]]; then
      local date
      date=$(echo "$content" | grep -oE '[0-9]{8}' | head -n1 || true)
      if [[ -n "$date" ]]; then
        log "R2: ${file} pins build date: ${date}"
        echo "$date"
      else
        log "R2: ${file} exists but contains no 8-digit date — pin skipped."
      fi
    fi
  }

  local stable_date latest_date iso_date iso_stable_date
  stable_date="$(_pin_from_pointer stable.txt)"
  latest_date="$(_pin_from_pointer latest.txt)"
  iso_date="$(_pin_from_pointer iso-latest.txt)"
  iso_stable_date="$(_pin_from_pointer iso-stable.txt)"

  local all_dates=()
  while IFS= read -r folder; do
    folder="${folder// /}"
    [[ "$folder" =~ ^[0-9]{8}$ ]] && all_dates+=("$folder")
  done < <(rclone lsd "r2:${R2_BUCKET}/${PROFILE}/" 2>/dev/null | awk '{print $NF}' | sort -r)

  if [[ ${#all_dates[@]} -eq 0 ]]; then
    log "R2: no dated build folders found, nothing to clean up."
    return 0
  fi

  # Deduplicating keep-list helper
  local keep=()
  _add_keep() {
    local d="$1"
    [[ -z "$d" ]] && return
    [[ " ${keep[*]:-} " =~ (^|[[:space:]])"${d}"([[:space:]]|$) ]] && return
    keep+=("$d")
  }

  # Always keep the 2 most recent dated folders
  _add_keep "${all_dates[0]:-}"
  _add_keep "${all_dates[1]:-}"

  # Pin folders referenced by pointer files
  _add_keep "$stable_date"
  _add_keep "$latest_date"
  _add_keep "$iso_date"
  _add_keep "$iso_stable_date"

  log "R2: keeping folders: ${keep[*]:-}"

  for d in "${all_dates[@]}"; do
    if [[ ! " ${keep[*]:-} " =~ (^|[[:space:]])"${d}"([[:space:]]|$) ]]; then
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

check_dependencies_upload
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

    # Write iso-latest.txt so r2_cleanup can pin this dated folder even when
    # it differs from the base-image latest.txt (e.g. built via iso-only).
    ISO_LATEST_TXT="${OUTPUT_DIR}/${PROFILE}/iso-latest.txt"
    echo "${RESOLVED_DATE}" > "${ISO_LATEST_TXT}" \
      || log "Warning: Failed to write iso-latest.txt (R2 cleanup may not pin ISO folder)"
    log "Uploading iso-latest.txt (points to ${RESOLVED_DATE})..."
    sf_upload "iso-latest.txt" "${ISO_LATEST_TXT}" "${REMOTE_PATH}"
    r2_upload "${ISO_LATEST_TXT}" "${R2_PATH}"
  fi

fi  # end uploads

# ---------------------------------------------------------------------------
# R2 cleanup (skipped in verify-only mode — that mode must be read-only)
# ---------------------------------------------------------------------------
if [[ "${VERIFY_ONLY}" != "true" ]]; then
  r2_cleanup
fi

# ---------------------------------------------------------------------------
# Post-upload SourceForge verification (base image modes only)
# ---------------------------------------------------------------------------
if [[ "${NO_SF}" == "false" && "${VERIFY_ONLY}" != "true" && "$MODE" != "iso" ]]; then
  log "Verifying uploaded base image artifact on SourceForge..."
  BASE_ZST=""
  for _f in "${OUTPUT_SUBDIR}"/*.zst; do
    [[ "$_f" == *flatpakfs.zst || "$_f" == *snapfs.zst ]] && continue
    [[ -f "$_f" ]] && { BASE_ZST="$_f"; break; }
  done

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
