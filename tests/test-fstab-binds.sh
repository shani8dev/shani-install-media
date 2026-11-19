#!/usr/bin/env bash
# test-fstab-binds.sh - every image fstab line is well-formed, and every
# /data bind source is created by tmpfiles.
#
# Both fail silently on a machine: a mount line whose fields ran together
# (a long path padded into a too-narrow column, found 2026-11-19 with
# /data/varlib/power-profiles-daemon) is skipped because of nofail, and a bind
# whose /data source nothing creates is skipped the same way - the service's
# state then sits on the /var tmpfs and is lost at every boot, which is what
# the bind was added to stop.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; checked=0
for prof in "$here"/image_profiles/*/; do
  f="$prof/overlay/rootfs/etc/fstab"; [[ -f $f && ! -L $f ]] || continue
  t="$prof/overlay/rootfs/usr/lib/tmpfiles.d/shanios-data-structure.conf"
  name=$(basename "$prof")
  while IFS= read -r line; do
    checked=$((checked + 1))
    n=$(awk '{print NF}' <<< "$line")
    (( n == 6 )) || { echo "FAIL $name: $n fields: $line"; fail=1; continue; }
    src=$(awk '{print $1}' <<< "$line"); opts=$(awk '{print $4}' <<< "$line")
    if [[ $opts == *bind* && $src == /data/* && -f $t ]]; then
      grep -qE "^d[[:space:]]+${src}[[:space:]]" "$t" \
        || { echo "FAIL $name: bind source $src has no tmpfiles 'd' line"; fail=1; }
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' "$f")
done
(( checked > 0 )) || { echo "FAIL no fstab found under image_profiles"; exit 1; }
(( fail == 0 )) && echo "PASS ${checked} fstab lines well-formed; every /data bind source is made by tmpfiles"
exit $fail
