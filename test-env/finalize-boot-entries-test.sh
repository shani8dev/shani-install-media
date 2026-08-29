#!/bin/bash
# finalize-boot-entries-test.sh — REAL exercise of shani-deploy.sh's
# finalize_boot_entries() (fix #2: writes to a .tmp file and atomically
# mv's it into place instead of writing the live file directly).
#
# Run as root inside the nspawn @blue slot, where /boot/efi is already a
# real mount (bind-mounted by cmd_enter). Programmatically extracts the
# ACTUAL function body from the currently-installed /usr/local/bin/shani-deploy
# (the edited copy) with sed — not a hand-retyped copy — so this exercises
# the real, current code.
set -uo pipefail

FAIL=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; FAIL=1; }

SRC=/usr/local/bin/shani-deploy
[[ -f "$SRC" ]] || { echo "FATAL: $SRC not found"; exit 2; }

FUNC_BODY=$(sed -n '/^finalize_boot_entries() {/,/^}/p' "$SRC")
if [[ -z "$FUNC_BODY" ]]; then
    echo "FATAL: could not extract finalize_boot_entries() from $SRC"
    exit 2
fi
echo "=== Extracted $(echo "$FUNC_BODY" | wc -l) lines for finalize_boot_entries() from the live installed binary ==="

OS_NAME="shanios"
ESP="/boot/efi"
log() { echo "[test-log] $*"; }
log_verbose() { :; }
log_error() { echo "[test-log][ERROR] $*"; }
log_warn() { echo "[test-log][WARN] $*"; }

eval "$FUNC_BODY"
if ! declare -f finalize_boot_entries >/dev/null; then
    echo "FATAL: eval did not define finalize_boot_entries"
    exit 2
fi

mountpoint -q "$ESP" || { echo "FATAL: $ESP is not mounted"; exit 2; }

echo ""
echo "########## Test 1: basic call — blue active, green candidate, with tries ##########"
finalize_boot_entries blue green yes
rc=$?
if [[ $rc -ne 0 ]]; then
    fail "Test 1: finalize_boot_entries returned $rc"
else
    if [[ -f "$ESP/loader/entries/shanios-blue+3-0.conf" && -f "$ESP/loader/entries/shanios-green.conf" \
          && ! -f "$ESP/loader/entries/shanios-blue.conf" ]]; then
        pass "Test 1: expected entry files present (shanios-blue+3-0.conf active-with-tries, shanios-green.conf candidate)"
    else
        fail "Test 1: unexpected entries dir contents: $(ls "$ESP/loader/entries")"
    fi
    if grep -q "^default shanios-blue.conf$" "$ESP/loader/loader.conf"; then
        pass "Test 1: loader.conf default points at shanios-blue.conf (base ID, tries suffix stripped)"
    else
        fail "Test 1: loader.conf default wrong: $(cat "$ESP/loader/loader.conf")"
    fi
fi

echo ""
echo "########## Test 2: swap active/candidate — green active (no tries), blue candidate ##########"
finalize_boot_entries green blue no
rc=$?
if [[ $rc -ne 0 ]]; then
    fail "Test 2: finalize_boot_entries returned $rc"
else
    ls_out=$(ls "$ESP/loader/entries")
    if [[ -f "$ESP/loader/entries/shanios-green.conf" && -f "$ESP/loader/entries/shanios-blue.conf" \
          && ! -f "$ESP/loader/entries/shanios-blue+3-0.conf" ]]; then
        pass "Test 2: stale shanios-blue+3-0.conf cleaned up, plain shanios-green.conf/shanios-blue.conf now present"
    else
        fail "Test 2: unexpected entries dir contents: $ls_out"
    fi
    if grep -q "^default shanios-green.conf$" "$ESP/loader/loader.conf"; then
        pass "Test 2: loader.conf default correctly switched to shanios-green.conf"
    else
        fail "Test 2: loader.conf default wrong: $(cat "$ESP/loader/loader.conf")"
    fi
fi

echo ""
echo "########## Test 3: concurrent-read atomicity stress ##########"
# Hammer finalize_boot_entries with alternating slots in the background while
# a concurrent reader continuously cats the active entry file. With the fixed
# tmp-then-atomic-mv implementation, a reader must NEVER observe a truncated
# (0-byte or partial) file — mv(2) is atomic on the same filesystem, so a
# concurrent open() always sees either the complete old file or the complete
# new file. This is exactly the race the original (direct-write) bug would
# have exposed.
READER_LOG=$(mktemp)
STOP_FILE=$(mktemp -u)
reader() {
    local n=0
    while [[ ! -f "$STOP_FILE" ]]; do
        for f in "$ESP/loader/entries/shanios-blue"*.conf "$ESP/loader/entries/shanios-green"*.conf; do
            [[ -f "$f" ]] || continue
            local sz
            sz=$(stat -c%s "$f" 2>/dev/null || echo -1)
            if [[ "$sz" == "0" ]]; then
                echo "TRUNCATED: $f was 0 bytes at iteration $n" >> "$READER_LOG"
            fi
        done
        n=$((n+1))
    done
    echo "reader iterations: $n" >> "$READER_LOG"
}
reader &
READER_PID=$!

for i in $(seq 1 40); do
    if (( i % 2 == 0 )); then
        finalize_boot_entries blue green yes >/dev/null
    else
        finalize_boot_entries green blue no >/dev/null
    fi
done

touch "$STOP_FILE"
wait "$READER_PID"
rm -f "$STOP_FILE"

if grep -q "TRUNCATED" "$READER_LOG"; then
    fail "Test 3: concurrent reader observed a truncated boot entry file — atomic replace is broken!"
    cat "$READER_LOG"
else
    pass "Test 3: 40 rapid alternating finalize_boot_entries calls, concurrent reader never saw a truncated entry file ($(grep -c 'reader iterations' "$READER_LOG" >/dev/null && tail -1 "$READER_LOG"))"
fi
rm -f "$READER_LOG"

echo ""
echo "=== FINALIZE_BOOT_ENTRIES TEST SUMMARY: FAIL=$FAIL ==="
exit "$FAIL"
