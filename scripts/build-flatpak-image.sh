#!/usr/bin/env bash
# build-flatpak-image.sh – Build the Flatpak image (container-only)

set -Eeuo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# Parse profile option
PROFILE="$DEFAULT_PROFILE"
while getopts "p:" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    *) die "Invalid option";;
  esac
done
shift $((OPTIND - 1))

# Define output subdirectory (same as base image)
OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
mkdir -p "${OUTPUT_SUBDIR}"

log "Building Flatpak image for profile: ${PROFILE}"

# Ensure Flathub remote is added
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Remove unused packages not in the list
log "Removing unused Flatpak packages not in the profile list"
installed_packages=$(flatpak list --system --columns=application | grep -v "flathub")
while IFS= read -r installed_pkg || [[ -n "$installed_pkg" ]]; do
    if ! grep -Fxq "$installed_pkg" "$FLATPAK_PACKAGE_LIST"; then
        log "Removing unused package: $installed_pkg"
        flatpak uninstall --assumeyes --noninteractive --system --delete-data "$installed_pkg" || warn "Failed to remove $installed_pkg"
    fi
done <<< "$installed_packages"

# Install Flatpak packages from profile list
FLATPAK_PACKAGE_LIST="${IMAGE_PROFILES_DIR}/${PROFILE}/flatpak-packages.txt"
if [[ -f "$FLATPAK_PACKAGE_LIST" ]]; then
    while IFS= read -r pkg || [[ -n "$pkg" ]]; do
        [[ -z "$pkg" ]] && continue
        log "Installing Flatpak package: $pkg"
        flatpak install --assumeyes --noninteractive --or-update --system flathub "$pkg" || warn "Failed to install $pkg"
    done < "$FLATPAK_PACKAGE_LIST"
else
    log "No Flatpak package list found at ${FLATPAK_PACKAGE_LIST}"
fi

flatpak uninstall --unused --system --delete-data || log "No unused Flatpak runtimes to remove."
flatpak remove --system --unused --delete-data -y || log "No unused Flatpak data to remove."
flatpak repair --system || log "Flatpak repair completed."

# Prepare Btrfs image for Flatpak data (1G)
FLATPAK_SOURCE="/var/lib/flatpak"
FLATPAK_IMG="${BUILD_DIR}/flatpak.img"
FLATPAK_SUBVOL="flatpak_subvol"
OUTPUT_FILE="${OUTPUT_SUBDIR}/flatpakfs.zst"

setup_btrfs_image "$FLATPAK_IMG" "10G"
# LOOP_DEVICE is automatically set by setup_btrfs_image function

# Mount image and create subvolume
FLATPAK_MOUNT="${BUILD_DIR}/flatpak_mount"
mkdir -p "$FLATPAK_MOUNT"
mount -o compress-force=zstd:19 "$LOOP_DEVICE" "$FLATPAK_MOUNT" || die "Failed to mount Flatpak image"
btrfs subvolume create "${FLATPAK_MOUNT}/${FLATPAK_SUBVOL}" || die "Failed to create subvolume for Flatpak data"

log "copying Flatpak data into Btrfs subvolume"

# Copy Flatpak data into the subvolume
tar -cf - -C "$FLATPAK_SOURCE" . | tar -xf - -C "${FLATPAK_MOUNT}/${FLATPAK_SUBVOL}" || die "Failed to copy Flatpak data"
sync

# Set subvolume read-only before taking snapshot
btrfs property set -f -ts "${FLATPAK_MOUNT}/${FLATPAK_SUBVOL}" ro true || die "Failed to set subvolume read-only"

btrfs_send_snapshot "${FLATPAK_MOUNT}/${FLATPAK_SUBVOL}" "${OUTPUT_FILE}"

# Reset subvolume to writable **only after** snapshot
btrfs property set -f -ts "${FLATPAK_MOUNT}/${FLATPAK_SUBVOL}" ro false || die "Failed to reset subvolume properties"

detach_btrfs_image "$FLATPAK_MOUNT" "$LOOP_DEVICE"

log "Flatpak image created successfully at ${OUTPUT_FILE}"

