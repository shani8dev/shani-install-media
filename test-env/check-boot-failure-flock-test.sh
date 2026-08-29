#!/bin/bash
# check-boot-failure-flock-test.sh — REAL exercise of check-boot-failure.sh's
# new flock (fix #5). Runs the ACTUAL installed /usr/local/bin/check-boot-failure
# binary (not an extracted copy) inside the nspawn @blue slot.
#
# Two things are tested for real:
#   1. Serialization: while an external process holds the exact same lock
#      file the script uses, a concurrent invocation of the real script must
#      BLOCK until the lock is released, not run concurrently.
#   2. No corruption under a rapid-fire concurrent stress: many overlapping
#      real invocations racing on /data/boot_failure must never leave it
#      empty/truncated/garbled — always exactly one valid slot name.
set -uo pipefail

FAIL=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; FAIL=1; }

BIN=/usr/local/bin/check-boot-failure
[[ -x "$BIN" ]] || { echo "FATAL: $BIN not found/executable"; exit 2; }
LOCK_FILE="/run/shani-boot-failure.lock"

# A plain `enter` (non --boot) nspawn session has no real subvol= on its
# kernel cmdline (that's the HOST's cmdline) and / is an overlayfs, not a
# raw btrfs mount, so check-boot-failure.sh's own BOOTED_SLOT detection
# (rootflags= parsing, falling back to `btrfs subvolume get-default /`)
# cannot resolve here and the script would exit early on every call ("Cannot
# detect booted subvolume — skipping"), never reaching the marker
# read/write logic the flock actually protects. Give each invocation its own
# private mount namespace with a bind-mounted fake /proc/cmdline reporting
# subvol=@blue, so BOOTED_SLOT reliably resolves to "blue" without needing a
# full systemd --boot. This changes nothing about the real host or the
# nspawn's real /proc outside that invocation's private namespace.
echo "BOOT_IMAGE=/x root=/dev/foo rootflags=subvol=@blue,ro rw" > /root/fake-cmdline
run_bin() {
    unshare --mount /bin/bash -c "mount --bind /root/fake-cmdline /proc/cmdline && exec '$BIN'"
}

setup_markers() {
    rm -f /data/boot-ok /data/boot_failure /data/boot_failure.acked /data/boot_hard_failure
    # current-slot = the slot check-boot-failure.sh treats as "the one that
    # was SUPPOSED to boot" (i.e. the candidate that failed). With the fake
    # cmdline reporting BOOTED_SLOT=blue, current-slot=green makes the
    # script record FAILED_SLOT=green.
    echo "green" > /data/current-slot
    touch /data/boot_in_progress
}

echo "########## Test 1: a held lock blocks the real script from proceeding ##########"
setup_markers
exec 8>"$LOCK_FILE"
flock 8
(
    START=$(date +%s%N)
    run_bin
    END=$(date +%s%N)
    echo "elapsed_ms=$(( (END-START)/1000000 ))" > /root/flock-test-elapsed
) &
CHILD=$!
sleep 3
STILL_RUNNING=1
if ! kill -0 "$CHILD" 2>/dev/null; then
    STILL_RUNNING=0
fi
if [[ "$STILL_RUNNING" -eq 1 ]]; then
    pass "Test 1a: with the lock held externally for 3s, the real check-boot-failure is still blocked (has not completed)"
else
    fail "Test 1a: check-boot-failure completed even though the lock was supposedly held externally — flock is not actually serializing!"
fi
flock -u 8
exec 8>&-
wait "$CHILD"
if [[ -f /root/flock-test-elapsed ]]; then
    cat /root/flock-test-elapsed
    elapsed=$(grep -oE '[0-9]+' /root/flock-test-elapsed)
    if [[ -n "$elapsed" && "$elapsed" -ge 2500 ]]; then
        pass "Test 1b: check-boot-failure only completed AFTER the external lock was released (elapsed ${elapsed}ms >= ~3000ms hold time)"
    else
        fail "Test 1b: check-boot-failure completed too quickly (elapsed=${elapsed}ms) — did it actually wait on the lock?"
    fi
else
    fail "Test 1b: elapsed-time marker file missing — child may have failed"
fi
rm -f /root/flock-test-elapsed

echo ""
echo "########## Test 2: rapid concurrent stress — no corrupted/empty boot_failure ##########"
BADRUNS=0
for iter in $(seq 1 15); do
    setup_markers
    pids=()
    for i in 1 2 3 4; do
        run_bin &
        pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p"; done

    if [[ ! -f /data/boot_failure ]]; then
        echo "iter $iter: FAIL - /data/boot_failure missing after 4 concurrent runs"
        BADRUNS=$((BADRUNS+1))
        continue
    fi
    content=$(cat /data/boot_failure)
    sz=$(stat -c%s /data/boot_failure)
    if [[ "$content" != "green" ]]; then
        echo "iter $iter: FAIL - /data/boot_failure content corrupted/wrong: '$content' (size=$sz bytes)"
        BADRUNS=$((BADRUNS+1))
    fi
done

if [[ "$BADRUNS" -eq 0 ]]; then
    pass "Test 2: 15 rounds x 4 concurrent real check-boot-failure invocations — /data/boot_failure always ended up exactly 'green', never empty/corrupted"
else
    fail "Test 2: $BADRUNS/15 rounds produced a missing/corrupted /data/boot_failure"
fi

rm -f /data/boot-ok /data/boot_failure /data/boot_failure.acked /data/boot_hard_failure /data/boot_in_progress /data/current-slot

echo ""
echo "=== CHECK_BOOT_FAILURE FLOCK TEST SUMMARY: FAIL=$FAIL ==="
exit "$FAIL"
