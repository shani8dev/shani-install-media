#!/usr/bin/env bash
# gen-var-tmpfiles.sh — write a tmpfiles.d entry for every directory (and empty
# file) a package ships under /var, so a ShaniOS boot recreates them.
#
# WHY THIS EXISTS: ShaniOS boots with systemd.volatile=state, so /var is an
# empty tmpfs, and the persistent parts of it (@subvolumes, /data/varlib/<svc>
# and /data/varspool/<svc> bind mounts) start out EMPTY on a fresh install.
# Whatever a package ships under /var therefore never exists at runtime unless
# a tmpfiles.d line creates it, and most Arch packages ship none. Found by
# shani-testbed's service-start slot-test on 2026-10-01: smb, nmb and winbind
# failed on every fresh install (no /var/lib/samba/private), rpc-statd failed
# (no /var/lib/nfs/statd), and libvirtd failed (its /var/lib/libvirt tree is a
# fresh @libvirt subvolume). A hand-kept list would go stale with the next
# package added; this derives the list from pacman's own per-package mtree, so
# mode and owner are the package's own.
#
# Every mode/user/group is prefixed with ':' — tmpfiles applies it only when it
# CREATES the inode — so persistent state a service has since chowned or
# chmodded (it lives on in /data across reboots) is never reset at boot.
# Paths some other tmpfiles.d file already declares are skipped: that file is
# the authority, and a duplicate line makes systemd-tmpfiles warn.
#
# Usage: gen-var-tmpfiles.sh <image-root> [out-file]
#   out-file defaults to <image-root>/usr/lib/tmpfiles.d/shanios-package-var.conf
set -Eeuo pipefail

ROOT=${1:?usage: gen-var-tmpfiles.sh <image-root> [out-file]}
OUT=${2:-$ROOT/usr/lib/tmpfiles.d/shanios-package-var.conf}
LOCAL="$ROOT/var/lib/pacman/local"
[[ -d "$LOCAL" ]] || { echo "gen-var-tmpfiles: no pacman db at $LOCAL" >&2; exit 1; }

# Paths every other tmpfiles.d snippet in the image already declares (column 2).
declared=$(mktemp); trap 'rm -f "$declared" "$declared.all"' EXIT
for d in "$ROOT/usr/lib/tmpfiles.d" "$ROOT/etc/tmpfiles.d"; do
    [[ -d "$d" ]] || continue
    find "$d" -maxdepth 1 -name '*.conf' ! -name "$(basename "$OUT")" -print0 \
        | xargs -0r awk '!/^[[:space:]]*(#|$)/ { print $2 }'
done \
  | sed -e 's|%S|/var/lib|g; s|%C|/var/cache|g; s|%L|/var/log|g; s|%V|/var/tmp|g; s|%T|/tmp|g; s|%t|/run|g' \
        -e 's|/$||' \
  | sort -u > "$declared"
# (system-scope specifiers expanded: podman's tmpfiles.d says `d %S/containers`,
#  and a literal /var/lib/containers line beside it made systemd-tmpfiles log
#  "Duplicate line for path" on every boot - seen 2026-10-01)

# mtree: "/set k=v ..." sets defaults, "/unset k" clears one, every other line
# is "./path k=v ..." overriding them. Paths escape bytes as \ooo octal.
for m in "$LOCAL"/*/mtree; do
    gzip -dc "$m"
done | awk '
    function unesc(s,   out, i, c) {
        out = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c == "\\" && substr(s, i+1, 3) ~ /^[0-7][0-7][0-7]$/) {
                out = out sprintf("%c", (substr(s,i+1,1)*64) + (substr(s,i+2,1)*8) + substr(s,i+3,1))
                i += 3
            } else out = out c
        }
        return out
    }
    /^#/ { next }
    $1 == "/set"   { for (i = 2; i <= NF; i++) { split($i, kv, "="); def[kv[1]] = kv[2] } ; next }
    $1 == "/unset" { for (i = 2; i <= NF; i++) delete def[$i]; next }
    $1 ~ /^\.\/var\// {
        delete e; for (k in def) e[k] = def[k]
        for (i = 2; i <= NF; i++) { split($i, kv, "="); e[kv[1]] = kv[2] }
        p = unesc(substr($1, 2))
        t = e["type"]; mode = e["mode"]; u = e["uid"]; g = e["gid"]
        if (mode == "") mode = (t == "dir") ? "755" : "644"
        if (u == "") u = 0
        if (g == "") g = 0
        if (t == "dir")                           printf "d %s :%04d :%s :%s -\n", p, mode, u, g
        else if (t == "file" && e["size"] == "0") printf "f %s :%04d :%s :%s -\n", p, mode, u, g
        # non-empty files and symlinks are not recreated: their content is the
        # package payload, which belongs to the package, not to boot-time setup
    }
' | sort -u -k2,2 > "$declared.all"

# /var itself and its first-level dirs come from systemd's own var.conf/fs layout
lines=$(awk 'NR==FNR { skip[$1] = 1; next }
             $2 ~ /^\/var\/?$/ { next }
             !($2 in skip)' "$declared" "$declared.all")

mkdir -p "$(dirname "$OUT")"
{
    echo "# Generated at image build by shani-install-media scripts/gen-var-tmpfiles.sh"
    echo "# from pacman's per-package mtree: every directory and empty file a package"
    echo "# ships under /var, which systemd.volatile=state and the empty /data/varlib"
    echo "# bind sources would otherwise leave missing. ':' = applied only on create."
    printf '%s\n' "$lines"
} > "$OUT"
echo "gen-var-tmpfiles: $(grep -c '^[df] ' "$OUT") entries -> ${OUT#"$ROOT"}"
