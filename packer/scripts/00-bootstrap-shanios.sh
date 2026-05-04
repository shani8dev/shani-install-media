#!/usr/bin/env bash
# 00-bootstrap-shanios.sh — Stage 1: write ShaniOS onto /dev/xvdf
#
# Run by Packer on the AL2023 builder instance. Installs tools, downloads the
# base image, verifies it, partitions /dev/xvdf, creates all Btrfs subvolumes,
# receives the btrfs send-stream, snapshots @blue/@green, and mounts @blue for
# Stage 2. Writes /tmp/shanios-env.sh so subsequent provisioners share context.
#
# Packer environment variables (set in shanios-ami.pkr.hcl):
#   ARTIFACT_BASE    – CDN base URL, no trailing slash (R2 or S3 HTTP)
#   SHANIOS_PROFILE  – image profile: gnome | plasma | cosmic
#   GPG_KEY_ID       – signing key fingerprint (used when GPG_PUBLIC_KEY is set)
#   GPG_PUBLIC_KEY   – ASCII-armored public key (blank = skip GPG verify)
#   ROOT_VOLUME_DEV  – target block device (default: /dev/xvdf)
#   EFI_SIZE_MB      – EFI partition size in MiB (default: 512)

set -Eeuo pipefail

log()  { echo "[BOOTSTRAP][INFO]  $*"; }
warn() { echo "[BOOTSTRAP][WARN]  $*" >&2; }
die()  { echo "[BOOTSTRAP][ERROR] $*" >&2; exit 1; }

ROOT_VOL="${ROOT_VOLUME_DEV:-/dev/xvdf}"
EFI_MB="${EFI_SIZE_MB:-512}"
WORK_DIR="/tmp/shanios-build"
MOUNT_DIR="/mnt/shanios-target"
# Mount options match install.sh BTRFS_TOP_OPTS exactly
BTRFS_OPTS="defaults,noatime,compress=zstd,space_cache=v2,autodefrag"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Install build dependencies
# ─────────────────────────────────────────────────────────────────────────────
log "Installing build dependencies..."

if command -v dnf &>/dev/null; then
    # Amazon Linux 2023 / RHEL / Fedora
    dnf install -y \
        btrfs-progs util-linux dosfstools parted zstd \
        aria2 gnupg2 \
        2>&1 || true
elif command -v apt-get &>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y \
        btrfs-progs util-linux dosfstools parted zstd \
        aria2 gnupg \
        2>&1 || true
else
    die "Unsupported package manager — cannot install dependencies"
fi

# Confirm critical tools are present
for cmd in btrfs mkfs.btrfs mkfs.fat parted zstd curl sha256sum partprobe blkid wipefs; do
    command -v "$cmd" &>/dev/null || warn "Not found after install: $cmd"
done

mkdir -p "${WORK_DIR}" "${MOUNT_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Validate artifact_base
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${ARTIFACT_BASE:-}" ]] || die "ARTIFACT_BASE is not set. Set r2_base_url or s3_base_url in your .pkrvars.hcl."

# ─────────────────────────────────────────────────────────────────────────────
# 3. Resolve latest image filename
# ─────────────────────────────────────────────────────────────────────────────
log "Resolving latest image for profile '${SHANIOS_PROFILE}'..."

LATEST_URL="${ARTIFACT_BASE}/${SHANIOS_PROFILE}/latest.txt"
log "Fetching: ${LATEST_URL}"
BASE_IMAGE_NAME=$(
    curl -fsSL --max-time 30 --retry 3 --retry-delay 5 "${LATEST_URL}" \
    | tr -d '[:space:]'
)
[[ -n "${BASE_IMAGE_NAME}" ]] || die "latest.txt is empty or unreachable: ${LATEST_URL}"
log "Latest image: ${BASE_IMAGE_NAME}"

# Extract 8-digit build date from filename (e.g. shanios-20240115-gnome.zst → 20240115)
BUILD_DATE=$(echo "${BASE_IMAGE_NAME}" | grep -oE '[0-9]{8}' | head -1)
[[ -n "${BUILD_DATE}" ]] || die "Cannot extract build date from filename: ${BASE_IMAGE_NAME}"

DATED_BASE="${ARTIFACT_BASE}/${SHANIOS_PROFILE}/${BUILD_DATE}"
IMAGE_URL="${DATED_BASE}/${BASE_IMAGE_NAME}"
SHA256_URL="${IMAGE_URL}.sha256"
ASC_URL="${IMAGE_URL}.asc"
IMAGE_FILE="${WORK_DIR}/${BASE_IMAGE_NAME}"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Download base image (aria2c preferred; curl fallback)
# ─────────────────────────────────────────────────────────────────────────────
log "Downloading ${BASE_IMAGE_NAME} from ${IMAGE_URL}..."

if command -v aria2c &>/dev/null; then
    aria2c \
        --allow-overwrite=true \
        --auto-file-renaming=false \
        --continue=true \
        --max-connection-per-server=4 \
        --split=4 \
        --file-allocation=none \
        --timeout=120 \
        --max-tries=5 \
        --retry-wait=10 \
        --dir="${WORK_DIR}" \
        --out="${BASE_IMAGE_NAME}" \
        "${IMAGE_URL}" \
        || die "aria2c download failed"
else
    curl -fL \
        --retry 5 --retry-delay 10 --retry-connrefused \
        --connect-timeout 30 \
        --continue-at - \
        --output "${IMAGE_FILE}" \
        "${IMAGE_URL}" \
        || die "curl download failed"
fi

log "Download complete: $(du -sh "${IMAGE_FILE}" | cut -f1)"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Verify integrity (SHA-256 always; GPG when key is provided)
# ─────────────────────────────────────────────────────────────────────────────
SHA256_FILE="${IMAGE_FILE}.sha256"
log "Fetching SHA-256 sidecar..."
if curl -fsSL --max-time 30 --retry 3 --output "${SHA256_FILE}" "${SHA256_URL}" 2>/dev/null; then
    log "Verifying SHA-256..."
    pushd "${WORK_DIR}" > /dev/null
    sha256sum --check --status "$(basename "${SHA256_FILE}")" \
        || die "SHA-256 mismatch — downloaded image is corrupt"
    popd > /dev/null
    log "SHA-256 OK"
else
    warn "SHA-256 sidecar not reachable — skipping checksum verification"
fi

if [[ -n "${GPG_PUBLIC_KEY:-}" ]]; then
    log "Importing GPG signing key (${GPG_KEY_ID})..."
    GNUPG_TMP=$(mktemp -d)
    chmod 700 "${GNUPG_TMP}"
    GNUPGHOME="${GNUPG_TMP}" gpg --batch --import <<< "${GPG_PUBLIC_KEY}" 2>/dev/null \
        || die "Failed to import GPG public key"
    GNUPGHOME="${GNUPG_TMP}" sh -c \
        "echo '${GPG_KEY_ID}:6:' | gpg --batch --import-ownertrust" 2>/dev/null || true

    log "Fetching GPG signature..."
    ASC_FILE="${IMAGE_FILE}.asc"
    curl -fsSL --max-time 30 --retry 3 --output "${ASC_FILE}" "${ASC_URL}" \
        || die "Cannot download GPG signature from ${ASC_URL}"

    log "Verifying GPG signature..."
    GNUPGHOME="${GNUPG_TMP}" gpg --batch --verify "${ASC_FILE}" "${IMAGE_FILE}" \
        || die "GPG signature verification FAILED — refusing to continue"
    log "GPG signature OK"

    rm -rf "${GNUPG_TMP}"
else
    warn "GPG_PUBLIC_KEY not set — skipping GPG verification (set it for production builds)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. Partition /dev/xvdf (GPT: EFI + Btrfs root)
# ─────────────────────────────────────────────────────────────────────────────
log "Partitioning ${ROOT_VOL}..."
[[ -b "${ROOT_VOL}" ]] || die "Block device not found: ${ROOT_VOL}"

wipefs -a "${ROOT_VOL}" 2>/dev/null || true
dd if=/dev/zero of="${ROOT_VOL}" bs=1M count=4 status=none 2>/dev/null || true

parted --script "${ROOT_VOL}" \
    mklabel gpt \
    mkpart EFI  fat32 1MiB "${EFI_MB}MiB" \
    set 1 esp  on \
    set 1 boot on \
    mkpart ROOT btrfs "${EFI_MB}MiB" 100% \
    || die "parted failed"

# Give the kernel time to update partition table entries
partprobe "${ROOT_VOL}" 2>/dev/null || true
udevadm settle 2>/dev/null || sleep 3

# Derive partition device paths
# NVMe:     /dev/nvme1n1  → /dev/nvme1n1p1, /dev/nvme1n1p2
# Xen/VirtIO: /dev/xvdf   → /dev/xvdf1,     /dev/xvdf2
if [[ "${ROOT_VOL}" =~ nvme[0-9]+n[0-9]+$ ]] || [[ "${ROOT_VOL}" =~ mmcblk[0-9]+$ ]]; then
    EFI_PART="${ROOT_VOL}p1"
    ROOT_PART="${ROOT_VOL}p2"
else
    EFI_PART="${ROOT_VOL}1"
    ROOT_PART="${ROOT_VOL}2"
fi

# Confirm the partition devices appeared
for part in "${EFI_PART}" "${ROOT_PART}"; do
    [[ -b "$part" ]] || die "Partition device not found after partprobe: $part"
done

log "EFI  partition: ${EFI_PART}"
log "Root partition: ${ROOT_PART}"

# ─────────────────────────────────────────────────────────────────────────────
# 7. Format partitions
# ─────────────────────────────────────────────────────────────────────────────
log "Formatting EFI partition (FAT32, label: shani_boot)..."
mkfs.fat -F32 -n shani_boot "${EFI_PART}" || die "mkfs.fat failed"

log "Formatting root partition (Btrfs, label: shani_root)..."
mkfs.btrfs -f -L shani_root "${ROOT_PART}" || die "mkfs.btrfs failed"

# ─────────────────────────────────────────────────────────────────────────────
# 8. Create Btrfs subvolumes (mirrors install.sh create_subvolumes exactly)
# ─────────────────────────────────────────────────────────────────────────────
log "Mounting top-level Btrfs volume..."
mount -o "${BTRFS_OPTS}" "${ROOT_PART}" "${MOUNT_DIR}" \
    || die "Btrfs top-level mount failed"

log "Creating subvolumes..."
# This list must stay in sync with install.sh create_subvolumes()
SUBVOLUMES=(
    "@root"       # /root (root user home)
    "@home"       # /home
    "@data"       # /data  — persistent overlay layers + service state
    "@nix"        # /nix
    "@cache"      # /var/cache
    "@log"        # /var/log
    "@flatpak"    # /var/lib/flatpak
    "@snapd"      # /var/lib/snapd
    "@waydroid"   # /var/lib/waydroid
    "@containers" # /var/lib/containers
    "@machines"   # /var/lib/machines
    "@lxc"        # /var/lib/lxc
    "@lxd"        # /var/lib/lxd
    "@libvirt"    # /var/lib/libvirt  (nodatacow — VM images)
    "@qemu"       # /var/lib/qemu     (nodatacow — VM images)
    "@swap"       # /swap             (nodatacow — swapfile)
)
for sv in "${SUBVOLUMES[@]}"; do
    btrfs subvolume create "${MOUNT_DIR}/${sv}" \
        || die "Failed to create subvolume ${sv}"
done

# no-COW on subvolumes that hold raw data files (VM images, swapfiles).
# Must be set before any files are written.
for nocow_sv in "@swap" "@libvirt" "@qemu"; do
    chattr +C "${MOUNT_DIR}/${nocow_sv}" 2>/dev/null \
        || warn "Could not set no-COW on ${nocow_sv} (non-fatal on some kernels)"
done

# ─────────────────────────────────────────────────────────────────────────────
# 9. Create persistent service-state directories under @data
#    Mirrors install.sh DATA_DIRS and configure.sh bind-mount list exactly.
# ─────────────────────────────────────────────────────────────────────────────
log "Creating persistent service-state directories under @data..."
DATA_DIRS=(
    # Overlay layer directories — required by the runtime overlay mounts
    overlay/etc/lower overlay/etc/upper overlay/etc/work
    overlay/var/lower  overlay/var/upper  overlay/var/work
    # Core system services
    varlib/dbus varlib/systemd varlib/fontconfig
    # Network & connectivity
    varlib/NetworkManager varlib/bluetooth varlib/firewalld
    # File sharing
    varlib/samba varlib/nfs
    # Remote access & VPN
    varlib/caddy varlib/tailscale varlib/cloudflared varlib/geoclue
    # Display managers
    varlib/gdm varlib/sddm
    # Audio & peripherals
    varlib/colord varlib/pipewire varlib/rtkit
    varlib/cups varlib/sane varlib/upower
    # User auth & security
    varlib/fprint varlib/AccountsService varlib/boltd
    varlib/sudo varlib/sshd varlib/polkit-1
    # Hardware & firmware
    varlib/fwupd varlib/tpm2-tss
    # Backup & persistence
    varlib/fail2ban varlib/restic varlib/rclone varlib/appimage
    # Job scheduling
    varspool/anacron varspool/cron varspool/at
    # Print & mail spools
    varspool/cups varspool/samba varspool/postfix
    # User downloads
    downloads
)
for d in "${DATA_DIRS[@]}"; do
    mkdir -p "${MOUNT_DIR}/@data/${d}"
done

# ─────────────────────────────────────────────────────────────────────────────
# 10. Receive the ShaniOS btrfs send-stream
# ─────────────────────────────────────────────────────────────────────────────
log "Receiving ShaniOS base image into ${MOUNT_DIR}/ ..."
log "(This step decompresses and writes several GiB — please be patient)"
zstd --decompress --long=31 -T0 "${IMAGE_FILE}" --stdout \
    | btrfs receive "${MOUNT_DIR}" \
    || die "btrfs receive failed"

btrfs subvolume show "${MOUNT_DIR}/shanios_base" &>/dev/null \
    || die "shanios_base not found after btrfs receive — image may be corrupt or truncated"
log "shanios_base received OK"

# ─────────────────────────────────────────────────────────────────────────────
# 11. Blue-green snapshot setup (mirrors install.sh extract_system_image)
# ─────────────────────────────────────────────────────────────────────────────
log "Creating blue-green snapshots..."
btrfs subvolume snapshot -r "${MOUNT_DIR}/shanios_base" "${MOUNT_DIR}/@blue" \
    || die "Snapshot @blue failed"
btrfs subvolume snapshot -r "${MOUNT_DIR}/@blue" "${MOUNT_DIR}/@green" \
    || die "Snapshot @green failed"
btrfs subvolume delete "${MOUNT_DIR}/shanios_base" \
    || warn "Could not delete shanios_base — remove manually if needed"

# Slot markers — consumed by shani-deploy and shani-user-setup.service
echo "blue"  > "${MOUNT_DIR}/@data/current-slot"
echo "green" > "${MOUNT_DIR}/@data/previous-slot"
touch "${MOUNT_DIR}/@data/user-setup-needed"
log "Slot markers: current=blue, previous=green"

# ─────────────────────────────────────────────────────────────────────────────
# 12. Mount @blue and its EFI partition for Stage 2
# ─────────────────────────────────────────────────────────────────────────────
BLUE_MOUNT="${MOUNT_DIR}/@blue-root"
mkdir -p "${BLUE_MOUNT}"

mount -o "subvol=@blue,${BTRFS_OPTS}" "${ROOT_PART}" "${BLUE_MOUNT}" \
    || die "Mount @blue subvolume failed"

mkdir -p "${BLUE_MOUNT}/boot/efi"
mount "${EFI_PART}" "${BLUE_MOUNT}/boot/efi" \
    || die "Mount EFI partition failed"

log "Bootstrap complete:"
log "  Target device   : ${ROOT_VOL}"
log "  @blue mounted   : ${BLUE_MOUNT}"
log "  EFI mounted     : ${BLUE_MOUNT}/boot/efi"
log "  Btrfs top-level : ${MOUNT_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# 13. Write environment for subsequent provisioner stages
# ─────────────────────────────────────────────────────────────────────────────
cat > /tmp/shanios-env.sh << ENVEOF
# Written by 00-bootstrap-shanios.sh
# Source this in every subsequent provisioner script.
export SHANIOS_MOUNT="${BLUE_MOUNT}"
export SHANIOS_ROOT_VOL="${ROOT_VOL}"
export SHANIOS_ROOT_PART="${ROOT_PART}"
export SHANIOS_EFI_PART="${EFI_PART}"
export SHANIOS_BTRFS_MOUNT="${MOUNT_DIR}"
export SHANIOS_BTRFS_OPTS="${BTRFS_OPTS}"
ENVEOF
chmod 644 /tmp/shanios-env.sh
log "Environment written to /tmp/shanios-env.sh"
