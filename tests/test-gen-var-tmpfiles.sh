#!/usr/bin/env bash
# test-gen-var-tmpfiles.sh - scripts/gen-var-tmpfiles.sh on a fake image root.
#
# A real boot has /var as an empty tmpfs, so everything a package ships under
# /var has to come back from a tmpfiles line: folders and empty files (d/f,
# ':' = only on create), files with content (C from /usr/share/factory, added
# 2026-11-19 - 43 such files were absent at runtime) and symlinks (L - the
# filesystem package's /var/lock and /var/mail were absent). A path another
# tmpfiles.d file declares is left to that file.
#
# No root: the image is a directory with one pacman mtree; systemd-tmpfiles
# --root (when installed) then applies the result to an empty "boot".
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; fail=$((fail + 1)); }

R=$(mktemp -d); trap 'rm -rf "$R"' EXIT
mkdir -p "$R/var/lib/pacman/local/demo-1-1" "$R/var/lib/demo/db" "$R/usr/lib/tmpfiles.d" "$R/var/spool/mail"
printf 'zone data\n' > "$R/var/lib/demo/db/zone"
: > "$R/var/lib/demo/empty"
ln -s spool/mail "$R/var/mail"
mkdir -p "$R/var/lib/owned"
echo 'd /var/lib/owned 0700 root root -' > "$R/usr/lib/tmpfiles.d/owned.conf"
cat <<'EOF' | gzip > "$R/var/lib/pacman/local/demo-1-1/mtree"
#mtree
/set type=file uid=0 gid=0 mode=644
./var type=dir mode=755
./var/lib/demo type=dir mode=750 gid=40
./var/lib/demo/db type=dir mode=755
./var/lib/demo/db/zone size=10 mode=640 gid=40
./var/lib/demo/empty size=0
./var/lib/owned type=dir mode=755
./var/mail type=link link=spool/mail
./var/log/demo.log size=5
EOF
mkdir -p "$R/var/log"; printf 'xxxx\n' > "$R/var/log/demo.log"

out=$(bash "$here/scripts/gen-var-tmpfiles.sh" "$R" 2>&1) || { echo "FAIL gen-var-tmpfiles: $out"; exit 1; }
C="$R/usr/lib/tmpfiles.d/shanios-package-var.conf"
has() { grep -qE "$1" "$C"; }

has '^d /var/lib/demo :0750 :0 :40 -$' && ok "folder: d with ':' mode/owner" || no "folder line" "$(cat "$C")"
has '^f /var/lib/demo/empty :0644 :0 :0 -$' && ok "empty file: f" || no "empty file line" "$(cat "$C")"
has '^C /var/lib/demo/db/zone - - - -$' && ok "file with content: C" || no "C line" "$(cat "$C")"
cmp -s "$R/var/lib/demo/db/zone" "$R/usr/share/factory/var/lib/demo/db/zone" \
  && ok "its factory copy is in /usr/share/factory" || no "factory copy" "$(ls -R "$R/usr/share" 2>&1)"
has '^L /var/mail - - - - spool/mail$' && ok "symlink: L" || no "L line" "$(cat "$C")"
has '/var/log/demo.log' && no "a /var/log file is not restored" "$(cat "$C")" || ok "/var/log content left alone"
has ' /var/lib/owned ' && no "a path another tmpfiles.d declares is skipped" "$(cat "$C")" || ok "owned.conf's path is left to it"

if command -v systemd-tmpfiles >/dev/null; then
  B=$(mktemp -d); mkdir -p "$B/usr/share" "$B/var/spool/mail"; cp -a "$R/usr/share/factory" "$B/usr/share/"
  systemd-tmpfiles --root="$B" --create "$C" >/dev/null 2>&1
  [[ "$(cat "$B/var/lib/demo/db/zone" 2>/dev/null)" == "zone data" ]] && ok "a boot restores the file" || no "restore" "$(ls -R "$B/var" 2>&1)"
  [[ "$(readlink "$B/var/mail")" == spool/mail ]] && ok "a boot makes the link" || no "link" "$(ls -la "$B/var")"
  echo changed > "$B/var/lib/demo/db/zone"; systemd-tmpfiles --root="$B" --create "$C" >/dev/null 2>&1
  [[ "$(cat "$B/var/lib/demo/db/zone")" == changed ]] && ok "a changed file is not reset" || no "kept change" "$(cat "$B/var/lib/demo/db/zone")"
  rm -rf "$B"
else
  echo "  SKIP  boot checks: no systemd-tmpfiles"
fi

# negative control: an mtree file the image lacks must stop the build
rm "$R/var/lib/demo/db/zone"; rm -rf "$R/usr/share/factory"
bash "$here/scripts/gen-var-tmpfiles.sh" "$R" >/dev/null 2>&1 \
  && no "a payload file missing from the image fails the build" "exit 0" || ok "missing payload file fails the build"

echo; echo "  ${pass} passed, ${fail} failed"
(( fail == 0 ))
