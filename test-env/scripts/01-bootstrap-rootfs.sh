#!/bin/bash
# 01-bootstrap-rootfs.sh -p <profile> [-d <date>|latest|stable]
# 01-bootstrap-rootfs.sh <OUTPUT_DIR>/<profile>/<date>/<file>.zst   (direct path also accepted)
#
# Mirrors what os-installer-config/scripts/install.sh does on a real install:
#   1. mount the Btrfs top level
#   2. create the top-level subvolumes a booted system expects (@data, @swap,
#      plus the others the installer creates; we keep the full list so any
#      fstab bind-dir checks in shani-deploy find what they expect)
#   3. `zstd -d | btrfs receive` the image -> subvolume "shanios_base"
#   4. snapshot shanios_base -> @blue (ro), then @blue -> @green (ro)
#   5. write /data/current-slot=blue, /data/previous-slot=green
#   6. write /etc/shani-version and /etc/shani-profile INTO @blue and @green
#      (parsed from the image filename, e.g. shanios-20260807-plasma.zst)
#   7. trust-anchor the throwaway test CA (00b-generate-test-ca.sh) into
#      EACH slot, so the real shani-deploy package already inside the image
#      can verify our local mirror over real HTTPS — the ONLY on-disk change
#      this harness makes to the received image; see README.
#
# The image itself is a `btrfs send` stream compressed with zstd, not a raw
# disk image — that's why this is "btrfs receive", not "loop mount".
#
# The source .zst is resolved directly against OUTPUT_DIR (config.sh — this
# repo's own ./cache/output, the same variable build-base-image.sh/release.sh
# write to), which is already laid out exactly like the real remote:
# <profile>/latest.txt or stable.txt -> filename,
# <profile>/<date>/<filename>.zst[.sha256|.asc].
set -euo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../../config/config.sh"

check_dependencies_test

DATA_DIR="${SHANIOS_TEST_DATA:-${SCRIPT_DIR}/../disk}"
MNT="${SHANIOS_TEST_MNT:-/mnt/shanios-toplevel}"

usage() {
    echo "Usage: $0 -p <profile> [-d <date>|latest|stable]" >&2
    echo "       $0 <OUTPUT_DIR>/<profile>/<date>/<file>.zst" >&2
    exit 1
}

IMAGE=""
if [[ "${1:-}" == /* ]]; then
    IMAGE="$1"
else
    PROFILE="" DATE_SEL="latest"
    while getopts "p:d:" opt; do
        case "$opt" in
            p) PROFILE="$OPTARG" ;;
            d) DATE_SEL="$OPTARG" ;;
            *) usage ;;
        esac
    done
    [[ -n "$PROFILE" ]] || usage

    if [[ "$DATE_SEL" == "latest" || "$DATE_SEL" == "stable" ]]; then
        POINTER="${OUTPUT_DIR}/${PROFILE}/${DATE_SEL}.txt"
        [[ -f "$POINTER" ]] || die "No ${DATE_SEL}.txt for profile '${PROFILE}' — build/release it first (./build.sh release -p ${PROFILE} ${DATE_SEL})."
        FILENAME=$(tr -d '[:space:]' < "$POINTER")
        DATE_DIR=$(echo "$FILENAME" | grep -oE '[0-9]{8}' | head -n1)
        [[ -n "$DATE_DIR" ]] || die "Couldn't parse a date out of '${FILENAME}' from ${POINTER}"
        IMAGE="${OUTPUT_DIR}/${PROFILE}/${DATE_DIR}/${FILENAME}"
    else
        # Same "dated folder under OUTPUT_DIR/<profile>" concept resolve_build_date()
        # uses for iso-only resumption — here the caller gave the date explicitly.
        IMAGE=$(find "${OUTPUT_DIR}/${PROFILE}/${DATE_SEL}" -maxdepth 1 -name "*-${PROFILE}.zst" | head -n1)
        [[ -n "$IMAGE" ]] || die "No .zst found under ${OUTPUT_DIR}/${PROFILE}/${DATE_SEL}"
    fi
fi

[[ -f "$IMAGE" ]] || die "Image not found: $IMAGE"

BASENAME=$(basename "$IMAGE")
if [[ "$BASENAME" =~ ^${OS_NAME}-([0-9]+)-([a-zA-Z]+)\.zst$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
    PROFILE="${BASH_REMATCH[2]}"
else
    warn "'$BASENAME' doesn't match ${OS_NAME}-<version>-<profile>.zst — you'll need to set /etc/shani-version and /etc/shani-profile by hand."
    VERSION=""
    PROFILE=""
fi

CA_CRT="${DATA_DIR}/ca/ca.crt"
[[ -f "$CA_CRT" ]] || die "Test CA not found at ${CA_CRT} — run 00b-generate-test-ca.sh first."

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount -o subvolid=5 "/dev/disk/by-label/shani_root" "$MNT"

log "Creating top-level subvolumes"
for subvol in @data @swap @etc @var; do
    if ! btrfs subvolume show "$MNT/$subvol" &>/dev/null; then
        btrfs subvolume create "$MNT/$subvol"
    fi
done
chattr +C "$MNT/@swap" 2>/dev/null || true

mkdir -p "$MNT/@data/overlay/etc/upper" "$MNT/@data/overlay/etc/work" \
         "$MNT/@data/overlay/var/upper" "$MNT/@data/overlay/var/work" \
         "$MNT/@data/downloads"

if btrfs subvolume show "$MNT/shanios_base" &>/dev/null; then
    log "shanios_base already exists from a previous run, deleting it first"
    btrfs subvolume delete "$MNT/shanios_base"
fi

log "Receiving image into shanios_base (this can take a while for multi-GB images)"
zstd -d --long=31 -T0 "$IMAGE" -c | btrfs receive "$MNT"

if ! btrfs subvolume show "$MNT/shanios_base" &>/dev/null; then
    die "Extraction finished but 'shanios_base' subvolume wasn't found — check the image."
fi

log "Snapshotting shanios_base -> @blue -> @green"
[[ -d "$MNT/@blue" ]] && { btrfs property set -f -ts "$MNT/@blue" ro false 2>/dev/null || true; btrfs subvolume delete "$MNT/@blue"; }
[[ -d "$MNT/@green" ]] && { btrfs property set -f -ts "$MNT/@green" ro false 2>/dev/null || true; btrfs subvolume delete "$MNT/@green"; }

btrfs subvolume snapshot -r "$MNT/shanios_base" "$MNT/@blue"
btrfs subvolume snapshot -r "$MNT/@blue" "$MNT/@green"
btrfs subvolume delete "$MNT/shanios_base"

echo "blue" > "$MNT/@data/current-slot"
echo "green" > "$MNT/@data/previous-slot"

for slot in @blue @green; do
    btrfs property set -f -ts "$MNT/$slot" ro false

    if [[ -n "$VERSION" ]]; then
        echo "$VERSION" > "$MNT/$slot/etc/shani-version"
        echo "$PROFILE" > "$MNT/$slot/etc/shani-profile"
        echo "stable" > "$MNT/$slot/etc/shani-channel" 2>/dev/null || true
    fi

    # Trust-anchor the test CA (Arch/p11-kit: drop under trust-source/anchors,
    # then regenerate /etc/ssl/certs/ca-certificates.crt). Skipped gracefully
    # if `trust` isn't present — deploys will then fail at the TLS step,
    # which is correct/expected, not a harness bug.
    if [[ -x "$MNT/$slot/usr/bin/trust" ]]; then
        cp "$CA_CRT" "$MNT/$slot/etc/ca-certificates/trust-source/anchors/shanios-test-ca.crt"
        chroot "$MNT/$slot" trust extract-compat
    else
        warn "'trust' not found in @${slot#@} — local-mirror TLS verification will fail."
    fi

    btrfs property set -f -ts "$MNT/$slot" ro true
done

btrfs filesystem sync "$MNT"

log "Bootstrap complete."
log "  @blue  = v${VERSION:-?} (${PROFILE:-?})  [current-slot]"
log "  @green = v${VERSION:-?} (${PROFILE:-?})  [previous-slot, identical clone for now]"
log "Next: test.sh enter blue"
