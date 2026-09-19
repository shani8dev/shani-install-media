#!/usr/bin/env bash
# config.sh – Global configuration and common helper functions

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Global configuration variables
# ---------------------------------------------------------------------------
OS_NAME="shanios"
# Honour a pre-exported BUILD_DATE (set by build.sh before dispatching
# sub-scripts) so all stages of a compound command share the same date
# even across a midnight boundary. Falls back to today when invoked standalone.
BUILD_DATE="${BUILD_DATE:-$(date +%Y%m%d)}"
DEFAULT_PROFILE="gnome"
OUTPUT_DIR="$(realpath -m ./cache/output)"
BUILD_DIR="$(realpath -m ./cache/build)"
TEMP_DIR="$(realpath -m ./cache/temp)"
MOK_DIR="$(realpath -m ./keys/mok)"
GPG_DIR="$(realpath -m ./keys/gpg)"
ISO_PROFILES_DIR="$(realpath ./iso_profiles)"
IMAGE_PROFILES_DIR="$(realpath ./image_profiles)"
GPG_KEY_ID="${GPG_KEY_ID:-7B927BFFD4A9EAAA8B666B77DE217F3DA8014792}"

# Must match the R2_BASE_URL constant hardcoded in shani-deploy.sh/shani-update.sh —
# it's baked into the .zsync control file's embedded URL at build time, so a
# mismatch here means deployed machines' zsync2 differential fetch would point
# at the wrong host.
R2_BASE_URL="${R2_BASE_URL:-https://downloads.shani.dev}"
# R2 paths use the BARE profile as the directory token (gnome/, plasma/).
# build-base-image.sh publishes to ${R2_BASE_URL}/${PROFILE}/... and
# shani-deploy.sh's download_update() resolves the same token from
# REMOTE_PROFILE — both sides must stay bare. A branch-prefixed directory
# (stable-gnome/) does not exist on R2 and would 404, silently falling back
# to SourceForge on every machine.
# Which channel/branch a build belongs to is tracked by the pointer files
# (latest.txt / <channel>.txt), NOT by the filename — build-base-image.sh
# names artifacts ${OS_NAME}-${BUILD_DATE}-${PROFILE}.zst with no branch
# segment, so adding a new channel is just a new <channel>.txt pointer.

# Canonical GPG home used by the builder container.
BUILDER_GNUPGHOME="${GNUPGHOME:-/home/builduser/.gnupg}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# Defined early (rather than further down with the other helpers) because the
# safety-guard block below runs immediately at source time and calls these.
log()  { echo "[INFO] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Shared network / retry constants (used by promote-stable.sh, upload.sh, etc.)
# ---------------------------------------------------------------------------
CURL_RETRIES=3
CURL_RETRY_DELAY=5
NETWORK_TIMEOUT=30
NETWORK_CONNECT_TIMEOUT=10

# ---------------------------------------------------------------------------
# Environment sanitization - prevent host environment leaks
# ---------------------------------------------------------------------------
# Unset variables that can cause issues in chroot/build environment
unset XDG_RUNTIME_DIR 2>/dev/null || true
export HOME="${HOME:-/root}"

# Ensure all writable cache directories exist before any script runs.
mkdir -p "${OUTPUT_DIR}" "${BUILD_DIR}" "${TEMP_DIR}" "${MOK_DIR}" "${GPG_DIR}"

# Per-variant cache directory to prevent parallel build collisions
VARIANT_CACHE_DIR="${BUILD_DIR}/variant-${PROFILE:-default}"
mkdir -p "${VARIANT_CACHE_DIR}"

# ---------------------------------------------------------------------------
# Safety guard - prevent accidental host modifications
# ---------------------------------------------------------------------------
# Verify we are not running as root on the host system unintentionally
# (builder container runs as root, but host execution should be cautious)
if [[ "${IS_IN_CONTAINER:-false}" != "true" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
        warn "Running as root outside container - ensure this is intentional"
        if [[ -t 0 ]]; then
            read -rp "Continue as root? [y/N] " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Branch/Channel configuration
# ---------------------------------------------------------------------------
# Supported branches: stable, unstable, forky, rolling
# Branch determines package repository URLs and appears in output filenames
SHANIOS_CHANNEL="${SHANIOS_CHANNEL:-stable}"

# Map branch names to repository URLs (Debian-style)
# These can be customized per branch as needed
declare -A BRANCH_REPOS=(
    [stable]="https://downloads.shani.dev stable main"
    [unstable]="https://downloads.shani.dev unstable main"
    [forky]="https://downloads.shani.dev forky main"
    [rolling]="https://downloads.shani.dev rolling main"
)

# Default repository for unknown branches
DEFAULT_REPO="https://downloads.shani.dev stable main"

# Branch-specific package list suffix (empty for stable)
declare -A BRANCH_PKG_SUFFIX=(
    [stable]=""
    [unstable]="-unstable"
    [forky]="-forky"
    [rolling]="-rolling"
)

# Dynamic variant name computation for unique build traceability
# Call after PROFILE and BRANCH are set to compute VARIANT_NAME
compute_variant_name() {
    local branch="${1:-${BRANCH:-stable}}"
    local profile="${2:-${PROFILE:-default}}"
    VARIANT_NAME="${branch}-${profile}"
    if [[ "${MINIMAL_BUILD:-false}" == "true" ]]; then
        VARIANT_NAME="${VARIANT_NAME}-minimal"
    fi
    if [[ "${WITH_NVIDIA:-false}" == "true" ]]; then
        VARIANT_NAME="${VARIANT_NAME}-nvidia"
    fi
}

# ---------------------------------------------------------------------------
# Unmount helpers
# ---------------------------------------------------------------------------

# Unmount all directories under a given prefix tree.
# Reads /proc/self/mounts, checks each path with mountpoint -q,
# and uses umount -R for recursive unmounting.
# Args:
#   $1 = directory prefix to match and unmount
unmount_tree() {
    local prefix="$1"
    local src mount_point rest

    # /proc/self/mounts lines are "<source> <mountpoint> <fstype> <opts> <dump>
    # <pass>" — reading into a single variable would capture the whole line
    # (source device first), so the prefix match against a mountpoint path
    # would never hit. Split into fields instead.
    while read -r src mount_point rest; do
        if [[ "$mount_point" == "$prefix"* ]] && mountpoint -q "$mount_point" 2>/dev/null; then
            umount -R "$mount_point" || warn "Failed to unmount $mount_point"
        fi
    done < /proc/self/mounts
}

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

# Check for tools required by build-base-image.sh.
check_dependencies() {
    local deps=( btrfs pacstrap losetup mount umount arch-chroot rsync gpg sha256sum zstd truncate mkfs.btrfs openssl )
    for cmd in "${deps[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed."
    done
    # zsyncmake2 generates the .zsync control file for differential updates.
    # Not fatal if missing — build-base-image.sh treats it as optional and
    # skips control-file generation with a warning rather than failing the
    # whole release, since it's an optimization on top of the full-image path.
    command -v zsyncmake2 >/dev/null 2>&1 || warn "zsyncmake2 not installed — .zsync control files will not be generated"
}

# Check for tools required by build-iso.sh / repack-iso.sh.
check_dependencies_iso() {
    local deps=( mkarchiso xorriso osirrox sbsign mcopy mktorrent )
    for cmd in "${deps[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed."
    done
}

# Check for tools required by upload.sh / promote-stable.sh.
check_dependencies_upload() {
    local deps=( rsync curl )
    for cmd in "${deps[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed."
    done
    # rclone is only required when R2 uploads are active
    if [[ -n "${R2_BUCKET:-}" ]]; then
        command -v rclone >/dev/null 2>&1 || die "rclone is required for R2 uploads but not installed."
    fi
}

# Verify or generate Secure Boot (MOK) keys.
check_mok_keys() {
    if [[ ! -f "${MOK_DIR}/MOK.key" || ! -f "${MOK_DIR}/MOK.crt" || ! -f "${MOK_DIR}/MOK.der" ]]; then
        log "MOK keys missing. Generating new keys..."
        mkdir -p "${MOK_DIR}"
        openssl req -newkey rsa:2048 -nodes -keyout "${MOK_DIR}/MOK.key" -new -x509 -sha256 -days 3650 \
          -out "${MOK_DIR}/MOK.crt" -subj "/CN=Shani OS Secure Boot Key/" \
          || die "Failed to generate MOK keys"
        openssl x509 -in "${MOK_DIR}/MOK.crt" -outform DER -out "${MOK_DIR}/MOK.der" \
          || die "Failed to convert MOK key to DER"
    else
        log "MOK keys exist."
    fi
}

# Verify GPG public key exists for embedding into the image.
# In CI the key is pre-exported by the 'Setup GPG public key' workflow step.
# As a fallback (local builds or if the step was skipped), attempt to export
# the public key from the container's keyring where GPG_PRIVATE_KEY was imported
# by run_in_container.sh. Fails hard if neither path produces the file.
check_gpg_key() {
    if [[ -f "${GPG_DIR}/gpg-public.asc" ]]; then
        log "GPG public key exists."
        return 0
    fi

    log "GPG public key not found — attempting to export from keyring..."
    mkdir -p "${GPG_DIR}"
    gpg --homedir "${BUILDER_GNUPGHOME}" \
        --batch \
        --armor \
        --export "${GPG_KEY_ID}" \
        > "${GPG_DIR}/gpg-public.asc" 2>/dev/null \
        || true

    if [[ ! -s "${GPG_DIR}/gpg-public.asc" ]]; then
        die "GPG public key not found at ${GPG_DIR}/gpg-public.asc and could not be exported" \
            "from keyring. Export it manually with:" \
            "gpg --armor --export ${GPG_KEY_ID} > ${GPG_DIR}/gpg-public.asc"
    fi

    log "GPG public key exported from keyring."
}

# Check for tools required by test-env/ (installing/booting/updating a
# built image on loop-mounted disks — see test-env/README.md).
check_dependencies_test() {
    # cmd:pacman-package — matches shani-builder/docker/Dockerfile's own
    # package list where possible (see test-env/test.sh's cmd_disk for the
    # one plausible gap, dosfstools, which self-heals before this runs).
    local deps=(
        "btrfs:btrfs-progs" "mkfs.btrfs:btrfs-progs" "mkfs.fat:dosfstools"
        "losetup:util-linux" "mount:util-linux" "umount:util-linux" "blkid:util-linux"
        "zstd:zstd" "systemd-nspawn:systemd" "openssl:openssl" "chroot:coreutils"
    )
    for entry in "${deps[@]}"; do
        local cmd="${entry%%:*}" pkg="${entry##*:}"
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed (pacman -S ${pkg})."
    done
}

# Check for tools required by test-env's cmd_install/cmd_configure — running
# the REAL os-installer-config install.sh/configure.sh end-to-end (see
# test-env/README.md's "install/configure" section). Superset of
# check_dependencies_test's disk/btrfs tooling plus everything those two
# scripts themselves shell out to directly. The published builder image is
# built for image/ISO assembly, not for running the installer, so several of
# these (sudo, parted/partprobe, cryptsetup, firewalld, dracut) are
# genuinely likely to be missing — auto-installed the same way cmd_disk
# auto-installs dosfstools, via the same persistent pacman cache
# run_in_container.sh already bind-mounts, before failing hard on anything
# that still can't be found afterward.
check_dependencies_install() {
    check_dependencies_test

    local deps=(
        "sudo:sudo" "sfdisk:util-linux" "parted:parted" "partprobe:parted"
        "cryptsetup:cryptsetup" "swapon:util-linux" "free:procps-ng"
        "awk:gawk" "mktemp:coreutils" "shred:coreutils"
        "udevadm:systemd" "hostnamectl:systemd" "localectl:systemd" "timedatectl:systemd"
        "firewall-offline-cmd:firewalld" "dracut:dracut"
        "sbsign:sbsigntools" "sbverify:sbsigntools" "mokutil:mokutil"
    )

    local missing_pkgs=() entry cmd pkg
    for entry in "${deps[@]}"; do
        cmd="${entry%%:*}"; pkg="${entry##*:}"
        command -v "$cmd" >/dev/null 2>&1 || missing_pkgs+=("$pkg")
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]] && command -v pacman >/dev/null 2>&1; then
        log "install/configure need packages not in the builder image: ${missing_pkgs[*]} — installing"
        pacman -Sy --needed --noconfirm "${missing_pkgs[@]}" \
            || warn "pacman install of one or more packages failed — see errors above"
    fi

    for entry in "${deps[@]}"; do
        cmd="${entry%%:*}"; pkg="${entry##*:}"
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed (pacman -S ${pkg})."
    done
}

# ---------------------------------------------------------------------------
# GPG signing
# ---------------------------------------------------------------------------

# Prepare the builder GPG keyring for signing:
#   - sets ultimate trust on GPG_KEY_ID
#   - verifies the secret key is present
# Must be called before gpg_sign_file().
gpg_prepare_keyring() {
    log "Preparing GPG keyring in ${BUILDER_GNUPGHOME}..."
    mkdir -p "${BUILDER_GNUPGHOME}"
    chmod 700 "${BUILDER_GNUPGHOME}"

    echo "${GPG_KEY_ID}:6:" \
        | gpg --homedir "${BUILDER_GNUPGHOME}" --batch --import-ownertrust \
        || die "Failed to set ultimate trust for ${GPG_KEY_ID}"

    if ! gpg --homedir "${BUILDER_GNUPGHOME}" --list-secret-keys "${GPG_KEY_ID}" >/dev/null 2>&1; then
        die "GPG secret key not found in ${BUILDER_GNUPGHOME}: ${GPG_KEY_ID}"
    fi
}

# Create a detached armored GPG signature for a file.
# Args:
#   $1 = path to the file to sign
# Output: <file>.asc written alongside the input file.
# Requires: gpg_prepare_keyring() called first; GPG_PASSPHRASE set in env.
gpg_sign_file() {
    local target="$1"
    [[ -f "$target" ]] || die "gpg_sign_file: file not found: $target"
    [[ -n "${GPG_PASSPHRASE:-}" ]] || die "gpg_sign_file: GPG_PASSPHRASE is not set"

    log "GPG signing: $(basename "$target")"
    gpg --homedir "${BUILDER_GNUPGHOME}" \
        --batch \
        --yes \
        --pinentry-mode loopback \
        --passphrase "${GPG_PASSPHRASE}" \
        --default-key "${GPG_KEY_ID}" \
        --detach-sign \
        --armor \
        --output "${target}.asc" \
        "${target}" \
        || die "GPG signing failed for ${target}"

    log "GPG signature created: ${target}.asc"
}

# ---------------------------------------------------------------------------
# Build date resolution
# ---------------------------------------------------------------------------

# Resolve the build date for a given profile.
# Uses today's date if a matching output folder exists, otherwise falls back
# to the most recently dated folder under OUTPUT_DIR/<profile>/.
# Args:
#   $1 = profile name
# Prints the resolved BUILD_DATE (8-digit string) to stdout.
# Dies if no dated folder can be found at all.
resolve_build_date() {
    local profile="$1"

    # If BUILD_DATE was exported by build.sh (to pin the date across a midnight
    # boundary during a compound command), honour it unconditionally — but only
    # when the corresponding folder actually exists to guard against stale values.
    if [[ -n "${BUILD_DATE:-}" ]]; then
        local pinned_dir="${OUTPUT_DIR}/${profile}/${BUILD_DATE}"
        if [[ -d "${pinned_dir}" ]]; then
            log "Using exported BUILD_DATE folder: ${BUILD_DATE}"
            echo "${BUILD_DATE}"
            return 0
        fi
        log "Warning: exported BUILD_DATE=${BUILD_DATE} folder not found — falling back to date discovery."
    fi

    local today
    today="$(date +%Y%m%d)"
    local expected_dir="${OUTPUT_DIR}/${profile}/${today}"

    if [[ -d "${expected_dir}" ]]; then
        log "Using today's build folder: ${today}"
        echo "${today}"
        return 0
    fi

    local latest
    latest=$(find "${OUTPUT_DIR}/${profile}" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null \
        | sort -r | head -n1)
    latest="${latest##*/}"  # basename without xargs

    if [[ -z "${latest}" ]]; then
        die "No build directory found under ${OUTPUT_DIR}/${profile}"
    fi

    log "Today's build folder not found; using latest build folder: ${latest}"
    echo "${latest}"
}

# ---------------------------------------------------------------------------
# Btrfs helpers
# ---------------------------------------------------------------------------

# Create a Btrfs image file, attach a loop device, format it, and print the
# loop device path to stdout.
#
# Args:
#   $1 = path to image file to create
#   $2 = size (e.g. "10G")
#
# Callers capture the loop device with:
#   LOOP_DEVICE=$(setup_btrfs_image "$img" "$size")
#
# All diagnostic output goes to stderr so stdout carries only the device path.
setup_btrfs_image() {
    local img_path="$1"
    local size="$2"
    local img_dir
    img_dir="$(dirname "$img_path")"
    mkdir -p "$img_dir" || die "Failed to create directory: $img_dir"

    # Detach EVERY loop device currently attached to this image file — a
    # prior crashed run can leave one attached (often still mounted), and a
    # half-detached state is what makes this step fail intermittently (which
    # is why a rerun then works: the file has been recreated in the meantime).
    # Three things here are deliberate, all of them learned the hard way:
    #   1. Unmount first — `losetup -d` on a mounted loop fails "device is
    #      busy", so a silent `|| warn` would leave the loop attached.
    #   2. Detach ALL of them, never just the first — `losetup -j` can return
    #      several, and a single `cut -d: -f1` hands a newline-joined string
    #      to `losetup -d`, which then errors on the multi-line arg.
    #   3. Loop over the output line by line rather than grepping for the
    #      path — the backing-file column can differ in resolution (symlink,
    #      relative vs absolute), so a substring grep can miss the stale
    #      device entirely.
    while read -r existing_loop; do
        [[ -n "$existing_loop" ]] || continue
        log "Detaching stale loop device $existing_loop (from a prior run)"
        # Unmount anything mounted on this loop before detaching.
        while read -r mnt; do
            [[ -n "$mnt" ]] || continue
            umount -R "$mnt" 2>/dev/null \
                || warn "Failed to unmount $mnt (loop $existing_loop)"
        done < <(findmnt --source "$existing_loop" -o TARGET -r --noheadings 2>/dev/null)
        losetup -d "$existing_loop" 2>/dev/null \
            || warn "Failed to detach existing loop device: $existing_loop"
    done < <(losetup -j "$img_path" 2>/dev/null | cut -d: -f1)

    log "Removing existing image file (if any): $img_path"
    rm -f "$img_path"

    # Sparse allocation: the Btrfs filesystem still reports "$size" capacity,
    # but the backing file only consumes disk blocks as they're actually
    # written, instead of the full size up front.
    truncate -s "$size" "$img_path" || die "Failed to allocate image file: $img_path"

    local loop_device
    loop_device=$(losetup --find --show "$img_path") \
        || die "Failed to setup loop device for $img_path"
    log "Loop device assigned: $loop_device"

    log "Formatting $loop_device as Btrfs..."
    mkfs.btrfs -f "$loop_device" || die "Failed to format $img_path as Btrfs"

    LOOP_DEVICE="$loop_device" #imp do not remove
    # Print the loop device path — this is the function's return value.
    echo "$loop_device"
}

# Unmount a Btrfs subvolume, detach the loop device, and remove the mount point.
# Args:
#   $1 = mount point
#   $2 = loop device
detach_btrfs_image() {
    local mount_point="$1"
    local loop_dev="$2"

    if mountpoint -q "$mount_point" 2>/dev/null; then
        umount -R "$mount_point" || warn "Failed to unmount $mount_point"
    fi

    if [[ -n "$loop_dev" ]]; then
        losetup -d "$loop_dev" || warn "Failed to detach loop device $loop_dev"
    fi

    # Guard against accidentally rm -rf'ing an empty or root path
    if [[ -n "$mount_point" && "$mount_point" != "/" ]]; then
        rm -rf "$mount_point"
    else
        warn "detach_btrfs_image: refusing to remove suspicious mount point: '${mount_point}'"
    fi
}

# Create a compressed snapshot of a read-only Btrfs subvolume.
# Uses a temp file so a failed compression never produces a partial output file.
# Args:
#   $1 = path to the read-only subvolume
#   $2 = destination output file (will be a zstd-compressed btrfs stream)
btrfs_send_snapshot() {
    local subvol_path="$1"
    local output_file="$2"
    local tmp_file="${output_file}.tmp"

    log "Creating Btrfs snapshot: ${subvol_path} → ${output_file}"

    # Write to a temp file so a partial run never leaves a corrupt output file.
    # pipefail (active via set -Eeuo pipefail) ensures btrfs send failures are caught.
    btrfs send "${subvol_path}" \
        | zstd --ultra --long=31 -T0 -22 -v > "${tmp_file}" \
        || { rm -f "${tmp_file}"; die "btrfs_send_snapshot failed for ${subvol_path}"; }

    mv "${tmp_file}" "${output_file}"
    log "Snapshot written: ${output_file} ($(du -sh "${output_file}" | cut -f1))"
}
