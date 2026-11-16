#!/bin/bash
# Gamescope profile: image-assembly for the gaming console.
#
# The console's own contents live in the shani-desktop-gamescope package (the
# session units, the sway/waybar/mako/fuzzel/swaylock configuration, the
# Control Center, the greetd config and the console password helper), so this
# script only does what a package cannot: prepare the image itself.
#
# $1 = image rootfs mountpoint.
set -euo pipefail
SUBVOL_MOUNT="${1:?usage: gamescope-customization.sh <rootfs-mount>}"

# Pre-download the Steam client so the first launch is offline, like
# SteamOS/Bazzite. gamescope-session-plus unpacks this into the gamescope
# user's Steam data directory on first boot; without it, Steam's first launch
# downloads ~600 MB before the login screen appears.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="${SUBVOL_MOUNT}/usr/share/gamescope-session-plus"
BOOTSTRAP="${BOOTSTRAP_DIR}/bootstrap_steam.tar.zst"
install -d "${SUBVOL_MOUNT}/etc/shani-arr" "${SUBVOL_MOUNT}/var/lib/shani-arr"

# The optional *arr media stack (podman compose), off by default.
install -d "${SUBVOL_MOUNT}/etc/shani-arr"

# The wallpaper is NOT generated here: it ships with shani-desktop-gamescope
# (usr/share/backgrounds/shani/), already rendered and blurred. Generating it
# in the builder would need ImageMagick in the build image for no gain.
if [ ! -f "$BOOTSTRAP" ]; then
    manifest="$(mktemp)"
    if curl -fsSL --retry 5 --retry-all-errors --max-time 60 \
        -o "$manifest" \
        https://client-update.steamstatic.com/steam_client_steamdeck_stable_steamrt64; then
        install -d "$BOOTSTRAP_DIR"
        if ! bash "${SCRIPT_DIR}/../../scripts/steam-bootstrap" "$manifest" "$BOOTSTRAP"; then
            echo "[WARN] steam-bootstrap failed; the gamescope session will download Steam on first launch" >&2
        fi
    else
        echo "[WARN] could not download the Steam client manifest; the gamescope session will download Steam on first launch" >&2
    fi
    rm -f "$manifest"
fi
