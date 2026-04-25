#!/usr/bin/env bash
# config.sh – Global configuration and common helper functions

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Global configuration variables
# ---------------------------------------------------------------------------
OS_NAME="shanios"
# Honour a pre-exported BUILD_DATE (set by build.sh before dispatching
# sub-scripts) so all stages of a compound command share the same date
# even across a midnight boundary. Falls back to today when invoked standalone.
BUILD_DATE="${BUILD_DATE:-$(date +%Y%m%d)}"
DEFAULT_PROFILE="gnome"
OUTPUT_DIR="$(realpath -m ./cache/output)"
BUILD_DIR="$(realpath -m ./cache/build)"
TEMP_DIR="$(realpath -m ./cache/temp)"
MOK_DIR="$(realpath -m ./keys/mok)"
GPG_DIR="$(realpath -m ./keys/gpg)"
ISO_PROFILES_DIR="$(realpath ./iso_profiles)"
IMAGE_PROFILES_DIR="$(realpath ./image_profiles)"
GPG_KEY_ID="${GPG_KEY_ID:-7B927BFFD4A9EAAA8B666B77DE217F3DA8014792}"

# Canonical GPG home used by the builder container.
BUILDER_GNUPGHOME="${GNUPGHOME:-/home/builduser/.gnupg}"

# ---------------------------------------------------------------------------
# Shared network / retry constants (used by promote-stable.sh, upload.sh, etc.)
# ---------------------------------------------------------------------------
CURL_RETRIES=3
CURL_RETRY_DELAY=5
NETWORK_TIMEOUT=30
NETWORK_CONNECT_TIMEOUT=10

# Ensure all writable cache directories exist before any script runs.
mkdir -p "${OUTPUT_DIR}" "${BUILD_DIR}" "${TEMP_DIR}" "${MOK_DIR}" "${GPG_DIR}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { echo "[INFO] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

# Check for tools required by build-base-image.sh.
check_dependencies() {
    local deps=( btrfs pacstrap losetup mount umount arch-chroot rsync gpg sha256sum zstd fallocate mkfs.btrfs openssl )
    for cmd in "${deps[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed."
    done
}

# Check for tools required by build-iso.sh / repack-iso.sh.
check_dependencies_iso() {
    local deps=( mkarchiso xorriso osirrox sbsign mcopy mktorrent )
    for cmd in "${deps[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed."
    done
}

# Check for tools required by upload.sh / promote-stable.sh.
check_dependencies_upload() {
    local deps=( rsync curl )
    for cmd in "${deps[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed."
    done
    # rclone is only required when R2 uploads are active
    if [[ -n "${R2_BUCKET:-}" ]]; then
        command -v rclone >/dev/null 2>&1 || die "rclone is required for R2 uploads but not installed."
    fi
}

# Verify or generate Secure Boot (MOK) keys.
check_mok_keys() {
    if [[ ! -f "${MOK_DIR}/MOK.key" || ! -f "${MOK_DIR}/MOK.crt" || ! -f "${MOK_DIR}/MOK.der" ]]; then
        log "MOK keys missing. Generating new keys..."
        mkdir -p "${MOK_DIR}"
        openssl req -newkey rsa:2048 -nodes -keyout "${MOK_DIR}/MOK.key" -new -x509 -sha256 -days 3650 \
          -out "${MOK_DIR}/MOK.crt" -subj "/CN=Shani OS Secure Boot Key/" \
          || die "Failed to generate MOK keys"
        openssl x509 -in "${MOK_DIR}/MOK.crt" -outform DER -out "${MOK_DIR}/MOK.der" \
          || die "Failed to convert MOK key to DER"
    else
        log "MOK keys exist."
    fi
}

# Verify GPG public key exists for embedding into the image.
# In CI the key is pre-exported by the 'Setup GPG public key' workflow step.
# As a fallback (local builds or if the step was skipped), attempt to export
# the public key from the container's keyring where GPG_PRIVATE_KEY was imported
# by run_in_container.sh. Fails hard if neither path produces the file.
check_gpg_key() {
    if [[ -f "${GPG_DIR}/gpg-public.asc" ]]; then
        log "GPG public key exists."
        return 0
    fi

    log "GPG public key not found — attempting to export from keyring..."
    mkdir -p "${GPG_DIR}"
    gpg --homedir "${BUILDER_GNUPGHOME}" \
        --batch \
        --armor \
        --export "${GPG_KEY_ID}" \
        > "${GPG_DIR}/gpg-public.asc" 2>/dev/null \
        || true

    if [[ ! -s "${GPG_DIR}/gpg-public.asc" ]]; then
        die "GPG public key not found at ${GPG_DIR}/gpg-public.asc and could not be exported" \
            "from keyring. Export it manually with:" \
            "gpg --armor --export ${GPG_KEY_ID} > ${GPG_DIR}/gpg-public.asc"
    fi

    log "GPG public key exported from keyring."
}

# ---------------------------------------------------------------------------
# GPG signing
# ---------------------------------------------------------------------------

# Prepare the builder GPG keyring for signing:
#   - sets ultimate trust on GPG_KEY_ID
#   - verifies the secret key is present
# Must be called before gpg_sign_file().
gpg_prepare_keyring() {
    log "Preparing GPG keyring in ${BUILDER_GNUPGHOME}..."
    mkdir -p "${BUILDER_GNUPGHOME}"
    chmod 700 "${BUILDER_GNUPGHOME}"

    echo "${GPG_KEY_ID}:6:" \
        | gpg --homedir "${BUILDER_GNUPGHOME}" --batch --import-ownertrust \
        || die "Failed to set ultimate trust for ${GPG_KEY_ID}"

    if ! gpg --homedir "${BUILDER_GNUPGHOME}" --list-secret-keys "${GPG_KEY_ID}" >/dev/null 2>&1; then
        die "GPG secret key not found in ${BUILDER_GNUPGHOME}: ${GPG_KEY_ID}"
    fi
}

# Create a detached armored GPG signature for a file.
# Args:
#   $1 = path to the file to sign
# Output: <file>.asc written alongside the input file.
# Requires: gpg_prepare_keyring() called first; GPG_PASSPHRASE set in env.
gpg_sign_file() {
    local target="$1"
    [[ -f "$target" ]] || die "gpg_sign_file: file not found: $target"
    [[ -n "${GPG_PASSPHRASE:-}" ]] || die "gpg_sign_file: GPG_PASSPHRASE is not set"

    log "GPG signing: $(basename "$target")"
    gpg --homedir "${BUILDER_GNUPGHOME}" \
        --batch \
        --yes \
        --pinentry-mode loopback \
        --passphrase "${GPG_PASSPHRASE}" \
        --default-key "${GPG_KEY_ID}" \
        --detach-sign \
        --armor \
        --output "${target}.asc" \
        "${target}" \
        || die "GPG signing failed for ${target}"

    log "GPG signature created: ${target}.asc"
}

# ---------------------------------------------------------------------------
# Build date resolution
# ---------------------------------------------------------------------------

# Resolve the build date for a given profile.
# Uses today's date if a matching output folder exists, otherwise falls back
# to the most recently dated folder under OUTPUT_DIR/<profile>/.
# Args:
#   $1 = profile name
# Prints the resolved BUILD_DATE (8-digit string) to stdout.
# Dies if no dated folder can be found at all.
resolve_build_date() {
    local profile="$1"
    local today
    today="$(date +%Y%m%d)"
    local expected_dir="${OUTPUT_DIR}/${profile}/${today}"

    if [[ -d "${expected_dir}" ]]; then
        log "Using today's build folder: ${today}"
        echo "${today}"
        return 0
    fi

    local latest
    latest=$(find "${OUTPUT_DIR}/${profile}" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null \
        | sort -r | head -n1 | xargs basename 2>/dev/null || true)

    if [[ -z "${latest}" ]]; then
        die "No build directory found under ${OUTPUT_DIR}/${profile}"
    fi

    log "Today's build folder not found; using latest build folder: ${latest}"
    echo "${latest}"
}

# ---------------------------------------------------------------------------
# Btrfs helpers
# ---------------------------------------------------------------------------

# Create a Btrfs image file, attach a loop device, format it, and print the
# loop device path to stdout.
#
# Args:
#   $1 = path to image file to create
#   $2 = size (e.g. "10G")
#
# Callers capture the loop device with:
#   LOOP_DEVICE=$(setup_btrfs_image "$img" "$size")
#
# All diagnostic output goes to stderr so stdout carries only the device path.
setup_btrfs_image() {
    local img_path="$1"
    local size="$2"
    local img_dir
    img_dir="$(dirname "$img_path")"
    mkdir -p "$img_dir" || die "Failed to create directory: $img_dir"

    # Detach any existing loop device associated with this image file
    if losetup -j "$img_path" | grep -q "$img_path"; then
        local existing_loop
        existing_loop=$(losetup -j "$img_path" | cut -d: -f1)
        losetup -d "$existing_loop" \
            || warn "Failed to detach existing loop device: $existing_loop" >&2
    fi

    log "Removing existing image file (if any): $img_path" >&2
    rm -f "$img_path"

    fallocate -l "$size" "$img_path" || die "Failed to allocate image file: $img_path"

    local loop_device
    loop_device=$(losetup --find --show "$img_path") \
        || die "Failed to setup loop device for $img_path"
    log "Loop device assigned: $loop_device" >&2

    log "Formatting $loop_device as Btrfs..." >&2
    mkfs.btrfs -f "$loop_device" || die "Failed to format $img_path as Btrfs"

    # Print the loop device path — this is the function's return value.
    echo "$loop_device"
}

# Unmount a Btrfs subvolume, detach the loop device, and remove the mount point.
# Args:
#   $1 = mount point
#   $2 = loop device
detach_btrfs_image() {
    local mount_point="$1"
    local loop_dev="$2"

    if mountpoint -q "$mount_point" 2>/dev/null; then
        umount -R "$mount_point" || warn "Failed to unmount $mount_point"
    fi

    if [[ -n "$loop_dev" ]]; then
        losetup -d "$loop_dev" || warn "Failed to detach loop device $loop_dev"
    fi

    # Guard against accidentally rm -rf'ing an empty or root path
    if [[ -n "$mount_point" && "$mount_point" != "/" ]]; then
        rm -rf "$mount_point"
    else
        warn "detach_btrfs_image: refusing to remove suspicious mount point: '${mount_point}'"
    fi
}

# Create a compressed snapshot of a read-only Btrfs subvolume.
# Uses a temp file so a failed compression never produces a partial output file.
# Args:
#   $1 = path to the read-only subvolume
#   $2 = destination output file (will be a zstd-compressed btrfs stream)
btrfs_send_snapshot() {
    local subvol_path="$1"
    local output_file="$2"
    local tmp_file="${output_file}.tmp"

    log "Creating Btrfs snapshot: ${subvol_path} → ${output_file}"

    # Write to a temp file so a partial run never leaves a corrupt output file.
    # pipefail (active via set -Eeuo pipefail) ensures btrfs send failures are caught.
    btrfs send "${subvol_path}" \
        | zstd --ultra --long=31 -T0 -22 -v > "${tmp_file}" \
        || { rm -f "${tmp_file}"; die "btrfs_send_snapshot failed for ${subvol_path}"; }

    mv "${tmp_file}" "${output_file}"
    log "Snapshot written: ${output_file} ($(du -sh "${output_file}" | cut -f1))"
}
