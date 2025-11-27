#!/usr/bin/env bash
# build-snap-image.sh — Build the Snap image (container-only)

set -Eeuo pipefail

# Ensure machine-id exists for DBUS
if [ ! -f /etc/machine-id ]; then
    dbus-uuidgen --ensure=/etc/machine-id
fi

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

log "Building Snap image for profile: ${PROFILE}"

# Ensure snapd is running
if ! systemctl is-active --quiet snapd.socket; then
    log "Starting snapd.socket..."
    systemctl start snapd.socket
fi

if ! systemctl is-active --quiet snapd; then
    log "Starting snapd service..."
    systemctl start snapd
fi

# Wait for snapd to be ready
log "Waiting for snapd to be ready..."
snap wait system seed.loaded

SNAP_PACKAGE_LIST="${IMAGE_PROFILES_DIR}/${PROFILE}/snap-packages.txt"

# Check for package list file and load packages into an array
if [[ ! -f "$SNAP_PACKAGE_LIST" ]]; then
    log "No Snap package list found at ${SNAP_PACKAGE_LIST}. Exiting..."
    exit 0
fi

packages=()
while IFS= read -r pkg || [[ -n "$pkg" ]]; do
    # Skip empty lines or lines containing only whitespace
    [[ -z "${pkg// }" ]] && continue
    # Skip comments
    [[ "$pkg" =~ ^[[:space:]]*# ]] && continue
    packages+=("$pkg")
done < "$SNAP_PACKAGE_LIST"

# Install Snap packages from profile list
for pkg in "${packages[@]}"; do
    # Parse package with optional channel (e.g., "firefox" or "firefox --classic" or "firefox --channel=beta")
    pkg_name=$(echo "$pkg" | awk '{print $1}')
    pkg_args=$(echo "$pkg" | cut -d' ' -f2-)
    
    log "Installing Snap package: $pkg_name (with args: $pkg_args)"
    
    if [[ "$pkg_args" == "$pkg_name" ]]; then
        # No additional arguments
        if ! snap install "$pkg_name"; then
            warn "Failed to install $pkg_name"
        fi
    else
        # Has additional arguments (e.g., --classic, --channel=edge)
        if ! snap install $pkg_name $pkg_args; then
            warn "Failed to install $pkg_name with args: $pkg_args"
        fi
    fi
done

# Refresh all installed snaps to ensure they're up to date
log "Refreshing all installed Snaps..."
if ! snap refresh; then
    warn "Failed to refresh some Snaps"
fi

# Remove unused Snap applications not in the profile list
log "Removing unused Snap applications not in the profile list"
installed_snaps=$(snap list --color=never | tail -n +2 | awk '{print $1}' || true)

if [[ -z "$installed_snaps" ]]; then
    warn "No Snap applications found to remove. Proceeding..."
fi

while IFS= read -r snap_pkg || [[ -n "$snap_pkg" ]]; do
    # Skip core snaps (snapd, core, core18, core20, core22, etc.)
    if [[ "$snap_pkg" =~ ^(snapd|core[0-9]*)$ ]]; then
        log "Keeping core snap: $snap_pkg"
        continue
    fi
    
    # Extract just the package name from the profile list (ignore arguments)
    pkg_in_list=0
    for profile_pkg in "${packages[@]}"; do
        profile_pkg_name=$(echo "$profile_pkg" | awk '{print $1}')
        if [[ "$snap_pkg" == "$profile_pkg_name" ]]; then
            pkg_in_list=1
            break
        fi
    done
    
    if [[ $pkg_in_list -eq 0 ]]; then
        log "Removing unused snap: $snap_pkg"
        if ! snap remove --purge "$snap_pkg"; then
            warn "Failed to remove $snap_pkg"
        fi
    fi
done <<< "$installed_snaps"

# Profile-specific configurations
if [[ "$PROFILE" == "plasma" ]]; then
    log "Applying Plasma-specific Snap configurations..."
    # Add any KDE Plasma specific snap configurations here
fi

if [[ "$PROFILE" == "gamescope" ]]; then
    log "Applying gamescope-specific Snap configurations..."
    # Add any gamescope specific snap configurations here
fi

# Prepare Btrfs image for Snap data
SNAP_IMG="${BUILD_DIR}/snap.img"
SNAP_SUBVOL="snap_subvol"
OUTPUT_FILE="${OUTPUT_SUBDIR}/snapfs.zst"

# This function is assumed to set up a loop device and create a Btrfs image.
setup_btrfs_image "$SNAP_IMG" "10G"  # Make sure this function is defined
# LOOP_DEVICE is set by setup_btrfs_image

# Define mount point for Snap image
SNAP_MOUNT="${BUILD_DIR}/snap_mount"

# Mount the loop device and create (or delete) the subvolume
mkdir -p "$SNAP_MOUNT"
if ! mount -t btrfs -o compress-force=zstd:19 "$LOOP_DEVICE" "$SNAP_MOUNT"; then
    die "Failed to mount Snap image"
fi

if btrfs subvolume list "$SNAP_MOUNT" | grep -q "$SNAP_SUBVOL"; then
    log "Deleting existing subvolume ${SNAP_SUBVOL}..."
    if ! btrfs subvolume delete "$SNAP_MOUNT/$SNAP_SUBVOL"; then
        die "Failed to delete existing subvolume"
    fi
fi

log "Creating new subvolume: ${SNAP_SUBVOL}"
if ! btrfs subvolume create "$SNAP_MOUNT/$SNAP_SUBVOL"; then
    die "Subvolume creation failed"
fi
sync
if ! umount "$SNAP_MOUNT"; then
    die "Failed to unmount Snap image after subvolume creation"
fi

# Remount the newly created subvolume
mkdir -p "$SNAP_MOUNT"
if ! mount -o subvol="$SNAP_SUBVOL",compress-force=zstd:19 "$LOOP_DEVICE" "$SNAP_MOUNT"; then
    die "Mounting Snap subvolume failed"
fi

# Copy Snap data into the subvolume
log "Copying Snap data into Btrfs subvolume"

# Create necessary directory structure
mkdir -p "$SNAP_MOUNT/snap"
mkdir -p "$SNAP_MOUNT/var/lib/snapd"

# Copy snap installations and snapd state
if ! tar -cf - -C /snap . | tar -xf - -C "$SNAP_MOUNT/snap"; then
    die "Failed to copy Snap installations"
fi

if ! tar -cf - -C /var/lib/snapd . | tar -xf - -C "$SNAP_MOUNT/var/lib/snapd"; then
    die "Failed to copy Snapd state"
fi

sync

# Set subvolume read-only before taking snapshot
if ! btrfs property set -f -ts "$SNAP_MOUNT" ro true; then
    die "Failed to set subvolume read-only"
fi

# Take a snapshot of the subvolume (this function must be defined)
btrfs_send_snapshot "$SNAP_MOUNT" "${OUTPUT_FILE}"

# Reset subvolume to writable after snapshot
if ! btrfs property set -f -ts "$SNAP_MOUNT" ro false; then
    die "Failed to reset subvolume properties"
fi

# Detach the Btrfs image (this function must be defined)
detach_btrfs_image "$SNAP_MOUNT" "$LOOP_DEVICE"

log "Snap image created successfully at ${OUTPUT_FILE}"
