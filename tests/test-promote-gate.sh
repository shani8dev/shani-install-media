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

# ── 6. A bare promotion machine is fed, not exempted ─────────────────────────
# CI promotes from a fresh runner where cache/output/<profile>/<date>/ does
# not exist at all, so the local-preservation rule above made every CI
# promote job a guaranteed gate failure (real failure: the gnome promote
# job, 2026-10-23 — R2 had the bytes; the runner had none). The gate must
# feed itself before it judges: fetch every file it reads from the same R2
# folder the remote pointer was resolved from, run BEFORE validate-image.sh,
# fail closed on anything still missing, and stay disabled under --no-r2
# (a local-copy-only promotion, exactly as before).
if grep -q '^_ensure_local_artifact() {' "$PROMOTE"; then
    ok "the gate feeds itself: an R2 fetch step exists"
else
    fail "the gate feeds itself: an R2 fetch step exists" \
         "no _ensure_local_artifact — a bare runner still cannot reach the gate"
fi
FETCH_CALL_LINE=$(grep -n '^  _ensure_local_artifact$' "$PROMOTE" | head -1 | cut -d: -f1)
if [[ -n "$FETCH_CALL_LINE" && -n "$GATE_LINE" && "$FETCH_CALL_LINE" -lt "$GATE_LINE" ]]; then
    ok "the fetch runs before validate-image.sh"
else
    fail "the fetch runs before validate-image.sh" \
         "fetch at ${FETCH_CALL_LINE:-none}, gate at ${GATE_LINE:-none}"
fi
if grep -q 'Refusing to promote an artifact whose bytes were never verified' "$PROMOTE"; then
    ok "an incomplete fetch aborts the promotion (bytes were never verified)"
else
    fail "an incomplete fetch aborts the promotion" "a partially fetched artifact could be promoted"
fi
if grep -q -- '--no-r2) — fetch the artifact' "$PROMOTE" || grep -q 'R2 fetching is disabled (--no-r2)' "$PROMOTE"; then
    ok "--no-r2 keeps the local-copy-only rule (no fetch, refuse if absent)"
else
    fail "--no-r2 keeps the local-copy-only rule" "the fetch ignores the --no-r2 opt-out"
fi
# The fetch must not silently overwrite an operator's or a local build's
# copy: it runs only when something is missing, and a complete local copy
# short-circuits before any network call.
if grep -qF '(( ${#missing[@]} == 0 )) && return 0' "$PROMOTE"; then
    ok "a complete local copy is never re-fetched (bytes judged as-is)"
else
    fail "a complete local copy is never re-fetched" "the fetch may overwrite local bytes"
fi

# ══ Behavioural: run a SCRIPTED COPY of the promotion, fully stubbed ═════════
# Everything that could touch the network, an upload target, or a real
# validator is replaced. What is left is promote-stable's own control flow.

run_promote() {
    # $1 = sed mutation applied to the copy (may be empty)
    # $2 = exit code the stubbed validate-image.sh should return
    # $3 = extra args to pass (e.g. --no-sf); default none (legacy runs add --no-r2)
    # $4 = artifact fixture mode: "full" (default — the release dir holds the
    #      image and every sidecar, so _ensure_local_artifact fetches nothing
    #      and the behaviour is the pre-fetch one) or "missing" (only
    #      latest.txt, so the promotion must fetch or refuse). "missing" runs
    #      must go through R2 (no --no-r2) or the promotion dies by design.
    local mutation="$1" vrc="${2:-0}" extra="${3:-}" mode="${4:-full}"
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
    if [[ "$mode" == "full" ]]; then
        # The artifact and its sidecars all present non-empty, so the gate's
        # own fetch step sees a complete local copy and never touches the
        # network — the cases below test the pre-fetch control flow.
        printf 'stub-image-bytes'      > "$dir/cache/output/gnome/20261006/shanios-20261006-gnome.zst"
        printf 'stub-checksum'         > "$dir/cache/output/gnome/20261006/shanios-20261006-gnome.zst.sha256"
        printf 'stub-signature'        > "$dir/cache/output/gnome/20261006/shanios-20261006-gnome.zst.asc"
        printf 'stub-package-list'     > "$dir/cache/output/gnome/20261006/shanios-20261006-gnome.packages.txt"
    fi

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
  *20261006*)   [ -n "$out" ] && printf 'stub-bytes' > "$out" ;;
esac
exit 0
EOF
    if [[ "$mode" == "halffetch" ]]; then
        # A fetching R2 that answers the pointer but not the artifact —
        # curl "succeeds" while writing nothing. The gate must still refuse:
        # trusting exit codes here is the truncated-download bug class.
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
    fi
    chmod +x "$dir/bin/curl"

    local out rc
    # Default to --no-r2 (the legacy behavioural posture: no R2 anywhere).
    # R2-fetch cases pass --no-sf explicitly instead.
    extra="${3:---no-r2}"
    out=$(cd "$dir" && PATH="$dir/bin:$PATH" \
          bash "$dir/scripts/promote-stable.sh" -p gnome $extra 2>&1)
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

# ── Fetch behaviour: the three cases the fresh-CI-runner failure is ──────────
echo ""
echo "behavioural: the fetch (stubbed, no network, no uploads)"

# Bare runner + R2: the artifact and its sidecars do not exist, --no-sf (the
# R2-only posture a CI promote run uses), R2 enabled. Fetch must complete and
# the gate must then run on the fetched bytes.
out=$(run_promote "" 0 "--no-sf" missing)
if printf '%s' "$out" | grep -q 'Fetching from R2'; then
    ok "a bare release dir is fetched from R2"
else
    fail "a bare release dir is fetched from R2" "the fetch never started: $(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-160)"
fi
if printf '%s' "$out" | grep -q 'stub-validate'; then
    ok "the fetched artifact reaches the real gate"
else
    fail "the fetched artifact reaches the real gate" \
         "validate never saw the fetched bytes"
fi

# Bare runner + --no-r2: nothing may be fetched, the local-copy rule stands,
# and the gate must not be reached with zero bytes.
out=$(run_promote "" 0 "--no-r2" missing)
if printf '%s' "$out" | grep -q 'stub-validate'; then
    fail "a bare runner with --no-r2 never reaches the gate" "the gate ran on nothing"
else
    ok "a bare runner with --no-r2 never reaches the gate"
fi
if printf '%s' "$out" | grep -q 'R2 fetching is disabled (--no-r2)'; then
    ok "the --no-r2 refusal names the cause (fetch the artifact first)"
else
    fail "the --no-r2 refusal names the cause" "died without saying why: $(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-160)"
fi

# An R2 that answers the pointer but not the artifact: curl exits 0, writes
# nothing. Trusting the exit code would promote an unfetched artifact.
out=$(run_promote "" 0 "--no-sf" halffetch)
if printf '%s' "$out" | grep -q 'stub-validate'; then
    fail "a silently empty fetch is refused, not promoted" "the promotion continued on a half-fetched artifact"
else
    ok "a silently empty fetch is refused, not promoted"
fi
if printf '%s' "$out" | grep -q 'still missing'; then
    ok "the incomplete-fetch refusal names what is missing"
else
    fail "the incomplete-fetch refusal names what is missing" \
         "died without naming the gap: $(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-160)"
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
# The artifact + sidecars exist (the fetch step must stay out of the way so
# the cross-check, not the fetch's refusal, is the thing under test).
printf 'stub-image-bytes'  > "$DIR3/cache/output/gnome/20261006/shanios-20261006-gnome.zst"
printf 'stub-checksum'     > "$DIR3/cache/output/gnome/20261006/shanios-20261006-gnome.zst.sha256"
printf 'stub-signature'    > "$DIR3/cache/output/gnome/20261006/shanios-20261006-gnome.zst.asc"
printf 'stub-package-list' > "$DIR3/cache/output/gnome/20261006/shanios-20261006-gnome.packages.txt"
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
