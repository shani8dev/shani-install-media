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
    mkdir -p "${output_dir}" "${temp_dir}" "${repack_dir}"   # Create new ones
}

get_latest_iso() {
    local output_dir="$1"
    local iso_file
    iso_file=$(find "$output_dir" -type f -name '*.iso' ! -name '*signed*.iso' -printf '%T@ %p\n' | sort -n | tail -1 | awk '{print $2}')
    [[ -n "$iso_file" ]] && echo "$iso_file" || { echo "No suitable ISO file found." >&2; return 1; }
}

# Extract and sign EFI files for 64-bit architectures
extract_files() {
    log "Extracting boot images for 64-bit architectures..."
    rm -rf "${repack_dir:?}/*"
    osirrox -indev "$iso_file" \
        -extract_boot_images "${repack_dir}/" \
        -extract /EFI/BOOT/BOOTx64.EFI "${repack_dir}/grubx64.efi" \
        -extract /shellx64.efi "${repack_dir}/shellx64.efi" || error_exit "Failed to extract EFI boot images" 

    # Mount the El Torito image containing the kernel (vmlinuz-linux)
    mkdir -p "${repack_dir}/mnt/eltorito"
    sleep 60s  # Wait (if necessary) for the extraction to complete
    mount -o loop "${repack_dir}/eltorito_img1_uefi.img" "${repack_dir}/mnt/eltorito" || error_exit "Failed to mount El Torito image"

    # Extract the kernel image (vmlinuz-linux) from the mounted image
    cp "${repack_dir}/mnt/eltorito/shani/boot/x86_64/vmlinuz-linux" "${repack_dir}/vmlinuz-linux" || error_exit "Failed to extract vmlinuz-linux"

    # Unmount the El Torito image after extraction
    umount "${repack_dir}/mnt/eltorito" || error_exit "Failed to unmount El Torito image"

    # Make the files writable
    chmod +w "${repack_dir}/grubx64.efi"
    chmod +w "${repack_dir}/shellx64.efi"
    chmod +w "${repack_dir}/vmlinuz-linux"
}

# Sign the extracted files
sign_files() {
    log "Signing EFI binaries..."
    for file in grubx64.efi shellx64.efi vmlinuz-linux; do
        sbsign --key "$mok_key" --cert "$mok_cert" --output "${repack_dir}/${file}" "${repack_dir}/${file}" || error_exit "Failed to sign ${file}"
    done
}

# Prepare Shim and MOK files for 64-bit  architectures
prepare_shim_and_mok() {
    log "Preparing Shim and MOK files for Secure Boot..."
    cp "${temp_dir}/x86_64/airootfs/usr/share/shim-signed/shimx64.efi" "${repack_dir}/BOOTx64.EFI" || error_exit "Failed to copy shimx64.efi"
    cp "${temp_dir}/x86_64/airootfs/usr/share/shim-signed/mmx64.efi" "${repack_dir}/" || error_exit "Failed to copy mmx64.efi"
    cp "$mok_der" "${repack_dir}/" || error_exit "Failed to copy MOK der"
    log "Shim and MOK files prepared successfully for both architectures."
}

# Function to disable Secure Boot validation
disable_secure_boot_validation() {
    log "Disabling Secure Boot validation (for Windows 11 compatibility)..."
    arch-chroot "${temp_dir}/x86_64/airootfs" mokutil --disable-validation || log "Failed to disable Secure Boot validation. Please check mokutil setup."
}

# Function to enroll MOK
enroll_mok() {
    log "Enrolling MOK..."
    arch-chroot "${temp_dir}/x86_64/airootfs" mokutil --import "$mok_cert" || error_exit "Failed to enroll MOK. Please reboot and complete the enrollment."
}

# Create El Torito image for both architectures
create_eltorito_image() {
    eltorito_img="${repack_dir}/eltorito_img1_uefi.img"
    log "Copying files to El Torito image..."
    mcopy -D oO -i "$eltorito_img" "${repack_dir}/vmlinuz-linux" ::/shani/boot/x86_64/vmlinuz-linux
    mcopy -D oO -i "$eltorito_img" "${repack_dir}/MOK.der" "${repack_dir}/shellx64.efi" ::/
    mcopy -D oO -i "$eltorito_img" "${repack_dir}/BOOTx64.EFI" ::/EFI/BOOT/
    mcopy -D oO -i "$eltorito_img" "${repack_dir}/grubx64.efi" "${repack_dir}/mmx64.efi" ::/EFI/BOOT/
}

repack_iso() {
    final_iso="${output_dir}/signed_$(basename "$iso_file")"
    # Remove existing final_iso if present
    rm -f "$final_iso" || error_exit "Failed to remove existing ISO file: $final_iso"
    log "Repacking the ISO with Secure Boot for 64-bit UEFI..."
    xorriso -indev "$iso_file" \
        -outdev "$final_iso" \
        -map "${repack_dir}/vmlinuz-linux" /shani/boot/x86_64/vmlinuz-linux \
        -map "${repack_dir}/shellx64.efi" /shellx64.efi \
        -map "${repack_dir}/MOK.der" /MOK.der \
        -map "${repack_dir}/BOOTx64.EFI" /EFI/BOOT/BOOTx64.EFI \
        -map "${repack_dir}/grubx64.efi" /EFI/BOOT/grubx64.efi \
        -map "${repack_dir}/mmx64.efi" /EFI/BOOT/mmx64.efi \
        -boot_image any replay \
        -append_partition 2 0xef "$eltorito_img"
    pushd "${output_dir}" > /dev/null
    sha256sum "$(basename "$final_iso")" > sha256sum.txt || error_exit "Failed to generate checksum"
    cat sha256sum.txt
    popd > /dev/null
    log "Signed ISO build with Secure Boot support completed successfully!"
}


# Main script execution
main() {
    check_root
    prepare_directories
    iso_file=$(get_latest_iso "$output_dir")
    mount_dir="${temp_dir}/iso_mount"
    mkdir -p "$mount_dir"
    mount -o loop "$iso_file" "$mount_dir"
    extract_files
    sign_files
    prepare_shim_and_mok
    create_eltorito_image
    # Optionally disable secure boot validation and enroll MOK if needed:
    # disable_secure_boot_validation
    # enroll_mok
    repack_iso
    umount "$mount_dir" || log "Failed to unmount ISO mount directory"
}

# Define configuration variables
output_dir="${PWD}/cache/output"
temp_dir="${PWD}/cache/temp"
repack_dir="${PWD}/cache/temp/repack"
mok_dir="${PWD}/mok"
mok_key="$mok_dir/MOK.key"
mok_cert="$mok_dir/MOK.crt"
mok_der="$mok_dir/MOK.der"

# Execute the main function
main

