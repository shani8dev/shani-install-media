#!/usr/bin/env bash
# build-snap-image.sh – Build the Snap seed image (container-only)
set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# -----------------------------
# Parse profile option
# -----------------------------
PROFILE="${DEFAULT_PROFILE:-desktop}"
while getopts "p:" opt; do
    case "$opt" in
        p) PROFILE="$OPTARG" ;;
        *) die "Invalid option" ;;
    esac
done
shift $((OPTIND - 1))

# Define output subdirectory (using the base image's structure)
OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
mkdir -p "${OUTPUT_SUBDIR}"

log "Building Snap seed for profile: $PROFILE"

SNAP_LIST="${IMAGE_PROFILES_DIR}/${PROFILE}/snap-packages.txt"
if [[ ! -f "$SNAP_LIST" ]]; then
    log "No snap-packages.txt found for profile ${PROFILE}; exiting..."
    exit 0
fi

# -----------------------------
# Read snap list
# -----------------------------
snaps=()
while IFS= read -r snap || [[ -n "$snap" ]]; do
    [[ -z "${snap// }" ]] && continue   # skip empty lines
    snaps+=("$snap")
done < "$SNAP_LIST"

if [[ ${#snaps[@]} -eq 0 ]]; then
    log "Snap list is empty; nothing to do."
    exit 0
fi

##############################################
# START SNAPD IF NEEDED
##############################################
if [ ! -S /run/snapd.socket ]; then
    log "Starting snapd in standalone mode..."
    
    mkdir -p /run/snapd /var/lib/snapd/snap /var/lib/snapd/seed/snaps /var/lib/snapd/seed/assertions /var/snap /snap
    ln -sf /var/lib/snapd/snap /snap

    /usr/lib/snapd/snapd --standalone &
    SNAPD_PID=$!

    for i in {1..60}; do
        if [ -S /run/snapd.socket ]; then
            log "snapd socket ready"
            break
        fi
        sleep 1
        if [ $i -eq 60 ]; then
            die "snapd socket not available after 60s"
        fi
    done

    if ! timeout 15 snap version &>/dev/null; then
        die "Cannot communicate with snapd"
    fi

    trap 'kill ${SNAPD_PID:-0} 2>/dev/null || true' EXIT
fi

##############################################
# MODEL ASSERTION
##############################################
MODEL_ASSERTION="/tmp/generic.model"

log "Fetching model assertion..."
# Try to get the model assertion - if it fails, we'll use a generic one
if snap known model > "$MODEL_ASSERTION" 2>/dev/null && [[ -s "$MODEL_ASSERTION" ]]; then
    log "Model assertion fetched successfully"
else
    warn "Could not fetch model assertion from snapd, using generic model"
    
    # Create a minimal generic model assertion
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

# -----------------------------
# Prepare snaps using seed directory
# -----------------------------
log "Preparing snap seeds..."
mkdir -p /var/lib/snapd/seed/snaps /var/lib/snapd/seed/assertions

# Build snap arguments for prepare-image
snap_args=()
for s in "${snaps[@]}"; do
    snap_args+=(--snap "$s")
done

# Run snap prepare-image once with all snaps
log "Running snap prepare-image with snaps: ${snaps[*]}"
if ! snap prepare-image "${snap_args[@]}" --classic --arch=amd64 "${MODEL_ASSERTION}" /var/lib/snapd/seed; then
    warn "snap prepare-image failed, but continuing with whatever was downloaded"
fi

log "Snap seed preparation complete"

# -----------------------------
# Create Btrfs image directly from /var/lib/snapd
# -----------------------------
SNAP_IMG="${BUILD_DIR}/snap.img"
SNAP_SUBVOL="snapd_subvol"
OUTPUT_FILE="${OUTPUT_SUBDIR}/snapfs.zst"

# This function is assumed to set up a loop device and create a Btrfs image.
setup_btrfs_image "$SNAP_IMG" "10G"  # Make sure this function is defined
# LOOP_DEVICE is set by setup_btrfs_image

# Define mount point for Snap image
SNAP_MOUNT="${BUILD_DIR}/snap_mount"

# Mount the loop device and create (or delete) the subvolume
mkdir -p "$SNAP_MOUNT"
if ! mount -t btrfs -o compress-force=zstd:19 "$LOOP_DEVICE" "$SNAP_MOUNT"; then
    die "Failed to mount snap image"
fi

if btrfs subvolume list "$SNAP_MOUNT" | grep -q "$SNAP_SUBVOL"; then
    log "Deleting existing subvolume ${SNAP_SUBVOL}..."
    if ! btrfs subvolume delete "$SNAP_MOUNT/$SNAP_SUBVOL"; then
        die "Failed to delete existing subvolume"
    fi
fi

log "Creating new subvolume: ${SNAP_SUBVOL}"
if ! btrfs subvolume create "$SNAP_MOUNT/$SNAP_SUBVOL"; then
    die "Subvolume creation failed"
fi
sync
if ! umount "$SNAP_MOUNT"; then
    die "Failed to unmount snap image after subvolume creation"
fi

# Remount the newly created subvolume
mkdir -p "$SNAP_MOUNT"
if ! mount -o subvol="$SNAP_SUBVOL",compress-force=zstd:19 "$LOOP_DEVICE" "$SNAP_MOUNT"; then
    die "Mounting snap subvolume failed"
fi

# -----------------------------
# Copy all of /var/lib/snapd
# -----------------------------
log "Copying Snap data into Btrfs subvolume"
mkdir -p "$SNAP_MOUNT/var/lib"
if ! tar -cf - -C /var/lib/snapd . | tar -xf - -C "$SNAP_MOUNT"; then
    die "Failed to copy /var/lib/snapd"
fi
sync

# -----------------------------
# Make read-only snapshot
# -----------------------------
# Set subvolume read-only before taking snapshot
if ! btrfs property set -f -ts "$SNAP_MOUNT" ro true; then
    die "Failed to set subvolume read-only"
fi

# Take a snapshot of the subvolume (this function must be defined)
btrfs_send_snapshot "$SNAP_MOUNT" "$OUTPUT_FILE"

# Reset subvolume to writable after snapshot
if ! btrfs property set -f -ts "$SNAP_MOUNT" ro false; then
    warn "Failed to reset subvolume properties"
fi

# Detach the Btrfs image (this function must be defined)
detach_btrfs_image "$SNAP_MOUNT" "$LOOP_DEVICE"

log "Snap seed image created successfully at: $OUTPUT_FILE"
