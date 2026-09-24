#!/usr/bin/env bash
# promote-stable.sh – Promote current latest release to stable
#
# This script downloads the current latest.txt from SourceForge,
# uses it to create stable.txt locally, and uploads it back to
# SourceForge and mirrors it to Cloudflare R2.
#
# Usage:
#   ./promote-stable.sh -p <profile> [--only=image|iso] [--no-sf] [--no-r2] [--expect=<file.zst>] [--expect-iso=<YYYYMMDD>]
#
# --only=image: latest.txt -> stable.txt only. --only=iso: iso-latest.txt ->
# iso-stable.txt only. They are separate artifacts (built on different days)
# with separate gate results, so one failing must not hold back the other.
# Default: both.
#
# --expect: promote only if latest.txt still names exactly this artifact —
# the one shani-testbed's `gate` just tested (its gate-<profile>.passed).
# A build published between the gate and the promotion is refused, never
# promoted untested. --expect-iso does the same for iso-latest.txt (the
# ISO folder the gate fresh-installed from).
#
set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# ---------------------------------------------------------------------------
# R2 mirror helper
# Mirrors a single file to Cloudflare R2 under the given remote subpath.
# Silently skipped if R2_BUCKET is not set or --no-r2 was passed.
# Failures are non-fatal — SourceForge remains the authoritative upload.
# ---------------------------------------------------------------------------
r2_upload() {
  local src="$1"
  local dest_subpath="$2"

  [[ "${NO_R2}" == "true" ]] && { log "R2: skipping $(basename "${src}") (--no-r2)"; return 0; }
  [[ -z "${R2_BUCKET:-}" ]]  && return 0

  log "R2: mirroring $(basename "${src}") → r2:${R2_BUCKET}/${dest_subpath}"
  # With --no-sf, R2 is the only destination: a failed copy there means
  # nothing was promoted, so it must not end in "SUCCESS".
  if ! rclone copy --progress "${src}" "r2:${R2_BUCKET}/${dest_subpath}"; then
    [[ "${NO_SF}" == "true" ]] && die "R2 upload of $(basename "${src}") failed and SourceForge is skipped (--no-sf) — nothing was promoted."
    log "Warning: R2 mirror failed for ${src} (SourceForge upload unaffected)"
  fi
}

usage() {
  echo "Usage: $(basename "$0") -p <profile> [--no-sf] [--no-r2] [--expect=<file.zst>]"
  echo "  -p <profile>         Profile name (e.g. gnome, plasma)"
  echo "  --no-sf              Skip SourceForge download, verification, and upload"
  echo "  --no-r2              Skip Cloudflare R2 verification and mirror"
  echo "  --expect=<file.zst>  Refuse unless latest.txt names exactly this (tested) artifact"
  echo "  --expect-iso=<date>  Refuse unless iso-latest.txt names exactly this (tested) ISO folder"
  echo "  --only=image|iso     Promote only the base image (stable.txt) or only the ISO (iso-stable.txt)"
  echo ""
  echo "This script will:"
  echo "  1. Download the current latest.txt from SourceForge (skipped with --no-sf)"
  echo "  2. Create stable.txt with the same content locally"
  echo "  2b. Promote iso-latest.txt → iso-stable.txt (if available)"
  echo "  3. Verify artifact + signature exist before promoting"
  echo "  4. Upload stable.txt (and iso-stable.txt if present) to SourceForge (skipped with --no-sf)"
  echo "  5. Mirror stable.txt (and iso-stable.txt if present) to Cloudflare R2 (skipped with --no-r2)"
  exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PROFILE=""
NO_SF="${NO_SF:-false}"
NO_R2="${NO_R2:-false}"
EXPECT="${EXPECT:-}"
EXPECT_ISO="${EXPECT_ISO:-}"
ONLY="${ONLY:-}"

_CLEAN_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --no-sf) NO_SF=true ;;
    --no-r2) NO_R2=true ;;
    --expect=*) EXPECT="${arg#--expect=}" ;;
    --expect-iso=*) EXPECT_ISO="${arg#--expect-iso=}" ;;
    --only=*) ONLY="${arg#--only=}" ;;
    *)       _CLEAN_ARGS+=("$arg") ;;
  esac
done
set -- "${_CLEAN_ARGS[@]+"${_CLEAN_ARGS[@]}"}"

while getopts "p:h" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    h) usage ;;
    *) die "Invalid option. Use -h for help.";;
  esac
done
shift $((OPTIND - 1))

[[ -z "$PROFILE" ]] && usage
case "${ONLY}" in
  "")    PROMOTE_IMAGE=true;  PROMOTE_ISO=true ;;
  image) PROMOTE_IMAGE=true;  PROMOTE_ISO=false ;;
  iso)   PROMOTE_IMAGE=false; PROMOTE_ISO=true ;;
  *)     die "--only must be image or iso (got '${ONLY}')" ;;
esac

# Guard: nothing to do if both destinations are skipped
if [[ "${NO_SF}" == "true" && "${NO_R2}" == "true" ]]; then
  die "Both --no-sf and --no-r2 specified — nothing to promote."
fi

PROJECT_NAME="shanios"
PROFILE_DIR="${OUTPUT_DIR}/${PROFILE}"
LATEST_TXT="${PROFILE_DIR}/latest.txt"

check_dependencies_upload
STABLE_TXT="${PROFILE_DIR}/stable.txt"
REMOTE_PATH="librewish@frs.sourceforge.net:/home/frs/project/shanios/${PROFILE}/"

# Cloudflare R2 configuration
# R2_BUCKET: rclone remote bucket name (required for rclone operations)
# R2_BASE_URL: public HTTP base URL for the bucket (used for HTTP verification)
# Both can be overridden by environment variables.
R2_BUCKET="${R2_BUCKET:-shanios}"
R2_BASE_URL="${R2_BASE_URL:-https://downloads.shani.dev}"

# Ensure profile directory exists
mkdir -p "${PROFILE_DIR}"

if [[ "${PROMOTE_IMAGE}" == "true" ]]; then
# ---------------------------------------------------------------------------
# Step 1: Obtain latest.txt
#   --no-sf        → fetch from R2
#   --no-r2        → fetch from SourceForge
#   --no-sf --no-r2 → use local file
#   (neither)      → fetch from R2; fall back to SourceForge on failure
# ---------------------------------------------------------------------------
# CURL_RETRIES, CURL_RETRY_DELAY, NETWORK_TIMEOUT, NETWORK_CONNECT_TIMEOUT
# are sourced from config.sh — do not redefine here.

_fetch_from_r2() {
  if [[ -n "${R2_BUCKET:-}" ]]; then
    log "Step 1: Fetching latest.txt from R2 (rclone)..."
    if rclone copy "r2:${R2_BUCKET}/${PROFILE}/latest.txt" "${PROFILE_DIR}" 2>/dev/null \
        && [[ -s "${LATEST_TXT}" ]]; then
      return 0
    fi
  fi
  if [[ -n "${R2_BASE_URL:-}" ]]; then
    log "Step 1: Fetching latest.txt from R2 (HTTP)..."
    if curl -fsSL \
        --retry "$CURL_RETRIES" --retry-delay "$CURL_RETRY_DELAY" \
        --max-time "$NETWORK_TIMEOUT" --connect-timeout "$NETWORK_CONNECT_TIMEOUT" \
        --output "${LATEST_TXT}" \
        "${R2_BASE_URL}/${PROFILE}/latest.txt" 2>/dev/null \
        && [[ -s "${LATEST_TXT}" ]]; then
      return 0
    fi
  fi
  return 1
}

_fetch_from_sf() {
  log "Step 1: Fetching latest.txt from SourceForge..."
  local url="https://sourceforge.net/projects/${PROJECT_NAME}/files/${PROFILE}/latest.txt/download"
  curl -fsSL \
    --retry "$CURL_RETRIES" --retry-delay "$CURL_RETRY_DELAY" \
    --max-time "$NETWORK_TIMEOUT" --connect-timeout "$NETWORK_CONNECT_TIMEOUT" \
    --user-agent "shanios-promote/1.0" \
    --output "${LATEST_TXT}" \
    "${url}" \
    && [[ -s "${LATEST_TXT}" ]] && return 0
  return 1
}

if [[ "${NO_SF}" == "true" && "${NO_R2}" == "true" ]]; then
  # Both skipped — use local
  log "Step 1: Both remotes skipped (--no-sf --no-r2) — using local latest.txt..."
  [[ -s "${LATEST_TXT}" ]] || die "No local latest.txt found at ${LATEST_TXT}."

elif [[ "${NO_SF}" == "true" ]]; then
  # SF skipped — R2 only, no further fallback
  _fetch_from_r2 || die "Failed to fetch latest.txt from R2 (--no-sf is set, no fallback)."

elif [[ "${NO_R2}" == "true" ]]; then
  # R2 skipped — SF only, no further fallback
  _fetch_from_sf || die "Failed to fetch latest.txt from SourceForge (--no-r2 is set, no fallback)."

else
  # Default: try R2, fall back to SF
  _fetch_from_r2 || {
    log "Warning: R2 fetch failed — falling back to SourceForge."
    _fetch_from_sf || die "Failed to fetch latest.txt from both R2 and SourceForge."
  }
fi

log "Step 1: latest.txt obtained successfully."

# Verify the file has content
if [[ ! -s "${LATEST_TXT}" ]]; then
  die "latest.txt is empty: ${LATEST_TXT}"
fi

LATEST_RELEASE=$(cat "${LATEST_TXT}")
log "Current latest release: ${LATEST_RELEASE}"

# ---------------------------------------------------------------------------
# Step 2: Canonicalize the artifact name — image filenames carry NO channel
# segment. build-base-image.sh names artifacts
# ${OS_NAME}-${BUILD_DATE}-${PROFILE}.zst (e.g. shanios-20260918-gnome.zst);
# which channel a build belongs to is tracked only by the pointer files
# (latest.txt / <channel>.txt). A channel-qualified name in latest.txt
# (legacy output from the branch-qualified-filename era, e.g.
# shanios-20260918-stable-gnome.zst) would make every verification URL below
# 404, because no such artifact is published — normalize it to the canonical
# name the pipeline actually ships. Anything that is not a shanios artifact
# name at all is a hard error.
# ---------------------------------------------------------------------------
# "|| true" keeps the errexit + pipefail combination from aborting the script
# silently on a date-less name — the die below must be the one to report it.
BUILD_DATE_DIR=$(echo "${LATEST_RELEASE}" | grep -oE '[0-9]{8}' | head -1 || true)
if [[ -z "$BUILD_DATE_DIR" ]]; then
  die "Could not extract build date from latest release filename: ${LATEST_RELEASE}"
fi

CANONICAL_IMAGE="${OS_NAME}-${BUILD_DATE_DIR}-${PROFILE}.zst"
if [[ "${LATEST_RELEASE}" != "${CANONICAL_IMAGE}" ]]; then
  if [[ "${LATEST_RELEASE}" =~ ^${OS_NAME}-[0-9]{8}-[a-z0-9_-]+\.zst$ ]]; then
    log "latest.txt names ${LATEST_RELEASE} — channel-qualified/non-canonical; normalizing to ${CANONICAL_IMAGE} (the channel lives in pointer files, not image names)."
    LATEST_RELEASE="${CANONICAL_IMAGE}"
    # Keep the local pointer file in sync so the stable pointer (Step 3)
    # publishes the canonical name, not the legacy channel-qualified one.
    printf '%s\n' "${LATEST_RELEASE}" > "${LATEST_TXT}"
  else
    die "latest.txt does not name a valid shanios artifact: ${LATEST_RELEASE}"
  fi
fi

if [[ -n "${EXPECT}" && "${LATEST_RELEASE}" != "${EXPECT}" ]]; then
  die "latest.txt names ${LATEST_RELEASE}, but the tested artifact is ${EXPECT} — refusing to promote an untested build."
fi
if [[ -n "${EXPECT}" ]]; then log "latest.txt matches the tested artifact (${EXPECT})."; fi

# SourceForge verification — artifact + every sidecar that upload.sh ships
# The package list is named after the image WITHOUT .zst
# (<os>-<date>-<profile>.packages.txt, build-base-image.sh / validate-image.sh);
# checking "<image>.zst.packages.txt" made every promotion abort on a 404.
RELEASE_FILES=("${LATEST_RELEASE}" "${LATEST_RELEASE}.asc" "${LATEST_RELEASE}.sha256" "${LATEST_RELEASE%.zst}.packages.txt")
if [[ "${NO_SF}" == "false" ]]; then
  log "Verifying artifact on SourceForge..."
  SF_BASE="https://downloads.sourceforge.net/project/shanios/${PROFILE}/${BUILD_DATE_DIR}"
  # Checksum + signature are mandatory; the resolved package list is the
  # reviewable ground-truth of what shipped, so it must be present too.
  for f in "${RELEASE_FILES[@]}"; do
    if ! curl -fsSL --head --max-time 20 --connect-timeout "$NETWORK_CONNECT_TIMEOUT" "${SF_BASE}/${f}" >/dev/null 2>&1; then
      die "Sidecar not reachable on SourceForge: ${SF_BASE}/${f} — aborting promotion."
    fi
  done
  log "SourceForge: artifact + .asc + .sha256 + .packages.txt OK."
else
  log "Skipping SourceForge artifact verification (--no-sf)."
fi

# R2 verification — via HTTP (R2_BASE_URL) or rclone (R2_BUCKET), whichever is configured
if [[ "${NO_R2}" == "false" ]]; then
  if [[ -n "${R2_BASE_URL:-}" ]]; then
    log "Verifying artifact on R2 (HTTP)..."
    R2_BASE="${R2_BASE_URL}/${PROFILE}/${BUILD_DATE_DIR}"
    for f in "${RELEASE_FILES[@]}"; do
      if ! curl -fsSL --head --max-time 20 --connect-timeout "$NETWORK_CONNECT_TIMEOUT" "${R2_BASE}/${f}" >/dev/null 2>&1; then
        die "Sidecar not reachable on R2: ${R2_BASE}/${f} — aborting promotion."
      fi
    done
    log "R2: artifact + .asc + .sha256 + .packages.txt OK."

  elif [[ -n "${R2_BUCKET:-}" ]]; then
    log "Verifying artifact on R2 (rclone)..."
    for f in "${RELEASE_FILES[@]}"; do
      if ! rclone lsf "r2:${R2_BUCKET}/${PROFILE}/${BUILD_DATE_DIR}/${f}" >/dev/null 2>&1; then
        die "Sidecar not found on R2: r2:${R2_BUCKET}/${PROFILE}/${BUILD_DATE_DIR}/${f} — aborting promotion."
      fi
    done
    log "R2: artifact + .asc + .sha256 + .packages.txt OK."

  else
    die "R2 verification required but neither R2_BASE_URL nor R2_BUCKET is set — aborting promotion."
  fi
else
  log "Skipping R2 artifact verification (--no-r2)."
fi

# ---------------------------------------------------------------------------
# Step 3: Create stable.txt locally
# ---------------------------------------------------------------------------
log "Step 3: Creating stable.txt locally..."
cp "${LATEST_TXT}" "${STABLE_TXT}" || die "Failed to create stable.txt"
log "Created stable.txt with content: $(cat "${STABLE_TXT}")"
else
  log "Base image: not promoted (--only=iso) — stable.txt untouched."
fi

# Also promote iso-latest.txt → iso-stable.txt if it exists.
# iso-latest.txt may point to a different dated folder than latest.txt
# (e.g. when the ISO was built separately via iso-only on a different day).
ISO_LATEST_TXT="${PROFILE_DIR}/iso-latest.txt"
ISO_STABLE_TXT="${PROFILE_DIR}/iso-stable.txt"
if [[ "${PROMOTE_ISO}" != "true" ]]; then
  log "ISO: not promoted (--only=image) — iso-stable.txt untouched."
else
  # Always from the remotes, like latest.txt in step 1 (a local copy can be
  # stale): rclone, then public R2 over HTTP, then SourceForge. The local
  # file only when both remotes are skipped.
  rm -f "${ISO_STABLE_TXT}"
  _fetched_iso=false
  if [[ "${NO_SF}" == "true" && "${NO_R2}" == "true" ]]; then
    [[ -s "${ISO_LATEST_TXT}" ]] && _fetched_iso=true
  else
    rm -f "${ISO_LATEST_TXT}"
    if [[ "${NO_R2}" == "false" && -n "${R2_BUCKET:-}" ]] && command -v rclone >/dev/null 2>&1 \
        && rclone copy "r2:${R2_BUCKET}/${PROFILE}/iso-latest.txt" "${PROFILE_DIR}" 2>/dev/null \
        && [[ -s "${ISO_LATEST_TXT}" ]]; then
      _fetched_iso=true
    fi
    if [[ "${_fetched_iso}" == "false" && "${NO_R2}" == "false" && -n "${R2_BASE_URL:-}" ]] \
        && curl -fsSL --retry "$CURL_RETRIES" --retry-delay "$CURL_RETRY_DELAY" \
             --max-time "$NETWORK_TIMEOUT" --connect-timeout "$NETWORK_CONNECT_TIMEOUT" \
             --output "${ISO_LATEST_TXT}" "${R2_BASE_URL}/${PROFILE}/iso-latest.txt" 2>/dev/null \
        && [[ -s "${ISO_LATEST_TXT}" ]]; then
      _fetched_iso=true
    fi
    if [[ "${_fetched_iso}" == "false" && "${NO_SF}" == "false" ]]; then
      curl -fsSL \
        --retry "$CURL_RETRIES" --retry-delay "$CURL_RETRY_DELAY" \
        --max-time "$NETWORK_TIMEOUT" --connect-timeout "$NETWORK_CONNECT_TIMEOUT" \
        --user-agent "shanios-promote/1.0" \
        --output "${ISO_LATEST_TXT}" \
        "https://sourceforge.net/projects/${PROJECT_NAME}/files/${PROFILE}/iso-latest.txt/download" \
        2>/dev/null && [[ -s "${ISO_LATEST_TXT}" ]] && _fetched_iso=true || true
    fi
  fi
  if [[ "${_fetched_iso}" == "true" ]]; then
    cp "${ISO_LATEST_TXT}" "${ISO_STABLE_TXT}" || die "Failed to create iso-stable.txt"
    log "Created iso-stable.txt with content: $(cat "${ISO_STABLE_TXT}")"
  else
    log "Warning: iso-latest.txt not found on any remote — iso-stable.txt not promoted."
    log "         Run 'build.sh iso-only' and upload before promoting stable if you want ISO pinning."
  fi
fi

if [[ "${PROMOTE_ISO}" == "true" && "${ONLY}" == "iso" && ! -s "${ISO_STABLE_TXT}" ]]; then
  die "--only=iso but no iso-latest.txt could be obtained — nothing to promote."
fi
if [[ "${PROMOTE_ISO}" == "true" && -s "${ISO_STABLE_TXT}" && "${NO_R2}" == "false" && -n "${R2_BASE_URL:-}" ]]; then
  # the ISO folder iso-stable.txt will name must really hold a signed ISO
  _iso_d="$(tr -d '[:space:]' < "${ISO_STABLE_TXT}")"
  _iso_f="signed_${OS_NAME}-${PROFILE}-${_iso_d:0:4}.${_iso_d:4:2}.${_iso_d:6:2}-x86_64.iso"
  for f in "${_iso_f}" "${_iso_f}.sha256" "${_iso_f}.asc"; do
    curl -fsSL --head --max-time 20 --connect-timeout "$NETWORK_CONNECT_TIMEOUT" "${R2_BASE_URL}/${PROFILE}/${_iso_d}/${f}" >/dev/null 2>&1 \
      || die "ISO file not reachable on R2: ${R2_BASE_URL}/${PROFILE}/${_iso_d}/${f} — aborting ISO promotion."
  done
  log "R2: ${_iso_f} + .sha256 + .asc OK."
fi
if [[ "${PROMOTE_ISO}" == "true" && -n "${EXPECT_ISO}" ]]; then
  _iso_latest="$(tr -d '[:space:]' < "${ISO_LATEST_TXT}" 2>/dev/null || true)"
  [[ "${_iso_latest}" == "${EXPECT_ISO}" ]] \
    || die "iso-latest.txt names '${_iso_latest:-nothing}', but the tested ISO is ${EXPECT_ISO} — refusing to promote an untested ISO."
  log "iso-latest.txt matches the tested ISO (${EXPECT_ISO})."
fi

# ---------------------------------------------------------------------------
# Step 4: Upload stable.txt to SourceForge
# ---------------------------------------------------------------------------
if [[ "${NO_SF}" == "false" ]]; then
  log "Step 4: Uploading stable.txt to SourceForge..."
  log "Uploading to: ${REMOTE_PATH}"
  if [[ "${PROMOTE_IMAGE}" == "true" ]]; then
    rsync -e ssh -avz --progress "${STABLE_TXT}" "${REMOTE_PATH}" \
      || die "Upload of stable.txt failed"
  fi
  if [[ "${PROMOTE_ISO}" == "true" && -s "${ISO_STABLE_TXT}" ]]; then
    rsync -e ssh -avz --progress "${ISO_STABLE_TXT}" "${REMOTE_PATH}" \
      || die "Upload of iso-stable.txt failed"
  fi
else
  log "Step 4: Skipping SourceForge upload (--no-sf)."
fi

# ---------------------------------------------------------------------------
# Step 5: Mirror stable.txt to Cloudflare R2
# ---------------------------------------------------------------------------
log "Step 5: Mirroring stable.txt to Cloudflare R2..."
if [[ "${PROMOTE_IMAGE}" == "true" ]]; then r2_upload "${STABLE_TXT}" "${PROFILE}"; fi
if [[ "${PROMOTE_ISO}" == "true" && -s "${ISO_STABLE_TXT}" ]]; then
  r2_upload "${ISO_STABLE_TXT}" "${PROFILE}"
fi

log ""
log "========================================="
log "SUCCESS: Promoted to stable (${ONLY:-image + iso})"
log "========================================="
if [[ "${PROMOTE_IMAGE}" == "true" ]]; then log "Image:   ${LATEST_RELEASE}"; fi
if [[ "${PROMOTE_ISO}" == "true" && -s "${ISO_STABLE_TXT}" ]]; then log "ISO:     $(cat "${ISO_STABLE_TXT}")"; fi
log "Profile: ${PROFILE}"
# Use if/then instead of [[ ]] && log — when the condition is false the [[ ]]
# returns exit 1, and if it is the last statement it becomes the script exit
# code, making CI report failure despite a successful promotion.
if [[ "${NO_SF}" == "true" ]]; then log "Note: SourceForge was skipped (--no-sf)"; fi
if [[ "${NO_R2}" == "true" ]]; then log "Note: Cloudflare R2 was skipped (--no-r2)"; fi
exit 0
