#!/bin/bash
# Contract test for the dracut pre-mount hook's boot-default failover.
#
# The decision is EXTRACTED FROM THE HOOK at run time and driven against a real
# loader.conf tree, because the property that matters is "the default was
# changed to a known-good entry AND only in that case" — which cannot be observed
# by reading the hook.
#
# WHY THIS USED TO BE A TRAP. The first version carried a hand-written copy of
# the decision, commented "lifted verbatim so the test cannot pass against logic
# the hook does not have". It was not verbatim, and the copy carried the same bug
# the hook had: it set the fallback to the entry STEM, while systemd-boot's entry
# id is the FILENAME including .conf. Ten assertions passed green while the hook
# wrote a default that systemd-boot cannot match — which is exactly how the
# rewrite landed on disk, looked correct, and changed nothing for a whole
# investigation. A copy of the logic tests the copy.
set -uo pipefail
HOOK="image_profiles/shared/overlay/rootfs/usr/lib/dracut/modules.d/99shanios/shanios-boot-failure-hook.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

if [[ ! -f $HOOK ]]; then echo "no hook at $HOOK" >&2; exit 2; fi

# The real code, lifted from the file rather than retyped. Anchored on where CUR
# is read and on the `esac` that closes the case it opens — anchoring on the
# success message instead yields a block with an unterminated `case`, which eval
# rejects after printing half the hook at you.
START=$(grep -n 'CUR=$(sed -n' "$HOOK" | head -1 | cut -d: -f1)
END=$(awk -v s="${START:-0}" 'NR>s && /^[[:space:]]*esac/ {print NR; exit}' "$HOOK")
if [[ -z $START || -z $END || $END -le $START ]]; then
    echo "could not locate the failover block in the hook (CUR at ${START:-none}, esac at ${END:-none})" >&2
    exit 2
fi
DECIDE=$(sed -n "${START},${END}p" "$HOOK")
# No pre-flight "does DECIDE look right" grep. Two of them lived here and were
# themselves unreliable — one matched the block by `\$FALLBACK` in a BRE and
# reported extraction failure on a block that was fine. If the extraction is
# wrong the assertions below fail loudly, which is the outcome worth having.

# Drive the extracted hook code against a real loader.conf tree and report the
# resulting default line. <entries...> are entry filenames; the first is loaded
# as the pre-existing default.
run_hook() {
    local first="$1"; shift
    local d; d=$(mktemp -d)
    mkdir -p "$d/loader/entries"
    printf 'timeout 5\nconsole-mode max\n' > "$d/loader/loader.conf"
    printf 'default %s\n' "$first" >> "$d/loader/loader.conf"
    local e
    for e in "$@"; do
        printf 'title   test\n' > "$d/loader/entries/$e"
        printf 'efi     /EFI/shanios/x.efi\n' >> "$d/loader/entries/$e"
    done
    ( set -uo pipefail
      ESP_MNT="$d"; ENTRIES="$d/loader/entries"; LOADER="$d/loader/loader.conf"
      PRIOR_FAILURE="blue"
      warn() { echo "warn: $*" >&2; }
      eval "$DECIDE"
    ) >/dev/null 2>&1
    sed -n 's/^default[[:space:]]*//p' "$d/loader/loader.conf" | head -1
    rm -rf "$d"
}

echo "== the hook contains the failover and registers at pre-mount"
grep -q 'previous boot also failed' "$HOOK" && ok "the failover block is present" || bad "no failover block"
grep -q 'boot_hard_failure' "$HOOK" && ok "it keys off a pre-existing failure marker" || bad "no marker check"
grep -q 'shani_boot' "$HOOK" && ok "it mounts the ESP by its label" || bad "no ESP label"
grep -qE '^\s*(rm|del)\s+.*\.conf' "$HOOK" && bad "it deletes a boot entry" || ok "it never deletes a boot entry"

echo
echo "== the positive case: a tries candidate with a plain sibling"
R=$(run_hook shanios-green+3-0.conf shanios-green+3-0.conf shanios-blue.conf)
if [[ "$R" == "shanios-blue.conf" ]]; then
  ok "switched to the known-good entry, by systemd-boot's entry id"
else
  bad "switched to the known-good entry" "got [$R], want [shanios-blue.conf]"
fi

# The regression this file exists for. The stem matches nothing systemd-boot can
# resolve; only the filename does.
if [[ "$R" != "shanios-blue" ]]; then
  ok "the default is the entry ID (filename incl. .conf), not the stem"
else
  bad "the default is the entry ID" "wrote the stem [shanios-blue]; systemd-boot matches on the id, so this selects nothing"
fi

echo
echo "== the cases where it must NOT act"
R=$(run_hook shanios-blue.conf shanios-blue.conf shanios-green.conf)
[[ "$R" == "shanios-blue.conf" ]] && ok "an already-plain default is left alone" || bad "plain default was changed" "got [$R]"

R=$(run_hook shanios-green+3-0.conf shanios-green+3-0.conf)
[[ "$R" == "shanios-green+3-0.conf" ]] && ok "a tries default with no plain sibling is left alone" || bad "switched with no fallback available" "got [$R]"

R=$(run_hook shanios-green+3-0.conf shanios-green+3-0.conf shanios-green+2-0.conf)
[[ "$R" == "shanios-green+3-0.conf" ]] && ok "every entry tries-counted is left alone" || bad "switched to another tries entry" "got [$R]"

R=$(run_hook shanios-blue.conf shanios-blue+3-0.conf shanios-blue.conf)
[[ "$R" == "shanios-blue.conf" ]] && ok "a plain default beats a tries entry of another name" || bad "plain default disturbed" "got [$R]"

echo
echo "== the backup the hook leaves behind"
D=$(mktemp -d); mkdir -p "$D/loader/entries"
printf 'default shanios-green+3-0.conf\n' > "$D/loader/loader.conf"
printf 'title   t\nefi     /e\n' > "$D/loader/entries/shanios-blue.conf"
( set -uo pipefail
  ESP_MNT="$D"; ENTRIES="$D/loader/entries"; LOADER="$D/loader/loader.conf"; PRIOR_FAILURE="blue"
  warn() { :; }; eval "$DECIDE" ) >/dev/null 2>&1
if [[ -f "$D/loader/loader.conf.shanios-bak" ]]; then
  ok "the pre-switch loader.conf is backed up"
  grep -q 'shanios-green+3-0' "$D/loader/loader.conf.shanios-bak" \
    && ok "the backup holds the value that was replaced" || bad "backup holds the wrong value"
else
  bad "the pre-switch loader.conf is backed up" "no .shanios-bak written"
fi
rm -rf "$D"

echo
echo "${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]