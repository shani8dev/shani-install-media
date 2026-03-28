#!/usr/bin/env bash
# build-base-image.sh – Build the immutable base system image (container-only)
# Artifacts are written to: cache/output/<profile>/<BUILD_DATE>/

set -Eeuo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# Parse options
PROFILE=""
while getopts "p:" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    *) die "Invalid option" ;;
  esac
done
shift $((OPTIND - 1))
[[ -z "$PROFILE" ]] && die "Profile (-p) is required."

OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
mkdir -p "${OUTPUT_SUBDIR}"

PACMAN_CONFIG="./image_profiles/${PROFILE}/pacman.conf"
BASE_SUBVOL="${OS_NAME}_base"
IMAGE_NAME="${OS_NAME}-${BUILD_DATE}-${PROFILE}.zst"
IMAGE_FILE="${OUTPUT_SUBDIR}/${IMAGE_NAME}"

log "Building base image for profile: ${PROFILE}"
check_dependencies
check_mok_keys
check_gpg_key

# ---------------------------------------------------------------------------
# Set up Btrfs image for base system (10G)
# ---------------------------------------------------------------------------
BASE_IMG="${BUILD_DIR}/base.img"
setup_btrfs_image "$BASE_IMG" "10G"
# LOOP_DEVICE is set by setup_btrfs_image

# Mount image, create subvolume, remount the subvolume
mkdir -p "${BUILD_DIR}"
mount -t btrfs -o compress-force=zstd:19 "$LOOP_DEVICE" "${BUILD_DIR}" \
    || die "Mounting base image failed"

if btrfs subvolume list "${BUILD_DIR}" | grep -q "${BASE_SUBVOL}"; then
    log "Deleting existing subvolume ${BASE_SUBVOL}..."
    btrfs subvolume delete "${BUILD_DIR}/${BASE_SUBVOL}" \
        || die "Failed to delete existing subvolume"
fi

log "Creating new subvolume: ${BASE_SUBVOL}"
btrfs subvolume create "${BUILD_DIR}/${BASE_SUBVOL}" || die "Subvolume creation failed"
sync
umount "${BUILD_DIR}" || die "Failed to unmount build directory"

mkdir -p "${BUILD_DIR}/${BASE_SUBVOL}"
mount -o subvol="${BASE_SUBVOL}",compress-force=zstd:19 "$LOOP_DEVICE" "${BUILD_DIR}/${BASE_SUBVOL}" \
    || die "Mounting subvolume failed"
mountpoint "${BUILD_DIR}/${BASE_SUBVOL}" || die "Subvolume mount verification failed"

# ---------------------------------------------------------------------------
# Install keys into the image
# ---------------------------------------------------------------------------
gpg_target="${BUILD_DIR}/${BASE_SUBVOL}/etc/shani-keys/"
mkdir -p "$gpg_target"
install -m 644 "${GPG_DIR}/gpg-public.asc" "$gpg_target/signing.asc" \
    || die "Failed to install signing.asc"

secureboot_target="${BUILD_DIR}/${BASE_SUBVOL}/etc/secureboot/keys"
mkdir -p "$secureboot_target"
install -m 600 "${MOK_DIR}/MOK.key" "$secureboot_target/MOK.key" || die "Failed to install MOK.key"
install -m 644 "${MOK_DIR}/MOK.crt" "$secureboot_target/MOK.crt" || die "Failed to install MOK.crt"
install -m 644 "${MOK_DIR}/MOK.der" "$secureboot_target/MOK.der" || die "Failed to install MOK.der"

# ---------------------------------------------------------------------------
# Install base system via pacstrap and apply overlays/customizations
# ---------------------------------------------------------------------------
log "Installing base system..."
package_list="${IMAGE_PROFILES_DIR}/${PROFILE}/package-list.txt"
[[ -f "$package_list" ]] || die "Package list not found for profile ${PROFILE}"
pacstrap -cC "$PACMAN_CONFIG" "${BUILD_DIR}/${BASE_SUBVOL}" $(<"$package_list") \
    || die "pacstrap failed"

if [[ -d "${IMAGE_PROFILES_DIR}/${PROFILE}/overlay/rootfs" ]]; then
    log "Applying overlay files..."
    cp -r "${IMAGE_PROFILES_DIR}/${PROFILE}/overlay/rootfs/"* "${BUILD_DIR}/${BASE_SUBVOL}/" \
        || die "Overlay copy failed"
fi

if [[ -f "${IMAGE_PROFILES_DIR}/${PROFILE}/${PROFILE}-customization.sh" ]]; then
    log "Applying customizations..."
    bash "${IMAGE_PROFILES_DIR}/${PROFILE}/${PROFILE}-customization.sh" "${BUILD_DIR}/${BASE_SUBVOL}" \
        || die "Customizations failed"
fi

# ---------------------------------------------------------------------------
# chroot configuration
# ---------------------------------------------------------------------------
arch-chroot "${BUILD_DIR}/${BASE_SUBVOL}" /bin/bash <<EOF
set -euo pipefail

echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

systemd-machine-id-setup --commit

echo "${OS_NAME}" > /etc/hostname
echo "PRETTY_HOSTNAME=${OS_NAME}" > /etc/machine-info
printf '127.0.0.1 localhost\n::1       localhost\n127.0.1.1 %s\n' "${OS_NAME}" > /etc/hosts
echo "${BUILD_DATE}" > /etc/shani-version
echo "${PROFILE}" > /etc/shani-profile
echo "stable" > /etc/shani-channel

# Extra groups added to every user account at creation time.
# Single source of truth read by shani-user-setup, adduser wrapper, useradd wrapper.
echo "sys,cups,lp,scanner,realtime,input,video,kvm,libvirt,lxd,nixbld,sambashare" > /etc/shani-extra-groups
chmod 644 /etc/shani-extra-groups

mkdir -p /boot/efi /swap /data /nix

ln -s /var/lib/snapd/snap /snap

mkdir -p /var/lib/flatpak /var/lib/snapd /var/lib/waydroid /var/lib/containers \
         /var/lib/machines /var/lib/lxc /var/lib/lxd /var/lib/libvirt /var/lib/qemu \
         /var/cache /var/log

# Groups with confirmed static GIDs (Arch archwiki / systemd basic.conf)
getent group sys     &>/dev/null || groupadd -r -g 3   sys
getent group lp      &>/dev/null || groupadd -r -g 7   lp
getent group kvm     &>/dev/null || groupadd -r -g 78  kvm
getent group video   &>/dev/null || groupadd -r -g 91  video
getent group scanner &>/dev/null || groupadd -r -g 96  scanner
getent group input   &>/dev/null || groupadd -r -g 97  input
getent group cups    &>/dev/null || groupadd -r -g 209 cups

# Groups with no upstream static GID — allocate dynamically
getent group realtime   &>/dev/null || groupadd -r realtime
getent group nixbld     &>/dev/null || groupadd -r nixbld
getent group lxd        &>/dev/null || groupadd -r lxd
getent group libvirt    &>/dev/null || groupadd -r libvirt
getent group sambashare &>/dev/null || groupadd -r sambashare

# subuid/subgid for root — required for rootless podman, lxc, lxd
usermod -v 1000000-1000999999 -w 1000000-1000999999 root

# Import Shani signing public key (for update verification)
if [[ -f /etc/shani-keys/signing.asc ]]; then
    mkdir -p /root/.gnupg
    chmod 700 /root/.gnupg
    gpg --homedir /root/.gnupg --import /etc/shani-keys/signing.asc
    echo "${GPG_KEY_ID}:6:" | gpg --homedir /root/.gnupg --import-ownertrust
fi

chmod 0440 /etc/sudoers.d/path
EOF

# ---------------------------------------------------------------------------
# Snapshot and sign
# ---------------------------------------------------------------------------
btrfs property set -f -ts "${BUILD_DIR}/${BASE_SUBVOL}" ro true \
    || die "Failed to set subvolume read-only"

btrfs_send_snapshot "${BUILD_DIR}/${BASE_SUBVOL}" "${IMAGE_FILE}"

btrfs property set -ts "${BUILD_DIR}/${BASE_SUBVOL}" ro false \
    || die "Failed to reset subvolume to writable"

detach_btrfs_image "${BUILD_DIR}/${BASE_SUBVOL}" "$LOOP_DEVICE"

# ---------------------------------------------------------------------------
# Sign and checksum
# ---------------------------------------------------------------------------
gpg_prepare_keyring
gpg_sign_file "${IMAGE_FILE}"

cd "$(dirname "${IMAGE_FILE}")"
sha256sum "$(basename "${IMAGE_FILE}")" > "$(basename "${IMAGE_FILE}").sha256" \
    || die "Checksum generation failed"

echo "$(basename "${IMAGE_FILE}")" > "${OUTPUT_SUBDIR}/latest.txt"
log "Base image build completed successfully!"
