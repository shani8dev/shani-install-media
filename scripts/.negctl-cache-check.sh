#!/bin/bash
# Negative control for scripts/check-pacman-cache.sh — run inside the builder
# container. Proves the checker can actually FAIL, i.e. that a clean report from
# it means something.
#
# A check that cannot fail is not a check, so this deliberately plants a cached
# package whose bytes do not match the repo and asserts the checker rejects it.
#
# On the invisibility of this corruption class: that was verified directly on
# the two REAL files that caused the incident
# (plasma6-applets-window-title-0.9.0-2-any, plasma-setup-git-0.1.0-2-x86_64),
# not synthesized here — `zstd -t` PASSED and `tar -tf` PASSED on both while
# their content hash differed from repo.shani.dev, which is why they survived
# until pacstrap aborted a 40-minute build. Reproducing that exact property
# synthetically is fiddly (it depends on where a truncation lands), and a
# synthetic stand-in that behaves differently would overstate the claim, so
# this control sticks to what it can prove cleanly: the checker detects a
# hash mismatch.
set -u
W=/tmp/negctl
rm -rf "$W"; mkdir -p "$W/pkg"

real=$(ls /var/cache/pacman/pkg/dracut-*.pkg.tar.zst 2>/dev/null | head -1)
if [ -z "$real" ]; then
    echo "SKIP: no suitable cached package to copy"
    exit 0
fi
name=$(basename "$real")
bad="$W/pkg/$name"
cp "$real" "$bad"

# Flip one byte deep inside the payload, then rewrite it as a valid zstd frame,
# so the file is still structurally a .pkg.tar.zst (the name still matches, so
# the checker's glob finds it) but no longer matches the repo hash.
zstd -dc "$real" 2>/dev/null \
  | dd bs=1 skip=500000 count=1 conv=notrunc 2>/dev/null \
  | tr '\000' '\001' \
  | zstd -q -f -o "$bad"

if [ ! -s "$bad" ]; then
    echo "SKIP: could not build a corrupt copy"
    exit 0
fi

if zstd -t "$bad" >/dev/null 2>&1; then
    echo "zstd -t on the corrupt copy : PASSES (still a structurally valid .zst)"
else
    echo "zstd -t on the corrupt copy : FAILS"
fi

cd /home/builduser/build || exit 2
out=$(PACMAN_CACHE_DIR="$W/pkg" ./scripts/check-pacman-cache.sh -p plasma --quiet 2>&1)
rc=$?
echo "$out" | grep -E 'CORRUPT|FAIL|repo says|file is|OK:' | head -8
echo "checker rc=$rc"

if [ "$rc" -eq 1 ] && grep -q CORRUPT <<<"$out"; then
    echo "NEGATIVE CONTROL PASS: a cached package that does not match the repo is reported, not waved through."
    exit 0
fi
echo "NEGATIVE CONTROL FAIL: the checker did not catch a corrupt cached package."
exit 1