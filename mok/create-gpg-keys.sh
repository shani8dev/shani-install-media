#!/usr/bin/env bash
# create-gpg-key.sh — Generate a GPG signing key for Shani OS artifact signing.
#
# Produces:
#   gpg-private.asc       Armored private key  (GPG_PRIVATE_KEY secret)
#   gpg-public.asc        Armored public key   (embed in base image as signing.asc)
#   github-gpg-secrets.env Values ready to paste into GitHub Actions secrets
#
# The key fingerprint is printed at the end — update GPG_KEY_ID in config/config.sh
# with that value before running any builds.
#
# Usage:
#   cd mok/          # or any directory — files are written to the current directory
#   bash create-gpg-key.sh
#
# If gpg-private.asc already exists, key generation is skipped and only
# github-gpg-secrets.env is regenerated from the existing files.

set -Eeuo pipefail

KEY_NAME="Shani OS"
KEY_EMAIL="shani@shani.dev"
KEY_COMMENT="Shani OS Artifact Signing Key"
KEY_TYPE="RSA"
KEY_LENGTH="4096"
KEY_EXPIRE="5y"

PRIVATE_KEY_FILE="gpg-private.asc"
PUBLIC_KEY_FILE="gpg-public.asc"
ENV_FILE="github-gpg-secrets.env"

# ── Prompt for passphrase ─────────────────────────────────────────────────────
if [[ -f "$PRIVATE_KEY_FILE" ]]; then
    echo "ℹ️  $PRIVATE_KEY_FILE already exists — skipping key generation."
    echo "   Reading passphrase to regenerate ${ENV_FILE}..."
    read -rsp "Enter the existing GPG key passphrase: " GPG_PASSPHRASE
    echo
else
    echo "🔑 Generating GPG signing key..."
    echo "   Name    : ${KEY_NAME}"
    echo "   Email   : ${KEY_EMAIL}"
    echo "   Type    : ${KEY_TYPE} ${KEY_LENGTH}-bit"
    echo "   Expires : ${KEY_EXPIRE}"
    echo ""

    while true; do
        read -rsp "Enter passphrase for the new key: " GPG_PASSPHRASE; echo
        read -rsp "Confirm passphrase: "               GPG_PASSPHRASE2; echo
        [[ "$GPG_PASSPHRASE" == "$GPG_PASSPHRASE2" ]] && break
        echo "❌ Passphrases do not match. Try again."
    done

    # Use a temporary isolated GNUPGHOME so we don't pollute the user's keyring
    TMPGNUPG="$(mktemp -d)"
    chmod 700 "$TMPGNUPG"
    trap 'rm -rf "$TMPGNUPG"' EXIT

    # Generate the key in batch mode
    gpg --homedir "$TMPGNUPG" --batch --gen-key <<EOF
%no-protection
Key-Type: ${KEY_TYPE}
Key-Length: ${KEY_LENGTH}
Subkey-Type: ${KEY_TYPE}
Subkey-Length: ${KEY_LENGTH}
Name-Real: ${KEY_NAME}
Name-Comment: ${KEY_COMMENT}
Name-Email: ${KEY_EMAIL}
Expire-Date: ${KEY_EXPIRE}
Passphrase: ${GPG_PASSPHRASE}
%commit
EOF

    # Get the fingerprint of the newly created key
    FINGERPRINT=$(gpg --homedir "$TMPGNUPG" --list-keys --with-colons "${KEY_EMAIL}" \
        | awk -F: '/^fpr/{print $10; exit}')

    [[ -n "$FINGERPRINT" ]] || { echo "ERROR: could not read key fingerprint" >&2; exit 1; }

    echo ""
    echo "✅ Key generated. Fingerprint: ${FINGERPRINT}"

    # Export armored private key (passphrase-protected)
    gpg --homedir "$TMPGNUPG" \
        --batch --yes \
        --pinentry-mode loopback \
        --passphrase "$GPG_PASSPHRASE" \
        --armor --export-secret-keys "$FINGERPRINT" > "$PRIVATE_KEY_FILE" \
        || { echo "ERROR: private key export failed" >&2; exit 1; }

    # Export armored public key
    gpg --homedir "$TMPGNUPG" \
        --armor --export "$FINGERPRINT" > "$PUBLIC_KEY_FILE" \
        || { echo "ERROR: public key export failed" >&2; exit 1; }

    chmod 0600 "$PRIVATE_KEY_FILE"

    echo ""
    echo "✅ Key files written:"
    echo "   $(pwd)/${PRIVATE_KEY_FILE}  (private — keep secret)"
    echo "   $(pwd)/${PUBLIC_KEY_FILE}"
    echo ""
    echo "⚠️  Update GPG_KEY_ID in config/config.sh:"
    echo "   GPG_KEY_ID=\"${FINGERPRINT}\""
fi

# ── Read fingerprint from existing private key (skip-generation path) ─────────
if [[ -z "${FINGERPRINT:-}" ]]; then
    TMPGNUPG="$(mktemp -d)"
    chmod 700 "$TMPGNUPG"
    trap 'rm -rf "$TMPGNUPG"' EXIT

    gpg --homedir "$TMPGNUPG" \
        --batch --yes \
        --pinentry-mode loopback \
        --passphrase "$GPG_PASSPHRASE" \
        --import "$PRIVATE_KEY_FILE" >/dev/null 2>&1 \
        || { echo "ERROR: could not import $PRIVATE_KEY_FILE (wrong passphrase?)" >&2; exit 1; }

    FINGERPRINT=$(gpg --homedir "$TMPGNUPG" --list-keys --with-colons \
        | awk -F: '/^fpr/{print $10; exit}')

    [[ -n "$FINGERPRINT" ]] || { echo "ERROR: could not read fingerprint" >&2; exit 1; }
    echo "   Fingerprint: ${FINGERPRINT}"
fi

# ── Build github-gpg-secrets.env ──────────────────────────────────────────────
GPG_PRIVATE_KEY_VAL=$(cat "$PRIVATE_KEY_FILE")
GPG_PUBLIC_KEY_VAL=$(cat "$PUBLIC_KEY_FILE")

{
    echo "# GitHub Actions secrets for Shani OS GPG artifact signing"
    echo "# Add each value at: Settings → Secrets and variables → Actions → New repository secret"
    echo "# Delete this file after uploading the secrets."
    echo ""
    echo "# ── Paste into GitHub secrets ───────────────────────────────────────────────"
    echo ""
    echo "GPG_PRIVATE_KEY<<EOF_VAL"
    echo "${GPG_PRIVATE_KEY_VAL}"
    echo "EOF_VAL"
    echo ""
    echo "GPG_PASSPHRASE=${GPG_PASSPHRASE}"
    echo "GPG_KEY_ID=${FINGERPRINT}"
    echo ""
    echo "# ── Update config/config.sh ─────────────────────────────────────────────────"
    echo ""
    echo "# GPG_KEY_ID=\"${FINGERPRINT}\""
    echo ""
    echo "# ── Embed public key in base image ──────────────────────────────────────────"
    echo "# Copy ${PUBLIC_KEY_FILE} to:"
    echo "#   image_profiles/shared/overlay/rootfs/etc/shani-keys/signing.asc"
    echo "# This is imported into the base image during build-base-image.sh"
    echo ""
    echo "GPG_PUBLIC_KEY<<EOF_VAL"
    echo "${GPG_PUBLIC_KEY_VAL}"
    echo "EOF_VAL"
} > "$ENV_FILE"

chmod 0600 "$ENV_FILE"

echo ""
echo "📄 GitHub secrets written to: $(pwd)/${ENV_FILE}"
echo ""
echo "Next steps:"
echo "  1. Update config/config.sh:"
echo "       GPG_KEY_ID=\"${FINGERPRINT}\""
echo ""
echo "  2. Copy the public key into the overlay so it gets embedded in the base image:"
echo "       cp ${PUBLIC_KEY_FILE} ../image_profiles/shared/overlay/rootfs/etc/shani-keys/signing.asc"
echo ""
echo "  3. Add GPG_PRIVATE_KEY and GPG_PASSPHRASE to GitHub Actions secrets"
echo "     (values are in ${ENV_FILE})"
echo ""
echo "  4. When done, shred all key files:"
echo "       shred -u ${PRIVATE_KEY_FILE} ${PUBLIC_KEY_FILE} ${ENV_FILE}"
