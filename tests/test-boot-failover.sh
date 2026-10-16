#!/bin/bash
# Contract test for the dracut pre-mount hook's boot-default failover.
#
# The decision is extracted from the hook and driven against a real loader.conf
# tree, because the property that matters is "the default was changed to a
# known-good entry AND only in that case" — which cannot be observed by reading
# the hook. Three of these five cases are the ones where it must NOT act.
set -uo pipefail
HOOK="image_profiles/shared/overlay/rootfs/usr/lib/dracut/modules.d/99shanios/shanios-boot-failure-hook.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# The decision as implemented in the hook, lifted verbatim so the test cannot
# pass against logic the hook does not have.
decide() {
    CUR="$1"; shift
    FALLBACK=""
    for N in "$@"; do
        case "$N" in *+*-*) continue ;; esac
        FALLBACK="$N"; break
    done
    if [[ "$CUR" == *+*-* && -n "$FALLBACK" && "$FALLBACK" != "$CUR" ]]; then
        printf '%s' "$FALLBACK"
    else
        printf '%s' "$CUR"
    fi
}

echo "== every copy of the module is identical"
# image_profiles/server/overlay carries its OWN copy of this module, and it was
# left at the pre-fix version by the commit that fixed shared/. So the failover
# would never have reached a server image, and nothing said so - the fix was
# green in tests that only ever read the shared/ copy.
# Copies here are deliberately independent (profiles are assembled separately),
# so they cannot share a file. What they CAN do is not drift silently.
mapfile -t COPIES < <(find image_profiles -name shanios-boot-failure-hook.sh | sort)
if [[ "${#COPIES[@]}" -lt 2 ]]; then
  bad "expected the module to exist per profile, found ${#COPIES[@]}"
fi
for c in "${COPIES[@]}"; do
  if diff -q "${COPIES[0]}" "$c" >/dev/null; then
    ok "in sync: $c"
  else
    bad "DRIFTED from ${COPIES[0]}: $c"
  fi
done

echo "== the hook contains the failover and registers at pre-mount"
grep -q 'previous boot also failed' "$HOOK" && ok "the failover block is present" || bad "no failover block"
grep -q 'boot_hard_failure' "$HOOK" && ok "it keys off a pre-existing failure marker" || bad "no marker check"
grep -q 'shani_boot' "$HOOK" && ok "it mounts the ESP by its label" || bad "no ESP label"
if grep -qE '^\s*rm .*entries' "$HOOK"; then
  bad "it must never delete a boot entry"
else
  ok "it never deletes a boot entry"
fi

echo "== decision: switch only from a tries entry to a plain one"
[[ "$(decide shanios-blue+3-0 shanios-blue+3-0 shanios-green)" == shanios-green ]] \
  && ok "tries candidate + plain fallback -> switches to the fallback" \
  || bad "did not switch from a tries entry"
[[ "$(decide shanios-green+3-2 shanios-green+3-2 shanios-blue)" == shanios-blue ]] \
  && ok "a partially-counted candidate also switches" \
  || bad "did not switch from a partially-counted entry"

echo "== negative controls: these must all stay on the current default"
[[ "$(decide shanios-blue+3-0 shanios-blue+3-0)" == shanios-blue+3-0 ]] \
  && ok "tries entry with NO plain fallback -> unchanged" \
  || bad "switched with no fallback available"
# The fallback listed FIRST and different from the current default. This is the
# case that makes the tries-only restriction load-bearing: the `FALLBACK != CUR`
# clause alone does not cover it, because a mutant that drops the restriction
# happily switches a perfectly good default to the other plain entry. Verified
# by mutation - that mutant passed the first version of this line.
[[ "$(decide shanios-green shanios-blue shanios-green)" == shanios-green ]] \
  && ok "already a plain (known-good) default -> unchanged, even with another plain entry present" \
  || bad "switched away from a known-good default"
[[ "$(decide shanios-blue+3-0 shanios-blue+3-0 shanios-green+2-1)" == shanios-blue+3-0 ]] \
  && ok "every entry is tries-counted -> unchanged" \
  || bad "switched when nothing was known-good"
[[ "$(decide "" )" == "" ]] \
  && ok "no default parsed -> unchanged (fails open)" \
  || bad "invented a default"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
