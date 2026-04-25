#!/usr/bin/env bash
# build-iso.sh – Build the bootable ISO image (container-only)
#
# By default expects a locally built base image in cache/output/<profile>/<BUILD_DATE>/.
#
# Pass --from-r2 to instead download the latest artifacts from Cloudflare R2
# (requires R2_BUCKET to be set and rclone to be configured):
#   ./build-iso.sh -p gnome --from-r2
#
# The script downloads:
#   - The base image named in <profile>/latest.txt on R2
#   - flatpakfs.zst and snapfs.zst from the same dated folder (if present)
#   - Verifies the base image SHA-256 and GPG signature (both required, hard failure)

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PROFILE=""
FROM_R2=false

_CLEAN_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --from-r2) FROM_R2=true ;;
    *)         _CLEAN_ARGS+=("$arg") ;;
  esac
done
set -- "${_CLEAN_ARGS[@]+"${_CLEAN_ARGS[@]}"}"

while getopts ":p:" opt; do
  case ${opt} in
    p) PROFILE="${OPTARG}" ;;
    \?) die "Invalid option: -$OPTARG" ;;
  esac
done

[[ -z "$PROFILE" ]] && die "Profile (-p) is required."

OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
mkdir -p "${OUTPUT_SUBDIR}"

# ---------------------------------------------------------------------------
# Download tool detection (used by r2_download / r2_exists below)
# Defined unconditionally so the functions work regardless of code path.
# ---------------------------------------------------------------------------
_HAS_ARIA2C=0; _HAS_CURL=0; _HAS_WGET=0
command -v aria2c &>/dev/null && _HAS_ARIA2C=1
command -v curl   &>/dev/null && _HAS_CURL=1
command -v wget   &>/dev/null && _HAS_WGET=1

# ---------------------------------------------------------------------------
# r2_download <url> <dest> [fatal: true|false]
#
# Download a large file from the public R2 URL.
# Priority: aria2c (4 connections, resume) → curl (-C -) → wget (--continue)
# On non-fatal failure: warns, removes partial files, returns 1.
# ---------------------------------------------------------------------------
r2_download() {
  local url="$1" dest="$2" fatal="${3:-true}"
  local name; name="$(basename "$dest")"

  log "Downloading ${name} from ${url}..."

  local aria2c_opts=(
    --allow-overwrite=true
    --auto-file-renaming=false
    --conditional-get=false
    --remote-time=true
    --file-allocation=none
    --timeout=60
    --max-tries=5
    --retry-wait=5
    --max-resume-failure-tries=10
    --connect-timeout=30
    --continue=true
    --max-connection-per-server=4
    --split=4
    --dir="$(dirname "$dest")"
    --out="$(basename "$dest")"
  )

  local ok=0

  if (( _HAS_ARIA2C )); then
    if aria2c "${aria2c_opts[@]}" "$url"; then
      ok=1
    else
      # Remove aria2c control file before falling through to the next tool
      rm -f "${dest}.aria2"
    fi
  fi

  if (( ! ok && _HAS_CURL )); then
    curl --fail --location --progress-bar \
         --retry 5 --retry-delay 5 --retry-connrefused \
         --connect-timeout 30 --max-time 600 \
         --remote-time \
         --continue-at - \
         --output "$dest" \
         "$url" && ok=1
  fi

  if (( ! ok && _HAS_WGET )); then
    wget --retry-connrefused --waitretry=30 --read-timeout=60 \
         --timeout=60 --tries=5 --connect-timeout=30 \
         --continue \
         -O "$dest" "$url" && ok=1
  fi

  if (( ok )); then
    log "${name} download complete ($(du -sh "$dest" | cut -f1))."
    return 0
  fi

  # All tools failed
  rm -f "$dest" "${dest}.aria2"
  if [[ "$fatal" == "true" ]]; then
    die "Failed to download ${name} from ${url}"
  else
    warn "${name} download failed — skipping."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# r2_exists <url> — HEAD check to probe optional files before downloading.
# Returns 1 and warns if no download tool is available.
# ---------------------------------------------------------------------------
r2_exists() {
  local url="$1"
  if (( _HAS_CURL )); then
    curl --fail --head --silent --max-time 15 --output /dev/null "$url" 2>/dev/null
  elif (( _HAS_WGET )); then
    wget -q --spider --timeout=15 --tries=1 "$url" 2>/dev/null
  else
    warn "r2_exists: no curl or wget available — cannot probe ${url}, assuming absent."
    return 1
  fi
}


# ---------------------------------------------------------------------------
# verify_base_image <image_file>
#
# Verify the SHA-256 checksum and GPG signature of a downloaded base image.
# Dies on any mismatch or missing sidecar file.
# Requires gpg_prepare_keyring() to have been called first.
# ---------------------------------------------------------------------------
verify_base_image() {
  local image="$1"
  local sha256_file="${image}.sha256"
  local asc_file="${image}.asc"

  [[ -f "$sha256_file" ]] || die "verify_base_image: missing checksum file: ${sha256_file}"
  log "Verifying SHA-256 checksum of $(basename "$image")..."
  pushd "$(dirname "$image")" > /dev/null
  sha256sum --check --status "$(basename "$sha256_file")" \
    || die "SHA-256 mismatch for $(basename "$image") — download may be corrupt."
  popd > /dev/null
  log "SHA-256 verified."

  [[ -f "$asc_file" ]] || die "verify_base_image: missing signature file: ${asc_file}"
  log "Verifying GPG signature of $(basename "$image")..."
  gpg --homedir "${BUILDER_GNUPGHOME}" \
      --batch \
      --verify "$asc_file" "$image" \
    || die "GPG signature verification failed for $(basename "$image")."
  log "GPG signature verified."
}

# ---------------------------------------------------------------------------
# --from-r2: download latest artifacts from Cloudflare R2
# ---------------------------------------------------------------------------
if [[ "$FROM_R2" == "true" ]]; then
  [[ -z "${R2_BUCKET:-}" ]] && die "--from-r2 requires R2_BUCKET to be set."
  command -v rclone >/dev/null 2>&1 \
    || die "--from-r2 requires rclone to be installed and configured."

  # Public base URL — same domain used by shani-deploy.sh and torrent webseeds
  R2_PUBLIC_BASE="https://downloads.shani.dev"

  # Fetch latest.txt via rclone (authenticated; tiny file, no resume needed)
  log "Fetching latest.txt from R2 (r2:${R2_BUCKET}/${PROFILE}/latest.txt)..."
  rclone copyto "r2:${R2_BUCKET}/${PROFILE}/latest.txt" "${OUTPUT_SUBDIR}/latest.txt" \
    || die "Failed to download latest.txt from R2. Has an image been uploaded yet?"

  [[ -s "${OUTPUT_SUBDIR}/latest.txt" ]] || die "Downloaded latest.txt is empty."
  r2_base_image=$(<"${OUTPUT_SUBDIR}/latest.txt")
  log "Latest image on R2: ${r2_base_image}"

  # Extract the 8-digit build date from the filename (POSIX-compatible grep)
  r2_date=$(echo "${r2_base_image}" | grep -oE '[0-9]{8}' | head -1)
  [[ -z "$r2_date" ]] \
    && die "Could not extract build date from R2 latest image name: ${r2_base_image}"

  R2_DATED_URL="${R2_PUBLIC_BASE}/${PROFILE}/${r2_date}"

  # Base image — always required.
  # Skip re-download if already present locally (resume-safe).
  if [[ -f "${OUTPUT_SUBDIR}/${r2_base_image}" ]]; then
    log "Base image already present locally — skipping download."
  else
    r2_download "${R2_DATED_URL}/${r2_base_image}" "${OUTPUT_SUBDIR}/${r2_base_image}" true
  fi

  # Prepare GPG trust before verifying — ensures the key has ultimate trust
  # in BUILDER_GNUPGHOME so the signature check doesn't fail or warn.
  gpg_prepare_keyring

  # Sidecar files (.sha256 and .asc) are mandatory — refuse to build from an unverified image.
  if [[ ! -f "${OUTPUT_SUBDIR}/${r2_base_image}.sha256" ]]; then
    r2_download "${R2_DATED_URL}/${r2_base_image}.sha256" \
                "${OUTPUT_SUBDIR}/${r2_base_image}.sha256" true
  fi
  if [[ ! -f "${OUTPUT_SUBDIR}/${r2_base_image}.asc" ]]; then
    r2_download "${R2_DATED_URL}/${r2_base_image}.asc" \
                "${OUTPUT_SUBDIR}/${r2_base_image}.asc" true
  fi

  # Verify integrity and authenticity — dies on any mismatch.
  verify_base_image "${OUTPUT_SUBDIR}/${r2_base_image}"

  # Optional layered images — local copy wins; download if present on R2.
  # No sidecars are uploaded for these layers so no verification is performed.
  for _layer in flatpakfs snapfs; do
    _layer_file="${OUTPUT_SUBDIR}/${_layer}.zst"
    _layer_url="${R2_DATED_URL}/${_layer}.zst"

    if [[ -f "$_layer_file" ]]; then
      log "${_layer}.zst found locally — using local copy."
    elif r2_exists "$_layer_url"; then
      r2_download "$_layer_url" "$_layer_file" false \
        || warn "${_layer}.zst download failed — skipping layer."
    else
      log "No ${_layer}.zst found locally or on R2 — skipping."
    fi
  done

  log "R2 artifacts ready in ${OUTPUT_SUBDIR}."
fi

# ---------------------------------------------------------------------------
# ISO build
# ---------------------------------------------------------------------------

# Clean only the mkarchiso work tree for this profile, not the whole temp dir.
# This avoids destroying other profile work dirs or data written earlier in the
# same pipeline run.
WORK_DIR="${TEMP_DIR}/${PROFILE}"
if [[ -n "$WORK_DIR" && "$WORK_DIR" != "/" && -d "$WORK_DIR" ]]; then
  log "Cleaning previous mkarchiso work tree: ${WORK_DIR}"
  rm -rf "${WORK_DIR}"
fi

[[ -f "${OUTPUT_SUBDIR}/latest.txt" ]] \
  || die "latest.txt not found. Run build-base-image.sh first, or pass --from-r2."
base_image=$(<"${OUTPUT_SUBDIR}/latest.txt")

[[ -f "${OUTPUT_SUBDIR}/${base_image}" ]] \
  || die "Base image file not found: ${OUTPUT_SUBDIR}/${base_image}"

ISO_DIR="${TEMP_DIR}/${PROFILE}/iso/${OS_NAME}/x86_64"
mkdir -p "$ISO_DIR"

log "Copying base image → rootfs.zst..."
cp "${OUTPUT_SUBDIR}/${base_image}" "${ISO_DIR}/rootfs.zst" \
  || die "Failed to copy base image"

if [[ -f "${OUTPUT_SUBDIR}/flatpakfs.zst" ]]; then
  log "Copying flatpakfs.zst..."
  cp "${OUTPUT_SUBDIR}/flatpakfs.zst" "${ISO_DIR}/" || die "Failed to copy Flatpak image"
else
  log "No flatpakfs.zst for profile '${PROFILE}' — skipping."
fi

if [[ -f "${OUTPUT_SUBDIR}/snapfs.zst" ]]; then
  log "Copying snapfs.zst..."
  cp "${OUTPUT_SUBDIR}/snapfs.zst" "${ISO_DIR}/" || die "Failed to copy Snap image"
else
  log "No snapfs.zst for profile '${PROFILE}' — skipping."
fi

# Inject profile marker so customize_airootfs.sh can detect the profile at
# chroot time. The marker is read and deleted immediately by that script so it
# never ends up in the final ISO squashfs. We register a trap to remove it on
# exit so it doesn't persist if mkarchiso fails.
AIROOTFS_ETC="${ISO_PROFILES_DIR}/${PROFILE}/airootfs/etc"
PROFILE_MARKER="${AIROOTFS_ETC}/shani-build-profile"
mkdir -p "$AIROOTFS_ETC"
echo "${PROFILE}" > "${PROFILE_MARKER}"
# Use a compound trap so the profile marker is cleaned up on exit without
# clobbering any EXIT trap already set by the caller or future additions.
trap 'rm -f "${PROFILE_MARKER}"' EXIT

log "Running mkarchiso..."
mkarchiso -v -w "${TEMP_DIR}/${PROFILE}" -o "${OUTPUT_SUBDIR}" "${ISO_PROFILES_DIR}/${PROFILE}" \
  || die "mkarchiso failed"

log "ISO build completed successfully!"
