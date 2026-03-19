#!/bin/bash
# create-keys.sh — Generate MOK keypair for ShaniOS Secure Boot.
#
# Writes MOK.key, MOK.crt, and MOK.der to the current directory.
# Copy them to /etc/secureboot/keys/ before running gen-efi:
#
#   sudo mkdir -p /etc/secureboot/keys
#   sudo cp MOK.key MOK.crt MOK.der /etc/secureboot/keys/
#   sudo chmod 0600 /etc/secureboot/keys/MOK.key
#   gen-efi enroll-mok
#
# Must be run as root (needed for openssl key generation).

set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root." >&2
    exit 1
fi

echo "🔑 Generating MOK keypair in $(pwd)..."

openssl req -newkey rsa:2048 -nodes \
    -keyout MOK.key \
    -new -x509 -sha256 -days 3650 \
    -out MOK.crt \
    -subj "/CN=Shani OS Secure Boot Key/" \
    || { echo "ERROR: openssl key generation failed" >&2; exit 1; }

openssl x509 -in MOK.crt -outform DER -out MOK.der \
    || { echo "ERROR: DER export failed" >&2; exit 1; }

# Validate the DER — a corrupt file causes mokutil to abort at enrollment time
openssl x509 -in MOK.der -inform DER -noout \
    || { echo "ERROR: MOK.der validation failed" >&2; exit 1; }

echo "✅ Secure Boot keys ready:"
echo "   $(pwd)/MOK.key  (private — keep secret)"
echo "   $(pwd)/MOK.crt"
echo "   $(pwd)/MOK.der"
echo ""
echo "Next: copy to /etc/secureboot/keys/ then run: gen-efi enroll-mok"
