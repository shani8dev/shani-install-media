#!/bin/bash
# self-update-test.sh — REAL end-to-end exercise of shani-deploy.sh's
# self_update() gate (fix #1). Run as root inside the nspawn @blue slot,
# where /usr/local/bin/shani-deploy has already been overridden with the
# edited scripts/shani-deploy.sh.
#
# Strategy: point raw.githubusercontent.com (the hardcoded self-update
# source) at a local HTTPS server via /etc/hosts (contained to this
# ephemeral nspawn/container — never touches the real host's /etc/hosts),
# serve it a cert signed by the same throwaway test CA already trusted in
# this slot, and drive shani-deploy's real self_update() through three
# real scenarios: bad SHA256, bad GPG signature, and a fully valid
# SHA256+GPG-signed payload — observing the ACTUAL exit behavior and
# whether /usr/local/bin/shani-deploy was replaced / the downloaded script
# was actually exec'd, not just re-reading the source.
set -uo pipefail

FAIL=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; FAIL=1; }

WORKDIR=/root/selfupdate-test
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/webroot/shani8dev/shani-deploy/refs/heads/main/scripts"

CA_DIR=/mnt/repo/test-env/disk/ca
[[ -f "$CA_DIR/ca.crt" && -f "$CA_DIR/ca.key" ]] || { echo "FATAL: test CA not found at $CA_DIR"; exit 2; }

cd "$WORKDIR" || exit 2

echo "=== Generating raw.githubusercontent.com leaf cert signed by test CA ==="
openssl genrsa -out server.key 2048 2>/dev/null
openssl req -new -key server.key -out server.csr -subj "/CN=raw.githubusercontent.com" 2>/dev/null
echo "subjectAltName=DNS:raw.githubusercontent.com" > ext.cnf
openssl x509 -req -in server.csr -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
    -CAserial "$WORKDIR/ca.srl" -CAcreateserial \
    -out server.crt -days 30 -extfile ext.cnf 2>server.crt.err
[[ -s server.crt ]] || { echo "FATAL: failed to generate server cert"; cat server.crt.err 2>/dev/null; exit 2; }

echo "=== Pointing raw.githubusercontent.com at 127.0.0.1 (this nspawn/container only) ==="
grep -q raw.githubusercontent.com /etc/hosts || echo "127.0.0.1 raw.githubusercontent.com" >> /etc/hosts

echo "=== Generating throwaway GPG signing key ==="
export GNUPGHOME="$WORKDIR/gnupg"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
cat > keyspec <<'EOF'
%no-protection
Key-Type: RSA
Key-Length: 2048
Name-Real: Shani Test Signer
Name-Email: test@example.invalid
Expire-Date: 0
%commit
EOF
gpg --batch --gen-key keyspec >gpg-genkey.log 2>&1
TEST_FPR=$(gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')
if [[ -z "$TEST_FPR" ]]; then
    echo "FATAL: could not generate test GPG key"; cat gpg-genkey.log; exit 2
fi
echo "Test GPG fingerprint: $TEST_FPR"
gpg --batch --armor --export "$TEST_FPR" > signing.asc

echo "=== Swapping in test key as the bundled signing key (backing up original) ==="
if [[ -f /etc/shani-keys/signing.asc ]]; then
    cp /etc/shani-keys/signing.asc "$WORKDIR/signing.asc.orig"
fi
mkdir -p /etc/shani-keys
cp signing.asc /etc/shani-keys/signing.asc

echo "=== Starting local HTTPS stand-in for raw.githubusercontent.com ==="
cd "$WORKDIR/webroot" || exit 2
cat > server.py <<'PYEOF'
import http.server, ssl
httpd = http.server.HTTPServer(("127.0.0.1", 443), http.server.SimpleHTTPRequestHandler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile="../server.crt", keyfile="../server.key")
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PYEOF
python3 server.py >"$WORKDIR/server.log" 2>&1 &
SERVER_PID=$!
sleep 1
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "FATAL: local HTTPS server failed to start"; cat "$WORKDIR/server.log"; exit 2
fi

URLDIR="$WORKDIR/webroot/shani8dev/shani-deploy/refs/heads/main/scripts"
cp /usr/local/bin/shani-deploy "$WORKDIR/shani-deploy.golden"

run_shani_deploy() {
    ( cd / && SHANIOS_DEPLOY_GPG_KEY_ID="$TEST_FPR" timeout 15 shani-deploy --verbose 2>&1 )
}

echo ""
echo "########## Scenario A: bad SHA256 (signature also present but should never matter) ##########"
cat > "$URLDIR/shani-deploy.sh" <<'EOF'
#!/bin/bash
# shanios-deploy REJECT-BAD-SHA test payload
echo "SELFUPDATE_REJECT_BAD_SHA_EXECUTED"
EOF
echo "deadbeef00000000000000000000000000000000000000000000000000000  shani-deploy.sh" > "$URLDIR/shani-deploy.sh.sha256"
gpg --batch --yes --local-user "$TEST_FPR" --detach-sign --armor -o "$URLDIR/shani-deploy.sh.asc" "$URLDIR/shani-deploy.sh" 2>/dev/null

OUT_A=$(run_shani_deploy)
echo "$OUT_A" > "$WORKDIR/out-A.log"
if echo "$OUT_A" | grep -qi "SHA256 checksum mismatch" && ! echo "$OUT_A" | grep -q "SELFUPDATE_REJECT_BAD_SHA_EXECUTED"; then
    if cmp -s /usr/local/bin/shani-deploy "$WORKDIR/shani-deploy.golden"; then
        pass "Scenario A (bad SHA256): self_update rejected, /usr/local/bin/shani-deploy left untouched"
    else
        fail "Scenario A: /usr/local/bin/shani-deploy WAS MODIFIED despite bad SHA256!"
    fi
else
    fail "Scenario A: expected SHA256-mismatch rejection log line not seen (see $WORKDIR/out-A.log)"
fi
echo "--- tail of scenario A output ---"; echo "$OUT_A" | grep -iE "sha256|self-update|SELFUPDATE" | tail -10

echo ""
echo "########## Scenario B: correct SHA256, corrupt/invalid GPG signature ##########"
cat > "$URLDIR/shani-deploy.sh" <<'EOF'
#!/bin/bash
# shanios-deploy REJECT-BAD-SIG test payload
echo "SELFUPDATE_REJECT_BAD_SIG_EXECUTED"
EOF
sha256sum "$URLDIR/shani-deploy.sh" | awk '{print $1"  shani-deploy.sh"}' > "$URLDIR/shani-deploy.sh.sha256"
{
  echo "-----BEGIN PGP SIGNATURE-----"
  echo ""
  echo "Q29ycnVwdGVkTm90QVJlYWxTaWduYXR1cmVBdEFsbA=="
  echo "-----END PGP SIGNATURE-----"
} > "$URLDIR/shani-deploy.sh.asc"

OUT_B=$(run_shani_deploy)
echo "$OUT_B" > "$WORKDIR/out-B.log"
if echo "$OUT_B" | grep -qi "GPG signature verification failed" && ! echo "$OUT_B" | grep -q "SELFUPDATE_REJECT_BAD_SIG_EXECUTED"; then
    if cmp -s /usr/local/bin/shani-deploy "$WORKDIR/shani-deploy.golden"; then
        pass "Scenario B (bad GPG signature): self_update rejected, /usr/local/bin/shani-deploy left untouched"
    else
        fail "Scenario B: /usr/local/bin/shani-deploy WAS MODIFIED despite bad signature!"
    fi
else
    fail "Scenario B: expected GPG-verification-failed rejection log line not seen (see $WORKDIR/out-B.log)"
fi
echo "--- tail of scenario B output ---"; echo "$OUT_B" | grep -iE "gpg|self-update|SELFUPDATE" | tail -10

echo ""
echo "########## Scenario C: valid SHA256 AND valid GPG signature -> should be exec'd ##########"
cat > "$URLDIR/shani-deploy.sh" <<'EOF'
#!/bin/bash
# shanios-deploy ACCEPT test payload
echo "SELFUPDATE_ACCEPT_EXECUTED_MARKER"
exit 0
EOF
sha256sum "$URLDIR/shani-deploy.sh" | awk '{print $1"  shani-deploy.sh"}' > "$URLDIR/shani-deploy.sh.sha256"
gpg --batch --yes --local-user "$TEST_FPR" --detach-sign --armor -o "$URLDIR/shani-deploy.sh.asc" "$URLDIR/shani-deploy.sh" 2>/dev/null

OUT_C=$(run_shani_deploy)
echo "$OUT_C" > "$WORKDIR/out-C.log"
if echo "$OUT_C" | grep -qi "signature-verified" && echo "$OUT_C" | grep -q "SELFUPDATE_ACCEPT_EXECUTED_MARKER"; then
    pass "Scenario C (valid SHA256+GPG): self_update accepted and the downloaded script was actually exec'd"
else
    fail "Scenario C: expected accept+exec markers not seen (see $WORKDIR/out-C.log)"
fi
echo "--- tail of scenario C output ---"; echo "$OUT_C" | grep -iE "signature-verified|SELFUPDATE|self-update" | tail -10

echo ""
echo "=== Cleanup ==="
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
if [[ -f "$WORKDIR/signing.asc.orig" ]]; then
    cp "$WORKDIR/signing.asc.orig" /etc/shani-keys/signing.asc
else
    rm -f /etc/shani-keys/signing.asc
fi
sed -i '/raw\.githubusercontent\.com/d' /etc/hosts

echo ""
echo "=== SELF_UPDATE TEST SUMMARY: FAIL=$FAIL ==="
exit "$FAIL"
