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
        "org.mozilla.firefox" "org.mozilla.Thunderbird" "org.libreoffice.LibreOffice"
        "org.gnome.NetworkDisplays" "org.gnome.Boxes"
        "org.gnome.Firmware" "org.gnome.Software"
        "com.mattjakeman.ExtensionManager" "com.github.tchx84.Flatseal"
        "io.podman_desktop.PodmanDesktop" "org.libretro.RetroArch"
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

    # Now copy Flatpak data to the airootfs
    log "Copying Flatpak data to airootfs..."

    # Ensure the required Flatpak directories exist in airootfs
    mkdir -p "${temp_dir}/x86_64/airootfs/var/lib/flatpak"
    
    # Copy the installed Flatpak data (apps and runtime) to airootfs
    cp -r /var/lib/flatpak/* "${temp_dir}/x86_64/airootfs/var/lib/flatpak/" || error_exit "Failed to copy Flatpak data to airootfs"

    log "Flatpak data copied to airootfs successfully."
}


# Copy MOK keys to airootfs
copy_mok_keys_to_airootfs() {
    log "Copying MOK keys to airootfs..."
    mkdir -p "${temp_dir}/x86_64/airootfs/usr/share/secureboot/keys"
    
    cp "$mok_key" "${temp_dir}/x86_64/airootfs/usr/share/secureboot/keys/MOK.key" || error_exit "Failed to copy MOK.key to airootfs"
    cp "$mok_cert" "${temp_dir}/x86_64/airootfs/usr/share/secureboot/keys/MOK.crt" || error_exit "Failed to copy MOK.crt to airootfs"
    cp "$mok_cer" "${temp_dir}/x86_64/airootfs/usr/share/secureboot/keys/MOK.cer" || error_exit "Failed to copy MOK.cer to airootfs"
    log "MOK keys copied to airootfs successfully."
}

# Create the initial ISO
create_iso() {
    log "Building Arch ISO..."
    mkarchiso -v -w "${temp_dir}" -o "${output_dir}" "${profile_dir}" || error_exit "Failed to create ISO"
}


# Main script execution
main() {
    check_root
    prepare_directories
    install_flatpak_packages
    copy_mok_keys_to_airootfs
    create_iso
}

# Define configuration variables
output_dir="${PWD}/cache/output"
profile_dir="${PWD}/shanios"
temp_dir="${PWD}/cache/temp"
repack_dir="${temp_dir}/repack"
mok_dir="${PWD}/mok"
mok_key="$mok_dir/MOK.key"
mok_cert="$mok_dir/MOK.crt"
mok_cer="$mok_dir/MOK.cer"

# Execute the main function
main

