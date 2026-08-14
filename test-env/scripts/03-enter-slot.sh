#!/bin/bash
# 03-enter-slot.sh <blue|green> [--boot] [command...]
#
# Two modes:
#   (default)  One-shot: runs `command` (or a shell) inside @<slot> with no
#              real init — fast, used by the 04/05/06 driver scripts to run
#              shani-update/shani-deploy non-interactively.
#   --boot     Full boot: real systemd as PID1, real cgroups/logind/session.
#              Use this if you want to `distrobox create`, run podman, or
#              anything else that expects a normal running Linux system —
#              or `03-enter-slot.sh blue --boot` then run 07-boot-qemu.sh
#              separately for the same slot with an actual GUI.
#
# Makes @<slot> look like the currently-booted ShaniOS system, the way
# shani-deploy.sh / shani-update.sh expect to find it:
#   /                -> the slot's own subvolume (@blue or @green)
#   /data            -> bind of the @data subvolume (slot markers, downloads,
#                        deployment_pending flag — all the state shani-update
#                        keys off of)
#   /swap            -> bind of the @swap subvolume (gen-efi reads this for
#                        the resume offset)
#   /boot/efi        -> the fake ESP loop device (LABEL=shani_boot)
#   /dev/disk/by-label/shani_root, shani_boot -> re-created inside so ROOT_DEV
#                        resolves the same way it does on a real machine
#
# Uses systemd-nspawn (not plain chroot) so /proc, /sys, /dev get a sane
# fresh mount namespace and shani-deploy's own internal `mount --bind` calls
# for CHROOT_STATIC_DIRS/CHROOT_BIND_DIRS (see shani-deploy.sh prepare_chroot)
# work exactly as they would on real hardware.
#
# NOTE (simplification vs. real ShaniOS): on real hardware /etc and /var are
# overlayfs mounts (lower=slot, upper=@data/overlay/...) so user config
# survives a slot switch. This harness leaves /etc and /var as plain parts of
# the slot subvolume — good enough for exercising the deploy/rollback/slot
# logic, not a full persistence test. See README.
#
# Two more things are bound in transiently (never written to @blue/@green on
# disk — see README "What this does NOT simulate"):
#   /etc/hosts          -> shares the outer container's hosts file, so
#                          downloads.shani.dev resolves to the local mirror
#                          exactly as run_in_container.sh's --add-host set it
#   /usr/bin/systemd-inhibit -> the stub (there's no logind/session in a
#                          one-shot nspawn invocation for it to talk to)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config/config.sh"

SLOT="${1:?Usage: 03-enter-slot.sh <blue|green> [--boot] [command...]}"
shift || true
[[ "$SLOT" =~ ^(blue|green)$ ]] || die "slot must be 'blue' or 'green'"

BOOT=0
if [[ "${1:-}" == "--boot" ]]; then
    BOOT=1
    shift || true
fi

MNT="${SHANIOS_TEST_MNT:-/mnt/shanios-toplevel}"
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount -o subvolid=5 "/dev/disk/by-label/shani_root" "$MNT"

SLOT_DIR="$MNT/@${SLOT}"
[[ -d "$SLOT_DIR" ]] || die "@${SLOT} does not exist — run 01-bootstrap-rootfs.sh first"

ESP_MNT="${SHANIOS_TEST_ESP_MNT:-/mnt/shanios-esp}"
mkdir -p "$ESP_MNT"
mountpoint -q "$ESP_MNT" || mount /dev/disk/by-label/shani_boot "$ESP_MNT"

DATA_DIR="${SHANIOS_TEST_DATA:-${SCRIPT_DIR}/../disk}"
ROOT_LOOP=$(cat "${DATA_DIR}/.root_loop")
ESP_LOOP=$(cat "${DATA_DIR}/.esp_loop")

# The slot subvolume is read-only in normal operation (blue/green are always
# ro snapshots). A booted system stays functional because /etc and /var are
# overlaid from writable @data. Since we skip the overlay here (see NOTE
# above), give the entered slot a writable view via nspawn's own overlay
# instead of flipping the real subvolume's ro property — keeps @blue/@green
# on disk exactly as shani-deploy left them.
WORK="${SHANIOS_TEST_DATA:-${SCRIPT_DIR}/../disk}/nspawn-overlay-${SLOT}"
mkdir -p "$WORK/upper" "$WORK/work" "$WORK/merged"
mount -t overlay overlay -o "lowerdir=${SLOT_DIR},upperdir=${WORK}/upper,workdir=${WORK}/work" "$WORK/merged"

if [[ ${#} -eq 0 ]]; then
    set -- /bin/bash
fi

# Stash the real command; nspawn runs a small setup shim first that recreates
# /dev/disk/by-label pointing at the *bound-in* loop device nodes (nspawn's
# private /dev is minimal — it won't have these unless we bind the specific
# device nodes and rebuild the by-label symlinks ourselves), then execs it.
SETUP='mkdir -p /dev/disk/by-label && ln -sf '"$ROOT_LOOP"' /dev/disk/by-label/shani_root && ln -sf '"$ESP_LOOP"' /dev/disk/by-label/shani_boot && exec "$@"'

FUSE_BIND=()
[[ -e /dev/fuse ]] && FUSE_BIND=(--bind=/dev/fuse)

if (( BOOT )); then
    # Full boot: real systemd as PID1 inside the slot, real cgroup/session/
    # logind — what distrobox/podman/Flatpak/Waydroid actually want. Runs
    # interactively (Ctrl-] ] ] to detach, `machinectl poweroff <name>` or
    # just Ctrl-C here to stop it). Console login: root, no password.
    log "Booting @${SLOT} (full systemd boot via nspawn --boot)"
    exec systemd-nspawn \
        --quiet \
        --boot \
        --machine="shanios-${SLOT}" \
        --directory="$WORK/merged" \
        --capability=all \
        --private-users=no \
        "${FUSE_BIND[@]}" \
        --bind="$ROOT_LOOP" \
        --bind="$ESP_LOOP" \
        --bind="$MNT/@data:/data" \
        --bind="$MNT/@swap:/swap" \
        --bind="$ESP_MNT:/boot/efi" \
        --bind=/etc/hosts \
        --resolv-conf=bind-host \
        --system-call-filter='add_key keyctl bpf'
    # Note: the by-label symlink SETUP shim above only runs for the one-shot
    # (non --boot) path — under --boot, PID1 is the guest's own systemd, so
    # fix up /dev/disk/by-label from inside once it's up if shani-deploy
    # needs it there: `mkdir -p /dev/disk/by-label && ln -sf <loop> ...`
    # (see the SETUP variable above for the exact commands / device paths).
fi

log "Entering @${SLOT} via systemd-nspawn (writable overlay, ephemeral upper layer persists across runs in ${WORK}/upper)"
exec systemd-nspawn \
    --quiet \
    --directory="$WORK/merged" \
    --capability=all \
    --bind="$ROOT_LOOP" \
    --bind="$ESP_LOOP" \
    --bind="$MNT/@data:/data" \
    --bind="$MNT/@swap:/swap" \
    --bind="$ESP_MNT:/boot/efi" \
    --bind=/etc/hosts \
    --bind="${SCRIPT_DIR}/systemd-inhibit-stub.sh:/usr/bin/systemd-inhibit" \
    --resolv-conf=bind-host \
    -- /bin/bash -c "$SETUP" -- "$@"
