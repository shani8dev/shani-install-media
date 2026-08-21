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
  iso         Boot a real installer ISO via OVMF — HOST-ONLY, see below (requires -p <profile> [-d latest|stable|<date>])
  clean       Unmount everything and detach root.img/esp.img's loop devices

Loop-device attachment does NOT survive across separate
run_in_container.sh invocations (each is a fresh --rm'd container) — every
disk/bootstrap/enter/cycle call re-attaches (or reuses) root.img/esp.img's
loop devices on the HOST, but nothing ever detaches them again on its own.
Run `clean` when you're done testing, or loop devices accumulate on the
host indefinitely across a session (only a reboot or manual `losetup -d`
otherwise releases them). root.img/esp.img themselves are left alone —
`clean` only tears down mounts and loop attachments, not the disk images.

Options:
  -p <profile>    Profile name (e.g. gnome, plasma) — for bootstrap/cycle/iso
  -d <sel>        Image selector: 'latest' (default), 'stable', or a date — for bootstrap/cycle/iso

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
  ./run_in_container.sh build.sh test clean

qemu/iso need your GPU/display, so run this file directly on the HOST
instead of through build.sh/run_in_container.sh (which would put it in a
container):
  test-env/test.sh qemu
  test-env/test.sh iso -p plasma
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
# Loop-device attachment (unlike root.img/esp.img themselves, which are
# bind-mounted and persist on the host) does NOT survive across separate
# `run_in_container.sh` invocations — each is a fresh container, so its
# /dev/disk/by-label/* symlinks (created by cmd_disk) start out empty even
# when root.img/esp.img already exist from an earlier session. Re-attach to
# the existing images instead of requiring a fresh `disk` (which would wipe
# and reformat them) every time a new container needs them.
_ensure_disk_attached() {
  [[ -e /dev/disk/by-label/shani_root && -e /dev/disk/by-label/shani_boot ]] && return 0

  [[ -f "$ROOT_IMG" && -f "$ESP_IMG" ]] \
    || die "root.img/esp.img not found under $DATA_DIR — run '$(basename "$0") disk' first"

  mkdir -p /dev/disk/by-label

  local root_loop esp_loop
  if losetup -j "$ROOT_IMG" | grep -q "$ROOT_IMG"; then
    root_loop=$(losetup -j "$ROOT_IMG" | cut -d: -f1)
  else
    root_loop=$(losetup --find --show "$ROOT_IMG") || die "Failed to attach loop device for $ROOT_IMG"
  fi
  if losetup -j "$ESP_IMG" | grep -q "$ESP_IMG"; then
    esp_loop=$(losetup -j "$ESP_IMG" | cut -d: -f1)
  else
    esp_loop=$(losetup --find --show "$ESP_IMG") || die "Failed to attach loop device for $ESP_IMG"
  fi

  ln -sf "$root_loop" /dev/disk/by-label/shani_root
  ln -sf "$esp_loop" /dev/disk/by-label/shani_boot
  echo "$root_loop" > "${DATA_DIR}/.root_loop"
  echo "$esp_loop" > "${DATA_DIR}/.esp_loop"
  log "Re-attached existing disk images from a prior session: root=$root_loop esp=$esp_loop"
}

_mount_root() {
  _ensure_disk_attached
  mkdir -p "$MNT"
  # compress=zstd matches production's BTRFS_TOP_OPTS (install.sh/build-base-image.sh).
  # Without it, a rootfs that fits comfortably in production's compressed
  # filesystem can exhaust an equally-sized uncompressed test disk mid-receive
  # — btrfs then blocks in uninterruptible I/O wait (D state) trying to find
  # metadata space rather than promptly failing with ENOSPC, hanging the
  # whole test indefinitely instead of erroring out.
  mountpoint -q "$MNT" || mount -o subvolid=5,compress=zstd "/dev/disk/by-label/shani_root" "$MNT"
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

  # 20G, not 16G: even with compress=zstd (see _mount_root), the transient
  # peak during shanios_base -> @blue -> @green snapshotting plus btrfs's own
  # metadata overhead needs headroom above a single profile's rootfs size.
  local root_size="${ROOT_SIZE:-20G}"
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
# clean — undo everything _ensure_disk_attached/cmd_disk/cmd_enter leave
# behind, without touching root.img/esp.img themselves.
#
# Nothing else in this file ever calls losetup -d on a successful path:
# _ensure_disk_attached() re-attaches or reuses the existing loop device on
# every invocation (correct — it can't know a later command still needs it),
# and every run_in_container.sh invocation is a fresh --rm'd container, so
# there's no container-exit hook to detach on either. Loop devices just
# accumulate on the host across a testing session unless something
# explicitly tears them down.
# ------------------------------------------------------------------
cmd_clean() {
  local any=0

  local slot work
  for slot in blue green; do
    work="${DATA_DIR}/nspawn-overlay-${slot}"
    if mountpoint -q "${work}/merged" 2>/dev/null; then
      log "Unmounting ${work}/merged"
      umount -R "${work}/merged" 2>/dev/null || warn "Failed to unmount ${work}/merged"
      any=1
    fi
  done

  if mountpoint -q "$ESP_MNT" 2>/dev/null; then
    log "Unmounting $ESP_MNT"
    umount "$ESP_MNT" 2>/dev/null || warn "Failed to unmount $ESP_MNT"
    any=1
  fi

  if mountpoint -q "$MNT" 2>/dev/null; then
    log "Unmounting $MNT"
    umount -R "$MNT" 2>/dev/null || warn "Failed to unmount $MNT"
    any=1
  fi

  local img loop
  for img in "$ROOT_IMG" "$ESP_IMG"; do
    [[ -f "$img" ]] || continue
    while read -r loop; do
      [[ -n "$loop" ]] || continue
      log "Detaching $loop ($img)"
      losetup -d "$loop" 2>/dev/null || warn "Failed to detach $loop"
      any=1
    done < <(losetup -j "$img" 2>/dev/null | cut -d: -f1)
  done

  rm -f /dev/disk/by-label/shani_root /dev/disk/by-label/shani_boot
  rm -f "${DATA_DIR}/.root_loop" "${DATA_DIR}/.esp_loop"

  if (( any )); then
    log "Clean complete — root.img/esp.img left in place, everything else torn down"
  else
    log "Nothing to clean up"
  fi
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

  # Matches install.sh's create_subvolumes() exactly — a genuine UEFI boot
  # (cmd_qemu, or --boot through cmd_enter) processes the received image's
  # own /etc/fstab, which references every one of these by name. The
  # earlier @data/@swap/@etc/@var-only set was enough for the plain
  # cmd_enter overlay (which never touches fstab) but left a real boot
  # dropping into emergency mode at "Failed to mount /var/cache" the
  # instant it needed anything this list was missing.
  log "Creating top-level subvolumes"
  for subvol in @root @home @data @nix @cache @log @flatpak @snapd @waydroid \
                @containers @machines @lxc @lxd @libvirt @qemu @swap; do
    if ! btrfs subvolume show "$MNT/$subvol" &>/dev/null; then
      btrfs subvolume create "$MNT/$subvol"
    fi
  done
  chattr +C "$MNT/@swap" 2>/dev/null || true

  # Matches install.sh's create_swapfile() — the shipped image's own
  # /etc/fstab has a "/swap/swapfile none swap defaults 0 0" entry, and a
  # real boot fails to activate it ("Failed to activate swap
  # /swap/swapfile") if the file doesn't actually exist. install.sh sizes
  # it to total RAM and skips it gracefully if there isn't enough space;
  # do the same here EXCEPT for the sizing basis — install.sh's `free -m`
  # runs on the machine being installed, but ours runs inside the builder
  # container, which reports the BUILD HOST's RAM (e.g. 32G on a beefy
  # build box), not the QEMU guest's. Sizing to that against a ~20G test
  # disk with only a few GB free post-receive would always trip the
  # low-space skip below, silently reproducing the exact bug this is
  # fixing. Size to the guest's actual configured RAM (cmd_qemu's
  # QEMU_MEM, same default) instead. Unlike install.sh, don't swapon it —
  # that would activate swap on the builder host, not the guest being
  # assembled.
  if [[ ! -f "$MNT/@swap/swapfile" ]]; then
    local swapfile_size available_mb
    swapfile_size="${QEMU_MEM:-4096}"
    available_mb=$(df -BM "$MNT" | awk 'NR==2 {print $4}' | sed 's/M//')
    if (( available_mb < swapfile_size )); then
      warn "Insufficient space for a ${swapfile_size}M swapfile (${available_mb}M available) — skipping, matching install.sh's zram-fallback behavior"
    else
      log "Creating swapfile at $MNT/@swap/swapfile (${swapfile_size}M)"
      btrfs filesystem mkswapfile --size "${swapfile_size}M" "$MNT/@swap/swapfile" \
        || die "Swapfile creation failed"
    fi
  fi

  # Matches install.sh's overlay-dir + varlib/varspool persistent-state-dir
  # creation — /etc/fstab bind-mounts each of these from /data, and systemd
  # fails the mount (cascading into emergency mode) if the source is missing.
  mkdir -p "$MNT/@data/overlay/etc/lower" "$MNT/@data/overlay/etc/upper" "$MNT/@data/overlay/etc/work" \
           "$MNT/@data/overlay/var/lower" "$MNT/@data/overlay/var/upper" "$MNT/@data/overlay/var/work" \
           "$MNT/@data/downloads"
  for dir in \
      varlib/dbus varlib/systemd varlib/fontconfig \
      varlib/NetworkManager varlib/bluetooth varlib/firewalld \
      varlib/samba varlib/nfs \
      varlib/caddy varlib/tailscale varlib/cloudflared varlib/geoclue \
      varlib/gdm varlib/sddm \
      varlib/colord varlib/pipewire varlib/rtkit \
      varlib/cups varlib/sane varlib/upower \
      varlib/fprint varlib/AccountsService varlib/boltd \
      varlib/sudo varlib/sshd varlib/polkit-1 \
      varlib/fwupd varlib/tpm2-tss \
      varlib/fail2ban varlib/restic varlib/rclone varlib/appimage \
      varspool/anacron varspool/cron varspool/at \
      varspool/cups varspool/samba varspool/postfix; do
    mkdir -p "$MNT/@data/${dir}"
  done

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

  # configure.sh's job on a real install: run gen-efi (UKI + bootloader
  # binaries + cmdline) for each slot and write systemd-boot's loader
  # entries. cmd_bootstrap skips the real installer, so without this a
  # genuine UEFI boot (cmd_qemu, or --boot through cmd_enter) finds a
  # completely empty ESP and never gets past firmware ("BdsDxe: failed to
  # load Boot0001 ... Not Found" -> falls through to PXE).
  mkdir -p "$ESP_MNT"
  mountpoint -q "$ESP_MNT" || mount /dev/disk/by-label/shani_boot "$ESP_MNT"
  mkdir -p "$ESP_MNT/EFI/BOOT" "$ESP_MNT/EFI/${OS_NAME}" "$ESP_MNT/loader/entries"

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

    if [[ -x "$MNT/$slot/usr/local/bin/gen-efi" ]]; then
      local slot_name="${slot#@}"
      mkdir -p "$MNT/$slot/boot/efi"
      mountpoint -q "$MNT/$slot/boot/efi" || mount --bind "$ESP_MNT" "$MNT/$slot/boot/efi"
      for fs in proc sys dev run; do
        mkdir -p "$MNT/$slot/$fs"
        mountpoint -q "$MNT/$slot/$fs" || mount --rbind "/$fs" "$MNT/$slot/$fs"
      done
      log "Generating UKI + bootloader for @${slot_name} (gen-efi configure ${slot_name})"
      chroot "$MNT/$slot" /usr/local/bin/gen-efi configure "$slot_name" \
        || warn "gen-efi failed for @${slot_name} — cmd_qemu/cmd_enter --boot won't find a working entry for it"
      # Matches shani-deploy.sh's own entry-writing exactly: the active slot
      # (@blue, being booted for the first time) gets +3-0 boot-count tries
      # so systemd-bless-boot / bless-boot.service has something real to
      # bless once the boot proves healthy; the candidate (@green) gets a
      # plain, non-counting entry as the unconditional fallback. Without the
      # tries suffix, systemd-bless-boot correctly refuses with "Not booted
      # with boot counting in effect" — confirmed live, this isn't cosmetic.
      # (Even with the suffix present, don't expect the file to actually get
      # renamed after booting on current systemd — that's a separate, open
      # upstream regression: https://github.com/systemd/systemd/issues/40405)
      local entry_filename
      if [[ "$slot" == "@blue" ]]; then
        entry_filename="${OS_NAME}-${slot_name}+3-0.conf"
      else
        entry_filename="${OS_NAME}-${slot_name}.conf"
      fi
      cat > "$ESP_MNT/loader/entries/${entry_filename}" <<ENTRYEOF
title   ${OS_NAME}-${slot_name} ($( [[ "$slot" == "@blue" ]] && echo Active || echo Candidate ))
efi     /EFI/${OS_NAME}/${OS_NAME}-${slot_name}.efi
ENTRYEOF
      for fs in run dev sys proc; do
        mountpoint -q "$MNT/$slot/$fs" && umount -R "$MNT/$slot/$fs"
      done
      mountpoint -q "$MNT/$slot/boot/efi" && umount "$MNT/$slot/boot/efi"
    else
      warn "gen-efi not found in @${slot#@} — cmd_qemu/cmd_enter --boot won't have a working ESP entry for it"
    fi

    btrfs property set -f -ts "$MNT/$slot" ro true
  done

  # Plain ID, no tries suffix and no glob — matches shani-deploy.sh's own
  # loader.conf writing exactly. systemd-boot resolves "default" against
  # entry IDs (the plain filename with any +tries-suffix stripped), not
  # against literal filenames, so shanios-blue+3-0.conf's ID is
  # shanios-blue.conf; per shani-deploy.sh's own comment a glob does not
  # reliably match here even though it looks like it should.
  cat > "$ESP_MNT/loader/loader.conf" <<LOADEREOF
default ${OS_NAME}-blue.conf
timeout 3
console-mode max
editor 0
LOADEREOF

  umount "$ESP_MNT"

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

# systemd-nspawn derives its own internal identifiers (machine naming,
# cgroup/network naming) from the CALLING environment's /etc/machine-id via
# sd_id128_get_machine_app_specific() — not from the target slot's machine-id,
# which is fine and untouched. The published builder image has no
# /etc/machine-id at all (it's not meant to run systemd services), so every
# nspawn invocation used to fail immediately with "Failed to retrieve machine
# ID: No such file or directory" before ever reaching the target rootfs.
_ensure_host_machine_id() {
  [[ -s /etc/machine-id ]] && return 0
  systemd-machine-id-setup >/dev/null 2>&1 \
    || die "Could not initialize /etc/machine-id in the builder container (needed by systemd-nspawn itself, not the target image)"
}

# Even with --register=no (which skips systemd-machined registration) and
# --keep-unit (which skips asking systemd to allocate a transient scope),
# nspawn still tries to connect to the system bus at startup — with no bus
# present at all, that connection failure makes nspawn's PARENT kill its own
# container-setup child outright, surfacing only the uninformative "Parent
# died too early". The builder image has dbus installed but nothing starts
# it. A private, otherwise-unused system bus is enough to satisfy this.
_ensure_dbus() {
  [[ -S /run/dbus/system_bus_socket ]] && return 0
  mkdir -p /run/dbus
  dbus-daemon --system --fork \
    || die "Could not start dbus-daemon in the builder container (needed by systemd-nspawn itself)"
}

# ------------------------------------------------------------------
# enter   (was 03-enter-slot.sh)
# ------------------------------------------------------------------
cmd_enter() {
  _ensure_host_machine_id
  _ensure_dbus
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
        --register=no \
        --keep-unit \
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
  # --register=no: skip registering the new machine with systemd-machined
  # over D-Bus (see _ensure_dbus above for why a bus needs to exist at all).
  # --keep-unit: place the container in the CALLING process's own cgroup
  # instead of asking systemd (over that same bus) to allocate a transient
  # scope unit for it — there's no real systemd manager listening as
  # org.freedesktop.systemd1 on this bus, so that request would otherwise
  # fail with "Failed to allocate scope: Failed to execute program
  # org.freedesktop.systemd1: Permission denied".
  exec systemd-nspawn \
      --quiet \
      --register=no \
      --keep-unit \
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

# Locate OVMF firmware. Sets globals OVMF_CODE_PATH / OVMF_VARS_TEMPLATE_PATH
# (shared by cmd_qemu and cmd_iso — both boot via the same firmware).
_locate_ovmf() {
  OVMF_CODE_PATH="${OVMF_CODE:-}"
  OVMF_VARS_TEMPLATE_PATH="${OVMF_VARS_TEMPLATE:-}"
  local candidate
  for candidate in \
      /usr/share/OVMF/OVMF_CODE_4M.fd \
      /usr/share/OVMF/OVMF_CODE.fd \
      /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
      /usr/share/edk2/x64/OVMF_CODE.fd; do
      [[ -z "$OVMF_CODE_PATH" && -f "$candidate" ]] && OVMF_CODE_PATH="$candidate"
  done
  for candidate in \
      /usr/share/OVMF/OVMF_VARS_4M.fd \
      /usr/share/OVMF/OVMF_VARS.fd \
      /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
      /usr/share/edk2/x64/OVMF_VARS.fd; do
      [[ -z "$OVMF_VARS_TEMPLATE_PATH" && -f "$candidate" ]] && OVMF_VARS_TEMPLATE_PATH="$candidate"
  done
  [[ -n "$OVMF_CODE_PATH" && -n "$OVMF_VARS_TEMPLATE_PATH" ]] || {
      echo "Couldn't find OVMF firmware. Install it:" >&2
      echo "  apt install qemu-system-x86 ovmf   (Debian/Ubuntu)" >&2
      echo "  pacman -S qemu-full edk2-ovmf      (Arch)" >&2
      echo "or set \$OVMF_CODE / \$OVMF_VARS_TEMPLATE explicitly." >&2
      exit 1
  }
}

# ------------------------------------------------------------------
# iso   — HOST-ONLY: boot a real, unmodified installer ISO via OVMF
#
# This is the one thing cmd_qemu deliberately does NOT cover: the real
# install flow (os-installer-config/scripts/install.sh's partitioning,
# configure.sh's locale/hostname/user setup, the os-installer GUI itself)
# has no automated test anywhere in this repo. cmd_iso doesn't automate the
# GUI either (it's an interactive installer — a human has to click through
# it), but it DOES give a genuine, automated confirmation that the signed
# ISO you built actually boots: firmware -> shim -> systemd-boot -> the
# live UKI -> kernel -> systemd -> the installer GUI, all unmodified.
#
# If disk/root.img + disk/esp.img already exist (run `disk` first), they're
# attached as a second virtio drive so a human can actually run the
# installer's partitioning/install step onto a real (throwaway) target
# disk for a full end-to-end test — entirely optional, the ISO boots fine
# without them.
# ------------------------------------------------------------------
cmd_iso() {
  if _in_container; then
    echo "qemu needs your GPU/display — it can't run inside the build container." >&2
    echo "Run this file directly on the HOST instead, from the repo root:" >&2
    echo "  test-env/test.sh iso -p <profile> [-d latest|stable|<date>]" >&2
    exit 1
  fi

  local usage_iso
  usage_iso() {
    echo "Usage: $(basename "$0") iso -p <profile> [-d <date>|latest|stable]" >&2
    exit 1
  }

  local profile="" date_sel="latest" opt OPTARG OPTIND=1
  while getopts "p:d:" opt "$@"; do
    case "$opt" in
      p) profile="$OPTARG" ;;
      d) date_sel="$OPTARG" ;;
      *) usage_iso ;;
    esac
  done
  [[ -n "$profile" ]] || usage_iso

  local date_dir
  if [[ "$date_sel" == "latest" || "$date_sel" == "stable" ]]; then
    local pointer="${OUTPUT_DIR}/${profile}/iso-${date_sel}.txt"
    [[ -f "$pointer" ]] || die "No iso-${date_sel}.txt for profile '${profile}' — build/release an ISO first (./build.sh iso -p ${profile} or iso-only)."
    date_dir=$(tr -d '[:space:]' < "$pointer")
  else
    date_dir="$date_sel"
  fi

  local iso_dir="${OUTPUT_DIR}/${profile}/${date_dir}"
  [[ -d "$iso_dir" ]] || die "No such directory: ${iso_dir}"

  # Prefer the Secure-Boot-repacked, signed ISO (what actually ships) —
  # fall back to the unsigned one if repack was never run in this dev setup.
  local iso
  iso=$(find "$iso_dir" -maxdepth 1 -name "signed_*.iso" | head -n1)
  [[ -n "$iso" ]] || iso=$(find "$iso_dir" -maxdepth 1 -name "*.iso" ! -name "*signed*" | head -n1)
  [[ -n "$iso" ]] || die "No .iso found under ${iso_dir}"

  _locate_ovmf

  # Separate NVRAM store from cmd_qemu's — installer-boot and post-install
  # boot are different machines as far as UEFI is concerned; sharing one
  # would let a MOK enrollment or boot-order change from one contaminate
  # the other.
  local vars_copy="${DATA_DIR}/OVMF_VARS_ISO.fd"
  [[ -f "$vars_copy" ]] || cp "$OVMF_VARS_TEMPLATE_PATH" "$vars_copy"

  local kvm_args=()
  [[ -e /dev/kvm && -w /dev/kvm ]] && kvm_args=(-enable-kvm -cpu host) || echo "no /dev/kvm access — falling back to (slow) TCG emulation" >&2

  local target_disk_args=()
  if [[ -f "$ROOT_IMG" && -f "$ESP_IMG" ]]; then
    log "Attaching disk/root.img + disk/esp.img as an install target (optional — the ISO boots without them)"
    target_disk_args=(-drive if=virtio,format=raw,file="$ROOT_IMG" -drive if=virtio,format=raw,file="$ESP_IMG")
  fi

  echo "==> Booting ${iso} via OVMF (close the window / send SIGTERM to stop)"
  echo "==> This lands in the live installer GUI — it does not automate clicking through it."
  exec qemu-system-x86_64 \
      -machine q35 \
      -smp 4 \
      -m "${QEMU_MEM:-4096}" \
      "${kvm_args[@]}" \
      -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE_PATH" \
      -drive if=pflash,format=raw,file="$vars_copy" \
      -drive if=none,id=isocd,format=raw,readonly=on,file="$iso" \
      -device virtio-scsi-pci,id=scsi0 \
      -device scsi-cd,drive=isocd,bootindex=0 \
      "${target_disk_args[@]}" \
      -device virtio-gpu-pci \
      -display "${QEMU_DISPLAY:-gtk}" \
      -device virtio-net-pci,netdev=net0 \
      -netdev user,id=net0 \
      -device qemu-xhci -device usb-kbd -device usb-tablet \
      -serial mon:stdio
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
  _locate_ovmf
  local ovmf_code="$OVMF_CODE_PATH"

  local vars_copy="${DATA_DIR}/OVMF_VARS.fd"
  [[ -f "$vars_copy" ]] || cp "$OVMF_VARS_TEMPLATE_PATH" "$vars_copy"

  local kvm_args=()
  [[ -e /dev/kvm && -w /dev/kvm ]] && kvm_args=(-enable-kvm -cpu host) || echo "no /dev/kvm access — falling back to (slow) TCG emulation" >&2

  # Every profile this harness boots (gnome/plasma/cosmic) ships
  # shani-video-guest -> qemu-guest-agent, enabled by default. A real
  # libvirt-managed VM always wires up this exact virtio-serial channel for
  # it; without it here, the guest blocks at boot on "Timed out waiting for
  # device /dev/virtio-ports/org.qemu.guest_agent.0" — a harness gap, not a
  # ShaniOS one, so provide the channel like a real hypervisor would.
  local qga_sock="${DATA_DIR}/qga.sock"
  rm -f "$qga_sock"

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
      -chardev socket,path="$qga_sock",server=on,wait=off,id=qga0 \
      -device virtio-serial \
      -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
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
  iso)       cmd_iso "$@" ;;
  clean)     cmd_clean "$@" ;;
  *)
    usage
    ;;
esac
