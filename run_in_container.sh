#!/bin/bash
# run_in_container.sh – Generic Docker wrapper to run any command inside the build container.

set -Eeuo pipefail

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <command> [arguments]"
    exit 1
fi

HOST_WORK_DIR="$(dirname "$(realpath "$0")")"
HOST_PACMAN_CACHE="${HOST_WORK_DIR}/cache/pacman_cache"
HOST_FLATPAK_DATA="${HOST_WORK_DIR}/cache/flatpak_data"
mkdir -p "${HOST_PACMAN_CACHE}" "${HOST_FLATPAK_DATA}"

CONTAINER_WORK_DIR="/builduser/build"
CONTAINER_PACMAN_CACHE="/var/cache/pacman"
CONTAINER_FLATPAK_DATA="/var/lib/flatpak"
CUSTOM_MIRROR="https://in.mirrors.cicku.me/archlinux/\$repo/os/\$arch"
DOCKER_IMAGE="shrinivasvkumbhar/shani-builder"

# Convert command to an absolute path inside the container
CMD="$1"
shift
if [[ "$CMD" != /* ]]; then
    CMD="${CONTAINER_WORK_DIR}/${CMD}"
fi

FULL_CMD=$(printf '%q ' "$CMD" "$@")

docker run -it --privileged --rm \
  -v "${HOST_WORK_DIR}:${CONTAINER_WORK_DIR}" \
  -v "${HOST_PACMAN_CACHE}:${CONTAINER_PACMAN_CACHE}" \
  -v "${HOST_FLATPAK_DATA}:${CONTAINER_FLATPAK_DATA}" \
  -e CUSTOM_MIRROR="${CUSTOM_MIRROR}" \
  -w "${CONTAINER_WORK_DIR}" \
  "${DOCKER_IMAGE}" bash -c "${FULL_CMD}"

