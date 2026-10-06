#!/usr/bin/env bash
# build-base-image.sh – Build the immutable base system image (container-only)
# Artifacts are written to: cache/output/<profile>/<BUILD_DATE>/

set -Eeuo pipefail

# Subshell error isolation — report which step failed
error_function() {
    local rc=$?
    (( rc == 0 )) && return 0   # EXIT trap: runs on success too
    echo "[ERROR] Build step failed with exit code $rc" >&2
    echo "[ERROR] Check output above for the failed step" >&2
    return $rc
}
trap error_function EXIT
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# Parse options
PROFILE=""
CLEAN_BASE=false
BRANCH=""
while getopts "p:cb:" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    c) CLEAN_BASE=true ;;
    b) BRANCH="$OPTARG" ;;
    *) die "Invalid option" ;;
  esac
done
shift $((OPTIND - 1))
[[ -z "$PROFILE" ]] && die "Profile (-p) is required."

# Use provided branch or fall back to config default
BRANCH="${BRANCH:-${SHANIOS_CHANNEL:-stable}}"

# Compute variant name for cache hash and traceability
compute_variant_name "$BRANCH" "$PROFILE"

# Deliberately NOT ${PROFILE}/${BRANCH}/${BUILD_DATE}: upload.sh, build-iso.sh,
# and repack-iso.sh all still expect ${PROFILE}/${BUILD_DATE} with no branch
# segment, so nesting under branch here would make this script write artifacts
# none of those (unmodified) downstream consumers would ever find.
# Which channel/branch a build belongs to is NOT encoded in the filename — it
# is tracked by the pointer files (latest.txt / <channel>.txt) this script
# writes and promote-stable.sh maintains, so adding a new channel is just a
# new <channel>.txt pointer. The branch is still recoverable at build time via
# BRANCH/VARIANT_NAME for cache hashing and traceability.
OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
mkdir -p "${OUTPUT_SUBDIR}"

# ── Cached base with change detection ────────────────────────────────────────
# Save the used package list hash in the base image for change detection.
# On subsequent builds, compare current package list vs cached list.
# Only regenerate base cache if list changed or CLEAN_BASE flag used.
# Package lists split into Base/Desktop/Extras for ordered installation.
PACKAGE_BASE="${IMAGE_PROFILES_DIR}/${PROFILE}/Packages-Base"
PACKAGE_DESKTOP="${IMAGE_PROFILES_DIR}/${PROFILE}/Packages-Desktop"
PACKAGE_EXTRAS="${IMAGE_PROFILES_DIR}/${PROFILE}/Packages-Extras"
[[ -f "$PACKAGE_BASE" ]] || die "Package list not found for profile ${PROFILE}: Packages-Base"

# Compute hash of current package lists (excluding comments and blank lines),
# concatenated in installation order: Base → Desktop → Extras.
#
# The key is NOT just the package lists. A lists-only key answers "are the
# requested package NAMES unchanged" and nothing else, so it cannot see:
#
#   * a rebuilt builder image — the base is assembled by whatever the
#     :latest tag resolved to, so a re-pulled image silently invalidated
#     every cached base while this check still reported "unchanged";
#   * a changed profile pacman.conf — different repos, SigLevel, or
#     mirrorlist change what those names resolve to;
#   * a package that vanished from a repo — the lists still name it, and
#     the cached base "matches", but a fresh build would now fail (this is
#     exactly how shani-core went missing from the pacman db while every
#     profile's Packages-Base still listed it: the guard reported a match
#     and skipped a build that could not have succeeded).
#
# So fold the builder image's resolved ID and the profile's pacman.conf into
# the key too. An image ID is the honest signal here: the tag is mutable and
# is re-pulled every run, so hashing the tag would change on a no-op pull
# and defeat the cache; the ID changes only when the bytes do.
CURRENT_LIST_HASH=$(
    {
        cat "$PACKAGE_BASE" "$PACKAGE_DESKTOP" "$PACKAGE_EXTRAS" \
            | grep -v '^\s*#' \
            | tr -d '\r' \
            | grep -v '^\s*$'
        # Delimiters matter: without them a package list ending in one name
        # and a conf starting with the same characters could in principle
        # concatenate into the same byte stream as a genuinely different
        # pair, silently aliasing two different cache entries.
        printf -- '--- pacman.conf ---\n'
        cat "${IMAGE_PROFILES_DIR}/${PROFILE}/pacman.conf"
        printf -- '--- builder image ---\n%s\n' "${BUILDER_IMAGE_ID:-unknown-builder-image}"
    } | sha256sum | awk '{print $1}'
)

# Deliberately NOT under OUTPUT_SUBDIR: that path includes BUILD_DATE, so a
# hash written there could never be found by tomorrow's build — the "skip if
# unchanged" check would never hit across a day boundary, which is the most
# common case it exists to speed up. mkdir -p above already created this
# stable, date-independent parent as a side effect of creating OUTPUT_SUBDIR.
# VARIANT_NAME already embeds the branch, so different branches of the same
# profile get distinct hash files without needing a branch subdirectory.
CACHE_HASH_FILE="${OUTPUT_DIR}/${PROFILE}/${VARIANT_NAME}.listhash"
CACHED_HASH=""
if [[ -f "$CACHE_HASH_FILE" ]]; then
    CACHED_HASH=$(cat "$CACHE_HASH_FILE")
fi

if [[ "$CLEAN_BASE" == "false" && "$CURRENT_LIST_HASH" == "$CACHED_HASH" ]]; then
    log "Base inputs unchanged (hash: ${CURRENT_LIST_HASH:0:12}...), skipping base rebuild"
    log "  keyed on: package lists + pacman.conf + builder image ${BUILDER_IMAGE_ID:0:19}"
    log "  this still does NOT detect upstream package versions moving, or a"
    log "  package disappearing from a repo — force a rebuild with -c if you"
    log "  suspect either."
    log "Use -c flag to force rebuild"
    exit 0
fi

if [[ "$CLEAN_BASE" == "false" && -n "$CACHED_HASH" && "$CURRENT_LIST_HASH" != "$CACHED_HASH" ]]; then
    log "Base inputs changed (hash: ${CURRENT_LIST_HASH:0:12}..., was ${CACHED_HASH:0:12}...) — rebuilding"
    log "  keyed on: package lists + pacman.conf + builder image ${BUILDER_IMAGE_ID:0:19}"
else
    log "Base inputs hash: ${CURRENT_LIST_HASH:0:12}..."
fi

PACMAN_CONFIG="./image_profiles/${PROFILE}/pacman.conf"
BASE_SUBVOL="${OS_NAME}_base"
IMAGE_NAME="${OS_NAME}-${BUILD_DATE}-${PROFILE}.zst"
IMAGE_FILE="${OUTPUT_SUBDIR}/${IMAGE_NAME}"

log "Building base image for profile: ${PROFILE}"
check_dependencies
check_mok_keys
check_gpg_key

# Preflight cleanup: release residual mounts from interrupted previous builds
for mnt in "${BUILD_DIR}/${OS_NAME}_base" "${BUILD_DIR}/${OS_NAME}_target"; do
    if mountpoint -q "$mnt" 2>/dev/null; then
        warn "Residual mount detected at ${mnt}, cleaning up"
        umount -R "$mnt" 2>/dev/null || warn "Failed to unmount ${mnt}"
    fi
done
for loop in $(losetup -j "${BUILD_DIR}/"*.img 2>/dev/null | cut -d: -f1); do
    warn "Residual loop device detected: ${loop}, detaching"
    losetup -d "$loop" 2>/dev/null || warn "Failed to detach ${loop}"
done

# ---------------------------------------------------------------------------
# Set up Btrfs image for base system (10G)
# ---------------------------------------------------------------------------
BASE_IMG="${BUILD_DIR}/base.img"
setup_btrfs_image "$BASE_IMG" "10G"
# LOOP_DEVICE is set by setup_btrfs_image reuse dont specify here
SUBVOL_MOUNT="${BUILD_DIR}/${BASE_SUBVOL}"

# ---------------------------------------------------------------------------
# Cleanup trap — runs on any exit (success, error, or signal).
# Ensures mounts are released and the loop device is detached so the host
# never leaks kernel resources when the script exits unexpectedly.
# ---------------------------------------------------------------------------
_cleanup() {
    local rc=$?
    # Unmount the subvolume mount if still active
    if mountpoint -q "${SUBVOL_MOUNT}" 2>/dev/null; then
        log "Cleanup: unmounting ${SUBVOL_MOUNT}"
        umount -R "${SUBVOL_MOUNT}" 2>/dev/null || warn "Cleanup: umount ${SUBVOL_MOUNT} failed"
    fi
    # Unmount the root loop mount if still active
    if mountpoint -q "${BUILD_DIR}" 2>/dev/null; then
        log "Cleanup: unmounting ${BUILD_DIR}"
        umount "${BUILD_DIR}" 2>/dev/null || warn "Cleanup: umount ${BUILD_DIR} failed"
    fi
    # Detach loop device
    if [[ -n "${LOOP_DEVICE:-}" ]] && losetup "${LOOP_DEVICE}" &>/dev/null; then
        log "Cleanup: detaching ${LOOP_DEVICE}"
        losetup -d "${LOOP_DEVICE}" 2>/dev/null || warn "Cleanup: losetup -d ${LOOP_DEVICE} failed"
    fi
    exit "$rc"
}
trap '_cleanup' EXIT

# ---------------------------------------------------------------------------
# Mount image, create subvolume, remount the subvolume
# ---------------------------------------------------------------------------
mkdir -p "${BUILD_DIR}"
mount -t btrfs -o compress-force=zstd:19 "$LOOP_DEVICE" "${BUILD_DIR}" \
    || die "Mounting base image failed"

if btrfs subvolume list "${BUILD_DIR}" | grep -q "${BASE_SUBVOL}"; then
    log "Deleting existing subvolume ${BASE_SUBVOL}..."
    btrfs subvolume delete "${BUILD_DIR}/${BASE_SUBVOL}" \
        || die "Failed to delete existing subvolume"
fi

log "Creating new subvolume: ${BASE_SUBVOL}"
btrfs subvolume create "${BUILD_DIR}/${BASE_SUBVOL}" || die "Subvolume creation failed"
sync
umount "${BUILD_DIR}" || die "Failed to unmount build directory"

mkdir -p "${SUBVOL_MOUNT}"
mount -o subvol="${BASE_SUBVOL}",compress-force=zstd:19 "$LOOP_DEVICE" "${SUBVOL_MOUNT}" \
    || die "Mounting subvolume failed"
mountpoint "${SUBVOL_MOUNT}" || die "Subvolume mount verification failed"

# ---------------------------------------------------------------------------
# Install keys into the image
# ---------------------------------------------------------------------------
gpg_target="${SUBVOL_MOUNT}/etc/shani-keys/"
mkdir -p "$gpg_target"
install -m 644 "${GPG_DIR}/gpg-public.asc" "$gpg_target/signing.asc" \
    || die "Failed to install signing.asc"

secureboot_target="${SUBVOL_MOUNT}/etc/secureboot/keys"
mkdir -p "$secureboot_target"
install -m 600 "${MOK_DIR}/MOK.key" "$secureboot_target/MOK.key" || die "Failed to install MOK.key"
install -m 644 "${MOK_DIR}/MOK.crt" "$secureboot_target/MOK.crt" || die "Failed to install MOK.crt"
install -m 644 "${MOK_DIR}/MOK.der" "$secureboot_target/MOK.der" || die "Failed to install MOK.der"

# ---------------------------------------------------------------------------
# Install base system via pacstrap and apply overlays/customizations
# ---------------------------------------------------------------------------
log "Installing base system..."

# Fail fast on a poisoned package cache, BEFORE pacstrap spends 40 minutes
# downloading and unpacking only to abort at the end with "invalid or corrupted
# package" (exactly how this was found on 2026-10-06: two silently truncated
# files in the shared cache — zstd -t and tar -tf both PASS on them, so only a
# hash comparison against the repo sees it). Advisory rather than fatal: the
# cache is shared between this repo and shani-pkgbuilds, so deleting from it is
# not this script's call. It is not suppressed — `|| true` here only means "do
# not abort", and the output is still printed, because a check whose findings
# are swallowed is worse than no check.
log "Verifying cached packages against the repos before installing..."
bash "${SCRIPT_DIR}/check-pacman-cache.sh" -p "${PROFILE}" --quiet \
    || warn "check-pacman-cache.sh reported problems (see above) — the build continues, but pacstrap may fail with 'invalid or corrupted package'."

# Read packages from Base, Desktop, Extras in installation order.
mapfile -t _packages < <(
    cat "$PACKAGE_BASE" "$PACKAGE_DESKTOP" "$PACKAGE_EXTRAS" \
    | grep -v '^\s*#' \
    | tr -d '\r' \
    | grep -v '^\s*$'
)
[[ ${#_packages[@]} -gt 0 ]] || die "Package list is empty for profile ${PROFILE}"

# Install in order: Base first, then Desktop, then Extras.
pacstrap -cC "$PACMAN_CONFIG" "${SUBVOL_MOUNT}" "${_packages[@]}" \
    || die "pacstrap failed"

# ── Export fully-resolved installed package set (read-only db query, no net) ──
# `pacman -Qq` reads /var/lib/pacman/local/ in the chroot, giving the complete
# list that actually landed in this image (top-level pkgs + all transitive
# deps) — the reviewable ground-truth for "what ships" checks.
PACKAGE_LIST_ARTIFACT="${OUTPUT_SUBDIR}/${OS_NAME}-${BUILD_DATE}-${PROFILE}.packages.txt"
arch-chroot "${SUBVOL_MOUNT}" pacman -Qq > "${PACKAGE_LIST_ARTIFACT}"
log "Exported resolved package list (${PACKAGE_LIST_ARTIFACT})"

# Apply shared overlay first, then the profile-specific overlay on top.
# Order matters: a profile's own overlay must be able to override shared
# defaults (server does this for its 20 server-only files). cosmic/gnome/plasma
# skip the second copy — their overlay/ is a symlink to ../shared/overlay, so
# following it would copy the same tree twice. Only real directories are copied.
if [[ -d "${IMAGE_PROFILES_DIR}/shared/overlay/rootfs" ]]; then
    log "Applying shared overlay files..."
    cp -r "${IMAGE_PROFILES_DIR}/shared/overlay/rootfs/"* "${SUBVOL_MOUNT}/" \
        || die "Shared overlay copy failed"
fi
if [[ -d "${IMAGE_PROFILES_DIR}/${PROFILE}/overlay/rootfs" \
      && "$(readlink -f "${IMAGE_PROFILES_DIR}/${PROFILE}/overlay" 2>/dev/null)" \
           != "$(readlink -f "${IMAGE_PROFILES_DIR}/shared/overlay" 2>/dev/null)" ]]; then
    log "Applying ${PROFILE} overlay files..."
    cp -r "${IMAGE_PROFILES_DIR}/${PROFILE}/overlay/rootfs/"* "${SUBVOL_MOUNT}/" \
        || die "Overlay copy failed"
fi

if [[ -f "${IMAGE_PROFILES_DIR}/${PROFILE}/${PROFILE}-customization.sh" ]]; then
    log "Applying customizations..."
    bash "${IMAGE_PROFILES_DIR}/${PROFILE}/${PROFILE}-customization.sh" "${SUBVOL_MOUNT}" \
        || die "Customizations failed"
fi

# Every directory a package ships under /var, as tmpfiles.d lines: /var is a
# tmpfs at runtime (systemd.volatile=state) and the /data/varlib binds start
# empty, so without this smb/nmb/winbind, rpc-statd and libvirtd fail on a
# fresh install. After the overlays and customizations, so every package and
# every hand-written tmpfiles.d line (which take precedence) is already there.
bash "${SCRIPT_DIR}/gen-var-tmpfiles.sh" "${SUBVOL_MOUNT}" \
    || die "Generating /var tmpfiles.d entries failed"

# Optional OEM/private-mirror injection (integration-map Product 6, Option A).
# Rewrites shani-deploy's compile-time constants inside the image before the
# btrfs snapshot — preserves immutability at runtime (no /etc override file).
if [[ -n "${CUSTOM_MIRROR_BASE_URL:-}" || -n "${CUSTOM_GPG_KEY_ID:-}" ]]; then
    DEPLOY_IN_IMAGE="${SUBVOL_MOUNT}/usr/local/bin/shani-deploy"
    [[ -f "$DEPLOY_IN_IMAGE" ]] || die "shani-deploy not found at ${DEPLOY_IN_IMAGE} — cannot inject custom mirror"
    if [[ -n "${CUSTOM_MIRROR_BASE_URL:-}" ]]; then
        sed -i "s|readonly R2_BASE_URL=.*|readonly R2_BASE_URL=\"${CUSTOM_MIRROR_BASE_URL}\"|" "$DEPLOY_IN_IMAGE"
        log "Injected CUSTOM_MIRROR_BASE_URL into image shani-deploy"
    fi
    if [[ -n "${CUSTOM_GPG_KEY_ID:-}" ]]; then
        sed -i "s|readonly GPG_KEY_ID=.*|readonly GPG_KEY_ID=\"${CUSTOM_GPG_KEY_ID}\"|" "$DEPLOY_IN_IMAGE"
        log "Injected CUSTOM_GPG_KEY_ID into image shani-deploy"
    fi
fi

# ---------------------------------------------------------------------------
# chroot configuration
# ---------------------------------------------------------------------------
# Validate GPG_KEY_ID is non-empty before interpolating it into the heredoc.
[[ -n "${GPG_KEY_ID:-}" ]] || die "GPG_KEY_ID is not set — cannot set ownertrust inside chroot."

arch-chroot "${SUBVOL_MOUNT}" /bin/bash <<EOF
set -euo pipefail

echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

systemd-machine-id-setup --commit

echo "${OS_NAME}" > /etc/hostname
echo "PRETTY_HOSTNAME=${OS_NAME}" > /etc/machine-info
printf '127.0.0.1 localhost\n::1       localhost\n127.0.1.1 %s\n' "${OS_NAME}" > /etc/hosts
echo "${BUILD_DATE}" > /etc/shani-version
echo "${PROFILE}" > /etc/shani-profile
echo "stable" > /etc/shani-channel

# Extra groups added to every user account at creation time.
# Single source of truth read by shani-user-setup, adduser wrapper, useradd wrapper.
echo "sys,cups,lp,scanner,realtime,input,video,kvm,libvirt,lxd,nixbld,sambashare" > /etc/shani-extra-groups
chmod 644 /etc/shani-extra-groups

mkdir -p /boot/efi /swap /data /nix

ln -s /var/lib/snapd/snap /snap

mkdir -p /var/lib/flatpak /var/lib/snapd /var/lib/waydroid /var/lib/containers \
         /var/lib/machines /var/lib/lxc /var/lib/lxd /var/lib/libvirt /var/lib/qemu \
         /var/cache /var/log

chmod 755 /var/lib/flatpak /var/lib/snapd /var/lib/waydroid /var/lib/containers \
          /var/lib/machines /var/lib/lxc /var/lib/lxd

# Groups with confirmed static GIDs (Arch archwiki / systemd basic.conf)
getent group sys     &>/dev/null || groupadd -r -g 3   sys
getent group lp      &>/dev/null || groupadd -r -g 7   lp
getent group kvm     &>/dev/null || groupadd -r -g 78  kvm
getent group video   &>/dev/null || groupadd -r -g 91  video
getent group scanner &>/dev/null || groupadd -r -g 96  scanner
getent group input   &>/dev/null || groupadd -r -g 97  input
getent group cups    &>/dev/null || groupadd -r -g 209 cups

# Groups with no upstream static GID — allocate dynamically
getent group realtime   &>/dev/null || groupadd -r realtime
getent group nixbld     &>/dev/null || groupadd -r nixbld
getent group lxd        &>/dev/null || groupadd -r lxd
getent group libvirt    &>/dev/null || groupadd -r libvirt
getent group sambashare &>/dev/null || groupadd -r sambashare
# subuid/subgid for root — required for rootless podman, lxc, lxd
usermod -v 1000000-1000999999 -w 1000000-1000999999 root

# Import Shani signing public key (for update verification)
if [[ -f /etc/shani-keys/signing.asc ]]; then
    mkdir -p /root/.gnupg
    chmod 700 /root/.gnupg
    gpg --homedir /root/.gnupg --import /etc/shani-keys/signing.asc
    echo "${GPG_KEY_ID}:6:" | gpg --homedir /root/.gnupg --import-ownertrust
fi

chmod 0440 /etc/sudoers.d/path
EOF

# ---------------------------------------------------------------------------
# Snapshot and sign
# ---------------------------------------------------------------------------
btrfs property set -f -ts "${SUBVOL_MOUNT}" ro true \
    || die "Failed to set subvolume read-only"

btrfs_send_snapshot "${SUBVOL_MOUNT}" "${IMAGE_FILE}"

btrfs property set -f -ts "${SUBVOL_MOUNT}" ro false \
    || die "Failed to reset subvolume to writable"

# detach_btrfs_image handles unmounting and loop detachment.
# Clear LOOP_DEVICE BEFORE calling detach so the EXIT trap never attempts
# a second detach if detach_btrfs_image itself fails partway through.
LOOP_DEVICE_TMP="$LOOP_DEVICE"
LOOP_DEVICE=""
detach_btrfs_image "${SUBVOL_MOUNT}" "$LOOP_DEVICE_TMP"

# ---------------------------------------------------------------------------
# Checksum and sign
# ---------------------------------------------------------------------------
gpg_prepare_keyring

pushd "${OUTPUT_SUBDIR}" > /dev/null
sha256sum "${IMAGE_NAME}" > "${IMAGE_NAME}.sha256" \
    || die "Checksum generation failed"
popd > /dev/null

gpg_sign_file "${IMAGE_FILE}"

# ---------------------------------------------------------------------------
# Differential-update control file (zsync2)
# ---------------------------------------------------------------------------
# Optional: lets shani-deploy fetch only the blocks that changed since a
# machine's previously downloaded image instead of the full file. Soft-fail
# on any problem — the full-image download/verify path works with or without
# this file, so a control-file generation issue must never block a release.
if command -v zsyncmake2 >/dev/null 2>&1; then
    pushd "${OUTPUT_SUBDIR}" > /dev/null
    if zsyncmake2 -u "${R2_BASE_URL}/${PROFILE}/${BUILD_DATE}/${IMAGE_NAME}" "${IMAGE_NAME}"; then
        log "Generated ${IMAGE_NAME}.zsync"
    else
        warn "zsyncmake2 failed — continuing without a .zsync control file for this build"
    fi
    popd > /dev/null
else
    warn "zsyncmake2 not found — skipping .zsync control file generation"
fi

echo "${IMAGE_NAME}" > "${OUTPUT_SUBDIR}/latest.txt"

# Save package list hash for change detection on subsequent builds
echo "${CURRENT_LIST_HASH}" > "${CACHE_HASH_FILE}"

log "Base image build completed successfully!"
