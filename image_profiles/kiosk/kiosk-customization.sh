#!/bin/bash
# Kiosk profile: wire the ephemeral-home units into sysinit.target.
# $1 = image rootfs mountpoint
set -euo pipefail
SUBVOL_MOUNT="${1:?usage: kiosk-customization.sh <rootfs-mount>}"
WANTS="${SUBVOL_MOUNT}/etc/systemd/system/sysinit.target.wants"
install -d "$WANTS"
ln -sfn ../systemd-kiosk-user.service   "$WANTS/systemd-kiosk-user.service"
ln -sfn ../systemd-kiosk-config.service "$WANTS/systemd-kiosk-config.service"
