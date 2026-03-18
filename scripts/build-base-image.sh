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
secureboot_target="${BUILD_DIR}/${BASE_SUBVOL}/etc/secureboot/keys"
mkdir -p "$secureboot_target"
install -m 600 "${MOK_DIR}/MOK.key" "$secureboot_target/MOK.key" || die "Failed to install MOK.key"
install -m 644 "${MOK_DIR}/MOK.crt" "$secureboot_target/MOK.crt" || die "Failed to install MOK.crt"
install -m 644 "${MOK_DIR}/MOK.der" "$secureboot_target/MOK.der" || die "Failed to install MOK.der"

# Install base system via pacstrap and apply overlays/customizations
log "Installing base system..."
package_list="${IMAGE_PROFILES_DIR}/${PROFILE}/package-list.txt"
[[ -f "$package_list" ]] || die "Package list not found for profile ${PROFILE}"
pacstrap -cC "$PACMAN_CONFIG" "${BUILD_DIR}/${BASE_SUBVOL}" $(<"$package_list") || die "pacstrap failed"
if [[ -d "${IMAGE_PROFILES_DIR}/${PROFILE}/overlay/rootfs" ]]; then
    log "Applying overlay files..."
    cp -r "${IMAGE_PROFILES_DIR}/${PROFILE}/overlay/rootfs/"* "${BUILD_DIR}/${BASE_SUBVOL}/" || die "Overlay copy failed"
fi
if [[ -f "${IMAGE_PROFILES_DIR}/${PROFILE}/${PROFILE}-customization.sh" ]]; then
    log "Applying customizations..."
    bash "${IMAGE_PROFILES_DIR}/${PROFILE}/${PROFILE}-customization.sh" "${BUILD_DIR}/${BASE_SUBVOL}" || die "Customizations failed"
fi

arch-chroot "${BUILD_DIR}/${BASE_SUBVOL}" /bin/bash <<EOF
set -euo pipefail

# Configure locale and keyboard settings
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# Set the timezone to UTC and update hardware clock
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

# Generate a new machine ID
systemd-machine-id-setup --commit

# Set system hostname and record build/version information
echo "${OS_NAME}" > /etc/hostname
echo "${BUILD_DATE}" > /etc/shani-version
echo "${PROFILE}" > /etc/shani-profile
echo "stable" > /etc/shani-channel

# Extra groups added to every user account at creation time.
# This is the single source of truth read by shani-user-setup,
# adduser wrapper, and useradd wrapper. Lives on the read-only root
# so it survives a factory reset (/data wipe) and is available
# before the /etc overlay activates.
echo "sys,cups,lp,scanner,realtime,input,video,kvm,libvirt,lxd,nixbld" > /etc/shani-extra-groups
chmod 644 /etc/shani-extra-groups

# Create directories required for the read-only root fstab mounts
mkdir -p /boot/efi
mkdir -p /swap
mkdir -p /data
mkdir -p /nix

# Container & virtualization mount points
mkdir -p /var/lib/flatpak
mkdir -p /var/lib/snapd
mkdir -p /var/lib/waydroid
mkdir -p /var/lib/containers
mkdir -p /var/lib/machines
mkdir -p /var/lib/lxc
mkdir -p /var/lib/lxd
mkdir -p /var/lib/libvirt
mkdir -p /var/lib/qemu

# var subvolume mount points
mkdir -p /var/cache
mkdir -p /var/log

# Groups with confirmed static GIDs from Arch archwiki / systemd basic.conf
getent group sys     &>/dev/null || groupadd -r -g 3   sys
getent group lp      &>/dev/null || groupadd -r -g 7   lp
getent group kvm     &>/dev/null || groupadd -r -g 78  kvm
getent group video   &>/dev/null || groupadd -r -g 91  video
getent group scanner &>/dev/null || groupadd -r -g 96  scanner
getent group input   &>/dev/null || groupadd -r -g 97  input
getent group cups    &>/dev/null || groupadd -r -g 209 cups

# Groups with no upstream static GID — allocate dynamically to avoid conflicts
getent group realtime &>/dev/null || groupadd -r realtime
getent group nixbld   &>/dev/null || groupadd -r nixbld
getent group lxd      &>/dev/null || groupadd -r lxd
getent group libvirt  &>/dev/null || groupadd -r libvirt

# subuid/subgid for root — required for rootless podman, lxc, lxd
usermod -v 1000000-1000999999 -w 1000000-1000999999 root

# --------------------------------------------------
# Import Shani signing public key (for verification)
# --------------------------------------------------
if [[ -f /etc/shani-keys/signing.asc ]]; then
    mkdir -p /root/.gnupg
    chmod 700 /root/.gnupg

    gpg --homedir /root/.gnupg --import /etc/shani-keys/signing.asc

    # Set trust (ultimate for system key)
    echo "${GPG_KEY_ID}:6:" | gpg --homedir /root/.gnupg --import-ownertrust
fi

EOF

btrfs property set -f -ts "${BUILD_DIR}/${BASE_SUBVOL}" ro true || die "Failed to set subvolume read-only"

# Create final base image snapshot
btrfs_send_snapshot "${BUILD_DIR}/${BASE_SUBVOL}" "${IMAGE_FILE}"

btrfs property set -f -ts "${BUILD_DIR}/${BASE_SUBVOL}" ro false || die "Failed to reset subvolume properties"
# Clean up Btrfs image resources
detach_btrfs_image "${BUILD_DIR}/${BASE_SUBVOL}" "$LOOP_DEVICE"

# Ensure all GPG operations use the correct home directory
export GNUPGHOME="/home/builduser/.gnupg"

# Trust the key in the USER keyring
echo -e "trust\n5\ny\nsave\n" | gpg --homedir "$GNUPGHOME" --batch --command-fd 0 --edit-key "$GPG_KEY_ID"

# Verify key exists in USER keyring
if ! gpg --homedir "$GNUPGHOME" --list-secret-keys "$GPG_KEY_ID" >/dev/null 2>&1; then
    die "GPG key not found in $GNUPGHOME: $GPG_KEY_ID"
fi

# Sign using USER keyring
log "Signing base image..."
gpg --homedir "$GNUPGHOME" \
    --batch \
    --yes \
    --pinentry-mode loopback \
    --passphrase "$GPG_PASSPHRASE" \
    --default-key "$GPG_KEY_ID" \
    --detach-sign \
    --armor \
    --output "${IMAGE_FILE}.asc" \
    "${IMAGE_FILE}" || die "Signing failed"
    
# Create checksum
cd "$(dirname "${IMAGE_FILE}")" || die "Failed to change directory"
sha256sum "$(basename "${IMAGE_FILE}")" > "$(basename "${IMAGE_FILE}").sha256" || die "Checksum generation failed"

# Write latest.txt in the same output subdirectory
echo "$(basename "${IMAGE_FILE}")" > "${OUTPUT_SUBDIR}/latest.txt"
log "Base image build completed successfully!"
