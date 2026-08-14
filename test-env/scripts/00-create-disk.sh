#!/bin/bash
# 00-create-disk.sh
#
# Creates two sparse loop-backed images that stand in for the real GPT disk
# ShaniOS installs to (see os-installer-config/bits/part.sfdisk):
#   - esp.img  -> FAT32, LABEL=shani_boot   (stand-in for the 1G EFI partition)
#   - root.img -> Btrfs, LABEL=shani_root   (stand-in for the rest-of-disk root)
#
# root.img is created with config.sh's own setup_btrfs_image() — the exact
# same helper build-base-image.sh uses for base.img — so this behaves
# identically to the real pipeline: it's destructive/idempotent-by-recreation,
# not idempotent-by-reuse. Re-running this wipes and recreates both images,
# same as re-running 01-bootstrap-rootfs.sh wipes @blue/@green — consistent,
# predictable state across test runs rather than silently stale ones.
#
# We skip real GPT partitioning of a single disk since there's no real UEFI
# firmware in a container anyway (see README "What this does NOT simulate").
# Two separately-labelled loop devices are functionally equivalent for every
# script here: they all just look up /dev/disk/by-label/shani_root and
# /dev/disk/by-label/shani_boot.
set -euo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../../config/config.sh"

# The published shani-builder image (see ../run_in_container.sh's
# DOCKER_IMAGE) is built for image/ISO assembly, not for this harness —
# dosfstools (mkfs.fat, for the fake ESP) isn't part of that role and may be
# absent. Installed once if missing; ../run_in_container.sh already
# bind-mounts a persistent pacman cache, so this is a no-op download-wise on
# every run after the first. Everything else check_dependencies_test lists
# below (btrfs-progs, util-linux, zstd, systemd) is already part of the
# builder image's own package list — see shani-builder/docker/Dockerfile.
if ! command -v mkfs.fat &>/dev/null && command -v pacman &>/dev/null; then
    log "mkfs.fat not found — installing dosfstools"
    pacman -Sy --needed --noconfirm dosfstools || warn "Could not auto-install dosfstools — install it manually if the ESP step below fails"
fi

check_dependencies_test

DATA_DIR="${SHANIOS_TEST_DATA:-${SCRIPT_DIR}/../disk}"
ROOT_IMG="${DATA_DIR}/root.img"
ESP_IMG="${DATA_DIR}/esp.img"
ROOT_SIZE="${ROOT_SIZE:-16G}"
ESP_SIZE="${ESP_SIZE:-512M}"

mkdir -p "$DATA_DIR" /dev/disk/by-label

log "Setting up root.img (Btrfs, LABEL=shani_root, ${ROOT_SIZE})"
setup_btrfs_image "$ROOT_IMG" "$ROOT_SIZE"
ROOT_LOOP="$LOOP_DEVICE"
btrfs filesystem label "$ROOT_LOOP" shani_root

# setup_btrfs_image() is Btrfs-specific (build-base-image.sh's only other
# caller also wants Btrfs) — the ESP has no equivalent helper upstream since
# gen-efi.sh writes into an existing ESP at deploy time, not build time. Same
# detach-existing/truncate/losetup shape as setup_btrfs_image(), just FAT32.
log "Setting up esp.img (FAT32, LABEL=shani_boot, ${ESP_SIZE})"
if losetup -j "$ESP_IMG" | grep -q "$ESP_IMG"; then
    existing_esp_loop=$(losetup -j "$ESP_IMG" | cut -d: -f1)
    losetup -d "$existing_esp_loop" || warn "Failed to detach existing loop device: $existing_esp_loop"
fi
rm -f "$ESP_IMG"
truncate -s "$ESP_SIZE" "$ESP_IMG"
ESP_LOOP=$(losetup --find --show "$ESP_IMG") || die "Failed to set up loop device for $ESP_IMG"
mkfs.fat -F32 -n shani_boot "$ESP_LOOP" || die "Failed to format $ESP_IMG as FAT32"

ln -sf "$ROOT_LOOP" /dev/disk/by-label/shani_root
ln -sf "$ESP_LOOP" /dev/disk/by-label/shani_boot

echo "$ROOT_LOOP" > "${DATA_DIR}/.root_loop"
echo "$ESP_LOOP" > "${DATA_DIR}/.esp_loop"

log "root loop: $ROOT_LOOP  (LABEL=shani_root)"
log "esp  loop: $ESP_LOOP  (LABEL=shani_boot)"
log "Disk images written under: $DATA_DIR"
