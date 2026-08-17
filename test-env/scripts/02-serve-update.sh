#!/bin/bash
# 02-serve-update.sh [port]
#
# The real remote layout (see shani-deploy.sh: r2_path="<profile>/<channel>.txt",
# r2_image_path="<profile>/<version>/<image>") and this repo's own build output
# (see upload.sh: R2_SUBPATH="${PROFILE}/${RESOLVED_DATE}", i.e. OUTPUT_DIR
# from config.sh) are IDENTICAL — so unlike a from-scratch fake mirror, there
# is nothing to stage or reshape here. We just serve OUTPUT_DIR exactly as-is,
# over real HTTPS using the throwaway CA from 00b-generate-test-ca.sh.
#
# Requires:
#   - downloads.shani.dev resolving to this container (run_in_container.sh's
#     --add-host, or the slot's bound-in /etc/hosts — see 03-enter-slot.sh)
#   - the test CA trust-anchored inside @blue/@green (done by
#     01-bootstrap-rootfs.sh at receive time)
#   - <profile>/<channel>.txt to actually exist under OUTPUT_DIR, i.e. you've
#     run ./build.sh release -p <profile> latest (or "stable") at least once
#     for the profile you're testing
#
# Serves on 0.0.0.0:${1:-443} (443 by default — R2_BASE_URL has no port).
# Run this in its own terminal/session — it blocks in the foreground.
set -euo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../../config/config.sh"

PORT="${1:-443}"
DATA_DIR="${SHANIOS_TEST_DATA:-${SCRIPT_DIR}/../disk}"
CA_DIR="${DATA_DIR}/ca"

[[ -f "${CA_DIR}/server.crt" && -f "${CA_DIR}/server.key" ]] \
    || die "Server cert not found under ${CA_DIR} — run 00b-generate-test-ca.sh first."
[[ -d "$OUTPUT_DIR" ]] \
    || die "${OUTPUT_DIR} not found."

log "Serving ${OUTPUT_DIR} on https://0.0.0.0:${PORT} (CN=downloads.shani.dev)"
log "Available profiles: $(find "$OUTPUT_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f ' 2>/dev/null)"

cd "$OUTPUT_DIR" && exec python3 - "$PORT" "${CA_DIR}/server.crt" "${CA_DIR}/server.key" <<'PYEOF'
import http.server, ssl, sys

port, certfile, keyfile = sys.argv[1], sys.argv[2], sys.argv[3]

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("  " + (fmt % args) + "\n")

httpd = http.server.HTTPServer(("0.0.0.0", int(port)), QuietHandler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile=certfile, keyfile=keyfile)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PYEOF
