#!/bin/bash
# Gamescope profile: wire the ephemeral-home units into sysinit.target.
# The gamescope session is a tiling Wayland compositor purpose-built for
# gaming — no GNOME/Plasma deps, just the gamescope session + the gaming
# stack. $1 = image rootfs mountpoint.
set -euo pipefail
SUBVOL_MOUNT="${1:?usage: gamescope-customization.sh <rootfs-mount>}"
WANTS="${SUBVOL_MOUNT}/etc/systemd/system/sysinit.target.wants"
install -d "$WANTS"
ln -sfn ../gamescope-session-user.service   "$WANTS/gamescope-session-user.service"
ln -sfn ../gamescope-session-config.service "$WANTS/gamescope-session-config.service"