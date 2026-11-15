#!/bin/bash
# Gamescope profile: wire the gamescope user/home units into sysinit.target.
# The gamescope session is a tiling Wayland compositor purpose-built for
# gaming — no GNOME/Plasma deps, just the gamescope session + the gaming
# stack. $1 = image rootfs mountpoint.
set -euo pipefail
SUBVOL_MOUNT="${1:?usage: gamescope-customization.sh <rootfs-mount>}"
WANTS="${SUBVOL_MOUNT}/etc/systemd/system/sysinit.target.wants"
install -d "$WANTS"
ln -sfn ../gamescope-session-user.service   "$WANTS/gamescope-session-user.service"
ln -sfn ../gamescope-session-config.service "$WANTS/gamescope-session-config.service"

# Pre-download the Steam client so the first launch is offline, like
# SteamOS/Bazzite. gamescope-session-plus unpacks this into the gamescope
# user's Steam data directory on first boot; without it, Steam's first launch
# downloads ~600 MB before the login screen appears.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="${SUBVOL_MOUNT}/usr/share/gamescope-session-plus"
BOOTSTRAP="${BOOTSTRAP_DIR}/bootstrap_steam.tar.zst"
install -d "${SUBVOL_MOUNT}/etc/shani-arr" "${SUBVOL_MOUNT}/var/lib/shani-arr"
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