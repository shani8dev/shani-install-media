#!/bin/bash
# run_in_container.sh — Docker/Podman wrapper to run a build command inside the builder container
set -Eeuo pipefail

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <command> [args...]"
    exit 1
fi

# Use BASH_SOURCE (symlink-aware) so bind-mounts resolve to the calling repo
HOST_WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Load .env if present — sets credentials and optional overrides like DOCKER_IMAGE,
# CUSTOM_MIRROR, NO_SF, NO_R2, BUILD_DATE, R2_BUCKET, etc.
if [ -f "${HOST_WORK_DIR}/.env" ]; then
    echo "Sourcing environment file: ${HOST_WORK_DIR}/.env"
    set +u
    # shellcheck disable=SC1090
    source "${HOST_WORK_DIR}/.env"
    set -u
fi

# ---------------------------------------------------------------------------
# Host-side cache directories (bind-mounted into the container for reuse
# between runs so pacman/flatpak/snap don't re-download everything each time)
# ---------------------------------------------------------------------------
HOST_OSI_CONFIG_DIR="${SHANIOS_TEST_OSI_HOST_DIR:-$(realpath -m "${HOST_WORK_DIR}/../os-installer-config")}"
HOST_PACMAN_CACHE="${HOST_WORK_DIR}/cache/pacman_cache"
HOST_FLATPAK_DATA="${HOST_WORK_DIR}/cache/flatpak_data"
HOST_SNAPD_DATA="${HOST_WORK_DIR}/cache/snapd_data"
HOST_SNAPD_SEED="${HOST_WORK_DIR}/cache/snapd_seed"
# Same reuse-between-runs purpose as the caches above, but for
# shani-deploy's own downloaded update images (test-env/test.sh binds this
# over /data/downloads inside the nspawn slot — see _nspawn_binds) —
# without it, a full cmd_bootstrap/cmd_install re-run wipes install.img's
# @data subvolume (and any in-progress or completed download on it) from
# scratch, forcing a full multi-GB re-download every time.
HOST_DOWNLOAD_CACHE="${HOST_WORK_DIR}/cache/download_cache"
mkdir -p "${HOST_PACMAN_CACHE}" "${HOST_FLATPAK_DATA}" "${HOST_SNAPD_DATA}" "${HOST_SNAPD_SEED}" "${HOST_DOWNLOAD_CACHE}"
chmod 755 "${HOST_FLATPAK_DATA}"   # flatpak creates as 750
chmod 755 "${HOST_SNAPD_DATA}"     # snapd may do the same
chmod 755 "${HOST_SNAPD_SEED}"     # snap seed dir
chmod 755 "${HOST_PACMAN_CACHE}"   # pacman cache, less likely but consistent
chmod 755 "${HOST_DOWNLOAD_CACHE}" 2>/dev/null || true   # no-op if a prior root-owned container write took ownership; 755 is already what's wanted

# ---------------------------------------------------------------------------
# Container paths (fixed — must match the Dockerfile)
# ---------------------------------------------------------------------------
CONTAINER_WORK_DIR="/home/builduser/build"
CONTAINER_GNUPGHOME="/home/builduser/.gnupg"
CONTAINER_PACMAN_CACHE="/var/cache/pacman"
CONTAINER_FLATPAK_DATA="/var/lib/flatpak"
CONTAINER_SNAPD_DATA="/var/lib/snapd"
CONTAINER_SNAPD_SEED="/tmp/snap-seed"
# test-env/test.sh's _nspawn_binds hardcodes this same path as the source
# of an additional --bind onto /data/downloads inside the nspawn slot —
# keep both in sync if this ever changes.
CONTAINER_DOWNLOAD_CACHE="/var/cache/shani-downloads"
# Fixed mount point for the sibling os-installer-config checkout (see below)
# — test-env/test.sh's cmd_install/cmd_configure look for it here first.
# MUST NOT be under /mnt: the real install.sh/configure.sh being tested
# hardcode /mnt (and /mnt/boot/efi) as their own install target and mount
# over it — a bind mount at /mnt/os-installer-config would be silently
# shadowed the moment install.sh runs, breaking a same-session cmd_configure
# call right after cmd_install (confirmed live: "os-installer-config not
# found" on the very next command in the same container invocation).
CONTAINER_OSI_CONFIG_DIR="/opt/os-installer-config"

# ---------------------------------------------------------------------------
# Detect container runtime: prefer docker, fall back to podman
# ---------------------------------------------------------------------------
if docker version &>/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
elif podman version &>/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
else
    echo "[ERROR] Neither docker nor podman is available." >&2
    exit 1
fi
DOCKER_IMAGE="${DOCKER_IMAGE:-docker.io/shrinivasvkumbhar/shani-builder}"
CUSTOM_MIRROR="${CUSTOM_MIRROR:-https://mirror.albony.in/archlinux/\$repo/os/\$arch}"

# ---------------------------------------------------------------------------
# TTY detection
# ---------------------------------------------------------------------------
if [ -t 0 ]; then
    TTY_FLAGS="-it"
else
    TTY_FLAGS="-i"
fi

# ---------------------------------------------------------------------------
# Resolve command path inside the container
# ---------------------------------------------------------------------------
CMD="$1"
shift
if [[ "$CMD" != /* ]]; then
    CMD="${CONTAINER_WORK_DIR}/${CMD}"
fi

# Build the user command string with proper bash quoting
USER_CMD=$(printf '%q ' "$CMD" "$@")

# ---------------------------------------------------------------------------
# Build the setup prefix that runs inside the container before the user command.
# Order: pacman SigLevel patch → SSH key → GPG key → rclone config → user cmd
# ---------------------------------------------------------------------------
IMPORT_KEYS_CMD=""

# Podman's gpg-agent socket handling is broken for pacman — disable sig checks
if [[ "${CONTAINER_RUNTIME}" == "podman" ]]; then
    IMPORT_KEYS_CMD="sed -i 's/^SigLevel[[:space:]]*.*/SigLevel = Never/' /etc/pacman.conf && "
fi

# SSH key — needed for SourceForge rsync uploads. Passed into the container
# base64-encoded via --env-file (see ENV_FILE below), never as a plain -e
# argument — docker run -e VAR=value lands in the process's argv, which
# /proc/<pid>/cmdline exposes to every local user via `ps aux`, not just root.
if [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
    IMPORT_KEYS_CMD+='mkdir -p ~/.ssh && \
echo "$SSH_PRIVATE_KEY_B64" | base64 -d > ~/.ssh/id_rsa && chmod 600 ~/.ssh/id_rsa && \
ssh-keyscan -H github.com sourceforge.net >> ~/.ssh/known_hosts 2>/dev/null && \
chmod 644 ~/.ssh/known_hosts && \
printf "Host *\n    StrictHostKeyChecking no\n    BatchMode yes\n" > ~/.ssh/config && '
fi

# GPG private key — needed for signing images and ISOs.
# `gpg --import` occasionally imports nothing on the first try in a brand-new
# GNUPGHOME (a gpg-agent startup race) — and `gpg --list-secret-keys` exits 0
# even with an empty keyring, so a silent failure here used to go unnoticed
# until the signing step died hours into a full build. Retry a few times and
# abort immediately (before any build work starts) if the secret key never
# actually lands in the keyring.
if [[ -n "${GPG_PRIVATE_KEY:-}" && -n "${GPG_PASSPHRASE:-}" ]]; then
    IMPORT_KEYS_CMD+="mkdir -p \"${CONTAINER_GNUPGHOME}\" && chmod 700 \"${CONTAINER_GNUPGHOME}\" && \
echo \"\$GPG_PRIVATE_KEY_B64\" | base64 -d > /tmp/gpg_private.key && \
_gpg_ok=0 && \
for _i in 1 2 3; do \
  gpg --batch --yes --pinentry-mode loopback --passphrase \"\$GPG_PASSPHRASE\" --homedir \"${CONTAINER_GNUPGHOME}\" --import /tmp/gpg_private.key; \
  if [ -n \"\$(gpg --homedir \"${CONTAINER_GNUPGHOME}\" --list-secret-keys 2>/dev/null)\" ]; then _gpg_ok=1; break; fi; \
  echo \"[run_in_container.sh] WARN: GPG import produced no secret key (attempt \$_i/3) - retrying\" >&2; \
  sleep 2; \
done && \
rm -f /tmp/gpg_private.key && \
if [ \"\$_gpg_ok\" != 1 ]; then echo \"[run_in_container.sh] FATAL: GPG_PRIVATE_KEY failed to import into the keyring after 3 attempts - aborting before the build starts.\" >&2; exit 1; fi && \
gpg --homedir \"${CONTAINER_GNUPGHOME}\" --list-secret-keys && "
fi

# rclone config for Cloudflare R2 (S3-compatible)
# R2_ACCOUNT_ID: 32-char hex Cloudflare account ID from the R2 dashboard
# no_check_bucket: skips BucketExists call which R2 does not support
#
# The heredoc terminator below is deliberately UNQUOTED (<<RCLONE_EOF, not
# <<'RCLONE_EOF') and the three R2 vars are backslash-escaped (\$R2_...) so
# the host's bash does NOT substitute their values while building this
# string — that would bake the literal secret into FINAL_CMD, which is
# itself passed as the `bash -c "..."` argument to `docker run`, exposing it
# via /proc/<pid>/cmdline just like a plain `-e VAR=secret` would. Expansion
# is deferred to the container's own bash, reading from --env-file instead.
if [[ -n "${R2_ACCESS_KEY_ID:-}" && -n "${R2_SECRET_ACCESS_KEY:-}" && -n "${R2_ACCOUNT_ID:-}" ]]; then
    IMPORT_KEYS_CMD+="mkdir -p ~/.config/rclone && cat > ~/.config/rclone/rclone.conf << RCLONE_EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = \$R2_ACCESS_KEY_ID
secret_access_key = \$R2_SECRET_ACCESS_KEY
endpoint = https://\${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
RCLONE_EOF
echo 'rclone config written for Cloudflare R2' && "
fi

FINAL_CMD="${IMPORT_KEYS_CMD}${USER_CMD}"

# ---------------------------------------------------------------------------
# Secrets env-file (never `-e VAR=value` on the docker CLI) — `docker run -e`
# arguments land in the process's argv, and /proc/<pid>/cmdline (hence `ps aux`)
# is readable by every local user by default, not just the owner. A 600-perm
# temp file read via --env-file never appears on the command line at all.
# SSH_PRIVATE_KEY/GPG_PRIVATE_KEY are base64-encoded to survive the env-file's
# one-value-per-line format (their real content is multi-line PEM/PGP blocks);
# the import commands above decode them back inside the container.
# ---------------------------------------------------------------------------
SECRETS_ENV_FILE="$(mktemp)"
chmod 600 "${SECRETS_ENV_FILE}"
trap 'rm -f "${SECRETS_ENV_FILE}"' EXIT
{
    echo "GPG_PASSPHRASE=${GPG_PASSPHRASE:-}"
    echo "R2_ACCESS_KEY_ID=${R2_ACCESS_KEY_ID:-}"
    echo "R2_SECRET_ACCESS_KEY=${R2_SECRET_ACCESS_KEY:-}"
    echo "R2_ACCOUNT_ID=${R2_ACCOUNT_ID:-}"
    # printf '%s\n', not '%s': OpenSSH's key parser rejects a private key file
    # that doesn't end in a trailing newline after the "-----END ... KEY-----"
    # line with exactly "invalid format" — and GitHub secrets frequently lose
    # that trailing newline when the key was originally copy-pasted in. Forcing
    # one here is harmless if the secret already had it (a lone trailing blank
    # line is ignored by both ssh and gpg parsers) and fixes the file if it didn't.
    [[ -n "${SSH_PRIVATE_KEY:-}" ]] && echo "SSH_PRIVATE_KEY_B64=$(printf '%s\n' "${SSH_PRIVATE_KEY}" | base64 -w0)"
    [[ -n "${GPG_PRIVATE_KEY:-}" ]] && echo "GPG_PRIVATE_KEY_B64=$(printf '%s\n' "${GPG_PRIVATE_KEY}" | base64 -w0)"
} > "${SECRETS_ENV_FILE}"

# ---------------------------------------------------------------------------
# Sibling os-installer-config checkout (optional) — bind-mounted read-only
# so test-env/test.sh's cmd_install/cmd_configure can run the REAL,
# unmodified install.sh/configure.sh from it (see test-env/README.md). Not
# every checkout of this repo has that sibling directory present (CI, a
# partial clone, someone not testing that path at all), so this is a no-op
# unless the directory actually exists on the host — same conditional
# pattern as the SSH/GPG/R2 blocks above, just a bind mount instead of a
# credential import.
# ---------------------------------------------------------------------------
OSI_MOUNT_ARGS=()
if [[ -d "${HOST_OSI_CONFIG_DIR}/scripts" ]]; then
    OSI_MOUNT_ARGS=(-v "${HOST_OSI_CONFIG_DIR}:${CONTAINER_OSI_CONFIG_DIR}:ro")
else
    echo "[run_in_container.sh] Note: no os-installer-config checkout found at ${HOST_OSI_CONFIG_DIR} — 'build.sh test install'/'configure' won't have a source to run (set SHANIOS_TEST_OSI_HOST_DIR to point elsewhere)."
fi

# ---------------------------------------------------------------------------
# Sibling shani-deploy checkout (optional) — bind-mounted read-only so
# test-env/test.sh's --local-src=<dir> (cmd_enter/cmd_upgrade/cmd_verifyboot/
# cmd_desktop) can overlay the REAL, CURRENT shani-deploy/shani-update/
# gen-efi/check-boot-failure scripts (and their systemd units) onto a slot,
# instead of only ever exercising whatever got baked into the bootstrapped
# image at build time. Same conditional/optional pattern as the
# os-installer-config bind above — a no-op unless the sibling checkout is
# actually present on the host.
# ---------------------------------------------------------------------------
HOST_SHANI_DEPLOY_DIR="${SHANIOS_TEST_DEPLOY_HOST_DIR:-$(realpath -m "${HOST_WORK_DIR}/../shani-deploy")}"
# Deliberately NOT under /mnt — see CONTAINER_OSI_CONFIG_DIR above for why.
CONTAINER_SHANI_DEPLOY_DIR="/opt/shani-deploy"
DEPLOY_MOUNT_ARGS=()
if [[ -d "${HOST_SHANI_DEPLOY_DIR}/scripts" ]]; then
    DEPLOY_MOUNT_ARGS=(-v "${HOST_SHANI_DEPLOY_DIR}:${CONTAINER_SHANI_DEPLOY_DIR}:ro")
else
    echo "[run_in_container.sh] Note: no shani-deploy checkout found at ${HOST_SHANI_DEPLOY_DIR} — --local-src=${CONTAINER_SHANI_DEPLOY_DIR}/scripts won't have a source (set SHANIOS_TEST_DEPLOY_HOST_DIR to point elsewhere)."
fi

# ---------------------------------------------------------------------------
# Pull latest builder image (non-fatal — uses cached image if offline)
# ---------------------------------------------------------------------------
# `timeout` here is load-bearing, not cosmetic: confirmed live that a stuck
# registry connection makes plain `docker pull` hang indefinitely (not fail
# fast), which silently defeats the "non-fatal, falls back to cached image"
# intent below — every single invocation of this script would just hang
# forever instead. 30s is generous for a real pull of this image while still
# failing fast on a genuinely wedged connection.
timeout 30 "${CONTAINER_RUNTIME}" pull "${DOCKER_IMAGE}" || echo "[WARN] Could not pull ${DOCKER_IMAGE} (timed out or offline) — using cached image"

# ---------------------------------------------------------------------------
# Run the container
#
# --network=host: every `run_in_container.sh` invocation is a separate,
# fresh `--rm`'d container (see test-env/README.md) — under Docker's default
# bridge networking each one gets its OWN private network namespace/loopback,
# so `test serve`'s HTTPS server (bound inside its own container's 127.0.0.1)
# was never actually reachable from a separately-invoked `test enter`/
# `test upgrade`/`test cycle` container. --add-host's mapping of
# downloads.shani.dev to 127.0.0.1 just pointed at that OTHER container's own
# empty loopback — confirmed live: the R2 fetch always failed, silently
# falling through to shani-update.sh's hardcoded SourceForge fallback
# (BASE_URL), which is NOT overridden by --add-host and reaches the REAL
# public internet. --network=host makes every container share the host's
# actual network stack, so `serve`'s bind on 0.0.0.0:443 and `--add-host`'s
# 127.0.0.1 mapping in every other container now refer to the same loopback.
#
# --add-host resolves downloads.shani.dev to that shared loopback — only
# meaningful for `build.sh test serve` / `test cycle` (see
# test-env/README.md); a harmless no-op for every other command here, since
# nothing else in this repo talks to that domain.
#
# -v /dev:/dev: without an explicit bind mount, Docker gives each container
# its own synthesized /dev that only reflects loop-device nodes present on
# the host at container-start time. Any loop device the HOST kernel
# allocates afterward (e.g. from a prior test-env run's containers, which
# don't get to clean up on exit — see test-env/README.md) has no device node
# inside a fresh container, so `losetup --find` picks a free device number
# that then fails with "No such file or directory" / "device node ... is
# lost". Bind-mounting the real host /dev keeps every container's view of
# loop devices in sync with the host's actual state.
#
# --cgroupns=host: Docker's default (private) cgroup namespace makes every
# container see its own cgroup as "/", regardless of where it actually sits
# in the host's real cgroup tree. `build.sh test enter`'s systemd-nspawn
# needs to create its own child cgroup to delegate to the container it
# spawns, and computes that child's path from what it reads as its own
# current cgroup — under the private namespace this resolves to a path that
# doesn't correspond to anything real, so the mkdir fails with "Failed to
# create /payload subcgroup: No such file or directory". --cgroupns=host
# makes the container's cgroup view match the host's actual tree.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Forward every SHANIOS_TEST_* runtime var set on the host into the
# container — test-env/test.sh reads a whole family of these
# (SHANIOS_TEST_EXTRA_BINDS, SHANIOS_TEST_MNT, SHANIOS_TEST_DATA,
# SHANIOS_TEST_ALLOW_NEW_LOCAL_SRC, ...) but none of them were actually
# reaching the container before this — setting one on the host silently
# did nothing, confirmed live (SHANIOS_TEST_ALLOW_NEW_LOCAL_SRC=1 set here
# had zero effect inside test.sh until this loop was added). Generic
# rather than one -e per variable so a new SHANIOS_TEST_* var test.sh adds
# later doesn't need a matching line added here too.
# ---------------------------------------------------------------------------
# Named to NOT start with SHANIOS_TEST_ itself — it did originally, which
# made compgen's own match list include this not-yet-populated array,
# and `${!_var}` on an empty array under `set -u` died with "unbound
# variable" (confirmed live). Anything actually named SHANIOS_TEST_* stays
# a plain scalar, so this only matters for this one array's own name.
TEST_ENV_FORWARD_ARGS=()
for _var in $(compgen -v SHANIOS_TEST_); do
    TEST_ENV_FORWARD_ARGS+=(-e "${_var}=${!_var}")
done

"${CONTAINER_RUNTIME}" run --rm ${TTY_FLAGS} --privileged \
    --network=host \
    --cgroupns=host \
    --tmpfs /tmp \
    --tmpfs /run/lock \
    --tmpfs /run \
    --cap-add SYS_ADMIN \
    --security-opt apparmor:unconfined \
    --security-opt seccomp:unconfined \
    -v /sys/fs/cgroup:/sys/fs/cgroup \
    -v /lib/modules:/lib/modules:ro \
    -v /dev:/dev \
    --add-host="downloads.shani.dev:127.0.0.1" \
    -v "${HOST_WORK_DIR}:${CONTAINER_WORK_DIR}" \
    "${OSI_MOUNT_ARGS[@]}" \
    "${DEPLOY_MOUNT_ARGS[@]}" \
    -v "${HOST_PACMAN_CACHE}:${CONTAINER_PACMAN_CACHE}" \
    -v "${HOST_FLATPAK_DATA}:${CONTAINER_FLATPAK_DATA}" \
    -v "${HOST_SNAPD_DATA}:${CONTAINER_SNAPD_DATA}" \
    -v "${HOST_SNAPD_SEED}:${CONTAINER_SNAPD_SEED}" \
    -v "${HOST_DOWNLOAD_CACHE}:${CONTAINER_DOWNLOAD_CACHE}" \
    -e CUSTOM_MIRROR="${CUSTOM_MIRROR}" \
    --env-file "${SECRETS_ENV_FILE}" \
    -e GPG_KEY_ID="${GPG_KEY_ID:-}" \
    -e GNUPGHOME="${CONTAINER_GNUPGHOME}" \
    -e R2_BUCKET="${R2_BUCKET:-}" \
    -e NO_SF="${NO_SF:-false}" \
    -e NO_R2="${NO_R2:-false}" \
    ${BUILD_DATE:+-e BUILD_DATE="${BUILD_DATE}"} \
    "${TEST_ENV_FORWARD_ARGS[@]}" \
    -w "${CONTAINER_WORK_DIR}" \
    "${DOCKER_IMAGE}" bash -c "${FINAL_CMD}"
