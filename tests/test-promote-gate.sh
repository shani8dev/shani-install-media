#!/bin/bash
# tests/test-promote-gate.sh — the promotion gate verifies bytes, not reachability.
#
# Why this exists. `promote-stable.sh` is the last thing between a build and
# every user who runs `shani-deploy`. Before this, its verification was: fetch
# the remote latest.txt, confirm `--expect` matches it, then HTTP-HEAD (or
# rclone-list) the artifact and each of its sidecars on SourceForge and on R2.
# Every one of those checks proves a file can be FETCHED. None of them proves
# the bytes are the ones that were built and signed — so a truncated upload, a
# corrupted mirror, or a substituted artifact with a reachable .sha256 and .asc
# would all have been promoted to stable.
#
# The gate that does prove it, `scripts/validate-image.sh`, has existed since
# 2026-09 and was invoked by nothing anywhere in the workspace. This suite
# covers the wiring, because a correct verifier that is never called is not a
# gate.
#
# IT NEVER RUNS promote-stable.sh. That script's own AGENTS.md entry is blunt
# about the hazard: "R2_BUCKET= empty is reset to `shanios` by the script — run
# it from a scratch copy on a machine with no rclone remote, or it really
# promotes." So the behavioural cases here execute a SCRIPTCOP of the promotion
# with the network, the uploads and validate-image.sh itself all replaced by
# stubs, and assert on what the copy decided. Nothing here can reach
# SourceForge, R2, or a local stable.txt.
#
# The case that matters most is the LAST one: that removing the gate makes the
# suite fail. Without it, every assertion below is equally satisfied by a
# promote-stable.sh that verifies nothing at all.

set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok    $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1 — $2"; }
summary() {
    echo ""
    echo "  ${PASS} passed, ${FAIL} failed"
    [[ "$FAIL" -eq 0 ]] || exit 1
    exit 0
}

PROMOTE=scripts/promote-stable.sh
VALIDATE=scripts/validate-image.sh

for f in "$PROMOTE" "$VALIDATE"; do
    [[ -f "$f" ]] || { echo "FATAL: $f not found" >&2; exit 1; }
    bash -n "$f" || { echo "FATAL: $f does not parse" >&2; exit 1; }
done

echo ""
echo "promote-stable gate"

# ── 1. The gate is actually invoked ──────────────────────────────────────────
# Static, because "is it called" is the whole claim. The behavioural cases
# below then prove what calling it does.
if grep -q 'validate-image\.sh" -p "\${PROFILE}" -d "\${BUILD_DATE_DIR}"' "$PROMOTE"; then
    ok "promote-stable.sh invokes validate-image.sh with the profile and build date"
else
    fail "promote-stable.sh invokes validate-image.sh with the profile and build date" \
         "no such invocation in $PROMOTE — the gate is not wired in"
fi

# ── 2. It runs BEFORE the reachability checks ────────────────────────────────
# Ordering is the point: verifying local bytes is the cheapest failure and the
# only unambiguous one. A gate placed after the network checks still works, but
# it wastes a round trip to find out the answer was no.
GATE_LINE=$(grep -n 'validate-image\.sh" -p' "$PROMOTE" | head -1 | cut -d: -f1)
NET_LINE=$(grep -n 'Verifying artifact on SourceForge' "$PROMOTE" | head -1 | cut -d: -f1)
if [[ -n "$GATE_LINE" && -n "$NET_LINE" && "$GATE_LINE" -lt "$NET_LINE" ]]; then
    ok "the gate runs before the SourceForge/R2 reachability checks"
else
    fail "the gate runs before the SourceForge/R2 reachability checks" \
         "gate at line ${GATE_LINE:-none}, reachability at ${NET_LINE:-none}"
fi

# ── 3. It is fail-closed ─────────────────────────────────────────────────────
# A soft-fail here is the exact bug class this repo's own supply-chain rule
# calls out, and the AMI/packer path has shipped one before. `|| true`, or any
# `if ! ... ; then` that does not die, is the shape to look for.
GATE_BLOCK=$(sed -n '/Validating the artifact/,/^fi$/p' "$PROMOTE")
if printf '%s' "$GATE_BLOCK" | grep -q 'validate-image.sh refused'; then
    ok "a failed validation aborts the promotion by name"
else
    fail "a failed validation aborts the promotion by name" "no die on validation failure"
fi
# Scoped to the INVOCATION line, not the whole block. A blanket "no || true
# anywhere near here" flagged a legitimate one: the local-latest.txt `cat` below
# ends in `|| true` on purpose (an absent file must not abort under `set -e`,
# and its emptiness is tested on the very next line). What must never appear is
# a `|| true` ON THE GATE, which would make a failed validation advisory.
if printf '%s\n' "$GATE_BLOCK" | grep 'validate-image\.sh" -p' | grep -qE '\|\| *true'; then
    fail "the gate itself is not soft-failed" "the validate-image invocation ends in || true"
else
    ok "the gate itself is not soft-failed"
fi

# ── 4. It refuses when the validated artifact is not the promoted one ───────
# validate-image resolves its target from the LOCAL latest.txt; this promotion
# publishes the one resolved from the REMOTE pointer. Two files, one name each.
if grep -q 'the validated artifact is not the one being promoted' "$PROMOTE"; then
    ok "a local/remote latest.txt disagreement refuses the promotion"
else
    fail "a local/remote latest.txt disagreement refuses the promotion" \
         "no cross-check — the gate could verify one image while promoting another"
fi

# ── 5. --only=iso must not demand a base image it will not promote ──────────
if grep -q 'if \[\[ "\${ONLY}" != "iso" \]\]; then' "$PROMOTE"; then
    ok "--only=iso skips the base-image gate"
else
    fail "--only=iso skips the base-image gate" "no ONLY guard around the gate"
fi
if grep -q 'skipping base-image validation' "$PROMOTE"; then
    ok "the --only=iso skip is stated, not silent"
else
    fail "the --only=iso skip is stated, not silent" "no log line for the skip"
fi

# ══ Behavioural: run a SCRIPTED COPY of the promotion, fully stubbed ═════════
# Everything that could touch the network, an upload target, or a real
# validator is replaced. What is left is promote-stable's own control flow.

run_promote() {
    # $1 = sed mutation applied to the copy (may be empty)
    # $2 = exit code the stubbed validate-image.sh should return
    local mutation="$1" vrc="${2:-0}"
    local dir; dir=$(mktemp -d /tmp/promote-gate.XXXXXX)
    # The REAL config/config.sh, not a hand-written stub. Two reasons, and the
    # first one cost this suite two rounds:
    #   1. A stub drifts. It was missing check_dependencies_upload, then
    #      CURL_RETRIES, and each omission aborted the script *before* the gate
    #      — so every behavioural case "passed" for the wrong reason and both
    #      negative controls were vacuous. The real file has every variable the
    #      script can reach.
    #   2. OUTPUT_DIR is `realpath -m ./cache/output` — cwd-relative — so
    #      running the copy from the scratch directory sandboxes every path
    #      without overriding anything. iso_profiles/ and image_profiles/ are
    #      plain `realpath` (no -m) and abort under `set -e` when absent, so
    #      they are created rather than stubbed.
    mkdir -p "$dir/scripts" "$dir/config" "$dir/iso_profiles" "$dir/image_profiles" \
             "$dir/cache/output/gnome/20261006" "$dir/keys/gpg" "$dir/bin"
    cp config/config.sh "$dir/config/config.sh"
    cp "$PROMOTE" "$dir/scripts/promote-stable.sh"
    # The stubbed validator: records that it ran, and returns what we asked.
    cat > "$dir/scripts/validate-image.sh" <<EOF
#!/bin/sh
echo "[stub-validate] ran for $2"
exit ${vrc}
EOF
    chmod +x "$dir/scripts/validate-image.sh"

    [[ -n "$mutation" ]] && sed -i "$mutation" "$dir/scripts/promote-stable.sh"

    # A local release dir whose latest.txt agrees with the promoted name.
    printf 'shanios-20261006-gnome.zst\n' > "$dir/cache/output/gnome/20261006/latest.txt"

    # Replace every remote interaction. The script must not reach the network.
    for tool in rclone sfcmd rsync; do
        printf '#!/bin/sh\necho "[stub] %s $*" >&2\nexit 0\n' "$tool" > "$dir/bin/$tool"
        chmod +x "$dir/bin/$tool"
    done
    # curl must honour --output: promote-stable fetches latest.txt to a FILE
    # (`--output "${LATEST_TXT}"`), it does not read it off stdout. A stub that
    # printed to stdout left LATEST_TXT empty and the script bailed at
    # "Failed to fetch latest.txt" — before the gate, which is why the first
    # two behavioural cases failed while the controls "passed".
    #
    # Note WHICH file this lands in. The remote pointer is
    # cache/output/<profile>/latest.txt; validate-image.sh reads the DATED
    # directory's own copy. The promotion's cross-check is precisely the
    # comparison between those two, so the stub has to write only the former.
    cat > "$dir/bin/curl" <<'EOF'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    http*)    url="$1"; shift ;;
    *)        shift ;;
  esac
done
case "$url" in
  *latest.txt*) [ -n "$out" ] && printf 'shanios-20261006-gnome.zst\n' > "$out" ;;
esac
exit 0
EOF
    chmod +x "$dir/bin/curl"

    local out rc
    out=$(cd "$dir" && PATH="$dir/bin:$PATH" \
          bash "$dir/scripts/promote-stable.sh" -p gnome --no-r2 2>&1)
    rc=$?
    printf '%s\n--RC=%s--\n' "$out" "$rc"
    rm -rf "$dir"
}

echo ""
echo "behavioural (stubbed, no network, no uploads)"

out=$(run_promote "" 0)
if printf '%s' "$out" | grep -q 'stub-validate'; then
    ok "the real promotion path reaches validate-image.sh"
else
    fail "the real promotion path reaches validate-image.sh" \
         "the stub was never called; control flow did not get there"
fi

out=$(run_promote "" 1)
if printf '%s' "$out" | grep -q 'refused'; then
    ok "a failing validation stops the promotion"
else
    fail "a failing validation stops the promotion" "promotion continued past a failed gate"
fi
# And it must not have reached an upload.
if printf '%s' "$out" | grep -q 'SUCCESS'; then
    fail "a failing validation never reports success" "it printed SUCCESS"
else
    ok "a failing validation never reports success"
fi

# ── N1 — remove the gate. Every behavioural case above must then fail. ───────
echo ""
echo "negative controls"
out=$(run_promote 's#^  if ! "\${SCRIPT_DIR}/validate-image.sh".*#  if false; then#' 0)
if printf '%s' "$out" | grep -q 'stub-validate'; then
    fail "N1: removing the gate makes the suite notice" \
         "the stub still ran — the sed did not remove the call"
else
    ok "N1: removing the gate makes the suite notice (the stub is no longer reached)"
fi

# ── N2 — make the failure non-fatal, the exact bug class this repo has shipped ──
# Mutating the `if !` line instead would leave an orphaned `fi` and turn the
# control into a syntax error — bash then prints the surrounding lines and the
# assertion greps its own noise. So this softens the `die` into a `warn`, which
# keeps the structure valid and isolates the one property under test: is a
# failed validation actually FATAL?
out=$(run_promote 's#^    die "validate-image\.sh refused#    warn "SOFTENED: validate-image.sh refused#' 1)
if printf '%s' "$out" | grep -q 'SOFTENED'; then
    ok "N2 control actually applied to the script"
else
    fail "N2 control actually applied to the script" "sed did not match the die line"
fi
if printf '%s' "$out" | grep -q 'SUCCESS'; then
    ok "N2: a soft-failed gate lets the promotion through — the die is what stops it"
else
    fail "N2: a soft-failed gate lets the promotion through" \
         "the promotion still stopped with die softened — the control cannot run"
fi

# ── N3 — the cross-check: local latest.txt pointing elsewhere. ──────────────
# validate-image would verify whatever the LOCAL latest.txt names. If that is
# a different image, the gate passes and the wrong artifact is promoted.
echo "-- N3: local latest.txt names a different artifact"
DIR3=$(mktemp -d /tmp/promote-gate-n3.XXXXXX)
mkdir -p "$DIR3/scripts" "$DIR3/config" "$DIR3/iso_profiles" "$DIR3/image_profiles" \
         "$DIR3/cache/output/gnome/20261006" "$DIR3/keys/gpg" "$DIR3/bin"
cp "$PROMOTE" "$DIR3/scripts/promote-stable.sh"
cp config/config.sh "$DIR3/config/config.sh"
printf '#!/bin/sh\necho "[stub-validate] ran"\nexit 0\n' > "$DIR3/scripts/validate-image.sh"
chmod +x "$DIR3/scripts/validate-image.sh"
# The mismatch: local says one image, the remote pointer says another.
printf 'shanios-20261005-gnome.zst\n' > "$DIR3/cache/output/gnome/20261006/latest.txt"
cat > "$DIR3/bin/curl" <<'EOF'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    http*)    url="$1"; shift ;;
    *)        shift ;;
  esac
done
case "$url" in
  *latest.txt*) [ -n "$out" ] && printf 'shanios-20261006-gnome.zst\n' > "$out" ;;
esac
exit 0
EOF
chmod +x "$DIR3/bin/curl"
for tool in rclone rsync sfcmd; do
    printf '#!/bin/sh\nexit 0\n' > "$DIR3/bin/$tool"; chmod +x "$DIR3/bin/$tool"
done
out3=$(cd "$DIR3" && PATH="$DIR3/bin:$PATH" bash "$DIR3/scripts/promote-stable.sh" -p gnome --no-r2 2>&1)
if printf '%s' "$out3" | grep -q 'not the one being promoted'; then
    ok "N3: a stale local latest.txt is caught before the wrong image is promoted"
else
    fail "N3: a stale local latest.txt is caught before the wrong image is promoted" \
         "the mismatch was not detected (output: $(printf '%s' "$out3" | tr '\n' ' ' | cut -c1-140))"
fi
rm -rf "$DIR3"

summary
