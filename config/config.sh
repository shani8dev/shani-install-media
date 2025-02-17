#!/usr/bin/env bash
# config.sh – Global configuration and common helper functions

set -Eeuo pipefail

# Global configuration variables
OS_NAME="shanios"
BUILD_DATE="$(date +%Y%m%d)"
DEFAULT_PROFILE="gnome"
OUTPUT_DIR="$(realpath ./cache/output)"
BUILD_DIR="$(realpath ./cache/build)"
TEMP_DIR="$(realpath ./cache/temp)"
MOK_DIR="$(realpath ./mok)"
ISO_PROFILES_DIR="$(realpath ./iso_profiles)"
IMAGE_PROFILES_DIR="$(realpath ./image_profiles)"
GPG_KEY_ID="7B927BFFD4A9EAAA8B666B77DE217F3DA8014792"

# Logging functions
log()   { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*" >&2; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

# Check for required commands
check_dependencies() {
    local deps=( btrfs pacstrap losetup mount umount arch-chroot rsync genfstab zsyncmake gpg sha256sum zstd fallocate mkfs.btrfs )
    for cmd in "${deps[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed."
    done
}

# Verify or generate Secure Boot (MOK) keys
check_mok_keys() {
    if [[ ! -f "${MOK_DIR}/MOK.key" || ! -f "${MOK_DIR}/MOK.crt" || ! -f "${MOK_DIR}/MOK.der" ]]; then
        log "MOK keys missing. Generating new keys..."
        mkdir -p "${MOK_DIR}"
        openssl req -newkey rsa:4096 -nodes -keyout "${MOK_DIR}/MOK.key" -new -x509 -sha256 -days 3650 \
          -out "${MOK_DIR}/MOK.crt" -subj "/CN=Shani OS Secure Boot Key/" || die "Failed to generate MOK keys"
        openssl x509 -in "${MOK_DIR}/MOK.crt" -outform DER -out "${MOK_DIR}/MOK.der" || die "Failed to convert MOK key to DER"
    else
        log "MOK keys exist."
    fi
}

# Create a Btrfs image file, attach a loop device, and format it.
# Args:
#   $1 = path to image file to create
#   $2 = size (e.g. "10G" or "1G")
# Returns: loop device (echoed)
setup_btrfs_image() {
    local img_path="$1"
    local size="$2"
    # Ensure the parent directory exists
    local img_dir
    img_dir="$(dirname "$img_path")"
    mkdir -p "$img_dir" || die "Failed to create directory: $img_dir"

    losetup -D || warn "Failed to detach $existing_loop"

    log "Removing existing image file: $img_path"
    rm -f "$img_path"

    dd if=/dev/zero of="$img_path" bs=1G count="${size%G}" status=progress || die "Failed to allocate image file: $img_path"

    # Setup loop device
    LOOP_DEVICE=$(losetup --find --show "$img_path") || die "Failed to setup loop device for $img_path"
    log "Loop device assigned: $LOOP_DEVICE"
    
    # Format as Btrfs
    log "Formatting $LOOP_DEVICE as Btrfs..."
    mkfs.btrfs -f "$LOOP_DEVICE" || die "Failed to format $img_path as Btrfs"
    echo "$LOOP_DEVICE"
}


# Detach a Btrfs image: unmount the mount point, detach the loop device, and remove the mount point.
# Args:
#   $1 = mount point
#   $2 = loop device
detach_btrfs_image() {
    local mount_point="$1"
    local loop_dev="$2"
    umount "$mount_point" || warn "Failed to unmount $mount_point"
    losetup -d "$loop_dev" || warn "Failed to detach loop device $loop_dev"
    rm -rf "$mount_point"
}

# Create a compressed snapshot using btrfs send.
# Args:
#   $1 = Path to the read-only subvolume to snapshot.
#   $2 = Destination output file (compressed image).
btrfs_send_snapshot() {
    local subvol_path="$1"
    local output_file="$2"
    log "Creating Btrfs snapshot from ${subvol_path} into ${output_file}"
    btrfs send "$subvol_path" | zstd --ultra --long=31 -T0 -22 -v > "$output_file" \
      || die "btrfs send failed for ${subvol_path}"
}
