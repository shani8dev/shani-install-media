#!/usr/bin/env bash
# seed-models.sh — bake the preinstalled models into the image under build.
#
# These models are too large for the package repo's 100 MB file limit to
# carry as packages, but the image build has no such limit — so they are
# fetched here, verified against the same pins shani-chronoa verifies
# against, and placed where Chronoa's packaged-model lookup finds them on
# first boot. (Kokoro's runtime is a package, shani-sherpa-onnx; its model
# is seeded here alongside the others.)
#   /usr/share/shani-chronoa/vision/  SmolVLM2-500M (the "eyes")
#   /usr/share/kokoro/                Kokoro-82M v1.0 int8 (the neural voice)
#   /usr/share/shani-chronoa/llm/     Qwen3-0.6B (the default brain)
# Without them the setup wizard downloads ~1.3 GB on first use, on
# whichever network the user has; with them, speech, vision and thinking
# all work offline from first boot (the wizard still offers bigger tiers).
#
# Usage:
#   seed-models.sh <dest>   seed into <dest>/usr/share/shani-chronoa/
#   seed-models.sh --pins   print the pins (URL + sha256) for the cache key
#
# Fail-closed: any download or digest mismatch aborts the image build.
# Resumable: verified files are reused from cache/seeded-models, so an
# interrupted build does not re-fetch ~1.3 GB.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_CACHE="${SCRIPT_DIR}/../cache/seeded-models"
mkdir -p "${SEED_CACHE}"

# Pins: each file's Hugging Face LFS size and sha256 at the revision named,
# read from the HF API. KEEP IN STEP with shani-chronoa: vision lives in
# local_vision.TIERS (smolvlm2-500m), the brain in local_llm.TIERS
# (qwen3-0.6b), Kokoro in voices._KOKORO_MODEL. If they disagree, the image
# seeds bytes Chronoa refuses.
_VISION_MODEL_URL="https://huggingface.co/ggml-org/SmolVLM2-500M-Video-Instruct-GGUF/resolve/ccd7aae53bcb1997355c2f094959e72b3642ce17/SmolVLM2-500M-Video-Instruct-Q8_0.gguf"
_VISION_MODEL_SHA="6f67b8036b2469fcd71728702720c6b51aebd759b78137a8120733b4d66438bc"
_VISION_PROJ_URL="https://huggingface.co/ggml-org/SmolVLM2-500M-Video-Instruct-GGUF/resolve/ccd7aae53bcb1997355c2f094959e72b3642ce17/mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf"
_VISION_PROJ_SHA="921dc7e259f308e5b027111fa185efcbf33db13f6e35749ddf7f5cdb60ef520b"
_BRAIN_URL="https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/23749fefcc72300e3a2ad315e1317431b06b590a/Qwen3-0.6B-Q8_0.gguf"
_BRAIN_SHA="9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031"
_KOKO_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2"
_KOKO_SHA="72c347230107ef8a31098ec4d468a605244beef5f1ed00db97efa13518800653"

if [[ "${1:-}" == "--pins" ]]; then
    printf '%s %s\n%s %s\n%s %s\n' \
        "${_VISION_MODEL_URL}" "${_VISION_MODEL_SHA}" \
        "${_VISION_PROJ_URL}" "${_VISION_PROJ_SHA}" \
        "${_BRAIN_URL}" "${_BRAIN_SHA}" \
        "${_KOKO_URL}" "${_KOKO_SHA}"
    exit 0
fi

# The name the shani-chronoa code checks (local_vision/local_llm paths).
DEST="${1:?usage: seed-models.sh <dest> | --pins}"

_fetch() {  # _fetch <url> <sha256> <filename> <subdir>
    local url="$1" sha="$2" name="$3" subdir="$4"
    local cached="${SEED_CACHE}/${name}"
    local target="${DEST}/usr/share/shani-chronoa/${subdir}"
    mkdir -p "${target}"
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
    install -m 644 "${cached}" "${target}/${name}"
}

_fetch "${_VISION_MODEL_URL}" "${_VISION_MODEL_SHA}" "SmolVLM2-500M-Video-Instruct-Q8_0.gguf" "vision"
_fetch "${_VISION_PROJ_URL}" "${_VISION_PROJ_SHA}" "mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf" "vision"
_fetch "${_BRAIN_URL}" "${_BRAIN_SHA}" "Qwen3-0.6B-Q8_0.gguf" "llm"

# Kokoro: the archive unpacks into its model directory, which is where
# voices.kokoro_files() looks for it on a system (packaged) install.
KOKO_CACHE="${SEED_CACHE}/kokoro-int8-multi-lang-v1_0.tar.bz2"
if [[ -f "${KOKO_CACHE}" ]] && [[ "$(sha256sum "${KOKO_CACHE}" | awk '{print $1}')" == "${_KOKO_SHA}" ]]; then
    echo "seed: kokoro archive already cached and verified"
else
    echo "seed: downloading kokoro archive ..."
    aria2c --allow-overwrite=true -x4 -s4 -o "${KOKO_CACHE}" "${_KOKO_URL}"
    got="$(sha256sum "${KOKO_CACHE}" | awk '{print $1}')"
    [[ "${got}" == "${_KOKO_SHA}" ]] || { echo "ERROR: sha256 mismatch for kokoro archive: got ${got}, want ${_KOKO_SHA}" >&2; exit 1; }
    echo "seed: kokoro archive verified"
fi
KOKO_TARGET="${DEST}/usr/share/kokoro"
mkdir -p "${KOKO_TARGET}"
INSTALL_TMP="$(mktemp -d)"
tar -xjf "${KOKO_CACHE}" -C "${INSTALL_TMP}"
install -dm755 "${KOKO_TARGET}/kokoro-int8-multi-lang-v1_0"
cp -r "${INSTALL_TMP}/kokoro-int8-multi-lang-v1_0/." "${KOKO_TARGET}/kokoro-int8-multi-lang-v1_0/"
rm -rf "${INSTALL_TMP}"
echo "seed: models baked into ${DEST}/usr/share/shani-chronoa (kokoro under /usr/share/kokoro)"
