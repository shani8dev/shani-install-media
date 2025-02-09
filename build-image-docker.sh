#!/bin/bash

# Get the directory of this script
work_dir="$(dirname "$(realpath "$0")")"

# Define your custom fast mirror (ensure proper URL format)
CUSTOM_MIRROR="https://in.mirrors.cicku.me/archlinux/\$repo/os/\$arch"

# Create volumes for pacman cache and flatpak data
CACHE_DIR="${work_dir}/cache/pacman_cache"
FLATPAK_DATA_DIR="${work_dir}/cache/flatpak_data"

# Ensure the necessary directories exist
mkdir -p "$CACHE_DIR" "$FLATPAK_DATA_DIR"

# Execute the build scripts directly inside the container
docker run -it --privileged --rm \
    -v "${work_dir}:/builduser/build" \
    -v "$CACHE_DIR:/var/cache/pacman" \
    -v "$FLATPAK_DATA_DIR:/var/lib/flatpak" \
    shrinivasvkumbhar/shani-builder bash -c "
        # Update the mirrorlist to only replace the Server lines for each section
        sed -i 's|^Server = .*|Server = $CUSTOM_MIRROR|' /etc/pacman.d/mirrorlist && \
        cd /builduser/build && \
        ./build-image.sh -p gnome
    "
