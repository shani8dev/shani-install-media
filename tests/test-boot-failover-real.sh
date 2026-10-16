#!/bin/bash
# Drives the REAL dracut hook, not a copy of its logic.
#
# tests/test-boot-failover.sh lifts the decision so it can exercise every branch
# cheaply. That copy is the weakness: a lifted function is not the hook, so a
# change to the hook that breaks the behaviour leaves that suite green. This one
# sources the shipped hook with the dracut environment stubbed (getarg/blkid/
# warn/mount/umount), against a real loader.conf + entries tree, and reads the
# rewritten default back off disk.
set -uo pipefail
HOOK="image_profiles/shared/overlay/rootfs/usr/lib/dracut/modules.d/99shanios/shanios-boot-failure-hook.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

WORK=$(mktemp -d /tmp/bootfail.XXXXXX)
DATA_MNT="/run/shanios-data-tmp"; ESP_MNT="/run/shanios-boot-esp-tmp"
trap 'rm -rf "$WORK"' EXIT

# ── dracut environment stubs ──────────────────────────────────────────────
# The hook opens with `type getarg ... || return 0` precisely so that running
# it outside dracut is a no-op. Sourcing it therefore REQUIRES getarg to exist,
# which is why these stubs are the test's main tool rather than an afterthought.
ESP_SRC="$WORK/esp"
mkdir -p "$ESP_SRC"
mount() {
    local target="${!#}"
    if [[ "${1:-}" == "-t" && "${2:-}" == "vfat" ]]; then
        mkdir -p "$target" && cp -a "$ESP_SRC/." "$target/" 2>/dev/null
    fi
    return 0
}
umount() { :; }
blkid() { case "${2:-}" in shani_boot) echo /dev/fake-esp ;; shani_root) echo /dev/fake-root ;; esac; }
warn()  { printf '     hook: %s\n' "$*"; }
getarg() { echo "subvol=@blue"; }

build_esp() {   # $1 = default entry, rest = entry names
    rm -rf "$ESP_SRC"; mkdir -p "$ESP_SRC/loader/entries"
    printf 'default %s\ntimeout 5\nconsole-mode auto\n' "$1" > "$ESP_SRC/loader/loader.conf"
    shift
    for n in "$@"; do printf 'title %s\nlinux /vmlinuz-%s\n' "$n" "$n" \
        > "$ESP_SRC/loader/entries/${n}.conf"; done
}
default_now() { sed -n 's/^default[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' \
    "$ESP_MNT/loader/loader.conf" 2>/dev/null | head -1; }
# The ESP is mounted BY the hook, and only inside the branch it takes when it
# decides to act. So when the hook correctly declines, the mount never happens
# and this function would read an empty directory and report the default as ""
# rather than as "unchanged" - the first version of this file did exactly that
# and failed a case where the hook had behaved perfectly. The mountpoint is
# therefore populated up front, so `default_now` always sees a real loader.conf.
run_hook() {
    rm -rf "$ESP_MNT"; mkdir -p "$ESP_MNT"
    cp -a "$ESP_SRC/." "$ESP_MNT/" 2>/dev/null
    . "$HOOK"
}

echo "== the hook actually runs (not short-circuiting on the dracut guard)"
build_esp "shanios-green+3-0" "shanios-green+3-0" "shanios-blue"
printf 'green\n' > "$DATA_MNT/boot_hard_failure" 2>/dev/null || { mkdir -p "$DATA_MNT"; printf 'green\n' > "$DATA_MNT/boot_hard_failure"; }
run_hook
if [[ "$(default_now)" == "shanios-blue" ]]; then
  ok "a prior failure + tries default switches the default to the plain entry"
else
  bad "expected shanios-blue, got '$(default_now)'"
fi
[[ -f "$ESP_MNT/loader/loader.conf.shanios-bak" ]] \
  && ok "the original loader.conf is backed up before it is rewritten" \
  || bad "no backup of loader.conf was written"

echo "== negative controls: the real hook must change NOTHING here"
# 1. No prior failure marker -> this is the first failing boot.
build_esp "shanios-green+3-0" "shanios-green+3-0" "shanios-blue"
rm -f "$DATA_MNT/boot_hard_failure"
run_hook
[[ "$(default_now)" == "shanios-green+3-0" ]] \
  && ok "first failing boot (no prior marker) leaves the default alone" \
  || bad "acted on a first failure: got '$(default_now)'"

# 2. Default is already a plain, known-good entry.
build_esp "shanios-green" "shanios-blue" "shanios-green"
printf 'blue\n' > "$DATA_MNT/boot_hard_failure"
run_hook
[[ "$(default_now)" == "shanios-green" ]] \
  && ok "an already-plain default is left alone even with another plain entry present" \
  || bad "switched away from a known-good default: got '$(default_now)'"

# 3. Every entry is tries-counted -> nothing known-good to go to.
build_esp "shanios-green+3-0" "shanios-green+3-0" "shanios-blue+2-1"
printf 'green\n' > "$DATA_MNT/boot_hard_failure"
run_hook
[[ "$(default_now)" == "shanios-green+3-0" ]] \
  && ok "no plain entry available -> left alone" \
  || bad "switched to an unproven entry: got '$(default_now)'"

# 4. Self-limiting: after switching once, a second run must not move again.
build_esp "shanios-green+3-0" "shanios-green+3-0" "shanios-blue"
printf 'green\n' > "$DATA_MNT/boot_hard_failure"
run_hook; first="$(default_now)"
printf 'blue\n' > "$DATA_MNT/boot_hard_failure"
run_hook; second="$(default_now)"
[[ "$first" == "shanios-blue" && "$second" == "shanios-blue" ]] \
  && ok "a second run does not ping-pong back" \
  || bad "ping-ponged: '$first' -> '$second'"

# 5. It must never delete an entry.
build_esp "shanios-green+3-0" "shanios-green+3-0" "shanios-blue"
printf 'green\n' > "$DATA_MNT/boot_hard_failure"
run_hook
[[ -f "$ESP_MNT/loader/entries/shanios-green+3-0.conf" && -f "$ESP_MNT/loader/entries/shanios-blue.conf" ]] \
  && ok "both entries survive (nothing is deleted)" \
  || bad "an entry was deleted"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
