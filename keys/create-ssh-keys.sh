#!/usr/bin/env bash
# create-ssh-keys.sh — Generate an ED25519 SSH keypair for ShaniOS CI/CD.
#
# Produces (in ./ssh/):
#   ssh/ssh-private            Private key  (SSH_PRIVATE_KEY secret)
#   ssh/ssh-public             Public key   (add to target servers / deploy keys)
#   ssh/github-ssh-secrets.env Values ready to paste into GitHub Actions secrets
#
# Usage:
#   bash create-ssh-keys.sh                        # generate keys + write env
#   bash create-ssh-keys.sh --upload               # same, then upload to all platforms
#   bash create-ssh-keys.sh --upload=github        # upload to GitHub only
#   bash create-ssh-keys.sh --upload=gitlab        # upload to GitLab only
#   bash create-ssh-keys.sh --upload=sourceforge   # upload to SourceForge only
#
# Each platform will prompt for its credentials when selected.
# If ssh/ssh-private already exists, key generation is skipped and only
# ssh/github-ssh-secrets.env is regenerated.

set -Eeuo pipefail

# ── Parse arguments ───────────────────────────────────────────────────────────
UPLOAD_TARGETS=()
for arg in "$@"; do
    case "$arg" in
        --upload)              UPLOAD_TARGETS=(github gitlab sourceforge) ;;
        --upload=github)       UPLOAD_TARGETS=(github) ;;
        --upload=gitlab)       UPLOAD_TARGETS=(gitlab) ;;
        --upload=sourceforge)  UPLOAD_TARGETS=(sourceforge) ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# ── Upload functions ──────────────────────────────────────────────────────────

upload_github() {
    local pubkey="$1"
    echo ""
    echo "── GitHub ───────────────────────────────────────────────────────────────────"
    read -rp  "  GitHub username: " GH_USER
    read -rsp "  GitHub personal access token (scope: admin:public_key): " GH_TOKEN; echo
    read -rp  "  Key title [ShaniOS CI]: " GH_TITLE
    GH_TITLE="${GH_TITLE:-ShaniOS CI}"

    local payload
    payload=$(printf '{"title":"%s","key":"%s"}' "$GH_TITLE" "$(cat "$pubkey")")

    local http_code
    http_code=$(curl -s -o /tmp/gh_upload_resp.json -w "%{http_code}" \
        -X POST "https://api.github.com/user/keys" \
        -u "${GH_USER}:${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if [[ "$http_code" == "201" ]]; then
        local key_id
        key_id=$(grep -o '"id":[0-9]*' /tmp/gh_upload_resp.json | head -1 | cut -d: -f2)
        echo "  ✅ Uploaded. Key ID: ${key_id}"
        echo "     https://github.com/settings/keys"
    else
        echo "  ❌ Failed (HTTP ${http_code})"
        cat /tmp/gh_upload_resp.json 2>/dev/null && echo
    fi
    rm -f /tmp/gh_upload_resp.json
}

upload_gitlab() {
    local pubkey="$1"
    echo ""
    echo "── GitLab ───────────────────────────────────────────────────────────────────"
    read -rp  "  GitLab instance URL [https://gitlab.com]: " GL_URL
    GL_URL="${GL_URL:-https://gitlab.com}"
    read -rsp "  GitLab personal access token (scope: api): " GL_TOKEN; echo
    read -rp  "  Key title [ShaniOS CI]: " GL_TITLE
    GL_TITLE="${GL_TITLE:-ShaniOS CI}"

    local http_code
    http_code=$(curl -s -o /tmp/gl_upload_resp.json -w "%{http_code}" \
        -X POST "${GL_URL}/api/v4/user/keys" \
        -H "PRIVATE-TOKEN: ${GL_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"${GL_TITLE}\",\"key\":\"$(cat "$pubkey")\"}")

    if [[ "$http_code" == "201" ]]; then
        local key_id
        key_id=$(grep -o '"id":[0-9]*' /tmp/gl_upload_resp.json | head -1 | cut -d: -f2)
        echo "  ✅ Uploaded. Key ID: ${key_id}"
        echo "     ${GL_URL}/-/profile/keys"
    else
        echo "  ❌ Failed (HTTP ${http_code})"
        cat /tmp/gl_upload_resp.json 2>/dev/null && echo
    fi
    rm -f /tmp/gl_upload_resp.json
}

upload_sourceforge() {
    local pubkey="$1"
    echo ""
    echo "── SourceForge ──────────────────────────────────────────────────────────────"
    echo "  SourceForge does not provide an API for SSH key upload."
    echo "  Add the key manually:"
    echo "    1. Go to https://sourceforge.net/auth/preferences/"
    echo "    2. Under 'SSH Public Keys', paste the contents of:"
    echo "       $(pwd)/${pubkey}"
    echo ""
    echo "  Public key:"
    cat "$pubkey"
}

KEY_COMMENT="shani-os-ci@shani.dev"
KEY_TYPE="ed25519"

OUTPUT_DIR="ssh"
PRIVATE_KEY_FILE="${OUTPUT_DIR}/ssh-private"
PUBLIC_KEY_FILE="${OUTPUT_DIR}/ssh-public.pub"
ENV_FILE="${OUTPUT_DIR}/github-ssh-secrets.env"

# ── Ensure output directory exists ────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
chmod 0700 "$OUTPUT_DIR"

# ── Prompt for optional passphrase ────────────────────────────────────────────
if [[ -f "$PRIVATE_KEY_FILE" ]]; then
    echo "ℹ️  $PRIVATE_KEY_FILE already exists — skipping key generation."
    echo "   Regenerating ${ENV_FILE} from existing key files..."
    SSH_PASSPHRASE=""
else
    echo "🔑 Generating ED25519 SSH keypair..."
    echo "   Comment : ${KEY_COMMENT}"
    echo "   Output  : $(pwd)/${OUTPUT_DIR}/"
    echo ""

    SSH_PASSPHRASE=""

    # ssh-keygen always writes the public key as <private>.pub; rename afterward
    ssh-keygen \
        -t "$KEY_TYPE" \
        -C "$KEY_COMMENT" \
        -f "$PRIVATE_KEY_FILE" \
        -N "$SSH_PASSPHRASE" \
        || { echo "ERROR: ssh-keygen failed" >&2; exit 1; }

    mv "${PRIVATE_KEY_FILE}.pub" "$PUBLIC_KEY_FILE"

    chmod 0600 "$PRIVATE_KEY_FILE"
    chmod 0644 "$PUBLIC_KEY_FILE"

    echo ""
    echo "✅ SSH keypair written:"
    echo "   $(pwd)/${PRIVATE_KEY_FILE}  (private — keep secret)"
    echo "   $(pwd)/${PUBLIC_KEY_FILE}"
fi

# ── Build github-ssh-secrets.env ──────────────────────────────────────────────
SSH_PRIVATE_KEY_VAL=$(cat "$PRIVATE_KEY_FILE")
SSH_PUBLIC_KEY_VAL=$(cat "$PUBLIC_KEY_FILE")

{
    echo "# GitHub Actions secrets for ShaniOS SSH access"
    echo "# Add each value at: Settings → Secrets and variables → Actions → New repository secret"
    echo "# Delete this file after uploading the secrets."
    echo ""
    echo "# ── Paste into GitHub secrets ───────────────────────────────────────────────"
    echo ""
    echo "SSH_PRIVATE_KEY<<EOF_VAL"
    echo "${SSH_PRIVATE_KEY_VAL}"
    echo "EOF_VAL"
    echo ""
    echo "SSH_PASSPHRASE=${SSH_PASSPHRASE}"
    echo ""
    echo "# ── Add public key to target servers / GitHub Deploy Keys ───────────────────"
    echo "# Paste the line below into ~/.ssh/authorized_keys on each target host, or"
    echo "# add it as a GitHub Deploy Key at: Settings → Deploy keys → Add deploy key"
    echo ""
    echo "SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY_VAL}"
} > "$ENV_FILE"

chmod 0600 "$ENV_FILE"

echo ""
echo "📄 GitHub secrets written to: $(pwd)/${ENV_FILE}"
echo ""
echo "Next steps:"
echo "  1. Add SSH_PRIVATE_KEY (and SSH_PASSPHRASE if set) to GitHub Actions secrets"
echo "     (values are in ${ENV_FILE})"
echo ""
echo "  2. Authorize the public key on each target host:"
echo "       ssh-copy-id -i ${PUBLIC_KEY_FILE} user@host"
echo "     Or paste $(pwd)/${PUBLIC_KEY_FILE} into GitHub → Settings → Deploy keys"
echo ""
echo "  3. Reference in your workflow:"
echo "       - uses: webfactory/ssh-agent@v0.9.0"
echo "         with:"
echo "           ssh-private-key: \${{ secrets.SSH_PRIVATE_KEY }}"
echo ""
echo "  4. When done, shred all key files:"
echo "       shred -u ${PRIVATE_KEY_FILE} ${ENV_FILE}"
echo "       rm -f ${PUBLIC_KEY_FILE}"
echo "       rmdir ${OUTPUT_DIR} 2>/dev/null || true"

# ── Optional: upload public key to platforms ──────────────────────────────────
if [[ ${#UPLOAD_TARGETS[@]} -gt 0 ]]; then
    echo ""
    echo "🌐 Uploading public key to: ${UPLOAD_TARGETS[*]}"
    for target in "${UPLOAD_TARGETS[@]}"; do
        case "$target" in
            github)      upload_github      "$PUBLIC_KEY_FILE" ;;
            gitlab)      upload_gitlab      "$PUBLIC_KEY_FILE" ;;
            sourceforge) upload_sourceforge "$PUBLIC_KEY_FILE" ;;
        esac
    done
    echo ""
    echo "✅ Upload step complete."
fi
