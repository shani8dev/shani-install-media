#!/usr/bin/env bash
# build-parallel.sh – Build multiple profiles in parallel with flock synchronization
#
# Builds multiple shani-install-media profiles concurrently, using flock
# to prevent race conditions on shared resources (pacman cache, loop devices).
# Includes real-time progress monitoring and graceful Ctrl+C handling.
#
# Usage:
#   ./build-parallel.sh [-p profile1,profile2,...] [--minimal] [--from-r2]
#
# Examples:
#   ./build-parallel.sh                                    # Build all profiles
#   ./build-parallel.sh -p gnome,plasma                    # Build specific profiles
#   ./build-parallel.sh --minimal                          # Build minimal profiles
#   ./build-parallel.sh --from-r2                          # Download base from R2

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# ── Defaults ────────────────────────────────────────────────────────────────
PROFILES=""
MINIMAL=false
FROM_R2=false
LOCK_FILE="${TEMP_DIR}/build-parallel.lock"
PROGRESS_FILE="${TEMP_DIR}/build-parallel-progress"
FAILED_FILE="${TEMP_DIR}/build-parallel-failed"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--profiles)
            PROFILES="$2"
            shift 2
            ;;
        --minimal)
            # Same situation as --from-r2 below: nothing downstream reads this.
            # build-base-image.sh has no minimal-package-list concept, no
            # image_profiles/*/package-list-minimal.txt exists, and config.sh's
            # compute_variant_name() checks a differently-named MINIMAL_BUILD
            # env var that this flag never set. Silently accepting --minimal
            # would produce a full build while claiming "Minimal mode: true".
            die "--minimal is not implemented yet (no minimal package list or build-base-image.sh support exists)"
            ;;
        --from-r2)
            # build-base-image.sh has no --from-r2 (or equivalent) support at
            # all — it only builds the base image locally via pacstrap. Fail
            # here, at parse time, rather than silently accepting the flag
            # and having every background profile build die deep inside a
            # subshell with a cryptic "Invalid option" from build-base-image.sh's
            # own getopts once it receives an option it doesn't recognize.
            die "--from-r2 is not implemented yet (build-base-image.sh has no matching flag)"
            ;;
        -h|--help)
            echo "Usage: $0 [-p profile1,profile2,...] [--minimal] [--from-r2]"
            echo ""
            echo "Options:"
            echo "  -p, --profiles    Comma-separated list of profiles to build"
            echo "  --minimal         Build minimal package sets"
            echo "  --from-r2         Download base from Cloudflare R2"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

# ── SSH key diagnostics ────────────────────────────────────────
check_ssh_key() {
    local key_path=""

    if [[ -f ~/.ssh/id_ed25519 ]]; then
        key_path=~/.ssh/id_ed25519
    elif [[ -f ~/.ssh/id_rsa ]]; then
        key_path=~/.ssh/id_rsa
    fi

    if [[ -z "$key_path" ]]; then
        warn "No SSH key found at ~/.ssh/id_rsa or ~/.ssh/id_ed25519"
        return 1
    fi

    log "Checking SSH key: ${key_path}"

    if ! ssh-keygen -l -f "$key_path" >/dev/null 2>&1; then
        warn "SSH key at ${key_path} has invalid format"
        return 1
    fi

    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no localhost exit 2>/dev/null; then
        warn "SSH key at ${key_path} failed authentication test"
        return 1
    fi

    log "SSH key validated successfully"
    return 0
}

check_ssh_key || true

# ── Determine profiles to build ──────────────────────────────────────
if [[ -z "$PROFILES" ]]; then
    # Default: build all available profiles. Comma-separated to match the
    # `IFS=',' read -ra` split below — a space-separated default here would
    # silently become one bogus profile name containing all six, not six
    # separate profiles.
    PROFILES="gnome,plasma,cosmic,kiosk,server,shared"
fi

# Convert comma-separated to array
IFS=',' read -ra PROFILE_ARRAY <<< "$PROFILES"

log "Parallel build starting for ${#PROFILE_ARRAY[@]} profiles: ${PROFILE_ARRAY[*]}"
log "Lock file: ${LOCK_FILE}"
log "Minimal mode: ${MINIMAL}"
log "Download from R2: ${FROM_R2}"

# ── Cleanup function ─────────────────────────────────────────────────────────
_cleanup_parallel() {
    local rc=$?
    log "Parallel build interrupted or completed"
    # Release all flock locks
    for lock_fd in $(ls "${TEMP_DIR}"/build-parallel-*.lock.fd 2>/dev/null || true); do
        rm -f "$lock_fd"
    done
    exit "$rc"
}
trap '_cleanup_parallel' EXIT INT TERM

# ── Function to build a single profile ───────────────────────────────────────
build_profile() {
    local profile="$1"
    local lock_fd="${TEMP_DIR}/build-parallel-${profile}.lock.fd"
    local progress_file="${PROGRESS_FILE}.${profile}"
    local failed_file="${FAILED_FILE}.${profile}"

    # Create lock file for this profile
    touch "$lock_fd"

    # Use flock to prevent concurrent builds of the same profile
    (
        flock -w 300 200 || { echo "Failed to acquire lock for ${profile}" >&2; exit 1; }

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

        # Renice/ionice to keep system responsive during builds (from ISO-main)
        renice -n 10 $$ >/dev/null 2>&1 || true
        ionice -c 2 -n 4 -p $$ >/dev/null 2>&1 || true

        log "=== Building profile: ${profile} ==="
        echo "STARTED" > "$progress_file"

        local start_time
        start_time=$(date +%s)

        local log_file="${TEMP_DIR}/build-${profile}-$(date +%Y%m%d-%H%M%S).log"
        log "Build log: ${log_file}"

        # Build the profile (reuse existing build-base-image.sh). FROM_R2 is
        # always false here (--from-r2 dies at parse time above until
        # build-base-image.sh actually supports it) — no flag to forward.
        if "${SCRIPT_DIR}/build-base-image.sh" -p "$profile" > "$log_file" 2>&1; then
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))
            echo "COMPLETED (${duration}s)" > "$progress_file"
            log "=== Profile ${profile} completed in ${duration}s ==="
        else
            echo "FAILED" > "$progress_file"
            echo "$profile" >> "$failed_file"
            log "=== Profile ${profile} FAILED ==="
            local last_step
            last_step=$(grep -iE 'Step|latest step' "$log_file" | tail -1 || true)
            if [[ -n "$last_step" ]]; then
                log "  Last step from log: ${last_step}"
            fi
            log "  Full log: ${log_file}"
        fi

    ) 200>"$lock_fd"
}

export -f build_profile
export SCRIPT_DIR FROM_R2 PROGRESS_FILE FAILED_FILE TEMP_DIR

# ── Build profiles in parallel ───────────────────────────────────────────────
log "Starting parallel builds with ${#PROFILE_ARRAY[@]} concurrent jobs..."

pids=()
for profile in "${PROFILE_ARRAY[@]}"; do
    build_profile "$profile" &
    pids+=($!)
    log "Started build for ${profile} (PID: $!)"
done

# ── Monitor progress ─────────────────────────────────────────────────────────
log "Monitoring progress..."
all_done=false
while ! $all_done; do
    all_done=true
    for profile in "${PROFILE_ARRAY[@]}"; do
        progress_file="${PROGRESS_FILE}.${profile}"
        if [[ -f "$progress_file" ]]; then
            status=$(cat "$progress_file")
            log "  ${profile}: ${status}"
            if [[ "$status" != "COMPLETED"* && "$status" != "FAILED" ]]; then
                all_done=false
            fi
        else
            all_done=false
        fi
    done
    if ! $all_done; then
        sleep 5
    fi
done

# ── Wait for all background jobs ─────────────────────────────────────────────
failed_profiles=()
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        failed_profiles+=("$pid")
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
log "=== Build Summary ==="
completed=0
failed=0
for profile in "${PROFILE_ARRAY[@]}"; do
    progress_file="${PROGRESS_FILE}.${profile}"
    if [[ -f "$progress_file" ]]; then
        status=$(cat "$progress_file")
        if [[ "$status" == "COMPLETED"* ]]; then
            log "  ✓ ${profile}: ${status}"
            ((completed++)) || true
        else
            log "  ✗ ${profile}: ${status}"
            local profile_log="${TEMP_DIR}/build-${profile}-"*.log
            if ls ${profile_log} >/dev/null 2>&1; then
                log "  Log file: $(ls -t ${profile_log} | head -1)"
            fi
            ((failed++)) || true
        fi
    else
        log "  ? ${profile}: NO STATUS FILE"
        ((failed++)) || true
    fi
done

log "Completed: ${completed}, Failed: ${failed}"

if [[ $failed -gt 0 ]]; then
    die "Parallel build completed with ${failed} failures"
fi

log "Parallel build completed successfully!"
