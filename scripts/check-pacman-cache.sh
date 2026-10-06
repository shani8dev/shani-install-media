#!/usr/bin/env bash
# check-pacman-cache.sh — verify the cached packages a profile's build will
# actually install, against what the repos publish, BEFORE pacstrap spends
# 40 minutes finding out.
#
# WHY THIS EXISTS (found live 2026-10-06, cost one full plasma image build):
# two packages in the shared pacman cache were silently truncated —
#   plasma6-applets-window-title-0.9.0-2-any
#   plasma-setup-git-0.1.0-2-x86_64
# and pacstrap aborted at the very end with:
#   error: failed to commit transaction (invalid or corrupted package)
#
# The important part is what did NOT catch them:
#
#   zstd -t  <file>    -> PASSES  (the zstd frame is well-formed)
#   tar -tf <file>     -> PASSES  (the stream lists cleanly)
#
# The truncation happened INSIDE the zstd frame — a valid frame whose payload
# is short. Every "does it decompress" check reports these files as fine,
# which is exactly the check one reaches for first. Only comparing the bytes
# against the repo's own %SHA256SUM% catches it, and pacman only gets there
# after downloading and unpacking everything, by which point the build is
# sunk.
#
# Expected hashes come straight out of the sync databases' %SHA256SUM%
# fields, not `pacman -Si` — pacman 7 does not print a checksum field at all
# (`-Si` shows "Validated By : SHA-256 Sum  Signature" and no hash), so a
# checker built on it silently compares nothing and reports success forever.
# That is the same failure shape as a check that cannot fail.
#
# Only the version the repos currently publish is checked — the exact file
# pacstrap would install. Stale cached copies of older versions are reported
# as a count, not as corruption: they are legitimately absent from the db and
# are not what the build consumes.
#
# Reads only. Never deletes unless --prune: the cache is shared between
# shani-install-media and shani-pkgbuilds, so removing files is the caller's
# decision.
#
# Usage:
#   check-pacman-cache.sh -p <profile> [--prune] [--quiet]
#
# Exit: 0 = every cached package that would be installed matches its repo hash
#       1 = at least one is corrupt (the build WILL fail later)
#       2 = usage / setup error

set -uo pipefail

PROFILE=""
PRUNE=false
QUIET=false
CACHE_DIR="${PACMAN_CACHE_DIR:-/var/cache/pacman/pkg}"
SYNC_DIR="${PACMAN_SYNC_DIR:-/var/lib/pacman/sync}"

usage() {
    cat <<'EOF'
Usage: check-pacman-cache.sh -p <profile> [--prune] [--quiet]

  -p, --profile   image profile whose package list to check (required)
      --prune     delete corrupt files instead of only reporting them
      --quiet     only print problems and the final verdict
  -h, --help      this message

Environment:
  PACMAN_CACHE_DIR   cache to inspect      (default /var/cache/pacman/pkg)
  PACMAN_SYNC_DIR    sync databases        (default /var/lib/pacman/sync)
  IMAGE_PROFILES_DIR profile tree          (default ../image_profiles)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--profile) PROFILE="${2:-}"; shift 2 ;;
        --prune)      PRUNE=true; shift ;;
        --quiet)      QUIET=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

say() { $QUIET || echo "$@"; }
# Corruption detail is ALWAYS printed (to stderr), including under --quiet:
# naming the bad files is the entire point of this script, and suppressing it
# would leave a failing run with nothing actionable. --quiet governs the
# progress/chatter, never the diagnosis.

[[ -n "$PROFILE" ]] || { echo "Error: --profile is required." >&2; usage >&2; exit 2; }
command -v pacman    >/dev/null 2>&1 || { echo "Error: pacman not available." >&2; exit 2; }
command -v bsdtar    >/dev/null 2>&1 || { echo "Error: bsdtar not available (needed to read sync dbs)." >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "Error: sha256sum not available." >&2; exit 2; }
[[ -d "$CACHE_DIR" ]] || { echo "Error: cache dir not found: $CACHE_DIR" >&2; exit 2; }

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
LIST_DIR="${IMAGE_PROFILES_DIR:-${SCRIPT_DIR}/../image_profiles}/${PROFILE}"
[[ -f "${LIST_DIR}/Packages-Base" ]] || {
    echo "Error: package lists not found for profile '${PROFILE}' at ${LIST_DIR}" >&2
    exit 2
}

# The profile's real install set, filtered exactly the way build-base-image.sh
# filters it (comments and blanks dropped, all three lists).
mapfile -t PACKAGES < <(
    cat "${LIST_DIR}/Packages-Base" "${LIST_DIR}/Packages-Desktop" "${LIST_DIR}/Packages-Extras" 2>/dev/null \
    | grep -v '^\s*#' | tr -d '\r' | grep -v '^\s*$' | sort -u
)
if [[ ${#PACKAGES[@]} -eq 0 ]]; then
    say "Package list for '${PROFILE}' is empty — nothing to check."
    exit 0
fi

say "Checking cached packages for profile '${PROFILE}' (${#PACKAGES[@]} requested)..."
say "  cache: ${CACHE_DIR}"
say "  sync dbs: ${SYNC_DIR}"

# Refresh the sync databases first, and say so when it fails.
#
# This is not optional politeness: without a current db the comparison below can
# validate a cached file against a DIFFERENT version's %SHA256SUM% and report a
# clean cache that is not clean. Observed live 2026-10-06 — the builder image's db
# snapshot predated shani-core-1.2-18, so the checker reported "1 requested
# package is in NO configured repo" for a package that is in fact published and
# installed. A stale db therefore produces both false alarms (here) and, in the
# mirrored case, a false all-clear.
#
# pacstrap syncs the same dbs moments later, so this costs nothing extra.
if ! pacman -Sy --noconfirm >/dev/null 2>&1; then
    say "WARNING: 'pacman -Sy' failed — the sync databases may be stale, so a" >&2
    say "  PASS below is weaker than it looks (a cached file could be validated" >&2
    say "  against another version's hash). Treat a clean result as unproven." >&2
else
    say "  sync databases refreshed"
fi

# Index every sync db into WANT_VER / WANT_SHA (name -> version, name -> sha256).
#
# Performance, learned the hard way: the first version ran one
# `bsdtar -xOf <db> <entry>` per package (~1500 process spawns per profile) and
# ran past 15 minutes — long enough to be killed mid-check, which is exactly the
# cost this script exists to avoid. Extracting each db ONCE to a temp dir and
# reading desc files off disk takes seconds.
#
# A single concatenated `bsdtar -xOf db --include='*/desc'` stream is NOT a valid
# shortcut: consecutive desc files have no delimiter, so records cannot be split
# reliably. Hence extract-then-read.
declare -A WANT_VER=() WANT_SHA=()
IDX="$(mktemp -d /tmp/shani-pacdb-index.XXXXXX)"
trap 'rm -rf "$IDX"' EXIT

for db in "${SYNC_DIR}"/*.db; do
    [[ -e "$db" ]] || continue
    dbdir="${IDX}/$(basename "$db")"
    mkdir -p "$dbdir"
    if ! bsdtar -xf "$db" -C "$dbdir" 2>/dev/null; then
        say "WARNING: could not read sync db ${db}" >&2
        rm -rf "$dbdir"
        continue
    fi
    # One awk pass over every desc in this db. desc files are flat KEY/VALUE
    # pairs, so "the line after the key" is the value — read with getline.
    while IFS=$'\t' read -r n v s; do
        [[ -n "$n" && -n "$v" && -n "$s" ]] || continue
        WANT_VER["$n"]="$v"; WANT_SHA["$n"]="$s"
    done < <(
        find "$dbdir" -type f -name desc -print0 2>/dev/null \
        | xargs -0 -r awk '
            function emit() { if (n != "" && v != "" && s != "") print n "\t" v "\t" s; n=""; v=""; s="" }
            FNR==1 { if (NR != 1) emit(); want="" }
            /^%NAME%$/      { getline n; want="n"; next }
            /^%VERSION%$/   { getline v; want="v"; next }
            /^%SHA256SUM%$/ { getline s; want="s"; next }
            want != ""      { if (want=="n" && n=="") n=$0;
                              else if (want=="v" && v=="") v=$0;
                              else if (want=="s" && s=="") s=$0;
                              want=""; next }
            END { emit() }
        ' 2>/dev/null
    )
    rm -rf "$dbdir"
done

if [[ ${#WANT_SHA[@]} -eq 0 ]]; then
    say "No sync database entries could be read from ${SYNC_DIR}."
    say "  Run 'pacman -Sy' first, or this check cannot verify anything and"
    say "  will NOT claim the cache is fine."
    exit 2
fi
say "  indexed ${#WANT_SHA[@]} package(s) from the sync databases"

checked=0; notcached=0; unknown=0; stale=0
declare -a CORRUPT=()

for pkg in "${PACKAGES[@]}"; do
    if [[ -z "${WANT_SHA[$pkg]:-}" ]]; then
        # Requested but in no configured repo — pacstrap would fail on this
        # regardless of any cache. Counted separately so it is never confused
        # with a corrupt file.
        unknown=$((unknown + 1))
        continue
    fi
    ver="${WANT_VER[$pkg]}"
    # Locate the cached file for exactly this version, across the arches a
    # package may legitimately have been built for.
    shopt -s nullglob
    matches=("${CACHE_DIR}/${pkg}-${ver}-"*.pkg.tar.zst)
    shopt -u nullglob
    if [[ ${#matches[@]} -eq 0 ]]; then
        notcached=$((notcached + 1))
        continue
    fi
    # Older copies of the same package are not what the build installs.
    shopt -s nullglob
    for old in "${CACHE_DIR}/${pkg}-"*.pkg.tar.zst; do
        [[ -e "$old" ]] || continue
        case "$(basename "$old")" in "${pkg}-${ver}-"*) ;; *) stale=$((stale + 1)) ;; esac
    done
    shopt -u nullglob

    want="${WANT_SHA[$pkg]}"
    for f in "${matches[@]}"; do
        got="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
        [[ -n "$got" ]] || continue
        checked=$((checked + 1))
        if [[ "$got" != "$want" ]]; then
            CORRUPT+=("$f")
            {
                echo "  CORRUPT: $(basename "$f")"
                echo "           repo says ${want}"
                echo "           file is  ${got}"
                # Say out loud WHY the obvious check misses it, so nobody
                # "verifies" this file with zstd -t and concludes it is fine.
                if command -v zstd >/dev/null 2>&1 && zstd -t "$f" >/dev/null 2>&1; then
                    echo "           note: zstd -t PASSES on this file. The zstd frame"
                    echo "                 is valid but its payload is wrong, so a"
                    echo "                 decompress-check cannot see this class of"
                    echo "                 corruption — only the hash comparison can."
                fi
            } >&2
        fi
    done
done

say ""
say "  compared ${checked}, not cached ${notcached}, no repo entry ${unknown}, stale copies ${stale}"

# From here on the VERDICT is never suppressed. --quiet governs progress
# chatter only: it was originally applied to the verdict too, so a --quiet run
# printed absolutely nothing and the caller could not tell "verified clean"
# from "never ran". Found live when wiring this into build-base-image.sh, whose
# own output showed only the "Verifying cached packages..." line and no result.
if [[ $unknown -gt 0 ]]; then
    {
        echo "WARNING: ${unknown} requested package(s) are in NO configured repo."
        echo "  pacstrap will fail with 'target not found' regardless of the cache."
    } >&2
fi

if [[ $checked -eq 0 ]]; then
    echo "NOTHING TO VERIFY: none of this profile's packages are both cached and in a repo."
    echo "  (the build will download them, so there is no cache to be corrupt)"
    exit 0
fi

if [[ ${#CORRUPT[@]} -eq 0 ]]; then
    echo "OK: all ${checked} cached package(s) that would be installed match their repo SHA256."
    exit 0
fi

{
    echo ""
    echo "FAIL: ${#CORRUPT[@]} of ${checked} cached package(s) do NOT match the repo."
    for f in "${CORRUPT[@]}"; do echo "  ${f}"; done
    echo ""
} >&2

if [[ "$PRUNE" == true ]]; then
    for f in "${CORRUPT[@]}"; do
        if rm -f "$f"; then
            echo "removed ${f}" >&2
        else
            echo "WARNING: could not remove ${f} (root-owned? re-run inside the builder container)" >&2
        fi
    done
    echo "Corrupt entries removed — pacman will re-download them." >&2
    [[ $unknown -eq 0 ]] && exit 0 || exit 1
fi

echo "These WILL fail the build at pacstrap with 'invalid or corrupted package'." >&2
echo "Re-run with --prune inside the builder container to delete them, or delete" >&2
echo "them by hand, then rebuild." >&2
exit 1