#!/usr/bin/env bash
# build-base-image.sh – Build the immutable base system image (container-only)
# Artifacts are written to: cache/output/<profile>/<BUILD_DATE>/

set -Eeuo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# Parse options (expects -p for profile)
PROFILE=""
while getopts "p:" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    *) die "Invalid option";;
  esac
done
shift $((OPTIND - 1))
[[ -z "$PROFILE" ]] && die "Profile (-p) is required."

# Define output subdirectory
OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
mkdir -p "${OUTPUT_SUBDIR}"

PACMAN_CONFIG="./image_profiles/${PROFILE}/pacman.conf"
BASE_SUBVOL="${OS_NAME}_base"
IMAGE_NAME="${OS_NAME}-${BUILD_DATE}-${PROFILE}.zst"
IMAGE_FILE="${OUTPUT_SUBDIR}/${IMAGE_NAME}"
ROOTLABEL="shani_root"
BOOTLABEL="shani_boot"

log "Building base image for profile: ${PROFILE}"
check_dependencies
check_mok_keys

# Setup Btrfs image for base system (10G)
BASE_IMG="${BUILD_DIR}/base.img"
setup_btrfs_image "$BASE_IMG" "10G"
# LOOP_DEVICE is set by setup_btrfs_image

# Mount image, create subvolume, and remount the subvolume
mkdir -p "${BUILD_DIR}"
mount -t btrfs -o compress-force=zstd:19 "$LOOP_DEVICE" "${BUILD_DIR}" || die "Mounting base image failed"
if btrfs subvolume list "${BUILD_DIR}" | grep -q "${BASE_SUBVOL}"; then
  log "Deleting existing subvolume ${BASE_SUBVOL}..."
  btrfs subvolume delete "${BUILD_DIR}/${BASE_SUBVOL}" || die "Failed to delete existing subvolume"
fi
log "Creating new subvolume: ${BASE_SUBVOL}"
btrfs subvolume create "${BUILD_DIR}/${BASE_SUBVOL}" || die "Subvolume creation failed"
sync
umount "${BUILD_DIR}" || die "Failed to unmount build directory"

mkdir -p "${BUILD_DIR}/${BASE_SUBVOL}"
mount -o subvol="${BASE_SUBVOL}",compress-force=zstd:19 "$LOOP_DEVICE" "${BUILD_DIR}/${BASE_SUBVOL}" || die "Mounting subvolume failed"
mountpoint "${BUILD_DIR}/${BASE_SUBVOL}" || die "Subvolume mount verification failed"

# Copy Secure Boot keys
secureboot_target="${BUILD_DIR}/${BASE_SUBVOL}/usr/share/secureboot/keys"
mkdir -p "$secureboot_target"
cp "${MOK_DIR}/MOK.key" "${MOK_DIR}/MOK.crt" "${MOK_DIR}/MOK.der" "$secureboot_target" || die "Failed to copy secure boot keys"

# Install base system via pacstrap and apply overlays/customizations
log "Installing base system..."
package_list="${IMAGE_PROFILES_DIR}/${PROFILE}/package-list.txt"
[[ -f "$package_list" ]] || die "Package list not found for profile ${PROFILE}"
pacstrap -cC "$PACMAN_CONFIG" "${BUILD_DIR}/${BASE_SUBVOL}" $(<"$package_list") || die "pacstrap failed"
if [[ -d "${IMAGE_PROFILES_DIR}/${PROFILE}/overlay/rootfs" ]]; then
    log "Applying overlay files..."
    cp -r "${IMAGE_PROFILES_DIR}/${PROFILE}/overlay/rootfs/"* "${BUILD_DIR}/${BASE_SUBVOL}/" || die "Overlay copy failed"
fi
if [[ -f "${IMAGE_PROFILES_DIR}/${PROFILE}/overlay/customizations.sh" ]]; then
    log "Applying customizations..."
    bash "${IMAGE_PROFILES_DIR}/${PROFILE}/overlay/customizations.sh" "${BUILD_DIR}/${BASE_SUBVOL}" || die "Customizations failed"
fi

arch-chroot "${BUILD_DIR}/${BASE_SUBVOL}" /bin/bash <<EOF
set -euo pipefail

# Set the timezone to UTC
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

# Set system hostname and build version
echo "${OS_NAME}" > /etc/hostname
echo "${BUILD_DATE}" > /etc/shani-version
echo "${PROFILE}" > /etc/shani-profile

EOF

btrfs property set -f -ts "${BUILD_DIR}/${BASE_SUBVOL}" ro true || die "Failed to set subvolume read-only"

# Create final base image snapshot
btrfs_send_snapshot "${BUILD_DIR}/${BASE_SUBVOL}" "${IMAGE_FILE}"

btrfs property set -f -ts "${BUILD_DIR}/${BASE_SUBVOL}" ro false || die "Failed to reset subvolume properties"
# Clean up Btrfs image resources
detach_btrfs_image "${BUILD_DIR}/${BASE_SUBVOL}" "$LOOP_DEVICE"

# Sign and checksum the final image
if gpg --list-keys "$GPG_KEY_ID" >/dev/null 2>&1; then
    log "Signing base image..."
    gpg --default-key "$GPG_KEY_ID" --detach-sign --armor "${IMAGE_FILE}" || die "Signing failed"
else
    die "GPG key not found: $GPG_KEY_ID"
fi
sha256sum "${IMAGE_FILE}" > "${IMAGE_FILE}.sha256" || die "Checksum generation failed"
zsyncmake -o "${IMAGE_FILE}.zsync" "${IMAGE_FILE}" || die "zsync file generation failed"
# Write latest.txt in the same output subdirectory
echo "$(basename "${IMAGE_FILE}")" > "${OUTPUT_SUBDIR}/latest.txt"
log "Base image build completed successfully!"

