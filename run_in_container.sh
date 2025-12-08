#!/bin/bash
# run_in_container.sh — Docker wrapper to run a command inside a container
set -Eeuo pipefail

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <command> [args...]"
    exit 1
fi

HOST_WORK_DIR="$(dirname "$(realpath "$0")")"

# Load .env if present
if [ -f "${HOST_WORK_DIR}/.env" ]; then
    echo "Sourcing environment file: ${HOST_WORK_DIR}/.env"
    set +u
    # shellcheck disable=SC1090
    source "${HOST_WORK_DIR}/.env"
    set -u
fi

# Local caches
HOST_PACMAN_CACHE="${HOST_WORK_DIR}/cache/pacman_cache"
HOST_FLATPAK_DATA="${HOST_WORK_DIR}/cache/flatpak_data"
HOST_SNAPD_DATA="${HOST_WORK_DIR}/cache/snapd_data"
mkdir -p "${HOST_PACMAN_CACHE}" "${HOST_FLATPAK_DATA}" "${HOST_SNAPD_DATA}"

CONTAINER_WORK_DIR="/home/builduser/build"
CONTAINER_GNUPGHOME="/home/builduser/.gnupg"
CONTAINER_PACMAN_CACHE="/var/cache/pacman"
CONTAINER_FLATPAK_DATA="/var/lib/flatpak"
CONTAINER_SNAPD_DATA="/var/lib/snapd"

DOCKER_IMAGE="${DOCKER_IMAGE:-shrinivasvkumbhar/shani-builder}"  # systemd-enabled image
CUSTOM_MIRROR="${CUSTOM_MIRROR:-https://mirror.albony.in/archlinux/\$repo/os/\$arch}"

# TTY flags
TTY_FLAGS="-it"
[ ! -t 0 ] && TTY_FLAGS="-i"

# Command inside container
CMD="$1"
shift
[[ "$CMD" != /* ]] && CMD="${CONTAINER_WORK_DIR}/${CMD}"
USER_CMD=$(printf '%q ' "$CMD" "$@")

# Prepare SSH/GPG imports
IMPORT_KEYS_CMD=""
if [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
    IMPORT_KEYS_CMD+="mkdir -p /home/builduser/.ssh && umask 077 && printf '%s\n' \"\$SSH_PRIVATE_KEY\" > /home/builduser/.ssh/id_rsa && chmod 600 /home/builduser/.ssh/id_rsa && "
    IMPORT_KEYS_CMD+="ssh-keyscan github.com sourceforge.net >> /home/builduser/.ssh/known_hosts 2>/dev/null || true && chmod 644 /home/builduser/.ssh/known_hosts && "
    IMPORT_KEYS_CMD+="echo -e \"Host *\\n    StrictHostKeyChecking no\" > /home/builduser/.ssh/config && chown -R builduser:builduser /home/builduser/.ssh && "
fi
if [[ -n "${GPG_PRIVATE_KEY:-}" && -n "${GPG_PASSPHRASE:-}" ]]; then
    IMPORT_KEYS_CMD+="mkdir -p \"${CONTAINER_GNUPGHOME}\" && chmod 700 \"${CONTAINER_GNUPGHOME}\" && "
    IMPORT_KEYS_CMD+="printf '%s\n' \"\$GPG_PRIVATE_KEY\" > /tmp/gpg_private.key && "
    IMPORT_KEYS_CMD+="gpg --batch --yes --passphrase \"\$GPG_PASSPHRASE\" --homedir \"${CONTAINER_GNUPGHOME}\" --import /tmp/gpg_private.key || true && "
    IMPORT_KEYS_CMD+="rm -f /tmp/gpg_private.key && chown -R builduser:builduser \"${CONTAINER_GNUPGHOME}\" && "
fi
IMPORT_KEYS_CMD+="chown -R builduser:builduser \"${CONTAINER_GNUPGHOME}\" || true && "

FINAL_CMD="${IMPORT_KEYS_CMD}${USER_CMD}"

# Run Docker container
docker run --rm ${TTY_FLAGS} --privileged \
    --device=/dev/fuse \
    --tmpfs /tmp \
    --tmpfs /run \
    -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
    -v /lib/modules:/lib/modules:ro \
  -v "${HOST_WORK_DIR}:${CONTAINER_WORK_DIR}" \
  -v "${HOST_PACMAN_CACHE}:${CONTAINER_PACMAN_CACHE}" \
  -v "${HOST_FLATPAK_DATA}:${CONTAINER_FLATPAK_DATA}" \
  -v "${HOST_SNAPD_DATA}:${CONTAINER_SNAPD_DATA}" \
  -e CUSTOM_MIRROR="${CUSTOM_MIRROR}" \
  -e SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-}" \
  -e GPG_PRIVATE_KEY="${GPG_PRIVATE_KEY:-}" \
  -e GPG_PASSPHRASE="${GPG_PASSPHRASE:-}" \
  -e GNUPGHOME="${CONTAINER_GNUPGHOME}" \
  -e container=docker \
  -e PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin" \
  -w "${CONTAINER_WORK_DIR}" \
  "${DOCKER_IMAGE}" bash -c "${FINAL_CMD}"

