#!/bin/bash
# Gamescope profile: image-assembly for the gaming console.
#
# The console's own contents live in the shani-desktop-gamescope package (the
# session units, the sway/waybar/mako/fuzzel/swaylock configuration, the
# Control Center, the greetd config and the console's sudoers grant), so this
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

# A simple dark gradient wallpaper; swaybg falls back to a solid color if
# ImageMagick is not present in the builder.
if command -v convert >/dev/null 2>&1; then
    install -d "${SUBVOL_MOUNT}/usr/share/backgrounds/shani"
    convert -size 1920x1080 gradient:'#0e1116-#1a1b26' \
        "${SUBVOL_MOUNT}/usr/share/backgrounds/shani/shani.png" || true
fi
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
