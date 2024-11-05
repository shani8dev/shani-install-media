#!/bin/bash

# Get the directory of this script
work_dir="$(dirname "$(realpath "$0")")"

# Define your custom fast mirror (NIT Raipur)
CUSTOM_MIRROR="Server = https://mirrors.kernel.org/arch/\$repo/os/\$arch"

# Execute the build script directly inside the container
exec docker run --privileged --rm \
    -v "${work_dir}:/builduser/build" \     # Mount the working directory
    -v "$GITHUB_OUTPUT:$GITHUB_OUTPUT" \   # Ensure GITHUB_OUTPUT is mounted
    -e "GITHUB_OUTPUT=$GITHUB_OUTPUT" \     # Pass the GITHUB_OUTPUT variable
    shrinivasvkumbhar/shani-builder bash -c "
        # Update the mirrorlist with the custom mirror
        echo \"$CUSTOM_MIRROR\" | tee -a /etc/pacman.d/mirrorlist && 

        # Ensure the working directory is set
        cd /builduser/build && 
        
        # Execute the build script
        ./build-iso.sh
    "

