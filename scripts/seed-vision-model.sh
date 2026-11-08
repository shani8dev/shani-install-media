#!/usr/bin/env bash
# seed-vision-model.sh — bake the vision model into the image under build.
#
# The smallest "eyes" tier (SmolVLM2-500M, ~545 MB) is too big for the
# shani-repo git limit (100 MB/file) to carry as a package, but the image
# build has no such limit — so it is fetched here, verified against the
# same pins shani-chronoa verifies against (local_vision.TIERS), and placed
# where Chronoa's packaged-model lookup finds it on first boot
# (/usr/share/shani-chronoa/vision). Without this the setup wizard's Eyes
# page downloads 545 MB on first use, on whichever network the user has.
#
# Usage:
#   seed-vision-model.sh <dest>   seed into <dest>/usr/share/shani-chronoa/vision
#   seed-vision-model.sh --pins   print the pins (URL + sha256) for the cache key
#
# Fail-closed: any download or digest mismatch aborts the image build.
# Resumable: verified files are reused from cache/seeded-models, so an
# interrupted build does not re-fetch 545 MB.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_CACHE="${SCRIPT_DIR}/../cache/seeded-models"
mkdir -p "${SEED_CACHE}"

# Pins: each file's Hugging Face LFS size and sha256 at the revision named,
# read from the HF API. KEEP IN STEP with shani-chronoa local_vision.TIERS
# (smolvlm2-500m): if they disagree, the image seeds bytes Chronoa refuses.
_MODEL_URL="https://huggingface.co/ggml-org/SmolVLM2-500M-Video-Instruct-GGUF/resolve/ccd7aae53bcb1997355c2f094959e72b3642ce17/SmolVLM2-500M-Video-Instruct-Q8_0.gguf"
_MODEL_SHA="6f67b8036b2469fcd71728702720c6b51aebd759b78137a8120733b4d66438bc"  # placeholder
_PROJ_URL="https://huggingface.co/ggml-org/SmolVLM2-500M-Video-Instruct-GGUF/resolve/ccd7aae53bcb1997355c2f094959e72b3642ce17/mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf"
_PROJ_SHA="921dc7e259f308e5b027111fa185efcbf33db13f6e35749ddf7f5cdb60ef520b"

if [[ "${1:-}" == "--pins" ]]; then
    printf '%s %s\n%s %s\n' "${_MODEL_URL}" "${_MODEL_SHA}" "${_PROJ_URL}" "${_PROJ_SHA}"
    exit 0
fi

DEST="${1:?usage: seed-vision-model.sh <dest> | --pins}"
TARGET="${DEST}/usr/share/shani-chronoa/vision"
mkdir -p "${TARGET}"

_fetch() {  # _fetch <url> <sha256> <filename>
    local url="$1" sha="$2" name="$3"
    local cached="${SEED_CACHE}/${name}"
    if [[ -f "${cached}" ]] && [[ "$(sha256sum "${cached}" | awk '{print $1}')" == "${sha}" ]]; then
        echo "seed: ${name} already cached and verified"
    else
        echo "seed: downloading ${name} ..."
        if command -v aria2c >/dev/null; then
            aria2c --allow-overwrite=true -x4 -s4 -o "${cached}" "${url}"
        elif command -v curl >/dev/null; then
            curl --fail --location --progress-bar -o "${cached}" "${url}"
        else
            wget -O "${cached}" "${url}"
        fi || { echo "ERROR: download failed for ${name}" >&2; exit 1; }
        local got
        got="$(sha256sum "${cached}" | awk '{print $1}')"
        [[ "${got}" == "${sha}" ]] || { echo "ERROR: sha256 mismatch for ${name}: got ${got}, want ${sha}" >&2; exit 1; }
        echo "seed: ${name} verified"
    fi
    install -m 644 "${cached}" "${TARGET}/${name}"
}

if [[ ! -f "${TARGET}/SmolVLM2-500M-Video-Instruct-Q8_0.gguf" || ! -f "${TARGET}/mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf" ]]; then
    _fetch "${_MODEL_URL}" "${_MODEL_SHA}" "SmolVLM2-500M-Video-Instruct-Q8_0.gguf"
    _fetch "${_PROJ_URL}" "${_PROJ_SHA}" "mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf"
else
    echo "seed: vision model already in image"
fi
echo "seed: vision model baked into ${TARGET}"
