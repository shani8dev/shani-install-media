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
    *) die "Invalid option" ;;
  esac
done
shift $((OPTIND - 1))

# Define output subdirectory (same as base image)
OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
mkdir -p "${OUTPUT_SUBDIR}"

log "Building Flatpak image for profile: ${PROFILE}"

# Ensure Flathub remote is added
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

FLATPAK_PACKAGE_LIST="${IMAGE_PROFILES_DIR}/${PROFILE}/flatpak-packages.txt"

# Check for package list file and load packages into an array
if [[ ! -f "$FLATPAK_PACKAGE_LIST" ]]; then
    log "No Flatpak package list found at ${FLATPAK_PACKAGE_LIST}. Exiting..."
    exit 0
fi

packages=()
while IFS= read -r pkg || [[ -n "$pkg" ]]; do
    [[ -z "$pkg" ]] && continue
    packages+=("$pkg")
done < "$FLATPAK_PACKAGE_LIST"

# Install Flatpak packages from profile list
for pkg in "${packages[@]}"; do
    log "Installing Flatpak package: $pkg"
    flatpak install --assumeyes --noninteractive --or-update --system flathub "$pkg" || warn "Failed to install $pkg"
done

# Detect required runtimes from the package list
declare -A required_runtimes
for pkg in "${packages[@]}"; do
    runtime_full=$(flatpak info --show-runtime "$pkg" 2>/dev/null)
    if [[ -n "$runtime_full" ]]; then
        runtime_base=$(echo "$runtime_full" | cut -d'/' -f1)
        required_runtimes["$runtime_base"]=1
        log "Detected runtime '$runtime_full' (base: '$runtime_base') required for package '$pkg'"
    fi
done

# Detect required extensions from the package list
declare -A required_extensions
for pkg in "${packages[@]}"; do
    extension_full=$(flatpak info --show-extensions "$pkg" 2>/dev/null)
    if [[ -n "$extension_full" ]]; then
        extension_base=$(echo "$extension_full" | cut -d'/' -f1)
        required_extensions["$extension_base"]=1
        log "Detected extension '$extension_full' (base: '$extension_base') required for package '$pkg'"
    fi
done

# Remove unused Flatpak applications not in the profile list
log "Removing unused Flatpak applications not in the profile list"
installed_apps=$(flatpak list --system --app --columns=application)
if [[ -z "$installed_apps" ]]; then
    warn "Warning: No Flatpak applications found to remove. Proceeding..."
fi

while IFS= read -r app || [[ -n "$app" ]]; do
    if ! printf '%s\n' "${packages[@]}" | grep -Fxq "$app"; then
        log "Removing unused application: $app"
        flatpak uninstall --assumeyes --noninteractive --system --delete-data "$app" || warn "Failed to remove $app"
    fi
done <<< "$installed_apps"

# Remove runtimes (and any extensions reported as runtimes) not required by any app
log "Removing runtimes and extensions not required by apps in the profile list"
installed_runtimes=$(flatpak list --system --runtime --columns=application)
if [[ -z "$installed_runtimes" ]]; then
    warn "Warning: No Flatpak runtimes found to remove. Proceeding..."
fi

while IFS= read -r pkg || [[ -n "$pkg" ]]; do
    # If this package looks like an extension, check if it is used by any application.
    if [[ "$pkg" == *".Extension."* ]]; then
        # This check leverages flatpak info output which lists applications using the extension.
        if flatpak info "$pkg" 2>/dev/null | grep -q "Info: applications using the extension"; then
            log "Keeping extension $pkg because it is used by an application"
            continue
        fi
    fi

    keep=0
    # Check if pkg is required as a runtime.
    for req in "${!required_runtimes[@]}"; do
        if [[ "$pkg" == "$req" || "$pkg" == "$req"* ]]; then
            keep=1
            break
        fi
    done
    # Also check if pkg is required as an extension.
    for req in "${!required_extensions[@]}"; do
        if [[ "$pkg" == "$req" || "$pkg" == "$req"* ]]; then
            keep=1
            break
        fi
    done
    if [[ $keep -eq 0 ]]; then
        log "Removing package not required: $pkg"
        flatpak uninstall --assumeyes --noninteractive --system --delete-data "$pkg" || warn "Failed to remove package $pkg"
    else
        log "Keeping required package: $pkg"
    fi
done <<< "$installed_runtimes"

# Optionally, run repair to clean up any remaining inconsistencies
flatpak repair --system || log "Flatpak repair completed."

# Prepare Btrfs image for Flatpak data (10G)
FLATPAK_IMG="${BUILD_DIR}/flatpak.img"
FLATPAK_SUBVOL="flatpak_subvol"
OUTPUT_FILE="${OUTPUT_SUBDIR}/flatpakfs.zst"

setup_btrfs_image "$FLATPAK_IMG" "10G"
# LOOP_DEVICE is set by setup_btrfs_image

# Define mount point for Flatpak image
FLATPAK_MOUNT="${BUILD_DIR}/flatpak_mount"

# Mount the loop device, create the subvolume, unmount, then remount the subvolume
mkdir -p "$FLATPAK_MOUNT"
mount -t btrfs -o compress-force=zstd:19 "$LOOP_DEVICE" "$FLATPAK_MOUNT" || die "Failed to mount Flatpak image"
if btrfs subvolume list "$FLATPAK_MOUNT" | grep -q "$FLATPAK_SUBVOL"; then
    log "Deleting existing subvolume ${FLATPAK_SUBVOL}..."
    btrfs subvolume delete "$FLATPAK_MOUNT/$FLATPAK_SUBVOL" || die "Failed to delete existing subvolume"
fi
log "Creating new subvolume: ${FLATPAK_SUBVOL}"
btrfs subvolume create "$FLATPAK_MOUNT/$FLATPAK_SUBVOL" || die "Subvolume creation failed"
sync
umount "$FLATPAK_MOUNT" || die "Failed to unmount Flatpak image after subvolume creation"

mkdir -p "$FLATPAK_MOUNT"
mount -o subvol="$FLATPAK_SUBVOL",compress-force=zstd:19 "$LOOP_DEVICE" "$FLATPAK_MOUNT" || die "Mounting Flatpak subvolume failed"

# Copy Flatpak data into the subvolume
log "Copying Flatpak data into Btrfs subvolume"
tar -cf - -C /var/lib/flatpak . | tar -xf - -C "$FLATPAK_MOUNT" || die "Failed to copy Flatpak data"
sync

# Set subvolume read-only before taking snapshot
btrfs property set -f -ts "$FLATPAK_MOUNT" ro true || die "Failed to set subvolume read-only"

btrfs_send_snapshot "$FLATPAK_MOUNT" "${OUTPUT_FILE}"

# Reset subvolume to writable after snapshot
btrfs property set -f -ts "$FLATPAK_MOUNT" ro false || die "Failed to reset subvolume properties"

detach_btrfs_image "$FLATPAK_MOUNT" "$LOOP_DEVICE"

log "Flatpak image created successfully at ${OUTPUT_FILE}"

