#!/bin/bash
# Mount encrypted Btrfs layout with customized subvolume options
set -euo pipefail

modprobe btrfs
modprobe overlay

root_dev=$(findmnt -n -o SOURCE /sysroot)

# Define subvolume order to ensure @data is mounted first
subvol_order=(
    "@data"
    "@home"
    "@var"
    "@flatpak"
    "@containers"
    "@swap"
)

declare -A subvols=(
    ["@home"]="/home|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@data"]="/data|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@var"]="/var|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@flatpak"]="/var/lib/flatpak|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@containers"]="/var/lib/containers|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@swap"]="/swap|rw,noatime,nodatacow,nospace_cache"
)

for subvol in "${subvol_order[@]}"; do
    if [[ ${subvols[$subvol]+_} ]]; then
        IFS='|' read -r target options <<< "${subvols[$subvol]}"
        mkdir -p "/sysroot${target}"
        mount -t btrfs -o "subvol=${subvol},${options}" "$root_dev" "/sysroot${target}"
    fi
done

# Special handling for swap subvolume
chattr +C /sysroot/swap >/dev/null 2>&1 || true

# OverlayFS setup (after @data is mounted)
mkdir -p "/sysroot/data/etc/overlay/{upper,work}"
chmod 0755 "/sysroot/data/etc/overlay/upper" "/sysroot/data/etc/overlay/work"
mount -t overlay overlay -o \
    "lowerdir=/sysroot/etc,\
    upperdir=/sysroot/data/etc/overlay/upper,\
    workdir=/sysroot/data/etc/overlay/work" \
    "/sysroot/etc"
