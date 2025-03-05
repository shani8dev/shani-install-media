#!/bin/bash
# run_in_container.sh – Generic Docker wrapper to run any command inside the build container,
# with support for importing SSH and GPG keys into the container.
#
# This version sources an .env file (if present) in the same directory as the script,
# sets a secure GNUPGHOME, and configures SSH to disable strict host key checking.

set -Eeuo pipefail

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <command> [arguments]"
    exit 1
fi

HOST_WORK_DIR="$(dirname "$(realpath "$0")")"

# Source .env file if it exists in the script directory
if [ -f "${HOST_WORK_DIR}/.env" ]; then
    echo "Sourcing environment file: ${HOST_WORK_DIR}/.env"
    source "${HOST_WORK_DIR}/.env"
fi

HOST_PACMAN_CACHE="${HOST_WORK_DIR}/cache/pacman_cache"
HOST_FLATPAK_DATA="${HOST_WORK_DIR}/cache/flatpak_data"
mkdir -p "${HOST_PACMAN_CACHE}" "${HOST_FLATPAK_DATA}"

# Set a secure GPG home directory for the container (consistent with Dockerfile)
export GNUPGHOME="/home/builduser/.gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

CONTAINER_WORK_DIR="/home/builduser/build"
CONTAINER_PACMAN_CACHE="/var/cache/pacman"
CONTAINER_FLATPAK_DATA="/var/lib/flatpak"
CUSTOM_MIRROR="https://in.mirrors.cicku.me/archlinux/\$repo/os/\$arch"
DOCKER_IMAGE="shrinivasvkumbhar/shani-builder"

# Determine whether a TTY is available
if [ -t 0 ]; then
    TTY_FLAGS="-it"
else
    TTY_FLAGS="-i"
fi

# Convert command to an absolute path inside the container
CMD="$1"
shift
if [[ "$CMD" != /* ]]; then
    CMD="${CONTAINER_WORK_DIR}/${CMD}"
fi

# Build the user command string with proper quoting
USER_CMD=$(printf '%q ' "$CMD" "$@")

# Build a command prefix that imports SSH and GPG keys if provided.
IMPORT_KEYS_CMD=""
if [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
    IMPORT_KEYS_CMD+='mkdir -p ~/.ssh && echo "$SSH_PRIVATE_KEY" > ~/.ssh/id_rsa && chmod 600 ~/.ssh/id_rsa && \
ssh-keyscan github.com sourceforge.net >> ~/.ssh/known_hosts && chmod 644 ~/.ssh/known_hosts && \
echo "Host *" > ~/.ssh/config && echo "    StrictHostKeyChecking no" >> ~/.ssh/config && '
fi
if [[ -n "${GPG_PRIVATE_KEY:-}" && -n "${GPG_PASSPHRASE:-}" ]]; then
    IMPORT_KEYS_CMD+='echo "$GPG_PRIVATE_KEY" > /tmp/gpg_private.key && gpg --batch --import /tmp/gpg_private.key && gpg --list-secret-keys && rm /tmp/gpg_private.key && '
fi

# Final command that first imports keys (if any) then executes the user command.
FINAL_CMD="${IMPORT_KEYS_CMD}${USER_CMD}"

docker run $TTY_FLAGS --privileged --rm \
  -v "${HOST_WORK_DIR}:${CONTAINER_WORK_DIR}" \
  -v "${HOST_PACMAN_CACHE}:${CONTAINER_PACMAN_CACHE}" \
  -v "${HOST_FLATPAK_DATA}:${CONTAINER_FLATPAK_DATA}" \
  -e CUSTOM_MIRROR="${CUSTOM_MIRROR}" \
  -e SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-}" \
  -e GPG_PRIVATE_KEY="${GPG_PRIVATE_KEY:-}" \
  -e GPG_PASSPHRASE="${GPG_PASSPHRASE:-}" \
  -w "${CONTAINER_WORK_DIR}" \
  "${DOCKER_IMAGE}" bash -c "${FINAL_CMD}"

