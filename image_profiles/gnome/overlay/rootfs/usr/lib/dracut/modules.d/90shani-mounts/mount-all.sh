#!/bin/bash
# Mount encrypted Btrfs layout with read-only root

set -euo pipefail

# Load required kernel modules
modprobe btrfs 
modprobe overlay

# Get root device information
root_dev=$(findmnt -n -o SOURCE /sysroot)

# Mount root as read-only first (base for overlay)
mount -o remount,ro /sysroot


# Define subvolumes and targets
declare -A subvols=(
    ["@home"]="/home"
    ["@data"]="/data"
    ["@swap"]="/swap"
    ["@flatpak"]="/var/lib/flatpak"
    ["@containers"]="/var/lib/containers"
)

# Mount RW subvolumes
for subvol in "${!subvols[@]}"; do
    target="${subvols[$subvol]}"
    mkdir -p "/sysroot$target"
    mount -t btrfs -o "subvol=$subvol,compress=zstd,rw,space_cache=v2,autodefrag" \
        "$root_dev" "/sysroot$target" || die "Failed mounting $subvol to $target"
done

# Special handling for swap subvolume
chattr +C /sysroot/swap >/dev/null 2>&1 || true  # Ensure CoW disabled

# Prepare /etc overlay
mkdir -p /sysroot/data/etc/overlay/{upper,work}
chmod 0755 /sysroot/data/etc/overlay/{upper,work}
mount -t overlay overlay -o \
    "lowerdir=/sysroot/etc,upperdir=/sysroot/data/etc/overlay/upper,workdir=/sysroot/data/etc/overlay/work" \
    /sysroot/etc
