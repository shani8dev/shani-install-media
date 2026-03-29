#!/bin/bash
# run_in_container.sh — Docker/Podman wrapper to run a build command inside the builder container
set -Eeuo pipefail

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <command> [args...]"
    exit 1
fi

HOST_WORK_DIR="$(dirname "$(realpath "$0")")"

# Load .env if present — sets credentials and optional overrides like DOCKER_IMAGE,
# CUSTOM_MIRROR, NO_SF, NO_R2, BUILD_DATE, R2_BUCKET, etc.
if [ -f "${HOST_WORK_DIR}/.env" ]; then
    echo "Sourcing environment file: ${HOST_WORK_DIR}/.env"
    set +u
    # shellcheck disable=SC1090
    source "${HOST_WORK_DIR}/.env"
    set -u
fi

# ---------------------------------------------------------------------------
# Host-side cache directories (bind-mounted into the container for reuse
# between runs so pacman/flatpak/snap don't re-download everything each time)
# ---------------------------------------------------------------------------
HOST_PACMAN_CACHE="${HOST_WORK_DIR}/cache/pacman_cache"
HOST_FLATPAK_DATA="${HOST_WORK_DIR}/cache/flatpak_data"
HOST_SNAPD_DATA="${HOST_WORK_DIR}/cache/snapd_data"
HOST_SNAPD_SEED="${HOST_WORK_DIR}/cache/snapd_seed"
mkdir -p "${HOST_PACMAN_CACHE}" "${HOST_FLATPAK_DATA}" "${HOST_SNAPD_DATA}" "${HOST_SNAPD_SEED}"
chmod 755 "${HOST_FLATPAK_DATA}"   # flatpak creates as 750
chmod 755 "${HOST_SNAPD_DATA}"     # snapd may do the same
chmod 755 "${HOST_SNAPD_SEED}"     # snap seed dir
chmod 755 "${HOST_PACMAN_CACHE}"   # pacman cache, less likely but consistent

# ---------------------------------------------------------------------------
# Container paths (fixed — must match the Dockerfile)
# ---------------------------------------------------------------------------
CONTAINER_WORK_DIR="/home/builduser/build"
CONTAINER_GNUPGHOME="/home/builduser/.gnupg"
CONTAINER_PACMAN_CACHE="/var/cache/pacman"
CONTAINER_FLATPAK_DATA="/var/lib/flatpak"
CONTAINER_SNAPD_DATA="/var/lib/snapd"
CONTAINER_SNAPD_SEED="/tmp/snap-seed"

DOCKER_IMAGE="${DOCKER_IMAGE:-docker.io/shrinivasvkumbhar/shani-builder}"
CUSTOM_MIRROR="${CUSTOM_MIRROR:-https://mirror.albony.in/archlinux/\$repo/os/\$arch}"

# ---------------------------------------------------------------------------
# TTY detection
# ---------------------------------------------------------------------------
if [ -t 0 ]; then
    TTY_FLAGS="-it"
else
    TTY_FLAGS="-i"
fi

# ---------------------------------------------------------------------------
# Resolve command path inside the container
# ---------------------------------------------------------------------------
CMD="$1"
shift
if [[ "$CMD" != /* ]]; then
    CMD="${CONTAINER_WORK_DIR}/${CMD}"
fi

# Build the user command string with proper bash quoting
USER_CMD=$(printf '%q ' "$CMD" "$@")

# ---------------------------------------------------------------------------
# Build the setup prefix that runs inside the container before the user command.
# Order: pacman SigLevel patch → SSH key → GPG key → rclone config → user cmd
# ---------------------------------------------------------------------------
IMPORT_KEYS_CMD=""

# Podman's gpg-agent socket handling is broken for pacman — disable sig checks
if podman version &>/dev/null 2>&1; then
    IMPORT_KEYS_CMD="sed -i 's/^SigLevel[[:space:]]*.*/SigLevel = Never/' /etc/pacman.conf && "
fi

# SSH key — needed for SourceForge rsync uploads
if [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
    IMPORT_KEYS_CMD+='mkdir -p ~/.ssh && \
echo "$SSH_PRIVATE_KEY" > ~/.ssh/id_rsa && chmod 600 ~/.ssh/id_rsa && \
ssh-keyscan -H github.com sourceforge.net >> ~/.ssh/known_hosts 2>/dev/null && \
chmod 644 ~/.ssh/known_hosts && \
printf "Host *\n    StrictHostKeyChecking no\n    BatchMode yes\n" > ~/.ssh/config && '
fi

# GPG private key — needed for signing images and ISOs
if [[ -n "${GPG_PRIVATE_KEY:-}" && -n "${GPG_PASSPHRASE:-}" ]]; then
    IMPORT_KEYS_CMD+="mkdir -p \"${CONTAINER_GNUPGHOME}\" && chmod 700 \"${CONTAINER_GNUPGHOME}\" && \
echo \"\$GPG_PRIVATE_KEY\" > /tmp/gpg_private.key && \
gpg --batch --passphrase \"\$GPG_PASSPHRASE\" --homedir \"${CONTAINER_GNUPGHOME}\" --import /tmp/gpg_private.key && \
rm -f /tmp/gpg_private.key && \
gpg --homedir \"${CONTAINER_GNUPGHOME}\" --list-secret-keys && "
fi

# rclone config for Cloudflare R2 (S3-compatible)
# R2_ACCOUNT_ID: 32-char hex Cloudflare account ID from the R2 dashboard
# no_check_bucket: skips BucketExists call which R2 does not support
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

FINAL_CMD="${IMPORT_KEYS_CMD}${USER_CMD}"

# ---------------------------------------------------------------------------
# Pull latest builder image (non-fatal — uses cached image if offline)
# ---------------------------------------------------------------------------
docker pull "${DOCKER_IMAGE}" || echo "[WARN] Could not pull ${DOCKER_IMAGE} — using cached image"

# ---------------------------------------------------------------------------
# Run the container
# ---------------------------------------------------------------------------
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
    -e GPG_KEY_ID="${GPG_KEY_ID:-}" \
    -e GNUPGHOME="${CONTAINER_GNUPGHOME}" \
    -e R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}" \
    -e R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}" \
    -e R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-}" \
    -e R2_BUCKET="${R2_BUCKET:-}" \
    -e NO_SF="${NO_SF:-false}" \
    -e NO_R2="${NO_R2:-false}" \
    -e BUILD_DATE="${BUILD_DATE:-}" \
    -w "${CONTAINER_WORK_DIR}" \
    "${DOCKER_IMAGE}" bash -c "${FINAL_CMD}"
