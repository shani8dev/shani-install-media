#!/usr/bin/env bash
# check-iso-layers.sh — assert the built ISO actually embeds the layers its
# release directory contains, and that no layer the profile DEFINES is missing.
#
# WHY THIS EXISTS (two real failures, both 2026-10-06, both would pass this):
#   1. build-snap-image.sh looked up the snap list at a path no profile uses,
#      printed "No Snap package list ... Exiting...", exited 0, and produced NO
#      snapfs.zst. `build.sh iso` then logged INFO "No snapfs.zst ... 
#      skipping." — a whole ISO shipped with no snap layer, CI green, because
#      every stage tolerates a missing OPTIONAL layer, including the logs.
#   2. plasma's flatpak layer could not be built at all (over a 15 GiB
#      budget), so its ISO carried only rootfs.zst while gnome's carried all
#      three. Nothing flagged the asymmetry.
#
# Invariant: a layer present in the release dir must appear inside the ISO at
# the location install.sh reads from —
#   os-installer-config: /run/archiso/bootmnt/<OS>/x86_64/<layer>zst
# build-iso.sh link_or_copy()s the layers alongside the airootfs squashfs, so
# the ISO must contain /<OS>/x86_64/{rootfs.zst,flatpakfs.zst,snapfs.zst}
# whenever the corresponding files exist in the release dir.
#
# Inverse check, which would have caught #1 and #2: a profile that DEFINES a
# layer (a flatpak-packages.txt / the shared snap list) but whose ISO carries
# no such layer is a FAIL — the build silently produced none.
#
# Usage:
#   ./scripts/check-iso-layers.sh -p <profile> [-d <BUILD_DATE>]
#
# Exit codes:
#   0  all checks passed
#   1  one or more checks failed
#   2  prerequisite failure

set -Eeuo pipefail

tmpdir="$(mktemp -d /tmp/check-iso-layers.XXXXXX)"
bgn() {
    # Best-effort unmount before cleanup so the mount is never left dangling.
    umount "${tmpdir}/iso" 2>/dev/null || true
    rm -rf "$tmpdir"
}
trap bgn EXIT

usage() { echo "Usage: $0 -p <profile> [-d <BUILD_DATE>]" >&2; }
fail() { echo "check-iso-layers[${PROFILE}]: $*" >&2; exit 1; }

PROFILE=""
BUILD_DATE=""
while getopts "p:d:" opt; do
    case "$opt" in
        p) PROFILE="$OPTARG" ;;
        d) BUILD_DATE="$OPTARG" ;;
        *) usage; exit 2 ;;
    esac
done
[[ -n "$PROFILE" ]] || { usage; exit 2; }

source "$(dirname "$(realpath "$0")")/../config/config.sh"

[[ -n "${BUILD_DATE}" ]] || BUILD_DATE="$(date +%Y%m%d)"
RELEASE_DIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
[[ -d "$RELEASE_DIR" ]] || fail "release dir not found: ${RELEASE_DIR}"

# The ISO build-iso.sh made. signed_*.iso (repack's output) keeps the same
# payload layout because the layers were embedded by build-iso.sh already.
shopt -s nullglob
candidates=("${RELEASE_DIR}"/signed_*.iso "${RELEASE_DIR}"/shanios-*.iso)
shopt -u nullglob
ISO=""
for c in "${candidates[@]}"; do if [[ -f "$c" ]]; then ISO="$c"; break; fi; done
[[ -f "$ISO" ]] || fail "no ISO found in ${RELEASE_DIR} (looked for signed_*.iso then shanios-*.iso)"

echo "check-iso-layers[${PROFILE}]: ISO ${ISO##*/}"

ISO_MNT="${tmpdir}/iso"
mkdir -p "$ISO_MNT"
if ! mount -o loop,ro "$ISO" "$ISO_MNT" 2>/dev/null; then
    fail "could not loop-mount the ISO (needs the privileged builder container)"
fi

payload_rel=""
for cand in "${ISO_MNT}"/*/x86_64; do
    if [[ -d "$cand" ]]; then
        payload_rel="$(basename "$(dirname "$cand")")/x86_64"
        break
    fi
done
[[ -n "$payload_rel" ]] || fail "no /<OS>/x86_64 payload dir on the ISO"

declare -A iso_size=()
shopt -s nullglob
for f in "${ISO_MNT}/${payload_rel}"/*; do
    [[ -f "$f" ]] || continue
    iso_size["$(basename "$f")"]="$(stat -c '%s' "$f")"
done
shopt -u nullglob
[[ ${#iso_size[@]} -gt 0 ]] || fail "no *.zst payloads under /${payload_rel} on the ISO"

echo "check-iso-layers[${PROFILE}]: payloads under /${payload_rel}:"
for name in $(printf '%s\n' "${!iso_size[@]}" | sort); do
    printf '  %12d  %s\n' "${iso_size[$name]}" "$name"
done

# ---- check 1: every *.zst in the release dir is embedded in the ISO at the
#      same size (build-iso.sh copies it verbatim) ----
have_base=0
have_flatpak=0
have_snap=0
for f in "${RELEASE_DIR}"/*.zst; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    # Map the release-dir name to the name install.sh actually encounters on the
    # ISO: build-iso.sh copies the base image in as rootfs.zst, and carries
    # flatpakfs.zst/snapfs.zst through under their own names.
    if [[ "$name" == shanios-*-*.zst ]]; then
        iso_name="rootfs.zst"
    else
        iso_name="$name"
    fi
    if [[ -z "${iso_size[$iso_name]:-}" ]]; then
        echo "check-iso-layers[${PROFILE}]: FAIL ${name} is in the release dir but '${iso_name}' is NOT on the ISO" >&2
        exit 1
    fi
    src_size="$(stat -c '%s' "$f")"
    src_size="$(stat -c '%s' "$f")"
    if [[ "$src_size" != "${iso_size[$iso_name]}" ]]; then
        echo "check-iso-layers[${PROFILE}]: FAIL ${name} size differs (release dir ${src_size} B vs ISO ${iso_size[$iso_name]} B)" >&2
        exit 1
    fi
    case "$name" in
        *flatpakfs*) have_flatpak=1 ;;
        *snapfs*)    have_snap=1 ;;
        *)           have_base=1 ;;
    esac
done
[[ $have_base -eq 1 ]] || fail "base image (shanios-*.zst) is missing from the ISO"

# ---- check 2: a profile that DEFINES a layer must have produced it ----
have_flatpak_list=0
for cand in \
    "${IMAGE_PROFILES_DIR}/${PROFILE}/flatpak-packages.txt" \
    "${IMAGE_PROFILES_DIR}/shared/flatpak-packages.txt"; do
    [[ -f "$cand" ]] && have_flatpak_list=1
done
have_snap_list=0
for cand in \
    "${IMAGE_PROFILES_DIR}/${PROFILE}/snap-packages.txt" \
    "${IMAGE_PROFILES_DIR}/shared/snap-packages.txt"; do
    [[ -f "$cand" ]] && have_snap_list=1
done

if [[ $have_flatpak_list -eq 1 && $have_flatpak -eq 0 ]]; then
    fail "profile '${PROFILE}' defines a Flatpak package list, but the ISO embeds no flatpakfs layer"
fi
if [[ $have_snap_list -eq 1 && $have_snap -eq 0 ]]; then
    fail "profile '${PROFILE}' defines a Snap package list, but the ISO embeds no snapfs layer"
fi

echo "check-iso-layers[${PROFILE}]: PASS — base + ${have_flatpak} flatpakfs + ${have_snap} snapfs, each matching the release-dir bytes"