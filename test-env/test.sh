#!/usr/bin/env bash
# test.sh – Single-file dispatcher + implementation for the shanios-test-env rig
#
# Every step (disk/ca/bootstrap/serve/enter/upgrade/reboot/rollback/cycle/qemu)
# is a function below (cmd_*), called directly by the case dispatcher at the
# bottom — no other scripts, no sourcing between sibling files. The two things
# that used to be separate standalone files are now generated/handled inline:
#   - the systemd-inhibit stub (bind-mounted BY PATH into the nspawn
#     container) is written out at runtime by _ensure_inhibit_stub()
#   - the qemu boot (genuinely HOST-ONLY — needs your GPU/display and,
#     optionally, /dev/kvm — cannot run inside the build container) is
#     cmd_qemu(), guarded by _in_container() so it still refuses to run if
#     you invoke it through build.sh/run_in_container.sh by mistake
#
# ============================================================
# FLOW OVERVIEW
# ============================================================
#
# disk       writes: disk/root.img, disk/esp.img
# ca         writes: disk/ca/{ca.crt,ca.key,server.crt,server.key}
# bootstrap  -p <profile> [-d latest|stable|<date>]
#              reads:  OUTPUT_DIR/<profile>/... (config.sh — this repo's own build output)
#              writes: @blue / @green subvolumes on disk/root.img
# serve      [port] serves OUTPUT_DIR over HTTPS as downloads.shani.dev (blocks)
# enter      <blue|green> [--boot] [cmd...]
# upgrade    (real shani-update, inside current slot)
# reboot     (re-enter whichever slot is now current)
# rollback   (real shani-update --rollback)
# cycle      disk (if missing) → ca (if missing) → bootstrap -p <profile> → serve (background)
#            → upgrade → reboot
#              requires -p <profile>
# qemu       Genuine UEFI boot via OVMF — HOST-ONLY, refuses to run inside a container
#              (needs your GPU/display and, optionally, /dev/kvm directly)
#
# ============================================================
# Invoked as: ./run_in_container.sh build.sh test <command> [options]
#   (build.sh's `test` case execs this script — see its dispatch table)
# qemu is the one exception: run this file directly on the HOST instead:
#   test-env/test.sh qemu
set -Eeuo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
# NOTE: deliberately NOT cd-ing into $SCRIPT_DIR (test-env/) — config.sh
# resolves OUTPUT_DIR etc. relative to CWD ("./cache/output"), so CWD must
# stay at the repo root (../run_in_container.sh already sets -w to the
# mounted repo root), same as build.sh never cd's away from it either.
source "${SCRIPT_DIR}/../config/config.sh"

DATA_DIR="${SHANIOS_TEST_DATA:-${SCRIPT_DIR}/disk}"
MNT="${SHANIOS_TEST_MNT:-/mnt/shanios-toplevel}"
ESP_MNT="${SHANIOS_TEST_ESP_MNT:-/mnt/shanios-esp}"
CA_DIR="${DATA_DIR}/ca"
ROOT_IMG="${DATA_DIR}/root.img"
ESP_IMG="${DATA_DIR}/esp.img"
INHIBIT_STUB="${DATA_DIR}/.systemd-inhibit-stub.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  disk        Create loop-backed ESP+root disk images
  ca          Generate throwaway CA + downloads.shani.dev server cert
  bootstrap   Receive a real build into @blue/@green (requires -p <profile> [-d latest|stable|<date>])
  serve       Serve cache/output as the local mirror [port] (blocks; run in its own session)
  enter       Enter a slot via systemd-nspawn (requires <blue|green> [--boot] [cmd...])
  upgrade     Simulate an upgrade (real shani-update, inside the current slot)
  reboot      Simulate a reboot (re-enters whichever slot is now current)
  rollback    Simulate a rollback (real shani-update --rollback)
  cycle       disk → ca → bootstrap → serve (background) → upgrade → reboot (requires -p <profile>)
  qemu        Genuine UEFI boot via OVMF — HOST-ONLY, see below

Options:
  -p <profile>    Profile name (e.g. gnome, plasma) — for bootstrap/cycle
  -d <sel>        Image selector: 'latest' (default), 'stable', or a date — for bootstrap/cycle

Run from the repo root, via build.sh (like every other command in this repo):
  ./run_in_container.sh build.sh test disk
  ./run_in_container.sh build.sh test ca
  ./run_in_container.sh build.sh test bootstrap -p plasma
  ./run_in_container.sh build.sh test serve &
  ./run_in_container.sh build.sh test enter blue
  ./run_in_container.sh build.sh test upgrade
  ./run_in_container.sh build.sh test reboot
  ./run_in_container.sh build.sh test rollback
  ./run_in_container.sh build.sh test cycle -p plasma

qemu needs your GPU/display, so run this file directly on the HOST instead
of through build.sh/run_in_container.sh (which would put it in a container):
  test-env/test.sh qemu
EOF
  exit 1
}

# True once this shell is PID 1's descendant inside the docker/podman builder
# container (see run_in_container.sh) — used only to keep `qemu` from trying
# to boot without a GPU when someone runs it via build.sh by mistake.
_in_container() {
  [[ -f /.dockerenv || -f /run/.containerenv ]] && return 0
  command -v systemd-detect-virt &>/dev/null && systemd-detect-virt --container -q && return 0
  return 1
}

_get_profile() {
  local _prev="" _profile=""
  for _arg in "$@"; do
    [[ "${_prev}" == "-p" ]] && { _profile="$_arg"; _prev="$_arg"; continue; }
    _prev="$_arg"
  done
  echo "$_profile"
}

# ------------------------------------------------------------------
# shared helpers
# ------------------------------------------------------------------
_mount_root() {
  mkdir -p "$MNT"
  mountpoint -q "$MNT" || mount -o subvolid=5 "/dev/disk/by-label/shani_root" "$MNT"
}

_current_slot() {
  _mount_root
  local slot
  slot=$(tr -d '[:space:]' < "$MNT/@data/current-slot" 2>/dev/null || echo "")
  [[ "$slot" =~ ^(blue|green)$ ]] || die "Couldn't read current-slot marker — run '$(basename "$0") bootstrap' first"
  echo "$slot"
}

# ------------------------------------------------------------------
# disk   (was 00-create-disk.sh)
# ------------------------------------------------------------------
cmd_disk() {
  if ! command -v mkfs.fat &>/dev/null && command -v pacman &>/dev/null; then
    log "mkfs.fat not found — installing dosfstools"
    pacman -Sy --needed --noconfirm dosfstools || warn "Could not auto-install dosfstools — install it manually if the ESP step below fails"
  fi

  check_dependencies_test

  local root_size="${ROOT_SIZE:-16G}"
  local esp_size="${ESP_SIZE:-512M}"

  mkdir -p "$DATA_DIR" /dev/disk/by-label

  log "Setting up root.img (Btrfs, LABEL=shani_root, ${root_size})"
  setup_btrfs_image "$ROOT_IMG" "$root_size"
  local root_loop="$LOOP_DEVICE"
  btrfs filesystem label "$root_loop" shani_root

  log "Setting up esp.img (FAT32, LABEL=shani_boot, ${esp_size})"
  if losetup -j "$ESP_IMG" | grep -q "$ESP_IMG"; then
    local existing_esp_loop
    existing_esp_loop=$(losetup -j "$ESP_IMG" | cut -d: -f1)
    losetup -d "$existing_esp_loop" || warn "Failed to detach existing loop device: $existing_esp_loop"
  fi
  rm -f "$ESP_IMG"
  truncate -s "$esp_size" "$ESP_IMG"
  local esp_loop
  esp_loop=$(losetup --find --show "$ESP_IMG") || die "Failed to set up loop device for $ESP_IMG"
  mkfs.fat -F32 -n shani_boot "$esp_loop" || die "Failed to format $ESP_IMG as FAT32"

  ln -sf "$root_loop" /dev/disk/by-label/shani_root
  ln -sf "$esp_loop" /dev/disk/by-label/shani_boot

  echo "$root_loop" > "${DATA_DIR}/.root_loop"
  echo "$esp_loop" > "${DATA_DIR}/.esp_loop"

  log "root loop: $root_loop  (LABEL=shani_root)"
  log "esp  loop: $esp_loop  (LABEL=shani_boot)"
  log "Disk images written under: $DATA_DIR"
}

# ------------------------------------------------------------------
# ca   (was 00b-generate-test-ca.sh)
# ------------------------------------------------------------------
cmd_ca() {
  mkdir -p "$CA_DIR"

  if [[ -f "${CA_DIR}/ca.crt" && -f "${CA_DIR}/server.crt" && -f "${CA_DIR}/server.key" ]]; then
    log "Test CA + server cert already exist under ${CA_DIR} — reusing (delete the dir to regenerate)."
    return 0
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
}

# ------------------------------------------------------------------
# bootstrap   (was 01-bootstrap-rootfs.sh)
# ------------------------------------------------------------------
cmd_bootstrap() {
  check_dependencies_test

  local usage_bootstrap
  usage_bootstrap() {
    echo "Usage: $(basename "$0") bootstrap -p <profile> [-d <date>|latest|stable]" >&2
    echo "       $(basename "$0") bootstrap <OUTPUT_DIR>/<profile>/<date>/<file>.zst" >&2
    exit 1
  }

  local image=""
  if [[ "${1:-}" == /* ]]; then
    image="$1"
  else
    local profile="" date_sel="latest" opt OPTARG OPTIND=1
    while getopts "p:d:" opt "$@"; do
      case "$opt" in
        p) profile="$OPTARG" ;;
        d) date_sel="$OPTARG" ;;
        *) usage_bootstrap ;;
      esac
    done
    [[ -n "$profile" ]] || usage_bootstrap

    if [[ "$date_sel" == "latest" || "$date_sel" == "stable" ]]; then
      local pointer="${OUTPUT_DIR}/${profile}/${date_sel}.txt"
      [[ -f "$pointer" ]] || die "No ${date_sel}.txt for profile '${profile}' — build/release it first (./build.sh release -p ${profile} ${date_sel})."
      local filename date_dir
      filename=$(tr -d '[:space:]' < "$pointer")
      date_dir=$(echo "$filename" | grep -oE '[0-9]{8}' | head -n1)
      [[ -n "$date_dir" ]] || die "Couldn't parse a date out of '${filename}' from ${pointer}"
      image="${OUTPUT_DIR}/${profile}/${date_dir}/${filename}"
    else
      image=$(find "${OUTPUT_DIR}/${profile}/${date_sel}" -maxdepth 1 -name "*-${profile}.zst" | head -n1)
      [[ -n "$image" ]] || die "No .zst found under ${OUTPUT_DIR}/${profile}/${date_sel}"
    fi
  fi

  [[ -f "$image" ]] || die "Image not found: $image"

  local basename version profile
  basename=$(basename "$image")
  if [[ "$basename" =~ ^${OS_NAME}-([0-9]+)-([a-zA-Z]+)\.zst$ ]]; then
    version="${BASH_REMATCH[1]}"
    profile="${BASH_REMATCH[2]}"
  else
    warn "'$basename' doesn't match ${OS_NAME}-<version>-<profile>.zst — you'll need to set /etc/shani-version and /etc/shani-profile by hand."
    version=""
    profile=""
  fi

  local ca_crt="${CA_DIR}/ca.crt"
  [[ -f "$ca_crt" ]] || die "Test CA not found at ${ca_crt} — run '$(basename "$0") ca' first."

  _mount_root

  log "Creating top-level subvolumes"
  for subvol in @data @swap @etc @var; do
    if ! btrfs subvolume show "$MNT/$subvol" &>/dev/null; then
      btrfs subvolume create "$MNT/$subvol"
    fi
  done
  chattr +C "$MNT/@swap" 2>/dev/null || true

  mkdir -p "$MNT/@data/overlay/etc/upper" "$MNT/@data/overlay/etc/work" \
           "$MNT/@data/overlay/var/upper" "$MNT/@data/overlay/var/work" \
           "$MNT/@data/downloads"

  if btrfs subvolume show "$MNT/shanios_base" &>/dev/null; then
    log "shanios_base already exists from a previous run, deleting it first"
    btrfs subvolume delete "$MNT/shanios_base"
  fi

  log "Receiving image into shanios_base (this can take a while for multi-GB images)"
  zstd -d --long=31 -T0 "$image" -c | btrfs receive "$MNT"

  if ! btrfs subvolume show "$MNT/shanios_base" &>/dev/null; then
    die "Extraction finished but 'shanios_base' subvolume wasn't found — check the image."
  fi

  log "Snapshotting shanios_base -> @blue -> @green"
  [[ -d "$MNT/@blue" ]] && { btrfs property set -f -ts "$MNT/@blue" ro false 2>/dev/null || true; btrfs subvolume delete "$MNT/@blue"; }
  [[ -d "$MNT/@green" ]] && { btrfs property set -f -ts "$MNT/@green" ro false 2>/dev/null || true; btrfs subvolume delete "$MNT/@green"; }

  btrfs subvolume snapshot -r "$MNT/shanios_base" "$MNT/@blue"
  btrfs subvolume snapshot -r "$MNT/@blue" "$MNT/@green"
  btrfs subvolume delete "$MNT/shanios_base"

  echo "blue" > "$MNT/@data/current-slot"
  echo "green" > "$MNT/@data/previous-slot"

  for slot in @blue @green; do
    btrfs property set -f -ts "$MNT/$slot" ro false

    if [[ -n "$version" ]]; then
      echo "$version" > "$MNT/$slot/etc/shani-version"
      echo "$profile" > "$MNT/$slot/etc/shani-profile"
      echo "stable" > "$MNT/$slot/etc/shani-channel" 2>/dev/null || true
    fi

    if [[ -x "$MNT/$slot/usr/bin/trust" ]]; then
      cp "$ca_crt" "$MNT/$slot/etc/ca-certificates/trust-source/anchors/shanios-test-ca.crt"
      chroot "$MNT/$slot" trust extract-compat
    else
      warn "'trust' not found in @${slot#@} — local-mirror TLS verification will fail."
    fi

    btrfs property set -f -ts "$MNT/$slot" ro true
  done

  btrfs filesystem sync "$MNT"

  log "Bootstrap complete."
  log "  @blue  = v${version:-?} (${profile:-?})  [current-slot]"
  log "  @green = v${version:-?} (${profile:-?})  [previous-slot, identical clone for now]"
  log "Next: $(basename "$0") enter blue"
}

# ------------------------------------------------------------------
# serve   (was 02-serve-update.sh)
# ------------------------------------------------------------------
cmd_serve() {
  local port="${1:-443}"

  [[ -f "${CA_DIR}/server.crt" && -f "${CA_DIR}/server.key" ]] \
    || die "Server cert not found under ${CA_DIR} — run '$(basename "$0") ca' first."
  [[ -d "$OUTPUT_DIR" ]] \
    || die "${OUTPUT_DIR} not found."

  log "Serving ${OUTPUT_DIR} on https://0.0.0.0:${port} (CN=downloads.shani.dev)"
  log "Available profiles: $(find "$OUTPUT_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f ' 2>/dev/null)"

  cd "$OUTPUT_DIR" && exec python3 - "$port" "${CA_DIR}/server.crt" "${CA_DIR}/server.key" <<'PYEOF'
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
}

# Minimal stand-in for systemd-inhibit inside the test container.
# shani-deploy.sh calls it like:
#   systemd-inhibit --what=... --who=... --why=... [env NAME=VAL ...] <script> <args...>
# There's no logind/session in the container so real inhibitor locks make no
# sense here. Strip the systemd-inhibit-specific tokens and exec the rest.
# Bind-mounted BY PATH into the nspawn container (see cmd_enter below), so it
# has to exist as a real file on disk — written out once here, idempotently.
_ensure_inhibit_stub() {
  [[ -f "$INHIBIT_STUB" ]] && return 0
  mkdir -p "$DATA_DIR"
  cat > "$INHIBIT_STUB" <<'STUBEOF'
#!/bin/bash
set -euo pipefail

cmd=()
for a in "$@"; do
    case "$a" in
        --what=*|--who=*|--why=*|--mode=*) continue ;;
        env) continue ;;
        *=*)
            if [[ ${#cmd[@]} -eq 0 ]]; then
                export "${a?}"
                continue
            fi
            ;;
    esac
    cmd+=("$a")
done

exec "${cmd[@]}"
STUBEOF
  chmod +x "$INHIBIT_STUB"
}

# ------------------------------------------------------------------
# enter   (was 03-enter-slot.sh)
# ------------------------------------------------------------------
cmd_enter() {
  local slot="${1:?Usage: $(basename "$0") enter <blue|green> [--boot] [command...]}"
  shift || true
  [[ "$slot" =~ ^(blue|green)$ ]] || die "slot must be 'blue' or 'green'"

  local boot=0
  if [[ "${1:-}" == "--boot" ]]; then
    boot=1
    shift || true
  fi

  _mount_root

  local slot_dir="$MNT/@${slot}"
  [[ -d "$slot_dir" ]] || die "@${slot} does not exist — run '$(basename "$0") bootstrap' first"

  mkdir -p "$ESP_MNT"
  mountpoint -q "$ESP_MNT" || mount /dev/disk/by-label/shani_boot "$ESP_MNT"

  local root_loop esp_loop
  root_loop=$(cat "${DATA_DIR}/.root_loop")
  esp_loop=$(cat "${DATA_DIR}/.esp_loop")

  local work="${DATA_DIR}/nspawn-overlay-${slot}"
  mkdir -p "$work/upper" "$work/work" "$work/merged"
  mount -t overlay overlay -o "lowerdir=${slot_dir},upperdir=${work}/upper,workdir=${work}/work" "$work/merged"

  _ensure_inhibit_stub

  if [[ ${#} -eq 0 ]]; then
    set -- /bin/bash
  fi

  local setup='mkdir -p /dev/disk/by-label && ln -sf '"$root_loop"' /dev/disk/by-label/shani_root && ln -sf '"$esp_loop"' /dev/disk/by-label/shani_boot && exec "$@"'

  local fuse_bind=()
  [[ -e /dev/fuse ]] && fuse_bind=(--bind=/dev/fuse)

  if (( boot )); then
    log "Booting @${slot} (full systemd boot via nspawn --boot)"
    exec systemd-nspawn \
        --quiet \
        --boot \
        --machine="shanios-${slot}" \
        --directory="$work/merged" \
        --capability=all \
        --private-users=no \
        "${fuse_bind[@]}" \
        --bind="$root_loop" \
        --bind="$esp_loop" \
        --bind="$MNT/@data:/data" \
        --bind="$MNT/@swap:/swap" \
        --bind="$ESP_MNT:/boot/efi" \
        --bind=/etc/hosts \
        --resolv-conf=bind-host \
        --system-call-filter='add_key keyctl bpf'
  fi

  log "Entering @${slot} via systemd-nspawn (writable overlay, ephemeral upper layer persists across runs in ${work}/upper)"
  exec systemd-nspawn \
      --quiet \
      --directory="$work/merged" \
      --capability=all \
      --bind="$root_loop" \
      --bind="$esp_loop" \
      --bind="$MNT/@data:/data" \
      --bind="$MNT/@swap:/swap" \
      --bind="$ESP_MNT:/boot/efi" \
      --bind=/etc/hosts \
      --bind="${INHIBIT_STUB}:/usr/bin/systemd-inhibit" \
      --resolv-conf=bind-host \
      -- /bin/bash -c "$setup" -- "$@"
}

# ------------------------------------------------------------------
# upgrade / reboot / rollback   (was 04/05/06-*.sh)
# ------------------------------------------------------------------
cmd_upgrade() {
  local current_slot
  current_slot="$(_current_slot)"
  log "Current slot marker: @${current_slot}"
  log "Running: shani-update --force --skip-self-update $* (inside @${current_slot})"
  cmd_enter "$current_slot" shani-update --force --skip-self-update "$@"
}

cmd_reboot() {
  local current_slot
  current_slot="$(_current_slot)"
  log "'Rebooting' into @${current_slot} (per /data/current-slot)"
  cmd_enter "$current_slot" "$@"
}

cmd_rollback() {
  local current_slot
  current_slot="$(_current_slot)"
  log "Rolling back FROM @${current_slot} (this restores the *other* slot and repoints boot at it)"
  cmd_enter "$current_slot" shani-update --rollback
}

# ------------------------------------------------------------------
# qemu   (was 07-boot-qemu.sh) — HOST-ONLY
#
# Boots disk/root.img + disk/esp.img exactly like real hardware would:
#   - esp.img contains /EFI/BOOT/BOOTX64.EFI (shim) -> grubx64.efi
#     (systemd-boot, renamed — see update_bootloader() in gen-efi.sh) -> the
#     UKI for whichever slot loader.conf points at. OVMF's firmware boot
#     manager finds this via the standard "removable media" fallback path,
#     same as booting an installer USB stick — no NVRAM boot-entry setup
#     needed for this to work.
#   - root.img is the real Btrfs filesystem (LABEL=shani_root) — the kernel
#     cmdline baked into the UKI points root= / rootflags=subvol=@<slot> at it.
#
# This is a genuine UEFI boot of the real bootloader/kernel/UKI shani-deploy
# produced — not a simulation. If it doesn't boot, that's signal about the
# image/deploy, not about this harness.
#
# Requirements on the HOST (not the container):
#   apt install qemu-system-x86 ovmf   (Debian/Ubuntu)
#   pacman -S qemu-full edk2-ovmf      (Arch)
# ------------------------------------------------------------------
cmd_qemu() {
  if _in_container; then
    echo "qemu needs your GPU/display — it can't run inside the build container." >&2
    echo "Run this file directly on the HOST instead, from the repo root:" >&2
    echo "  test-env/test.sh qemu" >&2
    exit 1
  fi

  [[ -f "$ROOT_IMG" && -f "$ESP_IMG" ]] || {
    echo "Expected $ROOT_IMG and $ESP_IMG — run this first:" >&2
    echo "  ./run_in_container.sh build.sh test disk   (from the repo root)" >&2
    exit 1
  }

  # Locate OVMF firmware + a per-VM copy of the vars file (writable NVRAM store
  # — bootctl's `set-default` EFI-var write and any MOK enrollment land here;
  # copied once so re-running this doesn't reset it).
  local ovmf_code="${OVMF_CODE:-}"
  local ovmf_vars_template="${OVMF_VARS_TEMPLATE:-}"
  local candidate
  for candidate in \
      /usr/share/OVMF/OVMF_CODE_4M.fd \
      /usr/share/OVMF/OVMF_CODE.fd \
      /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
      /usr/share/edk2/x64/OVMF_CODE.fd; do
      [[ -z "$ovmf_code" && -f "$candidate" ]] && ovmf_code="$candidate"
  done
  for candidate in \
      /usr/share/OVMF/OVMF_VARS_4M.fd \
      /usr/share/OVMF/OVMF_VARS.fd \
      /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
      /usr/share/edk2/x64/OVMF_VARS.fd; do
      [[ -z "$ovmf_vars_template" && -f "$candidate" ]] && ovmf_vars_template="$candidate"
  done
  [[ -n "$ovmf_code" && -n "$ovmf_vars_template" ]] || {
      echo "Couldn't find OVMF firmware. Install it (see cmd_qemu's header comment)" >&2
      echo "or set \$OVMF_CODE / \$OVMF_VARS_TEMPLATE explicitly." >&2
      exit 1
  }

  local vars_copy="${DATA_DIR}/OVMF_VARS.fd"
  [[ -f "$vars_copy" ]] || cp "$ovmf_vars_template" "$vars_copy"

  local kvm_args=()
  [[ -e /dev/kvm && -w /dev/kvm ]] && kvm_args=(-enable-kvm -cpu host) || echo "no /dev/kvm access — falling back to (slow) TCG emulation" >&2

  echo "==> Booting root.img + esp.img via OVMF (close the window / send SIGTERM to stop)"
  exec qemu-system-x86_64 \
      -machine q35 \
      -smp 4 \
      -m "${QEMU_MEM:-4096}" \
      "${kvm_args[@]}" \
      -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
      -drive if=pflash,format=raw,file="$vars_copy" \
      -drive if=virtio,format=raw,file="$ROOT_IMG" \
      -drive if=virtio,format=raw,file="$ESP_IMG" \
      -device virtio-gpu-pci \
      -display "${QEMU_DISPLAY:-gtk}" \
      -device virtio-net-pci,netdev=net0 \
      -netdev user,id=net0 \
      -device qemu-xhci -device usb-kbd -device usb-tablet \
      -serial mon:stdio
}

# ------------------------------------------------------------------
# main dispatch
# ------------------------------------------------------------------
[[ $# -lt 1 ]] && usage

COMMAND="$1"
shift

case "$COMMAND" in
  disk)      cmd_disk "$@" ;;
  ca)        cmd_ca "$@" ;;
  bootstrap) cmd_bootstrap "$@" ;;
  serve)     cmd_serve "$@" ;;
  enter)     cmd_enter "$@" ;;
  upgrade)   cmd_upgrade "$@" ;;
  reboot)    cmd_reboot "$@" ;;
  rollback)  cmd_rollback "$@" ;;
  cycle)
    PROFILE="$(_get_profile "$@")"
    [[ -n "$PROFILE" ]] || die "cycle requires -p <profile>"

    [[ -f "$ROOT_IMG" && -f "$ESP_IMG" ]] || cmd_disk
    [[ -f "${CA_DIR}/ca.crt" ]] || cmd_ca
    cmd_bootstrap "$@"

    cmd_serve &
    SERVE_PID=$!
    trap 'kill "$SERVE_PID" 2>/dev/null || true' EXIT
    sleep 1

    cmd_upgrade
    cmd_reboot
    ;;
  qemu)      cmd_qemu "$@" ;;
  *)
    usage
    ;;
esac
