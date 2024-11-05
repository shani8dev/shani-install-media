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
    rm -rf "${output_dir}" "${temp_dir}"  # Remove old directories
    mkdir -p "${output_dir}" "${temp_dir}" "${repack_dir}"  # Create new ones
}

# Install Flatpak packages into airootfs
install_flatpak_packages() {
    log "Installing Flatpak packages into airootfs..."

    # Enable the Flathub repository
    arch-chroot "${temp_dir}/airootfs" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

    # List of Flatpak packages to install
    local FLATPAK_PACKAGES=(
        "org.mozilla.firefox" "org.gnome.Epiphany"
        "org.libreoffice.LibreOffice" "org.gnome.TextEditor"
        "org.gnome.Calendar" "org.gnome.Contacts" "org.gnome.Todo"
        "org.gnome.Loupe" "io.bassi.Amberol" "org.gnome.Showtime"
        "org.gnome.SoundRecorder" "app.fotema.Fotema"
        "io.github.seadve.Kooha" "org.gnome.Snapshot"
        "org.gnome.Calculator" "org.gnome.Characters" "org.gnome.Connections"
        "org.gnome.Firmware" "org.gnome.Logs" "org.gnome.Usage"
        "org.gnome.clocks" "org.gnome.font-viewer" "org.gnome.Maps"
        "org.gnome.Weather" "org.gnome.Boxes" "org.gnome.Software"
        "com.mattjakeman.ExtensionManager" "com.discordapp.Discord"
        "org.telegram.desktop" "com.slack.Slack" "us.zoom.Zoom"
        "com.valvesoftware.Steam" "com.heroicgameslauncher.hgl"
        "com.github.tchx84.Flatseal" "org.gnome.NetworkDisplays"
    )

    # Install each Flatpak package into the airootfs
    for package in "${FLATPAK_PACKAGES[@]}"; do
        log "Installing Flatpak package: $package"
        arch-chroot "${temp_dir}/airootfs" flatpak install --assumeyes --noninteractive flathub "$package" || {
            log "Failed to install Flatpak package: $package"
            continue
        }
    done

    log "Flatpak packages installed successfully."
}

# Copy MOK keys to airootfs
copy_mok_keys_to_airootfs() {
    log "Copying MOK keys to airootfs..."
    mkdir -p "${temp_dir}/airootfs/usr/share/secureboot/keys"
    
    cp "$mok_key" "${temp_dir}/airootfs/usr/share/secureboot/keys/MOK.key" || error_exit "Failed to copy MOK.key to airootfs"
    cp "$mok_cert" "${temp_dir}/airootfs/usr/share/secureboot/keys/MOK.crt" || error_exit "Failed to copy MOK.crt to airootfs"
    cp "$mok_cer" "${temp_dir}/airootfs/usr/share/secureboot/keys/MOK.cer" || error_exit "Failed to copy MOK.cer to airootfs"
    log "MOK keys copied to airootfs successfully."
}

# Create the initial ISO
create_iso() {
    log "Building Arch ISO..."
    mkarchiso -v -w "${temp_dir}" -o "${output_dir}" "${script_dir}" || error_exit "Failed to create ISO"
}

# Extract and sign EFI files for both 64-bit and 32-bit architectures
extract_files() {
    log "Extracting boot images for both 64-bit and 32-bit architectures..."
    
    osirrox -indev "$iso_file" \
        -extract_boot_images "${repack_dir}/" \
        -extract /EFI/BOOT/BOOTx64.EFI "${repack_dir}/grubx64.efi" \
        -extract /EFI/BOOT/BOOTia32.EFI "${repack_dir}/grubia32.efi" \
        -extract /shellx64.efi "${repack_dir}/shellx64.efi" \
        -extract /shellia32.efi "${repack_dir}/shellia32.efi" \
        -extract /arch/boot/x86_64/vmlinuz-linux "${repack_dir}/vmlinuz-linux" || error_exit "Failed to extract boot images"

    # Make the files writable
    chmod +w "${repack_dir}/grubx64.efi" "${repack_dir}/grubia32.efi"
    chmod +w "${repack_dir}/shellx64.efi" "${repack_dir}/shellia32.efi"
    chmod +w "${repack_dir}/vmlinuz-linux"
}

# Sign the extracted files
sign_files() {
    log "Signing EFI binaries..."
    for file in grubx64.efi grubia32.efi shellx64.efi shellia32.efi vmlinuz-linux; do
        sbsign --key "$mok_key" --cert "$mok_cert" --output "${repack_dir}/${file}" "${repack_dir}/${file}" || error_exit "Failed to sign ${file}"
    done
}

# Prepare Shim and MOK files for both 64-bit and 32-bit architectures
prepare_shim_and_mok() {
    log "Preparing Shim and MOK files for Secure Boot..."

    # Copy 64-bit EFI binaries
    cp /usr/share/shim-signed/shimx64.efi "${repack_dir}/BOOTx64.EFI" || error_exit "Failed to copy shimx64.efi"
    cp /usr/share/shim-signed/mmx64.efi "${repack_dir}/" || error_exit "Failed to copy mmx64.efi"

    # Copy 32-bit EFI binaries
    cp /usr/share/shim-signed/shimia32.efi "${repack_dir}/BOOTia32.EFI" || error_exit "Failed to copy shimia32.efi"
    cp /usr/share/shim-signed/mmia32.efi "${repack_dir}/" || error_exit "Failed to copy mmia32.efi"

    # Copy MOK certificate for Secure Boot
    cp "$mok_cer" "${repack_dir}/" || error_exit "Failed to copy MOK certificate"

    log "Shim and MOK files prepared successfully for both architectures."
}

# Function to disable Secure Boot validation
disable_secure_boot_validation() {
    log "Disabling Secure Boot validation (for Windows 11 compatibility)..."
    arch-chroot "${temp_dir}/airootfs" mokutil --disable-validation || log "Failed to disable Secure Boot validation. Please check mokutil setup."
}

# Function to enroll MOK
enroll_mok() {
    log "Enrolling MOK..."
    arch-chroot "${temp_dir}/airootfs" mokutil --import "$mok_cer" || error_exit "Failed to enroll MOK. Please reboot and complete the enrollment."
}

# Create El Torito image for both architectures
create_eltorito_image() {
    eltorito_img="${repack_dir}/eltorito_img2_uefi.img"
    dd if=/dev/zero of="$eltorito_img" bs=1M count=64

    log "Copying files to El Torito image..."
    mcopy -D oO -i "$eltorito_img" "${repack_dir}/vmlinuz-linux" ::/arch/boot/x86_64/vmlinuz-linux
    mcopy -D oO -i "$eltorito_img" "${repack_dir}/MOK.cer" "${repack_dir}/shellx64.efi" "${repack_dir}/shellia32.efi" ::/
    mcopy -D oO -i "$eltorito_img" "${repack_dir}/BOOTx64.EFI" "${repack_dir}/BOOTia32.EFI" ::/EFI/BOOT/
    mcopy -D oO -i "$eltorito_img" "${repack_dir}/grubx64.efi" "${repack_dir}/grubia32.efi" "${repack_dir}/mmx64.efi" "${repack_dir}/mmia32.efi" ::/EFI/BOOT/
}

# Repack the ISO with signed files
repack_iso() {
    final_iso="${output_dir}/signed_$(basename "$iso_file")"
    log "Repacking the ISO with Secure Boot for both 64-bit and 32-bit UEFI..."
    xorriso -indev "$iso_file" \
        -outdev "$final_iso" \
        -map "${repack_dir}/vmlinuz-linux" /arch/boot/x86_64/vmlinuz-linux \
        -map_l "${repack_dir}/" /shellx64.efi shellia32.efi MOK.cer -- \
        -map_l "${repack_dir}/EFI/BOOT/" BOOTx64.EFI grubx64.efi mmx64.efi BOOTia32.EFI grubia32.efi mmia32.efi -- \
        -boot_image any replay \
        -append_partition 2 0xef "$eltorito_img"

    pushd "${output_dir}" > /dev/null
    sha256sum "$(basename "$final_iso")" > sha256sum.txt || error_exit "Failed to generate checksum"
    cat sha256sum.txt
    popd > /dev/null

    log "Signed ISO build with dual-architecture Secure Boot support completed successfully!"
}

# Main script execution
main() {
    check_root
    prepare_directories
    copy_mok_keys_to_airootfs
    create_iso
    iso_file=$(ls "${output_dir}"/*.iso)
    mount_dir="${temp_dir}/iso_mount"
    mkdir -p "$mount_dir"
    mount -o loop "$iso_file" "$mount_dir"
    extract_files
    sign_files
    prepare_shim_and_mok
    create_eltorito_image
    install_flatpak_packages
    disable_secure_boot_validation  # Added for secure boot validation
    enroll_mok  # Added for enrolling MOK
    repack_iso
}

# Define configuration variables
output_dir="${PWD}/output"
script_dir="${PWD}/shanios"
temp_dir="${PWD}/temp"
repack_dir="${temp_dir}/repack"
mok_dir="${PWD}/mok"
mok_key="$mok_dir/MOK.key"
mok_cert="$mok_dir/MOK.crt"
mok_cer="$mok_dir/MOK.cer"

# Execute the main function
main

