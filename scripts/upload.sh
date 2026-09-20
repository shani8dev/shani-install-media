#!/usr/bin/env bash
# upload.sh – Upload build artifacts to SourceForge FRS and mirror to Cloudflare R2
#
# Uploads:
#   image  *.zst, *.zst.sha256, *.zst.asc, latest.txt, central latest/stable.txt
#   iso    signed_*.iso, .sha256, .asc, .torrent
#   all    both of the above
#
# All uploads are mirrored to Cloudflare R2 if R2_BUCKET is set.
# After upload, old dated folders are pruned on both SourceForge FRS and
# Cloudflare R2 (keeps 2 latest + latest/stable/ISO pin).
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

# Prune old dated SourceForge FRS folders, keeping the 2 most recent and
# any folder pinned by latest.txt, stable.txt, iso-latest.txt, or
# iso-stable.txt. Mirrors r2_cleanup above, but the SF restricted shell
# blocks rm/ls/cat, so listing uses sftp, pins are read from the public CDN,
# and deletion is rsync --delete from an empty local dir + sftp rmdir.
sf_cleanup() {
  [[ "${NO_SF}" == "true" ]] && { log "SF: skipping cleanup (--no-sf)"; return 0; }

  log "SF: cleaning up old build folders under ${PROFILE}/ (keeping 2 latest + pinned by latest/stable + ISO folders)..."

  # Helper: extract 8-digit build date from a pointer file on the SF CDN.
  _sf_pin_from_pointer() {
    local file="$1"
    local content
    content=$(curl -fsSL --max-time 20 \
      "https://downloads.sourceforge.net/project/shanios/${PROFILE}/${file}" 2>/dev/null || true)
    if [[ -n "$content" ]]; then
      local date
      date=$(echo "$content" | grep -oE '[0-9]{8}' | head -n1 || true)
      if [[ -n "$date" ]]; then
        log "SF: ${file} pins build date: ${date}"
        echo "$date"
      else
        log "SF: ${file} exists but contains no 8-digit date — pin skipped."
      fi
    fi
  }

  local stable_date latest_date iso_date iso_stable_date
  stable_date="$(_sf_pin_from_pointer stable.txt)"
  latest_date="$(_sf_pin_from_pointer latest.txt)"
  iso_date="$(_sf_pin_from_pointer iso-latest.txt)"
  iso_stable_date="$(_sf_pin_from_pointer iso-stable.txt)"

  # List dated build folders on SourceForge via sftp (the restricted shell
  # blocks ls). sftp emits "sftp> " prompts and banner lines — keep only
  # pure YYYYMMDD folder names.
  local all_dates=()
  while IFS= read -r folder; do
    folder="${folder// /}"
    [[ "$folder" =~ ^[0-9]{8}$ ]] && all_dates+=("$folder")
  done < <(timeout 60 sftp -b - -o ConnectTimeout=15 -o BatchMode=yes \
      librewish@frs.sourceforge.net <<SFEOF 2>/dev/null \
      | grep -v '^sftp>' | awk '{print $NF}' | grep -E '^[0-9]{8}$' | sort -r || true
ls -la /home/frs/project/shanios/${PROFILE}/
exit
SFEOF
)

  if [[ ${#all_dates[@]} -eq 0 ]]; then
    log "SF: no dated build folders found, nothing to clean up."
    return 0
  fi

  # Deduplicating keep-list helper
  local keep=()
  _sf_add_keep() {
    local d="$1"
    [[ -z "$d" ]] && return
    [[ " ${keep[*]:-} " =~ (^|[[:space:]])"${d}"([[:space:]]|$) ]] && return
    keep+=("$d")
  }

  # Always keep the 2 most recent dated folders
  _sf_add_keep "${all_dates[0]:-}"
  _sf_add_keep "${all_dates[1]:-}"

  # Pin folders referenced by pointer files
  _sf_add_keep "$stable_date"
  _sf_add_keep "$latest_date"
  _sf_add_keep "$iso_date"
  _sf_add_keep "$iso_stable_date"

  log "SF: keeping folders: ${keep[*]:-}"

  # Deleting a folder needs an empty local dir for rsync --delete to drain
  # the remote tree; the empty shell of the dated folder is then removed
  # with sftp rmdir.
  local empty_dir
  empty_dir="$(mktemp -d)"
  for d in "${all_dates[@]}"; do
    if [[ ! " ${keep[*]:-} " =~ (^|[[:space:]])"${d}"([[:space:]]|$) ]]; then
      log "SF: deleting old build folder ${PROFILE}/${d}/"
      if ! rsync -r --delete -e "ssh -o ConnectTimeout=15" \
          "${empty_dir}/" "librewish@frs.sourceforge.net:/home/frs/project/shanios/${PROFILE}/${d}/" 2>/dev/null; then
        log "Warning: SF cleanup failed to drain ${PROFILE}/${d} (non-fatal)"
      else
        timeout 60 sftp -b - -o ConnectTimeout=15 -o BatchMode=yes \
            librewish@frs.sourceforge.net <<SFEOF >/dev/null 2>&1 || true
rmdir /home/frs/project/shanios/${PROFILE}/${d}
exit
SFEOF
      fi
    fi
  done
  rm -rf "${empty_dir}"

  log "SF: cleanup complete."
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

    if ls "${OUTPUT_SUBDIR}"/*.packages.txt 1>/dev/null 2>&1; then
      sf_upload "resolved package list" "${OUTPUT_SUBDIR}"/*.packages.txt "${REMOTE_SUBPATH}"
      for f in "${OUTPUT_SUBDIR}"/*.packages.txt; do r2_upload "$f" "${R2_SUBPATH}"; done
    else
      log "Warning: No .packages.txt files found in ${OUTPUT_SUBDIR}"
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

    # .zsync control file — optional, only present if zsyncmake2 was
    # available at build time (see build-base-image.sh). Not finding one is
    # not a warning-worthy condition on its own.
    if ls "${OUTPUT_SUBDIR}"/*.zst.zsync 1>/dev/null 2>&1; then
      sf_upload "base image zsync control file" \
        --exclude="flatpakfs.zst.zsync" --exclude="snapfs.zst.zsync" \
        "${OUTPUT_SUBDIR}"/*.zst.zsync "${REMOTE_SUBPATH}"
      for f in "${OUTPUT_SUBDIR}"/*.zst.zsync; do
        [[ "$f" == *flatpakfs.zst.zsync || "$f" == *snapfs.zst.zsync ]] && continue
        r2_upload "$f" "${R2_SUBPATH}"
      done
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
# Cleanup (skipped in verify-only mode — that mode must be read-only)
# ---------------------------------------------------------------------------
if [[ "${VERIFY_ONLY}" != "true" ]]; then
  r2_cleanup
  sf_cleanup
fi

# ---------------------------------------------------------------------------
# Remote SHA-256 verification against the SourceForge CDN
# ---------------------------------------------------------------------------
# verify_remote_sha256 <label> <local_file> [hard]
#   Fetches <local_file>.sha256 from the SF CDN for PROFILE/RESOLVED_DATE
#   and compares it against the local file's hash. Returns 0 on verified,
#   1 if the sidecar could not be fetched (CDN lag), 2 on mismatch.
#   With `hard`, a mismatch is fatal via die() (verify-only gate mode).
verify_remote_sha256() {
  local label="$1" local_file="$2" hard="${3:-}"
  local base remote_url remote_sha local_sha remote_hash attempt

  base="$(basename "${local_file}")"
  remote_url="https://downloads.sourceforge.net/project/shanios/${PROFILE}/${RESOLVED_DATE}/${base}.sha256"

  remote_sha=""
  for attempt in 1 2 3; do
    remote_sha=$(curl -fsSL --max-time 30 --connect-timeout 10 \
      --user-agent "shanios-verify/1.0" "${remote_url}" 2>/dev/null || true)
    [[ -n "$remote_sha" ]] && break
    sleep 3
  done

  if [[ -z "$remote_sha" ]]; then
    log "Warning: Could not fetch remote .sha256 for ${label} — CDN propagation may still be in progress."
    return 1
  fi

  local_sha=$(sha256sum "${local_file}" | awk '{print $1}')
  remote_hash=$(echo "$remote_sha" | awk '{print $1}')
  if [[ "$local_sha" == "$remote_hash" ]]; then
    log "✅ Verification passed: remote SHA-256 for ${label} matches local artifact."
    return 0
  fi

  if [[ "$hard" == "hard" ]]; then
    die "Verification FAILED: SHA-256 mismatch for ${label} — local: ${local_sha}, remote: ${remote_hash}."
  fi
  log "Warning: SHA-256 mismatch for ${label} — local: ${local_sha}, remote: ${remote_hash}."
  return 2
}

# ---------------------------------------------------------------------------
# Remote verification (also the whole body of --verify-only, which skips
# uploads and cleanup above and lands here to compare instead)
# ---------------------------------------------------------------------------
if [[ "${NO_SF}" == "false" ]]; then
  _verify_hard=""
  [[ "${VERIFY_ONLY}" == "true" ]] && _verify_hard="hard"

  if [[ "$MODE" == "image" || "$MODE" == "all" ]]; then
    BASE_ZST=""
    for _f in "${OUTPUT_SUBDIR}"/*.zst; do
      [[ "$_f" == *flatpakfs.zst || "$_f" == *snapfs.zst ]] && continue
      [[ -f "$_f" ]] && { BASE_ZST="$_f"; break; }
    done

    if [[ -n "$BASE_ZST" ]]; then
      verify_remote_sha256 "base image" "${BASE_ZST}" "$_verify_hard" || true
    else
      log "Warning: No base image .zst found in ${OUTPUT_SUBDIR} to verify."
    fi
  fi

  if [[ "$MODE" == "iso" || "$MODE" == "all" ]]; then
    for _iso in "${OUTPUT_SUBDIR}"/signed_*.iso; do
      [[ -f "$_iso" ]] && verify_remote_sha256 "signed ISO" "$_iso" "$_verify_hard" || true
    done
  fi
fi

log "Upload completed successfully!"
