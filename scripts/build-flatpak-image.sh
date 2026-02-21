#!/usr/bin/env bash
# build-flatpak-image.sh — Build the Flatpak image (container-only)

set -Eeuo pipefail

# Ensure machine-id exists for DBUS
if [ ! -f /etc/machine-id ]; then
    dbus-uuidgen --ensure=/etc/machine-id
fi

# (Optional) Set XDG_DATA environment variables so applications find Flatpak exports
export XDG_DATA_HOME=/usr/share
export XDG_DATA_DIRS=/var/lib/flatpak/exports/share:/usr/share

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

# Build a comprehensive list of all dependencies for installed apps
declare -A required_runtimes
declare -A required_extensions

log "Building dependency map for all installed applications..."

# Get all installed applications
all_installed_apps=$(flatpak list --system --app --columns=application || true)

while IFS= read -r app || [[ -n "$app" ]]; do
    [[ -z "$app" ]] && continue
    
    # Get runtime for this app
    runtime_full=$(flatpak info --show-runtime "$app" 2>/dev/null || true)
    if [[ -n "$runtime_full" ]]; then
        runtime_base=$(echo "$runtime_full" | cut -d'/' -f1)
        required_runtimes["$runtime_base"]=1
        log "App '$app' requires runtime: $runtime_base"
    fi
    
    # Get metadata to find extension points
    metadata=$(flatpak info --show-metadata "$app" 2>/dev/null || true)
    
    # Parse metadata for extension dependencies
    while IFS= read -r line; do
        # Look for Extension point declarations or runtime extensions
        if [[ "$line" =~ Extension.*=.* ]]; then
            # Extract extension name if present
            if [[ "$line" =~ Extension\ (.+)= ]]; then
                ext_name="${BASH_REMATCH[1]}"
                required_extensions["$ext_name"]=1
                log "App '$app' has extension point: $ext_name"
            fi
        fi
    done <<< "$metadata"
    
done <<< "$all_installed_apps"

# Additionally, scan all currently installed runtimes to build full dependency tree
log "Scanning installed runtimes for dependencies..."
all_runtimes=$(flatpak list --system --runtime --columns=application || true)

# Create a map of what each runtime depends on
declare -A runtime_deps

while IFS= read -r runtime || [[ -n "$runtime" ]]; do
    [[ -z "$runtime" ]] && continue
    
    runtime_base="${runtime#runtime/}"
    runtime_base="${runtime_base%%/*}"
    
    # Get metadata for this runtime to see what it depends on
    metadata=$(flatpak info --show-metadata "$runtime" 2>/dev/null || true)
    
    # Parse for runtime dependencies
    while IFS= read -r line; do
        if [[ "$line" =~ ^runtime= ]]; then
            dep_runtime=$(echo "$line" | cut -d'=' -f2)
            dep_base=$(echo "$dep_runtime" | cut -d'/' -f1)
            runtime_deps["$runtime_base"]+=" $dep_base"
            log "Runtime '$runtime_base' depends on: $dep_base"
        fi
    done <<< "$metadata"
    
done <<< "$all_runtimes"

# Mark all transitive dependencies as required
for app in "${packages[@]}"; do
    # Get runtime for this app
    app_runtime=$(flatpak info --show-runtime "$app" 2>/dev/null || true)
    if [[ -n "$app_runtime" ]]; then
        app_runtime_base=$(echo "$app_runtime" | cut -d'/' -f1)
        
        # Add this runtime and all its dependencies
        if [[ -n "${runtime_deps[$app_runtime_base]:-}" ]]; then
            for dep in ${runtime_deps[$app_runtime_base]}; do
                required_runtimes["$dep"]=1
                log "Marking transitive dependency as required: $dep (via $app_runtime_base for $app)"
            done
        fi
    fi
done

# Additional: Query flatpak for related refs
log "Querying flatpak for related refs of installed apps..."
for app in "${packages[@]}"; do
    related=$(flatpak info --show-related "$app" 2>/dev/null || true)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Lines look like: runtime/org.winehq.Wine.gecko/x86_64/stable-25.08
        if [[ "$line" =~ ^runtime/([^/]+)/ ]]; then
            ext="${BASH_REMATCH[1]}"
            required_extensions["$ext"]=1
            log "App '$app' has related ref: $ext"
        fi
    done <<< "$related"
done

# Critical fix: Scan for extension dependencies in /var/lib/flatpak
# Extensions are often not reported via standard queries but exist in the filesystem
log "Scanning filesystem for extension dependencies..."
if [[ -d /var/lib/flatpak/runtime ]]; then
    for runtime_dir in /var/lib/flatpak/runtime/*/x86_64/*; do
        [[ -d "$runtime_dir" ]] || continue
        
        runtime_name=$(basename "$(dirname "$(dirname "$runtime_dir")")")
        metadata_file="$runtime_dir/active/metadata"
        
        if [[ -f "$metadata_file" ]]; then
            # Check if this is an extension and if any app uses it
            if grep -q "ExtensionOf=" "$metadata_file"; then
                extension_of=$(grep "ExtensionOf=" "$metadata_file" | cut -d'=' -f2)
                
                # Check if any of our apps matches this ExtensionOf
                for app in "${packages[@]}"; do
                    app_runtime=$(flatpak info --show-runtime "$app" 2>/dev/null | cut -d'/' -f1 || true)
                    if [[ "$extension_of" == "$app_runtime" ]] || [[ "$extension_of" == "$app" ]]; then
                        required_extensions["$runtime_name"]=1
                        log "Found extension '$runtime_name' for app '$app' (ExtensionOf: $extension_of)"
                    fi
                done
            fi
        fi
    done
fi


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
	# Always remove "runtime/" prefix (if present) and extract the base name.
	pkg_base="${pkg#runtime/}"
	pkg_base="${pkg_base%%/*}"   # e.g., "org.gnome.Loupe.HEIC" or "org.gnome.Boxes.Extension.OsinfoDb"

	# Derive a secondary "base app" name:
	if [[ "$pkg_base" == *".Extension."* ]]; then
		# For extension packages, remove the extension part.
		base_app="${pkg_base%%.Extension.*}"   # e.g., from "org.gnome.Boxes.Extension.OsinfoDb" derive "org.gnome.Boxes"
	else
		# For non-extension packages, remove the last dot-separated token.
		base_app="${pkg_base%.*}"              # e.g., from "org.gnome.Loupe.HEIC" derive "org.gnome.Loupe"
	fi

	if printf '%s\n' "${packages[@]}" | grep -Fxq "$pkg_base" || \
	   printf '%s\n' "${packages[@]}" | grep -Fxq "$base_app"; then
		log "Keeping runtime $pkg because required package ($pkg_base or $base_app) is in the package list"
		keep=1
	fi
	
	# Special case: Keep Wine extensions if Bottles is installed
	if printf '%s\n' "${packages[@]}" | grep -q "bottles"; then
		if [[ "$pkg_base" == org.winehq.Wine.* ]]; then
			log "Keeping Wine extension $pkg (Bottles is installed)"
			keep=1
		fi
	fi

    # Check if pkg is required as a runtime
    if [[ $keep -eq 0 ]]; then
        for req in "${!required_runtimes[@]}"; do
            if [[ "$pkg_base" == "$req" || "$pkg" == "$req"* ]]; then
                keep=1
                log "Keeping required runtime: $pkg (matched: $req)"
                break
            fi
        done
    fi
    
    # Check if pkg is required as an extension
    if [[ $keep -eq 0 ]]; then
        for req in "${!required_extensions[@]}"; do
            if [[ "$pkg_base" == "$req" || "$pkg" == *"$req"* ]]; then
                keep=1
                log "Keeping required extension: $pkg (matched: $req)"
                break
            fi
        done
    fi
    
    if [[ $keep -eq 0 ]]; then
        # Before removing, do a final safety check with dry-run
        # Redirect stderr to stdout to capture all messages
        check_output=$(flatpak uninstall --system --noninteractive --dry-run "$pkg" 2>&1 || true)
        
        # Check if output contains "applications using the extension"
        if echo "$check_output" | grep -qi "applications using the extension"; then
            log "Keeping package $pkg (detected as in-use extension via dry-run)"
            keep=1
        fi
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

# Remove any unused Flatpak packages (e.g. orphaned runtimes and extensions)
log "Removing unused Flatpak packages"
if ! flatpak uninstall --assumeyes --noninteractive --unused --system --delete-data; then
    warn "Failed to remove unused Flatpak packages"
else
    log "Unused Flatpak packages removed successfully"
fi

# Run repair to clean up any remaining inconsistencies;
if ! flatpak repair --system; then
    warn "Flatpak repair encountered issues"
else
    log "Flatpak repair completed successfully"
fi

if [[ "$PROFILE" == "plasma" ]]; then
    log "Applying Kvantum override for Plasma profile"
    flatpak override --system --filesystem=xdg-config/Kvantum:ro
    flatpak override --system --env=QT_STYLE_OVERRIDE=kvantum
    log "Kvantum overrides applied successfully"
fi

if [[ "$PROFILE" == "gamescope" ]]; then
  log "Applying SteamOS-like Flatpak overrides for Steam..."

  sudo flatpak override com.valvesoftware.Steam \
    --share=network \
    --socket=wayland \
    --socket=x11 \
    --socket=pulseaudio \
    --socket=system-bus \
    --socket=session-bus \
    --device=all \
    --filesystem=home \
    --filesystem=/mnt \
    --filesystem=/media \
    --filesystem=/run/media
  log "Overrides applied."
fi

# Configure gaming app permissions (applies to all profiles)
log "Configuring gaming application permissions..."
declare -A gaming_apps=(
    ["com.valvesoftware.Steam"]="~/Games:create,/mnt,/media,/run/media"
    ["com.heroicgameslauncher.hgl"]="home,/mnt,/media,/run/media"
    ["org.libretro.RetroArch"]="home,/mnt,/media,/run/media"
    ["com.usebottles.bottles"]="home,/mnt,/media,/run/media"
)

for app in "${!gaming_apps[@]}"; do
    if flatpak list --system --app --columns=application | grep -Fxq "$app"; then
        IFS=',' read -ra perms <<< "${gaming_apps[$app]}"
        log "Setting permissions for $app: ${gaming_apps[$app]}"
        
        for perm in "${perms[@]}"; do
            sudo flatpak override --system "$app" --filesystem="$perm"
        done
    fi
done
log "Gaming app permissions configured"

# Prepare Btrfs image for Flatpak data (14G)
FLATPAK_IMG="${BUILD_DIR}/flatpak.img"
FLATPAK_SUBVOL="flatpak_subvol"
OUTPUT_FILE="${OUTPUT_SUBDIR}/flatpakfs.zst"

# This function is assumed to set up a loop device and create a Btrfs image.
setup_btrfs_image "$FLATPAK_IMG" "14G"  # Make sure this function is defined
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
