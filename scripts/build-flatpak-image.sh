#!/usr/bin/env bash
# build-flatpak-image.sh – Build the Flatpak image (container-only)

set -Eeuo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"  # Ensure that functions like die, warn, log, etc. are defined here

# Parse profile option
PROFILE="$DEFAULT_PROFILE"
while getopts "p:" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    *) die "Invalid option" ;;
  esac
done
shift $((OPTIND - 1))

# Define output subdirectory (using the base image's structure)
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
    # Skip empty lines or lines containing only whitespace
    [[ -z "${pkg// }" ]] && continue
    packages+=("$pkg")
done < "$FLATPAK_PACKAGE_LIST"

# Install Flatpak packages from profile list
for pkg in "${packages[@]}"; do
    log "Installing Flatpak package: $pkg"
    if ! flatpak install --assumeyes --noninteractive --or-update --system flathub "$pkg"; then
        warn "Failed to install or update $pkg"
    fi
done

# Detect required runtimes from the package list
declare -A required_runtimes
for pkg in "${packages[@]}"; do
    runtime_full=$(flatpak info --show-runtime "$pkg" 2>/dev/null || true)
    if [[ -n "$runtime_full" ]]; then
        runtime_base=$(echo "$runtime_full" | cut -d'/' -f1)
        required_runtimes["$runtime_base"]=1
        log "Detected runtime '$runtime_full' (base: '$runtime_base') required for package '$pkg'"
    fi
done

# Detect required extensions from the package list
declare -A required_extensions
for pkg in "${packages[@]}"; do
    extension_full=$(flatpak info --show-extensions "$pkg" 2>/dev/null || true)
    if [[ -n "$extension_full" ]]; then
        extension_base=$(echo "$extension_full" | cut -d'/' -f1)
        required_extensions["$extension_base"]=1
        log "Detected extension '$extension_full' (base: '$extension_base') required for package '$pkg'"
    fi
done

# Remove unused Flatpak applications not in the profile list
log "Removing unused Flatpak applications not in the profile list"
installed_apps=$(flatpak list --system --app --columns=application || true)
if [[ -z "$installed_apps" ]]; then
    warn "No Flatpak applications found to remove. Proceeding..."
fi

while IFS= read -r app || [[ -n "$app" ]]; do
    if ! printf '%s\n' "${packages[@]}" | grep -Fxq "$app"; then
        log "Removing unused application: $app"
        if ! flatpak uninstall --assumeyes --noninteractive --system --delete-data "$app"; then
            warn "Failed to remove $app"
        fi
    fi
done <<< "$installed_apps"

# Remove runtimes and extensions not required by any app in the profile list
log "Removing runtimes and extensions not required by apps in the profile list"
installed_runtimes=$(flatpak list --system --runtime --columns=application || true)
if [[ -z "$installed_runtimes" ]]; then
    warn "No Flatpak runtimes found to remove. Proceeding..."
fi

while IFS= read -r pkg || [[ -n "$pkg" ]]; do
    keep=0
    # For packages starting with "runtime/", try to extract base runtime name
    if [[ "$pkg" == runtime/* ]]; then
         runtime_name="${pkg#runtime/}"
         runtime_name="${runtime_name%%/*}"  # e.g. org.gnome.Platform or similar
         if [[ "$runtime_name" == *.* ]]; then
             # Remove last dot-separated token (to get base app name)
             base_app="${runtime_name%.*}"
             if printf '%s\n' "${packages[@]}" | grep -Fxq "$base_app"; then
                 log "Keeping runtime extension $pkg because base app $base_app is in the package list"
                 keep=1
             fi
         fi
    fi
    # Check if pkg is required as a runtime
    if [[ $keep -eq 0 ]]; then
        for req in "${!required_runtimes[@]}"; do
            if [[ "$pkg" == "$req" || "$pkg" == "$req"* ]]; then
                keep=1
                break
            fi
        done
    fi
    # Also check if pkg is required as an extension
    if [[ $keep -eq 0 ]]; then
        for req in "${!required_extensions[@]}"; do
            if [[ "$pkg" == "$req" || "$pkg" == "$req"* ]]; then
                keep=1
                break
            fi
        done
    fi
    if [[ $keep -eq 0 ]]; then
        log "Removing package not required: $pkg"
        if ! flatpak uninstall --assumeyes --noninteractive --system --delete-data "$pkg"; then
            warn "Failed to remove package $pkg"
        fi
    else
        log "Keeping required package: $pkg"
    fi
done <<< "$installed_runtimes"

# Run repair to clean up any remaining inconsistencies;
if ! flatpak repair --system; then
    warn "Flatpak repair encountered issues"
else
    log "Flatpak repair completed successfully"
fi

# Prepare Btrfs image for Flatpak data (10G)
FLATPAK_IMG="${BUILD_DIR}/flatpak.img"
FLATPAK_SUBVOL="flatpak_subvol"
OUTPUT_FILE="${OUTPUT_SUBDIR}/flatpakfs.zst"

# This function is assumed to set up a loop device and create a Btrfs image.
setup_btrfs_image "$FLATPAK_IMG" "10G"  # Make sure this function is defined
# LOOP_DEVICE is set by setup_btrfs_image

# Define mount point for Flatpak image
FLATPAK_MOUNT="${BUILD_DIR}/flatpak_mount"

# Mount the loop device and create (or delete) the subvolume
mkdir -p "$FLATPAK_MOUNT"
if ! mount -t btrfs -o compress-force=zstd:19 "$LOOP_DEVICE" "$FLATPAK_MOUNT"; then
    die "Failed to mount Flatpak image"
fi

if btrfs subvolume list "$FLATPAK_MOUNT" | grep -q "$FLATPAK_SUBVOL"; then
    log "Deleting existing subvolume ${FLATPAK_SUBVOL}..."
    if ! btrfs subvolume delete "$FLATPAK_MOUNT/$FLATPAK_SUBVOL"; then
        die "Failed to delete existing subvolume"
    fi
fi

log "Creating new subvolume: ${FLATPAK_SUBVOL}"
if ! btrfs subvolume create "$FLATPAK_MOUNT/$FLATPAK_SUBVOL"; then
    die "Subvolume creation failed"
fi
sync
if ! umount "$FLATPAK_MOUNT"; then
    die "Failed to unmount Flatpak image after subvolume creation"
fi

# Remount the newly created subvolume
mkdir -p "$FLATPAK_MOUNT"
if ! mount -o subvol="$FLATPAK_SUBVOL",compress-force=zstd:19 "$LOOP_DEVICE" "$FLATPAK_MOUNT"; then
    die "Mounting Flatpak subvolume failed"
fi

# Copy Flatpak data into the subvolume
log "Copying Flatpak data into Btrfs subvolume"
if ! tar -cf - -C /var/lib/flatpak . | tar -xf - -C "$FLATPAK_MOUNT"; then
    die "Failed to copy Flatpak data"
fi
sync

# Set subvolume read-only before taking snapshot
if ! btrfs property set -f -ts "$FLATPAK_MOUNT" ro true; then
    die "Failed to set subvolume read-only"
fi

# Take a snapshot of the subvolume (this function must be defined)
btrfs_send_snapshot "$FLATPAK_MOUNT" "${OUTPUT_FILE}"

# Reset subvolume to writable after snapshot
if ! btrfs property set -f -ts "$FLATPAK_MOUNT" ro false; then
    die "Failed to reset subvolume properties"
fi

# Detach the Btrfs image (this function must be defined)
detach_btrfs_image "$FLATPAK_MOUNT" "$LOOP_DEVICE"

log "Flatpak image created successfully at ${OUTPUT_FILE}"

