#!/bin/bash
# 00b-generate-test-ca.sh
#
# Generates a throwaway CA + leaf certificate for CN=downloads.shani.dev,
# used ONLY inside this test rig so the real, unmodified shani-deploy
# package (already inside the received image — see 01-bootstrap-rootfs.sh)
# can hit our local mirror over a real HTTPS connection, exactly as it would
# hit the real domain in production. See run_in_container.sh (--add-host)
# for the DNS half of this, and 02-serve-update.sh for the server itself.
#
# The CA is trust-anchored INSIDE each slot (@blue/@green) by
# 01-bootstrap-rootfs.sh at receive time — never on the host, never in the
# original .zst, and never in any repo. It's the one deliberate, documented
# on-disk change this harness makes to a received image; see README.
set -euo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../../config/config.sh"

DATA_DIR="${SHANIOS_TEST_DATA:-${SCRIPT_DIR}/../disk}"
CA_DIR="${DATA_DIR}/ca"
mkdir -p "$CA_DIR"

if [[ -f "${CA_DIR}/ca.crt" && -f "${CA_DIR}/server.crt" && -f "${CA_DIR}/server.key" ]]; then
    log "Test CA + server cert already exist under ${CA_DIR} — reusing (delete the dir to regenerate)."
    exit 0
fi

log "Generating throwaway CA + server cert for downloads.shani.dev ..."

openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "${CA_DIR}/ca.key" -out "${CA_DIR}/ca.crt" \
    -subj "/CN=shanios-test-env local CA (NOT FOR PRODUCTION)"

openssl req -newkey rsa:2048 -nodes \
    -keyout "${CA_DIR}/server.key" -out "${CA_DIR}/server.csr" \
    -subj "/CN=downloads.shani.dev"

openssl x509 -req -in "${CA_DIR}/server.csr" -sha256 -days 3650 \
    -CA "${CA_DIR}/ca.crt" -CAkey "${CA_DIR}/ca.key" -CAcreateserial \
    -out "${CA_DIR}/server.crt" \
    -extfile <(printf "subjectAltName=DNS:downloads.shani.dev")

rm -f "${CA_DIR}/server.csr" "${CA_DIR}/ca.srl"
chmod 644 "${CA_DIR}/ca.crt" "${CA_DIR}/server.crt"
chmod 600 "${CA_DIR}/ca.key" "${CA_DIR}/server.key"

log "Done. CA + server cert written under ${CA_DIR} (persists across runs)."
