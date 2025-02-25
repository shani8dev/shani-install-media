#!/bin/bash
# Mount encrypted Btrfs layout with customized subvolume options
set -euo pipefail

modprobe btrfs
modprobe overlay

root_dev=$(findmnt -n -o SOURCE /sysroot)

# Subvolume definitions with individual options
declare -A subvols=(
    # Format: ["subvolume"]="mountpoint|mount_options"
    ["@home"]="/home|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@data"]="/data|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@flatpak"]="/var/lib/flatpak|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@containers"]="/var/lib/containers|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@swap"]="/swap|rw,noatime,nodatacow,nospace_cache"
)

for subvol in "${!subvols[@]}"; do
    # Split mountpoint and options
    IFS='|' read -r target options <<< "${subvols[$subvol]}"
    
    # Create mountpoint and mount with specific options
    mkdir -p "/sysroot${target}"
    mount -t btrfs -o "subvol=${subvol},${options}" \
        "$root_dev" "/sysroot${target}"
done

# Special handling for swap subvolume
chattr +C /sysroot/swap >/dev/null 2>&1 || true

# OverlayFS setup
mkdir -p /sysroot/data/etc/overlay/{upper,work}
chmod 0755 /sysroot/data/etc/overlay/{upper,work}
mount -t overlay overlay -o \
    "lowerdir=/sysroot/etc,\
    upperdir=/sysroot/data/etc/overlay/upper,\
    workdir=/sysroot/data/etc/overlay/work" \
    /sysroot/etc
