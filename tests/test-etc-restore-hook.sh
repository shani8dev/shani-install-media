#!/usr/bin/env bash
# test-etc-restore-hook.sh - the initramfs half of "System Changes" restore.
#
# shani-deploy's shani-etc-changes queues paths in @data/etc-restore-pending;
# shanios-overlay-etc.sh (dracut 99shanios) removes their copies from the /etc
# overlay's upper layer before /etc is mounted. The hook is what deletes, so
# it refuses on its own - not only because the CLI never queues them:
#   - a path that is absolute or climbs out with ..
#   - a directory
#   - the accounts and this computer's identity (passwd, shadow, group,
#     gshadow, subuid, subgid, machine-id, crypttab, secureboot/*,
#     ssh/ssh_host_*) - a queue written any other way must not delete every
#     account (added 2026-11-19)
#
# No root, no initramfs: the restore block is lifted out of the hook and run
# against a scratch @data. NEGATIVE control: the same queue with the
# protected-name case removed must delete passwd.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$here/image_profiles/shared/overlay/rootfs/usr/lib/dracut/modules.d/99shanios/shanios-overlay-etc.sh"
pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; fail=$((fail + 1)); }

block=$(sed -n '/^PENDING="\${DATA_MNT}\/etc-restore-pending"/,/^fi$/p' "$HOOK")
[[ -n $block && $block == *'rm -f "$RTARGET"'* ]] || { echo "FAIL could not lift the restore block from $HOOK"; exit 1; }

# run BLOCK -> scratch dir; queue: every case below
run() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/overlay/etc/upper/secureboot/keys" "$d/overlay/etc/upper/ssh" "$d/overlay/etc/upper/conf.d" "$d/outside"
  for f in passwd shadow group gshadow subuid subgid machine-id crypttab hostname; do echo x > "$d/overlay/etc/upper/$f"; done
  echo k > "$d/overlay/etc/upper/secureboot/keys/MOK.key"
  echo h > "$d/overlay/etc/upper/ssh/ssh_host_ed25519_key"
  echo c > "$d/overlay/etc/upper/conf.d/a.conf"
  echo o > "$d/outside/victim"
  printf '%s\n' passwd shadow group gshadow subuid subgid machine-id crypttab \
    secureboot/keys/MOK.key ssh/ssh_host_ed25519_key hostname conf.d \
    conf.d/a.conf ../../outside/victim /etc/hostname > "$d/etc-restore-pending"
  (
    DATA_MNT=$d OVERLAY_UPPER=$d/overlay/etc/upper
    warn() { echo "$*" >> "$d/warn.log"; }
    sync() { :; }
    eval "$1"
  )
  echo "$d"
}

echo "== the hook as shipped"
d=$(run "$block")
U=$d/overlay/etc/upper
for f in passwd shadow group gshadow subuid subgid machine-id crypttab secureboot/keys/MOK.key ssh/ssh_host_ed25519_key; do
  [[ -e $U/$f ]] && ok "kept $f" || no "kept $f" "$(cat "$d/warn.log")"
done
[[ ! -e $U/hostname ]] && ok "an ordinary file is restored (hostname)" || no "hostname restored" "$(cat "$d/warn.log")"
[[ ! -e $U/conf.d/a.conf && -d $U/conf.d ]] && ok "a file in a folder is restored, the folder is not" || no "conf.d" "$(ls -R "$U")"
[[ -e $d/outside/victim ]] && ok "../ out of the upper layer refused" || no "climb-out" "$(cat "$d/warn.log")"
grep -q 'passwd is protected' "$d/warn.log" && ok "says why passwd was refused" || no "warning" "$(cat "$d/warn.log")"
[[ ! -e $d/etc-restore-pending ]] && ok "the queue is consumed" || no "queue left" ""
grep -qx '.* restored hostname' "$d/etc-restore-done" && ! grep -q passwd "$d/etc-restore-done" \
  && ok "etc-restore-done lists only what was restored" || no "done log" "$(cat "$d/etc-restore-done")"
rm -rf "$d"

echo "== negative control: the hook without the protected-name case"
d=$(run "$(sed '/passwd|shadow|group|gshadow/,+1d' <<< "$block")")
[[ ! -e $d/overlay/etc/upper/passwd ]] && ok "without it, passwd IS deleted (the check is what protects it)" \
  || no "control did not reproduce" "$(ls "$d/overlay/etc/upper")"
rm -rf "$d"

echo "== the hook refuses everything shani-etc-changes protects"
cli="$here/../shani-deploy/scripts/shani-etc-changes"
if [[ -f $cli ]]; then
  pat=$(grep -oE '^[[:space:]]+passwd\|[^)]+' "$HOOK" | tr -d '[:space:]')
  while read -r name; do
    grep -qxF "$name" <<< "$(tr '|' '\n' <<< "$pat")" && ok "hook refuses $name" || no "hook refuses $name" "pattern: $pat"
  done < <(sed -n '/^PROTECTED = {/,/^}/p' "$cli" | sed -n 's/^[[:space:]]*"\([^"]*\)":.*/\1/p')
else
  echo "  SKIP  no ../shani-deploy checkout"
fi

echo; echo "  ${pass} passed, ${fail} failed"
(( fail == 0 ))
