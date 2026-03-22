#!/bin/bash
# create-mok-keys.sh — Generate MOK keypair for ShaniOS Secure Boot.
#
# Writes MOK.key, MOK.crt, MOK.der, and github-secrets.env to ./mok/ subdir.
# If mok/MOK.key, mok/MOK.crt, mok/MOK.der already exist, skips key generation
# and only (re)creates mok/github-secrets.env from the existing files.
#
# Copy keys to /etc/secureboot/keys/ before running gen-efi:
#
#   sudo mkdir -p /etc/secureboot/keys
#   sudo cp mok/MOK.key mok/MOK.crt mok/MOK.der /etc/secureboot/keys/
#   sudo chmod 0600 /etc/secureboot/keys/MOK.key
#   gen-efi enroll-mok

set -Eeuo pipefail

OUTPUT_DIR="mok"
MOK_KEY="${OUTPUT_DIR}/MOK.key"
MOK_CRT="${OUTPUT_DIR}/MOK.crt"
MOK_DER="${OUTPUT_DIR}/MOK.der"
ENV_FILE="${OUTPUT_DIR}/github-mok-secrets.env"

# ── Ensure output directory exists ───────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
chmod 0700 "$OUTPUT_DIR"

# ── Key generation (skip if all three files already exist) ────────────────────
if [[ -f "$MOK_KEY" && -f "$MOK_CRT" && -f "$MOK_DER" ]]; then
    echo "ℹ️  ${MOK_KEY}, ${MOK_CRT}, ${MOK_DER} already exist — skipping key generation."
    echo "   Regenerating ${MOK_DER} and ${ENV_FILE} from existing key files..."

    openssl x509 -in "$MOK_CRT" -outform DER -out "$MOK_DER" \
        || { echo "ERROR: DER export failed" >&2; exit 1; }
    openssl x509 -in "$MOK_DER" -inform DER -noout \
        || { echo "ERROR: MOK.der validation failed" >&2; exit 1; }
    echo "   ✅ ${MOK_DER} regenerated."
else
    echo "🔑 Generating MOK keypair in $(pwd)/${OUTPUT_DIR}/..."

    openssl req -newkey rsa:2048 -nodes \
        -keyout "$MOK_KEY" \
        -new -x509 -sha256 -days 3650 \
        -out "$MOK_CRT" \
        -subj "/CN=Shani OS Secure Boot Key/" \
        || { echo "ERROR: openssl key generation failed" >&2; exit 1; }

    openssl x509 -in "$MOK_CRT" -outform DER -out "$MOK_DER" \
        || { echo "ERROR: DER export failed" >&2; exit 1; }

    # Validate the DER — a corrupt file causes mokutil to abort at enrollment time
    openssl x509 -in "$MOK_DER" -inform DER -noout \
        || { echo "ERROR: MOK.der validation failed" >&2; exit 1; }

    chmod 0600 "$MOK_KEY"

    echo "✅ Secure Boot keys ready:"
    echo "   $(pwd)/${MOK_KEY}  (private — keep secret)"
    echo "   $(pwd)/${MOK_CRT}"
    echo "   $(pwd)/${MOK_DER}"
fi

# ── Build github-secrets.env ──────────────────────────────────────────────────
MOK_KEY_VAL=$(cat "$MOK_KEY")
MOK_CRT_VAL=$(cat "$MOK_CRT")
MOK_DER_B64_VAL=$(base64 -w 0 "$MOK_DER")

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
echo "   shred -u ${MOK_KEY} ${MOK_CRT} ${MOK_DER} ${ENV_FILE}"
echo "   rmdir ${OUTPUT_DIR} 2>/dev/null || true"
echo ""
echo "Next: copy to /etc/secureboot/keys/ then run: gen-efi enroll-mok"
