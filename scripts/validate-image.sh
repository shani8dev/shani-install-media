#!/usr/bin/env bash
# validate-image.sh — Post-build validation gate for a base image artifact.
#
# Runs after build-base-image.sh produces a signed artifact and before any
# release/promote step. Fail-closed: any check that cannot be confirmed is a
# failure, not a warning.
#
# What it checks, per artifact:
#   1. Artifact + sidecar files all exist (.zst, .zst.asc, .zst.sha256,
#      .packages.txt, latest.txt)
#   2. SHA256 sidecar matches the artifact (recompute, compare)
#   3. GPG detached signature verifies against the pinned signing key
#   4. latest.txt names exactly the artifact that is on disk
#   5. Every package declared in the profile's Packages-* files is present in
#      the resolved .packages.txt (what actually shipped)
#   6. Optional: btrfs receive --dump structural check — only when btrfs AND
#      a memory budget are available (the builder container has both; a bare
#      host checkout has neither, so it is skipped with an explicit note
#      rather than a silent skip)
#
# Usage:
#   ./scripts/validate-image.sh -p <profile> [-d <BUILD_DATE>]
#
# Exit codes:
#   0  all checks passed
#   1  one or more checks failed (details on stderr)
#   2  prerequisite failure (bad args, missing config, missing signing key)

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

PROFILE=""
BUILD_DATE=""

usage() {
    echo "Usage: $(basename "$0") -p <profile> [-d <BUILD_DATE>]" >&2
    echo "  -p <profile>     Profile name (e.g. gnome, kiosk)" >&2
    echo "  -d <BUILD_DATE>  8-digit build date; defaults to resolve_build_date()" >&2
    exit 2
}

while getopts "p:d:" opt; do
    case "$opt" in
        p) PROFILE="$OPTARG" ;;
        d) BUILD_DATE="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ -n "$PROFILE" ]] || usage
[[ "$BUILD_DATE" =~ ^[0-9]{8}$ ]] || BUILD_DATE="$(resolve_build_date "$PROFILE")"

RELEASE_DIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
fail() { echo "validate-image[$PROFILE]: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Artifact + sidecars exist
# ---------------------------------------------------------------------------
[[ -d "$RELEASE_DIR" ]] || fail "release dir not found: ${RELEASE_DIR}"
latest="$(cat "${RELEASE_DIR}/latest.txt" 2>/dev/null || true)"
[[ -n "$latest" ]] || fail "latest.txt missing or empty in ${RELEASE_DIR}"
IMAGE="${RELEASE_DIR}/${latest}"
# .packages.txt is named after the image *without* its .zst extension
# (build-base-image.sh: <OS_NAME>-<DATE>-<PROFILE>.packages.txt — no branch
# segment; the channel is tracked by latest.txt/<channel>.txt instead).
# Optional layer sidecars (flatpakfs/snapfs .packages.txt) are not required
# here, since not every profile builds those layers.
PACKAGES_TXT="${IMAGE%.zst}.packages.txt"
for sidecar in "${IMAGE}" "${IMAGE}.asc" "${IMAGE}.sha256" \
                "${PACKAGES_TXT}" "${RELEASE_DIR}/latest.txt"; do
    [[ -f "$sidecar" ]] || fail "required artifact missing: ${sidecar}"
done
echo "validate-image[$PROFILE]: artifact + sidecars present (${latest})"

# ---------------------------------------------------------------------------
# 2. SHA256 sidecar matches
# ---------------------------------------------------------------------------
expected="$(awk '{print $1}' "${IMAGE}.sha256" | head -1 | tr -d '[:space:]')"
actual="$(sha256sum "$IMAGE" | awk '{print $1}')"
[[ -n "$expected" && -n "$actual" ]] || fail "could not read checksums"
[[ "$expected" == "$actual" ]] || fail "SHA256 mismatch: sidecar=${expected} actual=${actual}"
echo "validate-image[$PROFILE]: SHA256 verified (${actual:0:16}…)"

# ---------------------------------------------------------------------------
# 3. GPG detached signature verifies against the pinned signing key
# ---------------------------------------------------------------------------
PUBLIC_KEY="${GPG_DIR}/gpg-public.asc"
[[ -f "$PUBLIC_KEY" ]] || fail "signing public key not found: ${PUBLIC_KEY} (keys/gpg not provisioned?)"

# /run is root-only; fall back to $TMPDIR so the gate works for non-root
# callers (e.g. a developer running it by hand against a cached artifact).
gnupghome="$(mktemp -d "${TMPDIR:-/tmp}/shanios-validate.XXXXXX")" \
    || fail "could not create temp gnupghome"
trap 'rm -rf "$gnupghome"' EXIT
gpg --homedir "$gnupghome" --batch --import "$PUBLIC_KEY" >/dev/null 2>&1 \
    || fail "could not import signing public key"
echo "${GPG_KEY_ID}:6:" | gpg --homedir "$gnupghome" --batch --import-ownertrust >/dev/null 2>&1 || true

if ! gpg --homedir "$gnupghome" --batch --verify "${IMAGE}.asc" "$IMAGE" >/dev/null 2>&1; then
    # Re-run for diagnostics. `|| true` is required: under set -Eeuo pipefail a
    # bare failing pipe aborts with gpg's own exit code (2) before fail() runs,
    # which would report the wrong exit code to callers.
    gpg --homedir "$gnupghome" --batch --verify "${IMAGE}.asc" "$IMAGE" 2>&1 | tail -5 >&2 || true
    fail "GPG signature verification FAILED for ${IMAGE}"
fi
echo "validate-image[$PROFILE]: GPG signature verified (${GPG_KEY_ID:0:12}…)"

# ---------------------------------------------------------------------------
# 4. latest.txt names exactly the artifact on disk
# ---------------------------------------------------------------------------
on_disk="$(basename "$IMAGE")"
[[ "$latest" == "$on_disk" ]] || fail "latest.txt (${latest}) does not name the on-disk artifact (${on_disk})"
echo "validate-image[$PROFILE]: latest.txt points at on-disk artifact"

# ---------------------------------------------------------------------------
# 5. Every declared package is present in the resolved set
# ---------------------------------------------------------------------------
declare -a declared=()
for f in "${IMAGE_PROFILES_DIR}/${PROFILE}/Packages-Base" \
         "${IMAGE_PROFILES_DIR}/${PROFILE}/Packages-Desktop" \
         "${IMAGE_PROFILES_DIR}/${PROFILE}/Packages-Extras"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        [[ "$pkg" == \#* ]] && continue
        declared+=("$pkg")
    done < <(tr -d '\r' < "$f" | grep -v '^[[:space:]]*$')
done

missing=()
for pkg in "${declared[@]}"; do
    grep -qxF "$pkg" "${PACKAGES_TXT}" || missing+=("$pkg")
done
[[ ${#missing[@]} -eq 0 ]] || fail "declared packages missing from resolved set: ${missing[*]}"
echo "validate-image[$PROFILE]: all ${#declared[@]} declared packages present in resolved set"

# ---------------------------------------------------------------------------
# 6. Optional btrfs structural check (builder container only)
# ---------------------------------------------------------------------------
if command -v btrfs >/dev/null 2>&1 && command -v zstd >/dev/null 2>&1; then
    mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ "$mem_kb" -ge 1900000 ]]; then
        if zstd -dc --long=31 -T0 "$IMAGE" 2>/dev/null | btrfs receive --dump >/dev/null 2>&1; then
            echo "validate-image[$PROFILE]: btrfs stream structure check OK"
        else
            fail "btrfs receive --dump failed — stream is not a valid btrfs send stream"
        fi
    else
        echo "validate-image[$PROFILE]: btrfs structural check skipped (host has ${mem_kb} kB RAM; needs ~2 GB for --long=31 decode — run inside the builder container)"
    fi
else
    echo "validate-image[$PROFILE]: btrfs structural check skipped (btrfs/zstd not on PATH — run inside the builder container)"
fi

echo "validate-image[$PROFILE]: ALL CHECKS PASSED"
exit 0
