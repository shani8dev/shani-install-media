#!/usr/bin/env bash
# build-ai-models-image.sh — Build the AI models image layer (container-only)
#
# Separate from build-base-image.sh: the brain (Qwen3.5-2B, 1.28 GB) and its
# vision projector (mmproj-F16, 668 MB) are fetched here, into a btrfs
# subvolume that is snapshotted and published alongside flatpakfs.zst and
# snapfs.zst. Chronoa reads /var/lib/shani-chronoa/{llm,vision}, so baking
# them in here means the assistant thinks and sees at first boot with no
# download and no consent prompt. Pinned by byte size and sha256 (the
# Hugging Face LFS oid), fetched and verified - the same discipline as
# stt_provision.install.
#
# Which models to ship is controlled by ai-models.txt (profile dir or
# shared/), the same way flatpak-packages.txt controls Flatpaks. If the file
# is absent, this script exits 0 and no layer is produced; the user then
# downloads the model via the setup wizard into the same path.
#
# If this layer is NOT shipped in the ISO, the model is absent on first boot
# and the user downloads it via the setup wizard into the same path
# (/var/lib/shani-chronoa/llm). Chronoa detects either case.

set -Eeuo pipefail

error_function() {
    local rc=$?
    (( rc == 0 )) && return 0
    echo "[ERROR] Build step failed with exit code $rc" >&2
    return $rc
}
trap error_function EXIT

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

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

check_dependencies "for profile: ${PROFILE}"

# Skip profiles that don't ship the AI desktop (server, kiosk, gamescope).
case "$PROFILE" in
    server|kiosk|gamescope) log "Profile '$PROFILE' does not ship the AI desktop - skipping."; exit 0 ;;
esac

# Locate the model list (profile dir first, then shared/).
MODEL_LIST=""
if [[ -f "${IMAGE_PROFILES_DIR}/${PROFILE}/ai-models.txt" ]]; then
    MODEL_LIST="${IMAGE_PROFILES_DIR}/${PROFILE}/ai-models.txt"
elif [[ -f "${IMAGE_PROFILES_DIR}/shared/ai-models.txt" ]]; then
    MODEL_LIST="${IMAGE_PROFILES_DIR}/shared/ai-models.txt"
fi
if [[ -z "$MODEL_LIST" ]]; then
    log "No ai-models.txt found for profile '${PROFILE}' — skipping AI models layer."
    exit 0
fi

log "Building AI models image layer for profile: ${PROFILE}"
log "Model list: ${MODEL_LIST}"

# Prepare Btrfs image for AI models data
AI_IMG="${BUILD_DIR}/aimodels.img"
AI_SUBVOL="shani-chronoa_subvol"
AI_MOUNT="${BUILD_DIR}/aimodels_mount"
OUTPUT_FILE="${OUTPUT_SUBDIR}/aimodelsfs.zst"

AI_IMG_SIZE_GIB="${AI_IMG_SIZE_GIB:-4}"

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
_cleanup() {
    local rc=$?
    if mountpoint -q "${AI_MOUNT}" 2>/dev/null; then
        umount -R "${AI_MOUNT}" 2>/dev/null || true
    fi
    if [[ -n "${LOOP_DEVICE:-}" ]] && losetup "${LOOP_DEVICE}" &>/dev/null; then
        losetup -d "${LOOP_DEVICE}" 2>/dev/null || true
    fi
    exit "$rc"
}
trap '_cleanup' EXIT

setup_btrfs_image "$AI_IMG" "${AI_IMG_SIZE_GIB}G"

mkdir -p "${BUILD_DIR}"
mount -t btrfs -o compress-force=zstd:19 "$LOOP_DEVICE" "${BUILD_DIR}" \
    || die "Mounting AI models image failed"

if btrfs subvolume list "${BUILD_DIR}" | grep -q "${AI_SUBVOL}"; then
    log "Deleting existing subvolume ${AI_SUBVOL}..."
    btrfs subvolume delete "${BUILD_DIR}/${AI_SUBVOL}" \
        || die "Failed to delete existing subvolume"
fi

log "Creating new subvolume: ${AI_SUBVOL}"
btrfs subvolume create "${BUILD_DIR}/${AI_SUBVOL}" || die "Subvolume creation failed"
sync
umount "${BUILD_DIR}" || die "Failed to unmount build directory"

mkdir -p "${AI_MOUNT}"
mount -o subvol="${AI_SUBVOL}",compress-force=zstd:19 "$LOOP_DEVICE" "${AI_MOUNT}" \
    || die "Mounting AI models subvolume failed"
mountpoint "${AI_MOUNT}" || die "Subvolume mount verification failed"

_llm_dir="${AI_MOUNT}/llm"
_vis_dir="${AI_MOUNT}/vision"
mkdir -p "$_llm_dir" "$_vis_dir"

# Download each model listed in ai-models.txt.
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and blank lines.
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    [[ -z "$line" ]] && continue

    case "$line" in
        qwen3.5-2b)
            _repo="https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae"
            _entries=("Qwen3.5-2B-Q4_K_M.gguf:aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223:1280835840"
                      "mmproj-F16.gguf:7035e9cb8d7c6a9681d07eef9a364783e86ea4cd73faab2eabb4f43a101830c7:668227264")
            for entry in "${_entries[@]}"; do
                IFS=":" read -r _name _sha _size <<< "$entry"
                _dest="$_llm_dir/$_name"
                [[ "$_name" == mmproj-* ]] && _dest="$_vis_dir/$_name"
                if [[ -f "$_dest" ]] && [[ "$(sha256sum "$_dest" | awk '{print $1}')" == "$_sha" ]]; then
                    log "  $_name already present and verified"
                    continue
                fi
                log "  downloading $_name ($_size bytes)..."
                curl -fL --retry 3 -o "$_dest" "$_repo/$_name" \
                    || die "failed to download $_name"
                _got_sha=$(sha256sum "$_dest" | awk '{print $1}')
                _got_size=$(stat -c %s "$_dest")
                [[ "$_got_sha" == "$_sha" ]] || die "$_name sha256 mismatch"
                [[ "$_got_size" == "$_size" ]] || die "$_name size mismatch"
                log "  $_name verified ($_got_size bytes)"
            done
            ;;
        *)
            die "Unknown model in ai-models.txt: '$line'"
            ;;
    esac
done < "$MODEL_LIST"

chmod 755 "$_llm_dir" "$_vis_dir" 2>/dev/null || true

# Set subvolume read-only before snapshot
btrfs property set -f -ts "$AI_MOUNT" ro true \
    || die "Failed to set subvolume read-only"

btrfs_send_snapshot "$AI_MOUNT" "${OUTPUT_FILE}"

btrfs property set -f -ts "$AI_MOUNT" ro false \
    || die "Failed to reset subvolume properties"

log "AI models image layer complete: ${OUTPUT_FILE}"
