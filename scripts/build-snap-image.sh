#!/usr/bin/env bash
# build-snap-image.sh — Build the Snap image (container-only)

set -Eeuo pipefail

# Ensure machine-id exists for DBUS
if [ ! -f /etc/machine-id ]; then
    dbus-uuidgen --ensure=/etc/machine-id
fi

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

# Define output subdirectory
OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
mkdir -p "${OUTPUT_SUBDIR}"

log "Building Snap image for profile: ${PROFILE}"

# ===== MOCK SYSTEMCTL FOR CONTAINER BUILDS =====
log "Setting up mock systemctl for container environment..."

# Backup real systemctl if it exists
if [ -f /usr/bin/systemctl ] && [ ! -f /usr/bin/systemctl.real ]; then
    cp /usr/bin/systemctl /usr/bin/systemctl.real 2>/dev/null || true
fi

# Create mock systemctl
cat > /usr/local/bin/systemctl << 'EOF'
#!/bin/bash
# Mock systemctl for snap installation in containers
COMMAND="${1:-}"
case "$COMMAND" in
    daemon-reload|start|stop|restart|enable|disable|reload|reset-failed)
        exit 0 ;;
    is-active|is-enabled|is-failed)
        echo "active"
        exit 0 ;;
    show)
        echo "ActiveState=active"
        echo "LoadState=loaded"
        echo "SubState=running"
        exit 0 ;;
    list-units|list-unit-files)
        exit 0 ;;
    status)
        echo "● $*"
        echo "   Loaded: loaded"
        echo "   Active: active (running)"
        exit 0 ;;
    *)
        exit 0 ;;
esac
EOF

chmod +x /usr/local/bin/systemctl
export PATH="/usr/local/bin:$PATH"

log "Mock systemctl installed"

# ===== SNAPD SETUP FOR CONTAINER =====
log "Setting up snapd in container environment..."

# Fix snap mount directory for Arch Linux
export SNAP_MOUNT_DIR="/var/lib/snapd/snap"

# Ensure required directories exist
mkdir -p /run/snapd /var/lib/snapd/snap /var/lib/snapd /var/snap /snap

# Create symlink from /snap to /var/lib/snapd/snap for compatibility
if [ ! -L /snap ] || [ "$(readlink /snap)" != "/var/lib/snapd/snap" ]; then
    rm -rf /snap
    ln -sf /var/lib/snapd/snap /snap
fi

# Ensure loop control devices are available
if [ ! -e /dev/loop-control ]; then
    warn "/dev/loop-control not available. Loop device operations may fail."
fi

# Check if snapd is already running
if [ -S /run/snapd.socket ]; then
    log "Snapd socket already exists"
else
    log "Starting snapd daemon..."
    
    # Kill any existing snapd processes
    pkill -9 snapd 2>/dev/null || true
    sleep 1
    
    # Start snapd in background
    /usr/lib/snapd/snapd &
    SNAPD_PID=$!
    
    # Wait for socket with timeout
    log "Waiting for snapd socket..."
    for i in {1..90}; do
        if [ -S /run/snapd.socket ]; then
            log "Snapd socket is ready (attempt $i)"
            break
        fi
        if [ $i -eq 90 ]; then
            die "Snapd socket not available after 90 seconds"
        fi
        sleep 1
    done
fi

# Test snapd connectivity
log "Testing snapd connection..."
if ! timeout 15 snap version &>/dev/null; then
    die "Cannot communicate with snapd"
fi

log "Snapd is operational: $(snap version | head -1)"

# Wait for system seed (may not exist in container)
snap wait system seed.loaded 2>/dev/null || log "System seed not available (expected in container)"

SNAP_PACKAGE_LIST="${IMAGE_PROFILES_DIR}/${PROFILE}/snap-packages.txt"

# Check for package list file
if [[ ! -f "$SNAP_PACKAGE_LIST" ]]; then
    log "No Snap package list found at ${SNAP_PACKAGE_LIST}"
    exit 0
fi

# Load packages into array
packages=()
while IFS= read -r pkg || [[ -n "$pkg" ]]; do
    [[ -z "${pkg// }" ]] && continue
    [[ "$pkg" =~ ^[[:space:]]*# ]] && continue
    packages+=("$pkg")
done < "$SNAP_PACKAGE_LIST"

if [ ${#packages[@]} -eq 0 ]; then
    log "No packages to install from ${SNAP_PACKAGE_LIST}"
    exit 0
fi

# ===== INSTALL SNAP PACKAGES =====
log "Installing ${#packages[@]} snap package(s)..."

for pkg in "${packages[@]}"; do
    pkg_name=$(echo "$pkg" | awk '{print $1}')
    pkg_args=$(echo "$pkg" | cut -d' ' -f2-)
    [[ "$pkg_args" == "$pkg_name" ]] && pkg_args=""
    
    log "Processing: $pkg_name${pkg_args:+ with args: $pkg_args}"
    
    # Try normal installation first
    install_success=false
    install_log=$(mktemp)
    
    if [ -z "$pkg_args" ]; then
        if snap install "$pkg_name" &>"$install_log"; then
            install_success=true
        fi
    else
        if snap install $pkg_name $pkg_args &>"$install_log"; then
            install_success=true
        fi
    fi
    
    # Check if failed due to mount issues
    if ! $install_success; then
        if grep -q "expected snap.*to be mounted but is not" "$install_log"; then
            warn "Mount failed for $pkg_name, using manual extraction..."
            
            # Create temp directory for download
            temp_dir=$(mktemp -d)
            cd "$temp_dir"
            
            # Download the snap
            if snap download "$pkg_name" &>/dev/null; then
                snap_file=$(ls ${pkg_name}_*.snap 2>/dev/null | head -1)
                
                if [ -n "$snap_file" ] && [ -f "$snap_file" ]; then
                    # Create target directory
                    snap_target="/var/lib/snapd/snap/$pkg_name"
                    mkdir -p "$snap_target"
                    
                    # Extract using unsquashfs
                    if command -v unsquashfs &>/dev/null; then
                        if unsquashfs -f -d "$snap_target/current" "$snap_file" &>/dev/null; then
                            log "Successfully extracted $pkg_name"
                            install_success=true
                            
                            # Create version symlink if we can determine revision
                            revision=$(echo "$snap_file" | grep -oP '(?<=_)[0-9]+(?=\.snap)')
                            if [ -n "$revision" ]; then
                                ln -sf current "$snap_target/$revision" 2>/dev/null || true
                            fi
                        else
                            warn "Failed to extract $snap_file"
                        fi
                    else
                        warn "unsquashfs not available, cannot extract $pkg_name"
                    fi
                else
                    warn "Downloaded snap file not found for $pkg_name"
                fi
            else
                warn "Failed to download $pkg_name"
            fi
            
            # Cleanup temp directory
            cd - &>/dev/null
            rm -rf "$temp_dir"
        else
            warn "Failed to install $pkg_name: $(tail -1 "$install_log")"
        fi
    else
        log "Successfully installed $pkg_name"
    fi
    
    rm -f "$install_log"
done

# Refresh all installed snaps
log "Refreshing all installed Snaps..."
snap refresh 2>&1 | grep -v "All snaps up to date" || log "Snaps refreshed"

# Remove unused Snap applications not in profile list
log "Checking for unused Snap applications..."

# Get list of snaps that are actually installed via snapd
installed_snaps=$(snap list --color=never 2>/dev/null | tail -n +2 | awk '{print $1}' || echo "")

# Also check for manually extracted snaps in /var/lib/snapd/snap
if [ -d "/var/lib/snapd/snap" ]; then
    extracted_snaps=$(ls -1 /var/lib/snapd/snap 2>/dev/null || echo "")
else
    extracted_snaps=""
fi

# Combine both lists and get unique entries
all_snaps=$(echo -e "${installed_snaps}\n${extracted_snaps}" | sort -u | grep -v "^$")

if [[ -n "$all_snaps" ]]; then
    while IFS= read -r snap_pkg; do
        [[ -z "$snap_pkg" ]] && continue
        
        # Skip core snaps (snapd, core, core18, core20, core22, etc.)
        if [[ "$snap_pkg" =~ ^(snapd|core[0-9]*)$ ]]; then
            log "Keeping core snap: $snap_pkg"
            continue
        fi
        
        # Skip common snapd directories that aren't actual snaps
        if [[ "$snap_pkg" =~ ^(bin)$ ]]; then
            continue
        fi
        
        # Check if in profile list
        pkg_in_list=false
        for profile_pkg in "${packages[@]}"; do
            profile_pkg_name=$(echo "$profile_pkg" | awk '{print $1}')
            if [[ "$snap_pkg" == "$profile_pkg_name" ]]; then
                pkg_in_list=true
                break
            fi
        done
        
        if ! $pkg_in_list; then
            log "Removing unused snap: $snap_pkg"
            
            # Try to remove via snap command first (for properly installed snaps)
            if echo "$installed_snaps" | grep -q "^${snap_pkg}$"; then
                if snap remove --purge "$snap_pkg" 2>&1 | grep -q "removed"; then
                    log "Removed via snap command: $snap_pkg"
                else
                    warn "Failed to remove via snap command: $snap_pkg"
                fi
            fi
            
            # Remove manually extracted snap directory
            if [ -d "/var/lib/snapd/snap/$snap_pkg" ]; then
                log "Removing manually extracted directory: /var/lib/snapd/snap/$snap_pkg"
                rm -rf "/var/lib/snapd/snap/$snap_pkg"
            fi
            
            # Also check and remove from /snap if it's not a symlink
            if [ -d "/snap/$snap_pkg" ] && [ ! -L "/snap/$snap_pkg" ]; then
                log "Removing directory: /snap/$snap_pkg"
                rm -rf "/snap/$snap_pkg"
            fi
        else
            log "Keeping snap in profile: $snap_pkg"
        fi
    done <<< "$all_snaps"
else
    log "No snap applications found to check"
fi

# Profile-specific configurations
case "$PROFILE" in
    plasma)
        log "Applying Plasma-specific Snap configurations..."
        ;;
    gamescope)
        log "Applying gamescope-specific Snap configurations..."
        ;;
esac

# ===== PREPARE BTRFS IMAGE =====
SNAP_IMG="${BUILD_DIR}/snap.img"
SNAP_SUBVOL="snap_subvol"
OUTPUT_FILE="${OUTPUT_SUBDIR}/snapfs.zst"

log "Setting up Btrfs image for snap data..."
setup_btrfs_image "$SNAP_IMG" "10G"

# Verify loop device
if [ ! -b "$LOOP_DEVICE" ]; then
    die "Loop device $LOOP_DEVICE is not available"
fi

# Define mount point
SNAP_MOUNT="${BUILD_DIR}/snap_mount"
mkdir -p "$SNAP_MOUNT"

# Mount the Btrfs image
if ! mount -t btrfs -o compress-force=zstd:19 "$LOOP_DEVICE" "$SNAP_MOUNT"; then
    die "Failed to mount Snap image"
fi

# Delete existing subvolume if present
if btrfs subvolume list "$SNAP_MOUNT" | grep -q "$SNAP_SUBVOL"; then
    log "Deleting existing subvolume ${SNAP_SUBVOL}..."
    btrfs subvolume delete "$SNAP_MOUNT/$SNAP_SUBVOL" || die "Failed to delete existing subvolume"
fi

# Create new subvolume
log "Creating new subvolume: ${SNAP_SUBVOL}"
btrfs subvolume create "$SNAP_MOUNT/$SNAP_SUBVOL" || die "Subvolume creation failed"
sync
umount "$SNAP_MOUNT" || die "Failed to unmount after subvolume creation"

# Remount subvolume
if ! mount -o subvol="$SNAP_SUBVOL",compress-force=zstd:19 "$LOOP_DEVICE" "$SNAP_MOUNT"; then
    die "Mounting Snap subvolume failed"
fi

# ===== COPY SNAP DATA =====
log "Copying all Snap data into Btrfs subvolume using tar"

if [ -d "/var/lib/snapd" ] && [ "$(ls -A /var/lib/snapd 2>/dev/null)" ]; then
    if ! tar -cf - -C /var/lib/snapd . | tar -xf - -C "$SNAP_MOUNT" 2>&1; then
        warn "Failed to copy some snap data from /var/lib/snapd"
    else
        log "Snap data copied successfully"
    fi
else
    log "No data found in /var/lib/snapd"
fi

sync

# Set subvolume read-only
btrfs property set -f -ts "$SNAP_MOUNT" ro true || die "Failed to set subvolume read-only"

# Take snapshot
btrfs_send_snapshot "$SNAP_MOUNT" "${OUTPUT_FILE}"

# Reset to writable
btrfs property set -f -ts "$SNAP_MOUNT" ro false || warn "Failed to reset subvolume properties"

# Detach image
detach_btrfs_image "$SNAP_MOUNT" "$LOOP_DEVICE"

# ===== CLEANUP =====
if [ -n "${SNAPD_PID:-}" ]; then
    log "Stopping snapd daemon..."
    kill $SNAPD_PID 2>/dev/null || true
    wait $SNAPD_PID 2>/dev/null || true
fi

log "Cleaning up mocks..."
rm -f /usr/local/bin/systemctl
if [ -f /usr/bin/systemctl.real ]; then
    mv /usr/bin/systemctl.real /usr/bin/systemctl 2>/dev/null || true
fi

log "Snap image created successfully at ${OUTPUT_FILE}"

