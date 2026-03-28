#!/usr/bin/env bash
# promote-stable.sh – Promote current latest release to stable
#
# This script downloads the current latest.txt from SourceForge,
# uses it to create stable.txt locally, and uploads it back to
# SourceForge and mirrors it to Cloudflare R2.
#
# Usage:
#   ./promote-stable.sh -p <profile> [--no-sf] [--no-r2]
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
  rclone copy --progress "${src}" "r2:${R2_BUCKET}/${dest_subpath}" \
    || log "Warning: R2 mirror failed for ${src} (SourceForge upload unaffected)"
}

usage() {
  echo "Usage: $(basename "$0") -p <profile> [--no-sf] [--no-r2]"
  echo "  -p <profile>         Profile name (e.g. gnome, plasma)"
  echo "  --no-sf              Skip SourceForge download, verification, and upload"
  echo "  --no-r2              Skip Cloudflare R2 verification and mirror"
  echo ""
  echo "This script will:"
  echo "  1. Download the current latest.txt from SourceForge (skipped with --no-sf)"
  echo "  2. Create stable.txt with the same content locally"
  echo "  3. Verify artifact + signature exist before promoting"
  echo "  4. Upload stable.txt to SourceForge (skipped with --no-sf)"
  echo "  5. Mirror stable.txt to Cloudflare R2 (skipped with --no-r2)"
  exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PROFILE=""
NO_SF="${NO_SF:-false}"
NO_R2="${NO_R2:-false}"

_CLEAN_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --no-sf) NO_SF=true ;;
    --no-r2) NO_R2=true ;;
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

# Guard: nothing to do if both destinations are skipped
if [[ "${NO_SF}" == "true" && "${NO_R2}" == "true" ]]; then
  die "Both --no-sf and --no-r2 specified — nothing to promote."
fi

PROJECT_NAME="shanios"
PROFILE_DIR="${OUTPUT_DIR}/${PROFILE}"
LATEST_TXT="${PROFILE_DIR}/latest.txt"
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

# ---------------------------------------------------------------------------
# Step 1: Obtain latest.txt
#   --no-sf        → fetch from R2
#   --no-r2        → fetch from SourceForge
#   --no-sf --no-r2 → use local file
#   (neither)      → fetch from R2; fall back to SourceForge on failure
# ---------------------------------------------------------------------------
CURL_RETRIES=3
CURL_RETRY_DELAY=2
NETWORK_TIMEOUT=30

_fetch_from_r2() {
  if [[ -n "${R2_BUCKET:-}" ]]; then
    log "Step 1: Fetching latest.txt from R2 (rclone)..."
    rclone copy "r2:${R2_BUCKET}/${PROFILE}/latest.txt" "${PROFILE_DIR}" 2>/dev/null \
      && [[ -s "${LATEST_TXT}" ]] && return 0
  fi
  if [[ -n "${R2_BASE_URL:-}" ]]; then
    log "Step 1: Fetching latest.txt from R2 (HTTP)..."
    curl -fsSL \
      --retry "$CURL_RETRIES" --retry-delay "$CURL_RETRY_DELAY" \
      --max-time "$NETWORK_TIMEOUT" --connect-timeout 10 \
      --output "${LATEST_TXT}" \
      "${R2_BASE_URL}/${PROFILE}/latest.txt" 2>/dev/null \
      && [[ -s "${LATEST_TXT}" ]] && return 0
  fi
  return 1
}

_fetch_from_sf() {
  log "Step 1: Fetching latest.txt from SourceForge..."
  local url="https://sourceforge.net/projects/${PROJECT_NAME}/files/${PROFILE}/latest.txt/download"
  curl -fsSL \
    --retry "$CURL_RETRIES" --retry-delay "$CURL_RETRY_DELAY" \
    --max-time "$NETWORK_TIMEOUT" --connect-timeout 10 \
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
# Step 2: Extract build date and verify artifacts before promoting
# ---------------------------------------------------------------------------
BUILD_DATE_DIR=$(echo "${LATEST_RELEASE}" | grep -oE '[0-9]{8}' | head -1)
if [[ -z "$BUILD_DATE_DIR" ]]; then
  die "Could not extract build date from latest release filename: ${LATEST_RELEASE}"
fi

# SourceForge verification
if [[ "${NO_SF}" == "false" ]]; then
  log "Verifying artifact on SourceForge..."
  SF_ARTIFACT_URL="https://downloads.sourceforge.net/project/shanios/${PROFILE}/${BUILD_DATE_DIR}/${LATEST_RELEASE}"
  SF_SIGNATURE_URL="${SF_ARTIFACT_URL}.asc"

  if ! curl -fsSL --head --max-time 20 --connect-timeout 10 "${SF_ARTIFACT_URL}" >/dev/null 2>&1; then
    die "Artifact not reachable on SourceForge: ${SF_ARTIFACT_URL} — aborting promotion."
  fi
  if ! curl -fsSL --head --max-time 20 --connect-timeout 10 "${SF_SIGNATURE_URL}" >/dev/null 2>&1; then
    die "Signature not reachable on SourceForge: ${SF_SIGNATURE_URL} — aborting promotion."
  fi
  log "SourceForge: artifact and signature OK."
else
  log "Skipping SourceForge artifact verification (--no-sf)."
fi

# R2 verification — via HTTP (R2_BASE_URL) or rclone (R2_BUCKET), whichever is configured
if [[ "${NO_R2}" == "false" ]]; then
  if [[ -n "${R2_BASE_URL:-}" ]]; then
    log "Verifying artifact on R2 (HTTP)..."
    R2_ARTIFACT_URL="${R2_BASE_URL}/${PROFILE}/${BUILD_DATE_DIR}/${LATEST_RELEASE}"
    R2_SIGNATURE_URL="${R2_ARTIFACT_URL}.asc"

    if ! curl -fsSL --head --max-time 20 --connect-timeout 10 "${R2_ARTIFACT_URL}" >/dev/null 2>&1; then
      die "Artifact not reachable on R2: ${R2_ARTIFACT_URL} — aborting promotion."
    fi
    if ! curl -fsSL --head --max-time 20 --connect-timeout 10 "${R2_SIGNATURE_URL}" >/dev/null 2>&1; then
      die "Signature not reachable on R2: ${R2_SIGNATURE_URL} — aborting promotion."
    fi
    log "R2: artifact and signature OK."

  elif [[ -n "${R2_BUCKET:-}" ]]; then
    log "Verifying artifact on R2 (rclone)..."
    R2_ARTIFACT_KEY="${PROFILE}/${BUILD_DATE_DIR}/${LATEST_RELEASE}"
    R2_SIGNATURE_KEY="${R2_ARTIFACT_KEY}.asc"

    if ! rclone lsf "r2:${R2_BUCKET}/${R2_ARTIFACT_KEY}" >/dev/null 2>&1; then
      die "Artifact not found on R2: r2:${R2_BUCKET}/${R2_ARTIFACT_KEY} — aborting promotion."
    fi
    if ! rclone lsf "r2:${R2_BUCKET}/${R2_SIGNATURE_KEY}" >/dev/null 2>&1; then
      die "Signature not found on R2: r2:${R2_BUCKET}/${R2_SIGNATURE_KEY} — aborting promotion."
    fi
    log "R2: artifact and signature OK."

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

# ---------------------------------------------------------------------------
# Step 4: Upload stable.txt to SourceForge
# ---------------------------------------------------------------------------
if [[ "${NO_SF}" == "false" ]]; then
  log "Step 4: Uploading stable.txt to SourceForge..."
  log "Uploading to: ${REMOTE_PATH}"
  rsync -e ssh -avz --progress "${STABLE_TXT}" "${REMOTE_PATH}" \
    || die "Upload of stable.txt failed"
else
  log "Step 4: Skipping SourceForge upload (--no-sf)."
fi

# ---------------------------------------------------------------------------
# Step 5: Mirror stable.txt to Cloudflare R2
# ---------------------------------------------------------------------------
log "Step 5: Mirroring stable.txt to Cloudflare R2..."
r2_upload "${STABLE_TXT}" "${PROFILE}"

log ""
log "========================================="
log "SUCCESS: Promoted latest to stable!"
log "========================================="
log "Release: ${LATEST_RELEASE}"
log "Profile: ${PROFILE}"
[[ "${NO_SF}" == "true" ]] && log "Note: SourceForge was skipped (--no-sf)"
[[ "${NO_R2}" == "true" ]] && log "Note: Cloudflare R2 was skipped (--no-r2)"
