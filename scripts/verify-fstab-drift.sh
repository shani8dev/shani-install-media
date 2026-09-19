#!/usr/bin/env bash
# verify-fstab-drift.sh — Guard against fstab <-> configure.sh drift.
#
# Two independent sources of truth define the same Btrfs subvolume layout:
#   1. image_profiles/shared/overlay/rootfs/etc/fstab        (boot-time mounts)
#   2. os-installer-config/scripts/configure.sh              (install-time mounts)
#
# Both must agree on the SET of subvolumes and on each subvolume's mount
# point + core mount options. They used to be hand-maintained in lock-step
# and silently drifted (a subvolume added to one but not the other boots
# with a dangling mount or an unmounted persistent store). This check makes
# drift a hard failure instead of a footgun.
#
# Usage:
#   ./scripts/verify-fstab-drift.sh            # exit 0 on match, 1 on drift
#
# Exit codes:
#   0  subvolume set + per-subvolume target/options match
#   1  drift detected (details on stderr)
#   2  prerequisite failure (missing files, parse error)
#
# Options note: fstab is allowed to carry extras that configure.sh doesn't
# (defaults, nofail, x-systemd.after/requires ordering). What must match is
# the *core* option set that configure.sh specifies — every configure option
# for a subvolume must be present, with the same value, in that subvolume's
# fstab entry. A configure option missing from fstab, or with a different
# value (e.g. compress=zstd -> nodatacow), is drift.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FSTAB="${REPO_ROOT}/image_profiles/shared/overlay/rootfs/etc/fstab"
CONFIGURE="${REPO_ROOT}/../os-installer-config/scripts/configure.sh"

fail() { echo "verify-fstab-drift: $*" >&2; exit 2; }

for f in "$FSTAB" "$CONFIGURE"; do
  [[ -f "$f" ]] || fail "required file not found: $f"
done

# ---------------------------------------------------------------------------
# Extract the subvolume SET from each source.
#   fstab:      every mount line carrying subvol=@xxx
#   configure: the keys of the declare -A subvols=( [...] ) associative array
# ---------------------------------------------------------------------------
fstab_set="$(grep -oE 'subvol=@[A-Za-z0-9._-]+' "$FSTAB" \
  | sed -E 's/^subvol=@//' | sort -u)"

configure_set="$(sed -n '/declare -A subvols=/,/^[[:space:]]*)/p' "$CONFIGURE" \
  | grep -oE '"@[A-Za-z0-9._-]+"' \
  | tr -d '"@' | sort -u)"

if [[ "$fstab_set" != "$configure_set" ]]; then
  echo "verify-fstab-drift: SUBVOLUME SET MISMATCH" >&2
  echo "  only in fstab:     $(comm -23 <(printf '%s\n' "$fstab_set") <(printf '%s\n' "$configure_set") | tr '\n' ' ')" >&2
  echo "  only in configure: $(comm -13 <(printf '%s\n' "$fstab_set") <(printf '%s\n' "$configure_set") | tr '\n' ' ')" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Per-subvolume: mount point + core options.
#   fstab line:  LABEL=shani_root   /var/cache   btrfs   <opts with subvol=@cache>   0 0
#     -> mount point = field 2, options = field 4
#   configure:   ["@cache"]="/var/cache|rw,noatime,compress=zstd,..."
#     -> target + options split on '|'
# ---------------------------------------------------------------------------
fstab_mp="$(awk '!/^[[:space:]]*#/ && /subvol=@/ {print $2}' "$FSTAB")"
fstab_opts="$(awk '!/^[[:space:]]*#/ && /subvol=@/ {print $4}' "$FSTAB")"

# configure.sh writes the associative array as:  ["@root"]="/root|rw,..."
# (bracket between the key and '='), so the key/value regex must allow for it.
# The value's pipe separators live *inside* the quotes (e.g. /var/cache|rw,...),
# so capture the quoted value as one group rather than trying to match a '|'
# after the closing quote.
configure_vals="$(sed -n '/declare -A subvols=/,/^[[:space:]]*)/p' "$CONFIGURE" \
  | grep -oE '"@[A-Za-z0-9._-]+"\]?="[^"]*"' \
  | sed -E 's/^"(@[A-Za-z0-9._-]+)"\]?="([^"]*)"/\1|\2/')"

# Map subvol -> mount point (fstab) and subvol -> options (fstab).
# paste joins mount point + options with a space; field 1 is the mount point,
# the remainder is the option list (which may itself contain spaces only as
# x-systemd.* tokens separated by commas — no internal spaces).
declare -A f_mp=()
declare -A f_opts=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  sv="$(grep -oE 'subvol=@[A-Za-z0-9._-]+' <<<"$line" | sed -E 's/^subvol=@//')"
  f_mp["$sv"]="${line%% *}"
  f_opts["$sv"]="${line#* }"
done < <(paste -d' ' <(printf '%s\n' "$fstab_mp") <(printf '%s\n' "$fstab_opts"))

declare -A c_tgt=()
declare -A c_opts=()
while IFS='|' read -r sv tgt opts; do
  [[ -z "$sv" ]] && continue
  c_tgt["$sv"]="$tgt"
  c_opts["$sv"]="$opts"
done < <(printf '%s\n' "$configure_vals")

drift=0
for sv in $fstab_set; do
  # fstab_set strips the '@'; configure's associative-array keys keep it.
  ckey="@${sv}"
  # Mount point must match.
  if [[ "${f_mp[$sv]:-}" != "${c_tgt[$ckey]:-}" ]]; then
    echo "verify-fstab-drift: MOUNT POINT MISMATCH for @${sv}" >&2
    echo "  fstab:     ${f_mp[$sv]:-(none)}" >&2
    echo "  configure: ${c_tgt[$ckey]:-(none)}" >&2
    drift=1
  fi
  # Every configure option must be present in fstab with the same value.
  f_opts="${f_opts[$sv]:-}"
  if [[ -z "$f_opts" ]]; then
    echo "verify-fstab-drift: no fstab options for @${sv}" >&2
    drift=1
    continue
  fi
  IFS=',' read -ra tokens <<< "${c_opts[$ckey]:-}"
  for tok in "${tokens[@]}"; do
    [[ -z "$tok" ]] && continue
    if [[ "$tok" == *=* ]]; then
      key="${tok%%=*}"; val="${tok#*=}"
      if ! grep -qE "(^|,)([^,]*${key}=${val})(,|$)" <<< "$f_opts"; then
        echo "verify-fstab-drift: OPTION MISMATCH for @${sv}: '${tok}' not present in fstab" >&2
        echo "  fstab options: ${f_opts}" >&2
        drift=1
      fi
    else
      if ! grep -qE "(^|,${tok})(,|$)" <<< "$f_opts"; then
        echo "verify-fstab-drift: OPTION MISMATCH for @${sv}: flag '${tok}' not present in fstab" >&2
        echo "  fstab options: ${f_opts}" >&2
        drift=1
      fi
    fi
  done
done

if [[ "$drift" -ne 0 ]]; then
  exit 1
fi

echo "verify-fstab-drift: OK — subvolume set, mount points, and core options match"
exit 0
