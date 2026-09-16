#!/usr/bin/env bash
# generate-manifest.sh – Generate SHA256SUMS and download manifest for build artifacts
#
# Scans cache/output/ for build artifacts and generates:
#   - SHA256SUMS: checksums for all artifacts
#   - manifest.json: structured metadata for download portal
#   - latest.txt: pointer to latest build per profile/branch
#
# Usage:
#   ./generate-manifest.sh [-p profile] [-b branch]
#
# Examples:
#   ./generate-manifest.sh                    # All profiles/channels
#   ./generate-manifest.sh -p gnome           # Specific profile
#   ./generate-manifest.sh -p gnome -b stable # Specific profile and branch

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# Parse options
PROFILE=""
BRANCH=""
while getopts "p:b:" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    b) BRANCH="$OPTARG" ;;
    *) die "Invalid option" ;;
  esac
done

# Determine which profiles to process
if [[ -n "$PROFILE" ]]; then
    PROFILES=("$PROFILE")
else
    PROFILES=(gnome plasma cosmic kiosk server shared)
fi

log "Generating manifests for profiles: ${PROFILES[*]}"

# Generate a manifest for each dated build directory found under each
# profile. There is deliberately no branch level in the directory tree here:
# build-base-image.sh, upload.sh, and build-iso.sh all share a single
# ${OUTPUT_DIR}/${profile}/${date}/ layout — branch is distinguished in the
# artifact filenames instead (e.g. shanios-20260916-stable-gnome.zst), not by
# a separate directory. -b/BRANCH filters which files get checksummed within
# each date directory rather than selecting a (nonexistent) branch directory.
# latest.txt is intentionally NOT written here: build-base-image.sh already
# writes the per-date one, and upload.sh already maintains the central
# profile-level one during publish — duplicating that here risks the two
# falling out of sync.
for prof in "${PROFILES[@]}"; do
    if [[ ! -d "${OUTPUT_DIR}/${prof}" ]]; then
        warn "No output directory for profile ${prof}: ${OUTPUT_DIR}/${prof}"
        continue
    fi

    while IFS= read -r date_dir; do
        date_name="$(basename "$date_dir")"

        if [[ -n "$BRANCH" ]]; then
            shopt -s nullglob
            branch_matches=("${date_dir}"/*"-${BRANCH}-${prof}".*)
            shopt -u nullglob
            if [[ ${#branch_matches[@]} -eq 0 ]]; then
                continue
            fi
        fi

        log "Generating manifest for ${prof}/${date_name}..."

        # Generate SHA256SUMS
        pushd "$date_dir" > /dev/null
        if [[ -n "$BRANCH" ]]; then
            sha256sum *"-${BRANCH}-${prof}".* 2>/dev/null > SHA256SUMS || true
        else
            sha256sum *.zst *.asc *.sha256 2>/dev/null > SHA256SUMS || true
        fi
        popd > /dev/null

        # Generate manifest.json with structured metadata
        manifest_file="${date_dir}/manifest.json"
        cat > "$manifest_file" << MANIFEST_EOF
{
  "profile": "${prof}",
  "date": "${date_name}",
  "generated": "$(date -Iseconds)",
  "artifacts_dir": "${date_dir}",
  "checksums": "SHA256SUMS"
}
MANIFEST_EOF

        log "Manifest generated: ${manifest_file}"
    done < <(find "${OUTPUT_DIR}/${prof}" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | sort -r)
done

log "Manifest generation complete!"