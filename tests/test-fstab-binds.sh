#!/usr/bin/env bash
# test-fstab-binds.sh - /etc/fstab is the ONE list of /var state ShaniOS keeps.
#
# /var is a tmpfs (systemd.volatile=state); a folder under it keeps nothing
# across a boot unless an fstab line mounts it (a /data bind or a subvolume).
# Everything else is derived from those lines: the /data source folders are
# made by tmpfiles lines generated from fstab at image build
# (build-base-image.sh -> shanios-data-binds.conf), by the installer from the
# installed image's fstab (create_bind_sources) and by shani-deploy at every
# update (parse_fstab_bind_dirs). Before 2026-11-19 the installer and tmpfiles
# had hand-kept copies that drifted from fstab in both directions.
#
# Checks: every fstab line has six fields (a line whose fields ran together is
# skipped silently under nofail - found with power-profiles-daemon); no second
# hand-kept list of bind sources has come back; every '# ram:' declaration (a
# /var folder deliberately left on the tmpfs) is a /var path no line mounts.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; checked=0
no() { echo "FAIL $*"; fail=1; }

for prof in "$here"/image_profiles/*/; do
  f="$prof/overlay/rootfs/etc/fstab"; [[ -f $f && ! -L $f ]] || continue
  name=$(basename "$prof")
  mounted=$(grep -vE '^[[:space:]]*(#|$)' "$f" | awk '{print $2}')
  while IFS= read -r line; do
    checked=$((checked + 1))
    n=$(awk '{print NF}' <<< "$line")
    (( n == 6 )) || no "$name: $n fields: $line"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$f")
  while read -r path; do
    [[ $path == /var/* ]] || no "$name: '# ram: $path' is not under /var"
    grep -qxF "$path" <<< "$mounted" && no "$name: $path is declared ram but an fstab line mounts it"
  done < <(sed -n 's/^# ram: \([^ ]*\) .*/\1/p' "$f")
  t="$prof/overlay/rootfs/usr/lib/tmpfiles.d/shanios-data-structure.conf"
  if [[ -f $t ]] && grep -qE '^d[[:space:]]+/data/var(lib|spool)/[^[:space:]]+' "$t"; then
    no "$name: shanios-data-structure.conf lists bind sources by hand again (they are generated from fstab)"
  fi
done
(( checked > 0 )) || { echo "FAIL no fstab found under image_profiles"; exit 1; }

grep -q 'shanios-data-binds.conf' "$here/scripts/build-base-image.sh" \
  || no "build-base-image.sh no longer generates shanios-data-binds.conf from fstab"

inst="$here/../os-installer-config/scripts/install.sh"
if [[ -f $inst ]]; then
  grep -qE '^[[:space:]]+"var(lib|spool)/' "$inst" \
    && no "install.sh hard-codes varlib/varspool folders again (create_bind_sources reads the image's fstab)"
  grep -qE '^[[:space:]]+create_bind_sources$' "$inst" || no "install.sh no longer calls create_bind_sources"
else
  echo "SKIP install.sh checks: no ../os-installer-config"
fi

(( fail == 0 )) && echo "PASS ${checked} fstab lines well-formed; fstab is the one list (tmpfiles generated, installer derives)"
exit $fail
