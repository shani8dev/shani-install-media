#!/usr/bin/env bash
# build-snap-image.sh – Build the Snap seed image (container-only)
# Mirrors the structure of build-flatpak-image.sh (same variable style, same flow)

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"  # log, die, warn, setup_btrfs_image, btrfs_send_snapshot, detach_btrfs_image

# ---------------------------------------------------------
# Parse profile option
# ---------------------------------------------------------
PROFILE="$DEFAULT_PROFILE"
while getopts "p:" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    *) die "Invalid option" ;;
  esac
done
shift $((OPTIND - 1))

OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
mkdir -p "${OUTPUT_SUBDIR}"

log "Building Snap image for profile: ${PROFILE}"

# ---------------------------------------------------------
# Load snap list
# ---------------------------------------------------------
SNAP_LIST="${IMAGE_PROFILES_DIR}/${PROFILE}/snap-packages.txt"

if [[ ! -f "$SNAP_LIST" ]]; then
    log "No Snap package list found at ${SNAP_LIST}. Exiting..."
    exit 0
fi

snaps=()
while IFS= read -r snap || [[ -n "$snap" ]]; do
    [[ -z "${snap// }" ]] && continue
    snaps+=("$snap")
done < "$SNAP_LIST"

if [[ ${#snaps[@]} -eq 0 ]]; then
    log "Snap list empty; exiting."
    exit 0
fi

# ---------------------------------------------------------
# Ensure snapd is running (standalone mode)
# ---------------------------------------------------------
if [ ! -S /run/snapd.socket ]; then
    log "Starting snapd standalone..."

    mkdir -p /run/snapd /var/lib/snapd/snap /var/lib/snapd/seed/snaps /var/lib/snapd/seed/assertions /var/snap /snap
    ln -sf /var/lib/snapd/snap /snap

    /usr/lib/snapd/snapd --standalone &
    SNAPD_PID=$!

    trap 'kill ${SNAPD_PID:-0} 2>/dev/null || true' EXIT

    for i in {1..60}; do
        [ -S /run/snapd.socket ] && break
        sleep 1
        [ $i -eq 60 ] && die "snapd socket never came ready"
    done
fi

# ---------------------------------------------------------
# Model assertion
# ---------------------------------------------------------
MODEL_ASSERTION="/tmp/generic.model"

log "Fetching model assertion..."
if snap known model > "$MODEL_ASSERTION" 2>/dev/null && [[ -s "$MODEL_ASSERTION" ]]; then
    log "Model assertion retrieved from snapd"
else
    warn "Using fallback generic model"
    cat > "$MODEL_ASSERTION" <<'EOF'
type: model
authority-id: generic
series: 16
brand-id: generic
model: generic-classic
classic: true
timestamp: 2017-07-27T00:00:00.0Z
sign-key-sha3-384: d-JcZF9nD9eBw7bwMnH61x-bklnQOhQud1Is6o_cn2wTj8EYDi9musrIT9z2MdAa

AcLBXAQAAQoABgUCWYuXiAAKCRAdLQyY+/mCiST0D/0XGQauzV2bbTEy6DkrR1jlNbI6x8vfIdS8
KvEWYvzOWNhNlVSfwNOkFjs3uMHgCO6/fCg03wGXTyV9D7ZgrMeUzWrYp6EmXk8/LQSaBnff86XO
4/vYyfyvEYavhF0kQ6QGg8Cqr0EaMyw0x9/zWEO/Ll9fH/8nv9qcQq8N4AbebNvNxtGsCmJuXpSe
2rxl3Dw8XarYBmqgcBQhXxRNpa6/AgaTNBpPOTqgNA8ZtmbZwYLuaFjpZP410aJSs+evSKepy/ce
+zTA7RB3384YQVeZDdTudX2fGtuCnBZBAJ+NYlk0t8VFXxyOhyMSXeylSpNSx4pCqmUZRyaf5SDS
g1XxJet4IP0stZH1SfPOwc9oE81/bJlKsb9QIQKQRewvtUCLfe9a6Vy/CYd2elvcWOmeANVrJK0m
nRaz6VBm09RJTuwUT6vNugXSOCeF7W3WN1RHJuex0zw+nP3eCehxFSr33YrVniaA7zGfjXvS8tKx
AINNQB4g2fpfet4na6lPPMYM41WHIHPCMTz/fJQ6dZBSEg6UUZ/GiQhGEfWPBteK7yd9pQ8qB3fj
ER4UvKnR7hcVI26e3NGNkXP5kp0SFCkV5NQs8rzXzokpB7p/V5Pnqp3Km6wu45cU6UiTZFhR2IMT
l+6AMtrS4gDGHktOhwfmOMWqmhvR/INF+TjaWbsB6g==
EOF
fi

# ---------------------------------------------------------
# Prepare-image: build seed into temp dir
# ---------------------------------------------------------
TMP_SEED="/tmp/snap-seed"
mkdir -p "$TMP_SEED"

snap_args=()
for s in "${snaps[@]}"; do
    snap_args+=(--snap "$s")
done

log "Running snap prepare-image..."
if ! snap prepare-image "${snap_args[@]}" --classic --arch=amd64 "$MODEL_ASSERTION" "$TMP_SEED"; then
    warn "prepare-image failed; using partial results"
fi

# ---------------------------------------------------------
# Install produced seed into host /var/lib/snapd
# ---------------------------------------------------------
log "Installing snap seed into /var/lib/snapd"

mkdir -p /var/lib/snapd
rm -rf /var/lib/snapd/seed
mkdir -p /var/lib/snapd/seed

if [ -d "$TMP_SEED/var/lib/snapd/seed" ]; then
    log "Copying prepared seed into /var/lib/snapd/seed"
    tar -cf - -C "$TMP_SEED/var/lib/snapd/seed" . | tar -xf - -C /var/lib/snapd/seed
else
    warn "prepare-image produced no seed"
fi

# ---------------------------------------------------------
# Create Btrfs image and snapd subvolume
# ---------------------------------------------------------
SNAP_IMG="${BUILD_DIR}/snap.img"
SNAP_SUBVOL="snapd_subvol"
SNAP_MOUNT="${BUILD_DIR}/snap_mount"
OUTPUT_FILE="${OUTPUT_SUBDIR}/snapfs.zst"

log "Creating btrfs image ${SNAP_IMG}"

setup_btrfs_image "$SNAP_IMG" "10G"

mkdir -p "$SNAP_MOUNT"
mount -t btrfs -o compress-force=zstd:19 "$LOOP_DEVICE" "$SNAP_MOUNT"

if btrfs subvolume list "$SNAP_MOUNT" | grep -q "$SNAP_SUBVOL"; then
    log "Removing existing subvolume..."
    btrfs subvolume delete "$SNAP_MOUNT/$SNAP_SUBVOL"
fi

log "Creating new subvolume"
btrfs subvolume create "$SNAP_MOUNT/$SNAP_SUBVOL"
sync

umount "$SNAP_MOUNT"

mkdir -p "$SNAP_MOUNT"
mount -o subvol="$SNAP_SUBVOL",compress-force=zstd:19 "$LOOP_DEVICE" "$SNAP_MOUNT"

# ---------------------------------------------------------
# Single-pass copy of /var/lib/snapd into subvolume
# ---------------------------------------------------------
log "Copying /var/lib/snapd → snapd_subvol (single tar pass)"
tar -cf - -C /var/lib/snapd . | tar -xf - -C "$SNAP_MOUNT"
sync

# ---------------------------------------------------------
# Read-only snapshot + export
# ---------------------------------------------------------
btrfs property set -ts "$SNAP_MOUNT" ro true || warn "Cannot set read-only"

log "Sending snapshot to ${OUTPUT_FILE}"
btrfs_send_snapshot "$SNAP_MOUNT" "$OUTPUT_FILE"

btrfs property set -ts "$SNAP_MOUNT" ro false || true

detach_btrfs_image "$SNAP_MOUNT" "$LOOP_DEVICE"

log "Snap image created successfully at ${OUTPUT_FILE}"
exit 0

