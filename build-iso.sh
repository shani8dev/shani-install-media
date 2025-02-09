#!/bin/bash

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Function to log messages with timestamps
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1"
}

# Function to handle errors
error_exit() {
    log "Error: $1"
    exit 1
}

# Ensure the script is running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "$(basename "$0") must be run as root"
    fi
}

# Prepare working directories
prepare_directories() {
    log "Preparing directories..."
    rm -rf "${temp_dir}"  # Remove old directories
    mkdir -p "${output_dir}" "${temp_dir}" "${repack_dir}"   # Create new ones
}

# Install Flatpak packages directly to root filesystem (airootfs)
install_flatpak_packages() {
    log "Installing Flatpak packages into root filesystem..."

    # Enable the Flathub repository directly in the root filesystem
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

    # List of Flatpak packages to install
    local FLATPAK_PACKAGES=(
        "com.google.Chrome" "org.libreoffice.LibreOffice"
        "org.gnome.Software" "com.mattjakeman.ExtensionManager" "com.github.tchx84.Flatseal"	
        "com.valvesoftware.Steam" "com.heroicgameslauncher.hgl"
    )

    # Remove existing Flatpak packages not in the list
    log "Removing Flatpak packages not in the defined list..."
    local installed_packages
    installed_packages=$(flatpak list --columns=application --system | tail -n +1)

    for installed in $installed_packages; do
        if [[ ! " ${FLATPAK_PACKAGES[@]} " =~ " ${installed} " ]]; then
            log "Removing unwanted Flatpak package: $installed"
            flatpak uninstall --assumeyes --noninteractive --system "$installed" || {
                log "Failed to remove Flatpak package: $installed"
                continue
            }
        fi
    done
    # Install each Flatpak package to the root filesystem
    log "Installing desired Flatpak packages..."
    for package in "${FLATPAK_PACKAGES[@]}"; do
        log "Installing Flatpak package: $package"
        flatpak install --verbose --assumeyes --noninteractive --system flathub "$package" || {
            log "Failed to install Flatpak package: $package"
            continue
        }
    done

    log "Flatpak packages are up to date."

    # Prune unused runtimes and clean cache
    log "Cleaning up unused Flatpak data..."
    flatpak uninstall --unused --system || log "No unused runtimes to remove."
    flatpak remove --system --unused -y || log "No unused Flatpak data to remove."
    flatpak repair --system || log "Flatpak system repair completed."
  
    log "Creating flatpak.sfs."

    # Create the flatpak.sfs
    mksquashfs "${cache_dir}/flatpak_data/" "${output_dir}/flatpak.sfs" -comp xz -Xdict-size 100% -b 1M -Xbcj x86 || error_exit "Failed to create flatpak.sfs"

}

# Create the initial ISO
create_iso() {
    log "Copying image and flatpak.sfs to ISO directory..."

    # Read the built image name from latest.txt (created by build-image.sh)
    if [ -f "${output_dir}/latest.txt" ]; then
        IMAGE_NAME=$(cat "${output_dir}/latest.txt")
    else
        error_exit "Latest image file not found. Ensure build-image.sh ran correctly."
    fi

    mkdir -p "$IMAGE_DIR"
	
    cp "${output_dir}/${IMAGE_NAME}" "$IMAGE_DIR/rootfs.zst" || error_exit "Failed to copy ${IMAGE_NAME} to $IMAGE_DIR"
    cp "${output_dir}/flatpak.sfs" "$IMAGE_DIR/" || error_exit "Failed to copy flatpak.sfs to $IMAGE_DIR"

    log "Image and flatpak.sfs copied to $IMAGE_DIR"
    
    log "Building Arch ISO..."
    mkarchiso -v -w "${temp_dir}" -o "${output_dir}" "${profile_dir}" || error_exit "Failed to create ISO"
}


# Main script execution
main() {
    check_root
    prepare_directories
    install_flatpak_packages
    create_iso
}

# Define configuration variables
output_dir="${PWD}/cache/output"
profile_dir="${PWD}/shanios"
temp_dir="${PWD}/cache/temp"
cache_dir="${PWD}/cache"
repack_dir="${temp_dir}/repack"
IMAGE_DIR="${temp_dir}/iso/shani/x86_64"
# Execute the main function
main

