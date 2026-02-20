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
HOST_SNAPD_SEED="${HOST_WORK_DIR}/cache/snapd_seed"
mkdir -p "${HOST_PACMAN_CACHE}" "${HOST_FLATPAK_DATA}" "${HOST_SNAPD_DATA}" "${HOST_SNAPD_SEED}"

# Set a secure GPG home directory for the container (consistent with Dockerfile)
export GNUPGHOME="/home/builduser/.gnupg"
mkdir -p "$GNUPGHOME"

CONTAINER_WORK_DIR="/home/builduser/build"
CONTAINER_GNUPGHOME="/home/builduser/.gnupg"
CONTAINER_PACMAN_CACHE="/var/cache/pacman"
CONTAINER_FLATPAK_DATA="/var/lib/flatpak"
CONTAINER_SNAPD_DATA="/var/lib/snapd"
CONTAINER_SNAPD_SEED="/tmp/snap-seed"

DOCKER_IMAGE="${DOCKER_IMAGE:-shrinivasvkumbhar/shani-builder}"  # systemd-enabled image
CUSTOM_MIRROR="${CUSTOM_MIRROR:-https://mirror.albony.in/archlinux/\$repo/os/\$arch}"

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

# Build a command prefix that imports SSH, GPG keys, and rclone config if provided.
# Dollar signs are not escaped here because we want the container's shell to expand them.
IMPORT_KEYS_CMD=""

if [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
    IMPORT_KEYS_CMD+='mkdir -p ~/.ssh && echo "$SSH_PRIVATE_KEY" > ~/.ssh/id_rsa && chmod 600 ~/.ssh/id_rsa && \
ssh-keyscan github.com sourceforge.net >> ~/.ssh/known_hosts && chmod 644 ~/.ssh/known_hosts && \
echo "Host *" > ~/.ssh/config && echo "    StrictHostKeyChecking no" >> ~/.ssh/config && '
fi

if [[ -n "${GPG_PRIVATE_KEY:-}" && -n "${GPG_PASSPHRASE:-}" ]]; then
    IMPORT_KEYS_CMD+="mkdir -p \"$GNUPGHOME\" && \
    echo \"\$GPG_PRIVATE_KEY\" > /tmp/gpg_private.key && \
    gpg --batch --passphrase \"\$GPG_PASSPHRASE\" --homedir \"$GNUPGHOME\" --import /tmp/gpg_private.key && \
    rm -f /tmp/gpg_private.key && gpg --homedir \"$GNUPGHOME\" --list-secret-keys && "
fi

# Write rclone config for Cloudflare R2 (S3-compatible) if credentials are provided.
# R2_ACCOUNT_ID is your Cloudflare account ID (32-char hex, found in R2 dashboard).
# no_check_bucket skips the BucketExists API call which R2 does not support.
# The remote is named "r2" so upload.sh needs no changes.
if [[ -n "${R2_ACCESS_KEY_ID:-}" && -n "${R2_SECRET_ACCESS_KEY:-}" && -n "${R2_ACCOUNT_ID:-}" ]]; then
    IMPORT_KEYS_CMD+="mkdir -p ~/.config/rclone && cat > ~/.config/rclone/rclone.conf << 'RCLONE_EOF'
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
RCLONE_EOF
echo 'rclone config written for Cloudflare R2' && "
fi

# Final command that first imports keys/config (if any) then executes the user command.
FINAL_CMD="${IMPORT_KEYS_CMD}${USER_CMD}"

# Run Docker container
docker run --rm ${TTY_FLAGS} --privileged \
    --tmpfs /tmp \
    --tmpfs /run/lock \
    --tmpfs /run \
    --cap-add SYS_ADMIN \
    --device=/dev/fuse \
    --security-opt apparmor:unconfined \
    --security-opt seccomp:unconfined \
    -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
    -v /lib/modules:/lib/modules:ro \
    -v "${HOST_WORK_DIR}:${CONTAINER_WORK_DIR}" \
    -v "${HOST_PACMAN_CACHE}:${CONTAINER_PACMAN_CACHE}" \
    -v "${HOST_FLATPAK_DATA}:${CONTAINER_FLATPAK_DATA}" \
    -v "${HOST_SNAPD_DATA}:${CONTAINER_SNAPD_DATA}" \
    -v "${HOST_SNAPD_SEED}:${CONTAINER_SNAPD_SEED}" \
    -e CUSTOM_MIRROR="${CUSTOM_MIRROR}" \
    -e SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-}" \
    -e GPG_PRIVATE_KEY="${GPG_PRIVATE_KEY:-}" \
    -e GPG_PASSPHRASE="${GPG_PASSPHRASE:-}" \
    -e GNUPGHOME="${CONTAINER_GNUPGHOME}" \
    -e R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}" \
    -e R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}" \
    -e R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-}" \
    -e R2_BUCKET="${R2_BUCKET:-}" \
    -w "${CONTAINER_WORK_DIR}" \
    "${DOCKER_IMAGE}" bash -c "${FINAL_CMD}"
