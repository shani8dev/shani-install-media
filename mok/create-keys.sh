#!/bin/bash
# create-keys.sh — Generate MOK keypair for ShaniOS Secure Boot.
#
# Writes MOK.key, MOK.crt, MOK.der, and github-secrets.env to the current directory.
# If MOK.key/MOK.crt/MOK.der already exist, skips key generation and only
# (re)creates github-secrets.env from the existing files.
#
# Copy keys to /etc/secureboot/keys/ before running gen-efi:
#
#   sudo mkdir -p /etc/secureboot/keys
#   sudo cp MOK.key MOK.crt MOK.der /etc/secureboot/keys/
#   sudo chmod 0600 /etc/secureboot/keys/MOK.key
#   gen-efi enroll-mok

set -Eeuo pipefail

# ── Key generation (skip if all three files already exist) ────────────────────
if [[ -f MOK.key && -f MOK.crt && -f MOK.der ]]; then
    echo "ℹ️  MOK.key, MOK.crt, MOK.der already exist — skipping key generation."
else
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

    chmod 0600 MOK.key

    echo "✅ Secure Boot keys ready:"
    echo "   $(pwd)/MOK.key  (private — keep secret)"
    echo "   $(pwd)/MOK.crt"
    echo "   $(pwd)/MOK.der"
fi

# ── Build github-secrets.env ──────────────────────────────────────────────────
ENV_FILE="github-secrets.env"

MOK_KEY_VAL=$(cat MOK.key)
MOK_CRT_VAL=$(cat MOK.crt)
MOK_DER_B64_VAL=$(base64 -w 0 MOK.der)

{
  echo "# GitHub Actions secrets for ShaniOS Secure Boot"
  echo "# Add each value at: Settings → Secrets and variables → Actions → New repository secret"
  echo "# Delete this file after uploading the secrets."
  echo ""
  echo "MOK_KEY<<EOF_VAL"
  echo "${MOK_KEY_VAL}"
  echo "EOF_VAL"
  echo ""
  echo "MOK_CRT<<EOF_VAL"
  echo "${MOK_CRT_VAL}"
  echo "EOF_VAL"
  echo ""
  echo "MOK_DER_B64=${MOK_DER_B64_VAL}"
} > "${ENV_FILE}"

chmod 0600 "${ENV_FILE}"

echo ""
echo "📄 GitHub secrets written to: $(pwd)/${ENV_FILE}"
echo "   → Open it, copy each value into GitHub Actions secrets, then delete it."
echo ""
echo "⚠️  When done, shred all key files:"
echo "   shred -u MOK.key MOK.crt MOK.der ${ENV_FILE}"
echo ""
echo "Next: copy to /etc/secureboot/keys/ then run: gen-efi enroll-mok"
