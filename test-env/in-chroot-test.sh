#!/bin/bash
# in-chroot-test.sh — REAL exercise of gen-efi.sh's in_chroot() (fix #4:
# fail CLOSED — error out — instead of silently treating a failed
# chroot-detection stat as "yes we're in a chroot").
#
# Run as root inside the nspawn @blue slot. Programmatically extracts the
# ACTUAL function body (in_chroot, error_exit) from the currently-installed
# /usr/local/bin/gen-efi with sed.
#
# To make "stat /proc/1/root" genuinely fail (not simulate it), this uses a
# private mount namespace (unshare --mount) and lazily unmounts /proc inside
# it — /proc/1/root then really doesn't exist (ENOENT), a real, reproducible
# trigger for the exact failure branch the fix targets. This never touches
# the real /proc outside the private namespace.
set -uo pipefail

FAIL=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; FAIL=1; }

SRC=/usr/local/bin/gen-efi
[[ -f "$SRC" ]] || { echo "FATAL: $SRC not found"; exit 2; }

FUNC_BODY=$(sed -n '/^in_chroot() {/,/^}/p' "$SRC")
[[ -n "$FUNC_BODY" ]] || { echo "FATAL: could not extract in_chroot() from $SRC"; exit 2; }
echo "=== Extracted in_chroot() from the live installed binary: ==="
echo "$FUNC_BODY"
echo "=============================================================="

HARNESS=/root/in-chroot-harness.sh
cat > "$HARNESS" <<HARNESSEOF
#!/bin/bash
error_exit() { echo "[test-log][ERROR] \$*"; exit 1; }
$FUNC_BODY

echo "########## Case 1: normal environment (real /proc/1/root accessible) ##########"
if in_chroot; then
    echo "in_chroot => TRUE (unexpected in the un-modified nspawn root)"
else
    echo "in_chroot => FALSE"
fi
echo "in_chroot rc=\$?"
HARNESSEOF
chmod +x "$HARNESS"

echo ""
echo "########## Baseline: call in_chroot() with a normal, accessible /proc/1/root ##########"
OUT_BASE=$(bash "$HARNESS" 2>&1)
echo "$OUT_BASE"
if echo "$OUT_BASE" | grep -q "in_chroot => FALSE"; then
    pass "Baseline: in_chroot() correctly returns false in the normal (non-chroot) nspawn environment"
else
    fail "Baseline: unexpected in_chroot() result: $OUT_BASE"
fi

echo ""
echo "########## Test: force 'stat /proc/1/root' to genuinely fail (private mount ns, /proc lazily unmounted) ##########"
OUT_FAIL=$(unshare --mount /bin/bash -c '
    mount --make-rprivate /proc 2>&1 >/dev/null
    umount -l /proc 2>&1 >/dev/null
    # Sanity: confirm the stat this function relies on really does fail now.
    if stat -c %d:%i /proc/1/root/. &>/dev/null; then
        echo "SANITY_FAILED: stat /proc/1/root still succeeded"
        exit 3
    fi
    bash '"$HARNESS"'
' 2>&1)
rc=$?
echo "$OUT_FAIL"
echo "(harness exit code: $rc)"

if echo "$OUT_FAIL" | grep -q "SANITY_FAILED"; then
    fail "Could not force 'stat /proc/1/root' to fail — test setup broken, results below are not meaningful"
elif echo "$OUT_FAIL" | grep -q "in_chroot => TRUE"; then
    fail "SECURITY: in_chroot() returned TRUE (fail-OPEN) when it could not determine chroot status — this is the original bug!"
elif echo "$OUT_FAIL" | grep -qi "Cannot determine chroot status" && [[ $rc -ne 0 ]]; then
    pass "in_chroot() failed CLOSED: errored out (rc=$rc) instead of guessing 'yes, in chroot' when the detection stat failed"
else
    fail "Unexpected outcome — neither a clean fail-closed error nor a fail-open TRUE was observed"
fi

echo ""
echo "=== IN_CHROOT TEST SUMMARY: FAIL=$FAIL ==="
exit "$FAIL"
