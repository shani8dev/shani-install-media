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
# ca         [extra-host ...] writes: disk/ca/{ca.crt,ca.key,server.crt,server.key,<extra-host>.crt,...}
# bootstrap  -p <profile> [-d latest|stable|<date>]
#              reads:  OUTPUT_DIR/<profile>/... (config.sh — this repo's own build output)
#              writes: @blue / @green subvolumes on disk/root.img
# serve      [port] [docroot] [cert-host] serves a docroot over HTTPS as a CA'd hostname (blocks)
# enter      <blue|green> [--boot] [--local-src=<dir>] [cmd...]
# install    -p <profile> [-d latest|stable|<date>] [--encrypted]
#              real, unmodified os-installer-config install.sh against a fresh whole-disk image
# configure  -p <profile> [--encrypted]
#              real, unmodified os-installer-config configure.sh against install's result
# upgrade    Real, direct shani-deploy --force --channel latest --skip-self-update
#              (download/verify/extract/sign/deploy — does NOT go through
#              shani-update, which needs a real display for its progress
#              terminal). See update-check for shani-update.sh itself.
# update-check  Real shani-update.sh (GUI-dialog fallback + console-approval
#              prompt, PTY-fed 'y') — proves shani-update's own decision
#              logic, not a complete deploy (its shani-deploy hand-off also
#              needs a real display).
# reboot     (re-enter whichever slot is now current)
# rollback   (real shani-deploy --rollback, same direct-call reasoning as upgrade)
# cycle      ca (if missing) → bootstrap -p <profile> (real install.sh+
#            configure.sh) → serve (background) → upgrade (real shani-deploy)
#            → reboot
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

# realpath -m'd (not just interpolated, unlike a plain "${SCRIPT_DIR}/disk"
# concat) so an override left as a relative path (SHANIOS_TEST_DATA, now
# forwarded from the host by run_in_container.sh) can't silently resolve
# against whatever the current CWD happens to be and land somewhere
# unintended — SCRIPT_DIR/REPO_ROOT already get this same realpath
# treatment; DATA_DIR was the one path in this file that didn't. Prompted
# by finding a stray root-owned
# shani-install-media/shani-install-media/test-env/disk/... nested one
# level too deep on disk (the **/test-env/disk/* .gitignore fallback
# already covers it existing, but not why) — the exact original trigger
# wasn't confirmed, but this closes the one concrete CWD-dependent gap
# actually found in this file, and the fallback below now clarifies it's
# a real, previously-unexplained artifact rather than purely hypothetical.
DATA_DIR="$(realpath -m "${SHANIOS_TEST_DATA:-${SCRIPT_DIR}/disk}")"
# Deliberately NOT under /mnt: the real install.sh/configure.sh hardcode
# /mnt as their own install target, and configure.sh's mount_target()
# mounts subvol=@<slot> directly AT /mnt (not /mnt/@<slot>) — a read-only
# snapshot once configure.sh finishes, matching a real booted system's ro
# rootfs. A test-harness mountpoint nested under /mnt (as this used to be)
# gets silently shadowed by install.sh's own mount, then finds itself
# inside a read-only filesystem after configure.sh's — confirmed live
# ("mkdir: cannot create directory '/mnt/shanios-toplevel': Read-only file
# system" from cmd_bootstrap's post-install/configure step). Same fix as
# OSI_ROOT below: keep the harness's own mountpoints off /mnt entirely.
MNT="$(realpath -m "${SHANIOS_TEST_MNT:-/opt/shanios-toplevel}")"
ESP_MNT="$(realpath -m "${SHANIOS_TEST_ESP_MNT:-/opt/shanios-esp}")"
CA_DIR="${DATA_DIR}/ca"
ROOT_IMG="${DATA_DIR}/root.img"
ESP_IMG="${DATA_DIR}/esp.img"
INSTALL_IMG="${DATA_DIR}/install.img"
INHIBIT_STUB="${DATA_DIR}/.systemd-inhibit-stub.sh"
# Repo root (shani-install-media). Inside the builder container this is the
# same tree that run_in_container.sh bind-mounts at /home/builduser/build.
# It is bound READ-ONLY into every nspawn slot at /mnt/repo so tests can run
# repo scripts (scripts/, test-scripts/, etc.) inside the installed system
# without copying files into slot overlays by hand.
REPO_ROOT="$(realpath "${SCRIPT_DIR}/..")"
# Optional extra nspawn binds: "host_src:ctr_dst[,host_src2:ctr_dst2,...]"
# Applied read-write to both `enter` and `verify-boot` invocations.
EXTRA_BINDS="${SHANIOS_TEST_EXTRA_BINDS:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  disk        Create loop-backed ESP+root disk images (root.img/esp.img) —
              a faster, fabricate-only disk pair. NOT used by bootstrap
              anymore (which creates its own install.img via the real
              install.sh instead); only relevant if something else in your
              workflow specifically wants a pre-partitioned pair. Self-heals
              stale/duplicate loop-device attachments left over from a
              previous run_in_container.sh session (see "Loop-device
              attachment" below).
  ca          [extra-host ...]   Generate a throwaway CA + a leaf server cert
              for downloads.shani.dev, plus one more per extra hostname given
              (e.g. ca raw.githubusercontent.com) — see "The local mirror"
              in README.md for how to wire a hostname up end to end.
  pacstrap    -p <profile>   Real signature-verification smoke test: runs an
              actual `pacstrap` against that profile's real pacman.conf into
              a throwaway target (removed on success), using the builder
              container's real, already-populated pacman keyring — proves a
              SigLevel/mirror/keyring change actually works in ~1-2 minutes
              instead of a full 30+ min image build. Target is left in place
              for inspection on failure.
  bootstrap   -p <profile> [-d latest|stable|<date>] [--encrypted]   Runs the
              REAL install.sh+configure.sh (calls cmd_install/cmd_configure
              directly) to produce @blue/@green, plus one genuinely
              test-only step: trust-anchoring this session's throwaway CA
              into both slots. Requires `ca` to have been run first.
  serve       [port] [docroot] [cert-host]   Serve a docroot as an HTTPS
              stand-in for cert-host (default: cache/output as
              downloads.shani.dev). Binds 127.0.0.1 unless SHANIOS_TEST_SERVE_ALL=1.
              Run a second instance on a different port/docroot/cert-host to
              stand in for a second external hostname at the same time.
  enter       Enter a slot via systemd-nspawn (requires <blue|green> [--boot]
              [--local-src=<dir>] [cmd...]). The repo is available read-only
              inside at /mnt/repo — run repo scripts directly, e.g.:
              enter blue /mnt/repo/scripts/foo.sh
              --local-src=/opt/shani-deploy/scripts overlays the sibling
              shani-deploy checkout's CURRENT scripts (shani-deploy,
              gen-efi, shani-update, check-boot-failure, shani-health,
              shani-reset, shani-user-setup, beesd-setup) and systemd units
              over the package-installed ones — see "Testing edited
              scripts" in README.md.
  verify-boot [blue|green] [seconds]   Headless boot smoke test: full systemd
              --boot, console captured to disk/boot-<slot>-console.log, then
              reports reached target / failed units. No display or TTY needed.
  desktop     <blue|green> [--exec="cmd"] [--out=<file.png>] [--timeout=N]
              [--settle=N]   Real GNOME desktop verification via nspawn --
              no VM, no host GPU/display needed (runs inside the container,
              unlike qemu/gui/iso). Boots the slot for real (--boot, so
              systemd-logind exists), nsenter's into it once it settles, and
              runs a controlled `gnome-shell --headless` session, optionally
              running --exec="..." inside it (e.g. flip a theme setting)
              before screenshotting via GNOME Shell's own D-Bus Screenshot
              API. Only GNOME is proven end-to-end so far — Plasma/Cosmic
              would need the same recipe with kwin_wayland --virtual /
              cosmic-comp's headless mode instead.
  probe       <blue|green> --exec="cmd" [--timeout=N] [--settle=N]
              [--local-src=<dir>]   Generic live-boot diagnostic: boots the
              slot for real (--boot), nsenter's in once a Multi-User/
              Graphical target is reached, runs any command (e.g.
              `systemctl status <unit> --no-pager -l`), prints its output.
              Built for when verify-boot's console-log capture isn't
              reliable enough — confirmed live that some units genuinely
              start/fail without either line appearing in the captured
              console output, so `probe` asking systemd directly is the
              only way to get a real answer for those.
  install     -p <profile> [-d latest|stable|<date>] [--encrypted]   Runs the
              REAL os-installer-config install.sh (partitioning, LUKS,
              subvolumes, image extraction) against a fresh whole-disk image
              — see "install / configure" in README.md.
  configure   -p <profile> [--encrypted]   Runs the REAL os-installer-config
              configure.sh (locale/hostname/user/Secure Boot/UKI) against
              install's result. Must follow install (same --encrypted).
  upgrade     [--local-src=<dir>] [extra shani-deploy args...]   Real deploy:
              calls shani-deploy directly (--force --channel latest
              --skip-self-update) — download, SHA256+GPG verify, extract,
              gen-efi UKI generation/signing, boot-entry write. Does NOT go
              through shani-update (needs a real display for its progress
              terminal) — see update-check for that layer specifically.
  update-check [--local-src=<dir>] [extra shani-update args...]   Real
              shani-update.sh: GUI-dialog fallback chain (fails over, no
              display here) then a genuine console-approval prompt, fed 'y'
              via an allocated pty. Proves shani-update's own dialog/prompt/
              decision logic — its shani-deploy hand-off still needs a real
              display, so this does NOT complete an actual deploy; use
              `upgrade` for that.
  reboot      Simulate a reboot (re-enters whichever slot is now current)
  rollback    [--local-src=<dir>]   Real rollback: calls shani-deploy
              --rollback directly (same direct-call reasoning as upgrade —
              shani-update's --rollback ALSO needs a real display)
  cycle       ca (if missing) → bootstrap → serve (background) → upgrade → reboot (requires -p <profile>)
  qemu        Genuine UEFI boot via OVMF — HOST-ONLY, see below
              [--vnc[=port]]   Serve the real framebuffer over VNC-over-
              websocket (default port 5700) instead of a local GTK window —
              open it in `watch`'s Desktop panel, or any VNC client at
              localhost:5900.
  gui         Headless real-desktop check via OVMF+QMP+guest-agent — HOST-ONLY,
              see below (requires python3 on the host; no distrobox/socat).
              [--exec="shell command"] [--out=<file.ppm>] [--timeout=N]
  watch       [--port=N]   HOST-ONLY local dashboard (default
              http://127.0.0.1:8090/) to actually SEE a boot: live-tails
              whichever *-console.log is newest (desktop/verify-boot), plus
              a noVNC panel for `qemu --vnc`. Nothing leaves 127.0.0.1.
  iso         Boot a real installer ISO via OVMF — HOST-ONLY, see below (requires -p <profile> [-d latest|stable|<date>])
  clean       Unmount everything and detach root.img/esp.img/install.img's loop devices

Loop-device attachment does NOT survive across separate
run_in_container.sh invocations (each is a fresh --rm'd container) — every
disk/enter/cycle call re-attaches (or reuses) root.img/esp.img's loop
devices, and every bootstrap/install call re-attaches (or reuses)
install.img's, on the HOST, but nothing ever detaches them again on its own.
Run clean when you're done testing, or loop devices accumulate on the
host indefinitely across a session (only a reboot or manual losetup -d
otherwise releases them). root.img/esp.img/install.img themselves are left alone —
clean only tears down mounts and loop attachments, not the disk images.

Options:
  -p <profile>    Profile name (e.g. gnome, plasma) — for bootstrap/cycle/iso
  -d <sel>        Image selector: 'latest' (default), 'stable', or a date — for bootstrap/cycle/iso

Environment:
  SHANIOS_TEST_EXTRA_BINDS   Extra nspawn binds "host:ctr[,host:ctr...]"
                             (read-write, applied to enter and verify-boot)
  SHANIOS_TEST_SERVE_ALL=1   Let serve bind 0.0.0.0 instead of 127.0.0.1
  SHANIOS_TEST_DATA          Override the data dir (default test-env/disk)
  SHANIOS_TEST_OSI_HOST_DIR  Path to the os-installer-config checkout on the
                             HOST (default: ../os-installer-config next to
                             this repo) — set on the run_in_container.sh
                             invocation, not test.sh itself
  INSTALL_DISK_SIZE          Whole-disk image size for install (default 24G)
  SHANIOS_TEST_LUKS_PIN      LUKS passphrase for install --encrypted /
                             configure --encrypted (default: shanios-test-passphrase)
  SHANIOS_TEST_OSI_*         Override individual configure.sh OSI_* values
                             (OSI_LOCALE, OSI_TIMEZONE, OSI_KEYBOARD, OSI_USERNAME,
                             OSI_USER_NAME, OSI_USER_PASSWORD, OSI_ROOT_PASSWORD,
                             OSI_FORMATS, OSI_AUTOLOGIN) — see configure's
                             defaults below

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
  ./run_in_container.sh build.sh test install -p plasma
  ./run_in_container.sh build.sh test configure -p plasma
  ./run_in_container.sh build.sh test clean

qemu/gui/iso need your GPU/display (gui needs it indirectly, via QEMU's own
graphics device — see below), so run this file directly on the HOST instead
of through build.sh/run_in_container.sh (which would put it in a container):
  test-env/test.sh qemu
  test-env/test.sh gui --exec="gsettings get org.gnome.desktop.interface gtk-theme"
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
#
# Loop devices themselves, however, DO live in the host kernel (not the
# container's namespace) and are exposed into every container via
# run_in_container.sh's `-v /dev:/dev` — so a loop device attached by an
# EARLIER container invocation that never ran `clean` is still attached when
# a later, unrelated container starts. Two things go wrong from this if
# unhandled: (1) `losetup -j <img>` can find MORE THAN ONE loop device
# already bound to the same backing file (e.g. a previous `disk`/`enter` run
# that was interrupted before writing .root_loop, then something re-attached
# a second one), which silently broke the naive
# `$(losetup -j "$img" | cut -d: -f1)` one-liner this used to be — piping
# multiple lines through command substitution collapses them into one
# newline-containing string, which `ln -sf`/`losetup -d` then choke on; and
# (2) /dev/disk/by-label/* symlinks always get re-pointed at whatever this
# run just resolved, so a stale symlink from a dead loop device is replaced
# rather than left dangling. _loops_for_image/_detach_all_loops/
# _ensure_single_loop below are the shared self-healing primitives — see
# their own comments for exactly how each one behaves.
# ------------------------------------------------------------------

# Prints one loop device path per line currently attached to backing file $1.
# Empty output (no lines) if none are attached. Never fails — a missing
# image or no attachments are both just "no output", not an error.
_loops_for_image() {
  losetup -j "$1" 2>/dev/null | cut -d: -f1
}

# Detaches EVERY loop device currently attached to backing file $1, however
# many there are (0, 1, or a stale duplicate). Used right before an image is
# about to be wiped and recreated (cmd_disk, cmd_install) — at that point no
# attachment should survive, clean or not.
# A prior encrypted `install` run can leave /dev/mapper/shani_root open,
# referencing a partition of a loop device something is about to detach —
# `losetup -d` on a loop device with a live dm-crypt mapping still backed
# by it doesn't fully release the device, and can leave the mapping
# itself dangling against a now-gone backing loop. Every loop-detach path
# in this file (cmd_clean's own loop, and _detach_all_loops below) needs
# this same close-first step — confirmed live: without it, a second
# `install --encrypted` run in the same session fails with "Device
# shani_root already exists." / "LUKS open failed" even though the loop
# was already "detached". One shared helper instead of duplicating the
# same 3 lines in both places.
_close_stale_shani_root_mapper() {
  [[ -e /dev/mapper/shani_root ]] || return 0
  log "Closing stale LUKS mapper shani_root"
  cryptsetup close shani_root 2>/dev/null || true
}

_detach_all_loops() {
  local img="$1" loop
  _close_stale_shani_root_mapper
  while read -r loop; do
    [[ -n "$loop" ]] || continue
    log "Detaching loop device $loop (stale attachment to $img from a previous session)"
    losetup -d "$loop" 2>/dev/null || warn "Failed to detach $loop"
  done < <(_loops_for_image "$img")
}

# Ensures exactly ONE loop device is attached to backing file $1 and prints
# its path to stdout. This is the "reuse cleanly, or detach+reattach" half of
# the contract (cmd_disk's preflight uses _detach_all_loops instead, since it
# always wipes the image anyway): zero attachments -> attach fresh; exactly
# one -> reuse it as-is (the common case: reattaching after a prior
# container exited without `clean`); MORE than one (the actual "stale/
# duplicate loop-device attachments" scenario from a prior session) -> log a
# warning, detach ALL of them, then attach one fresh device — never guesses
# which of several existing attachments is "the right one".
_ensure_single_loop() {
  local img="$1"
  local -a loops=()
  local l
  while read -r l; do
    [[ -n "$l" ]] && loops+=("$l")
  done < <(_loops_for_image "$img")

  if (( ${#loops[@]} > 1 )); then
    warn "Found ${#loops[@]} loop devices attached to $img at once (${loops[*]}) — this is the stale/duplicate-attachment scenario from a prior run_in_container.sh session; detaching all of them and reattaching cleanly"
    for l in "${loops[@]}"; do
      losetup -d "$l" 2>/dev/null || warn "Failed to detach stale loop device $l"
    done
    loops=()
  fi

  if (( ${#loops[@]} == 1 )); then
    echo "${loops[0]}"
    return 0
  fi

  losetup --find --show "$img" || die "Failed to attach loop device for $img"
}

_ensure_disk_attached() {
  [[ -e /dev/disk/by-label/shani_root && -e /dev/disk/by-label/shani_boot ]] && return 0

  [[ -f "$ROOT_IMG" && -f "$ESP_IMG" ]] \
    || die "root.img/esp.img not found under $DATA_DIR — run '$(basename "$0") disk' first"

  mkdir -p /dev/disk/by-label

  local root_loop esp_loop
  root_loop=$(_ensure_single_loop "$ROOT_IMG")
  esp_loop=$(_ensure_single_loop "$ESP_IMG")

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

  # 32G disk (~28GB usable after btrfs metadata overhead) for deployment testing.
  local root_size="${ROOT_SIZE:-32G}"
  local esp_size="${ESP_SIZE:-512M}"

  mkdir -p "$DATA_DIR" /dev/disk/by-label

  # Preflight: this command is about to wipe and recreate both images, so any
  # loop device already attached to them — whether left over cleanly from a
  # previous session (documented in `clean`'s help text) or a stale/duplicate
  # attachment (more than one loop device bound to the same backing file,
  # which happens if an earlier session's disk/enter/bootstrap was
  # interrupted) — must go first. setup_btrfs_image() (config.sh) only
  # detaches a single, already-known attachment for root.img; do the same
  # (and cover the duplicate case) for both images here explicitly, rather
  # than leaving a human to `losetup -d` + re-disk + re-bootstrap by hand.
  _detach_all_loops "$ROOT_IMG"
  _detach_all_loops "$ESP_IMG"

  log "Setting up root.img (Btrfs, LABEL=shani_root, ${root_size})"
  setup_btrfs_image "$ROOT_IMG" "$root_size"
  local root_loop="$LOOP_DEVICE"
  btrfs filesystem label "$root_loop" shani_root

  log "Setting up esp.img (FAT32, LABEL=shani_boot, ${esp_size})"
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
# pacstrap — real signature-verification smoke test for a profile's
# pacman.conf, independent of a full `build.sh image` run (30+ min).
#
# Runs an actual `pacstrap -cC image_profiles/<profile>/pacman.conf` against
# a throwaway target directory with a small, real package set — this is the
# same command build-base-image.sh uses, just pointed at a scratch dir
# instead of the real build's subvolume mount, so a SigLevel/mirror/keyring
# change can be proven to actually work (or fail) in minutes, using the
# real builder container's already-populated pacman keyring, without
# waiting for or discarding a full image build.
# ------------------------------------------------------------------
cmd_pacstrap() {
  local profile
  profile="$(_get_profile "$@")"
  [[ -n "$profile" ]] || die "pacstrap requires -p <profile>"

  local conf="${REPO_ROOT}/image_profiles/${profile}/pacman.conf"
  [[ -f "$conf" ]] || die "No such profile pacman.conf: $conf"

  local target
  target="$(mktemp -d "${DATA_DIR}/pacstrap-check.XXXXXX")"
  log "Real pacstrap smoke test — profile: ${profile}  config: ${conf}"
  log "Target (throwaway, removed after): ${target}"

  local rc=0
  pacstrap -cC "$conf" "$target" base 2>&1 | tee "${target}.log" || rc=$?

  if [[ -x "${target}/usr/bin/bash" ]]; then
    log "pacstrap OK — real packages installed and signature-verified under ${conf}'s SigLevel."
    rm -rf "$target" "${target}.log"
    return 0
  fi

  warn "pacstrap did NOT produce a working target — see ${target}.log for the real pacman/GPG error."
  warn "(exit code from pacstrap: ${rc}; target left in place for inspection: ${target})"
  return 1
}

# ------------------------------------------------------------------
# clean — undo everything _ensure_disk_attached/cmd_disk/cmd_enter leave
# behind, without touching root.img/esp.img/install.img themselves.
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
  for img in "$ROOT_IMG" "$ESP_IMG" "$INSTALL_IMG"; do
    [[ -f "$img" ]] || continue
    while read -r loop; do
      [[ -n "$loop" ]] || continue
      log "Detaching $loop ($img)"
      # Whole-disk images (install.img) may have partition sub-devices
      # (loopNp1/loopNp2, plus the no-'p' compat symlinks cmd_install
      # creates for install.sh's benefit — see _make_loop_partition_compat)
      # still open (e.g. a LUKS mapping) — close that first so the detach
      # below doesn't fail with "device is busy".
      _close_stale_shani_root_mapper
      rm -f "${loop}1" "${loop}2"
      losetup -d "$loop" 2>/dev/null || warn "Failed to detach $loop"
      any=1
    done < <(losetup -j "$img" 2>/dev/null | cut -d: -f1)
  done

  rm -f /dev/disk/by-label/shani_root /dev/disk/by-label/shani_boot
  rm -f "${DATA_DIR}/.root_loop" "${DATA_DIR}/.esp_loop" "${DATA_DIR}/.install_loop"

  if (( any )); then
    log "Clean complete — root.img/esp.img/install.img left in place, everything else torn down"
  else
    log "Nothing to clean up"
  fi
}

# ------------------------------------------------------------------
# ca   [extra-host ...]   (was 00b-generate-test-ca.sh)
# ------------------------------------------------------------------
# Generalized beyond downloads.shani.dev: any hostname a test needs to
# intercept (raw.githubusercontent.com for a self-update-source test,
# api.example.com for some other external call, ...) gets its own leaf cert
# signed by the SAME throwaway CA, so a slot only ever needs to trust one CA
# (already done once, at bootstrap time) no matter how many hostnames a
# given test redirects to 127.0.0.1. This is the generalized form of what
# test-env/self-update-test.sh used to hand-roll for
# raw.githubusercontent.com alone — see that file's own comments for the
# end-to-end pattern (mint cert here, serve with `cmd_serve`, resolve via
# `cmd_enter`'s hosts file — see _ensure_test_hosts_file below).
#
# Filenames: downloads.shani.dev keeps its historical server.crt/server.key
# (predates multi-host support, and is still what run_in_container.sh's own
# --add-host hardcodes); every other hostname gets <host>.crt/<host>.key.
# Re-running `ca` is additive and idempotent per-hostname — it only
# generates a cert for a hostname that doesn't already have one; delete a
# specific <host>.crt/<host>.key (or the whole ca dir, which also forces the
# CA itself to regenerate) to force a re-mint.
# ------------------------------------------------------------------
cmd_ca() {
  mkdir -p "$CA_DIR"

  local -a hosts=("downloads.shani.dev" "$@")

  if [[ -f "${CA_DIR}/ca.crt" && -f "${CA_DIR}/ca.key" ]]; then
    log "Test CA already exists under ${CA_DIR} — reusing (delete ca.crt/ca.key, and every leaf cert, to regenerate from scratch)."
  else
    log "Generating throwaway CA (NOT FOR PRODUCTION) ..."
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
      -keyout "${CA_DIR}/ca.key" -out "${CA_DIR}/ca.crt" \
      -subj "/CN=shanios-test-env local CA (NOT FOR PRODUCTION)"
  fi

  local host crt key csr
  for host in "${hosts[@]}"; do
    if [[ "$host" == "downloads.shani.dev" ]]; then
      crt="${CA_DIR}/server.crt"; key="${CA_DIR}/server.key"
    else
      crt="${CA_DIR}/${host}.crt"; key="${CA_DIR}/${host}.key"
    fi

    if [[ -f "$crt" && -f "$key" ]]; then
      log "Leaf cert for ${host} already exists (${crt}) — reusing (delete it to regenerate)."
      continue
    fi

    log "Minting leaf cert for ${host}, signed by the test CA ..."
    csr="$(mktemp)"
    openssl req -newkey rsa:2048 -nodes \
      -keyout "$key" -out "$csr" \
      -subj "/CN=${host}"
    openssl x509 -req -in "$csr" -sha256 -days 3650 \
      -CA "${CA_DIR}/ca.crt" -CAkey "${CA_DIR}/ca.key" -CAcreateserial \
      -out "$crt" \
      -extfile <(printf "subjectAltName=DNS:%s" "$host")
    rm -f "$csr" "${CA_DIR}/ca.srl"
    chmod 644 "$crt"
    chmod 600 "$key"
  done

  log "Done. CA + leaf cert(s) for: ${hosts[*]} — written under ${CA_DIR} (persists across runs)."
}

# Resolves -p <profile> -d <latest|stable|<date>> to a concrete
# <profile>-<version>.zst path under OUTPUT_DIR — shared by cmd_bootstrap and
# cmd_install so both ever pick the exact same build for a given selector.
# Prints the resolved path to stdout; dies with a pointer to the right
# `./build.sh release` invocation if nothing matches.
_resolve_build_image() {
  local profile="$1" date_sel="$2"
  local image

  if [[ "$date_sel" == "latest" || "$date_sel" == "stable" ]]; then
    local pointer="${OUTPUT_DIR}/${profile}/${date_sel}.txt"
    [[ -f "$pointer" ]] || die "No ${date_sel}.txt for profile '${profile}' — build/release it first (./build.sh release -p ${profile} ${date_sel})."
    local filename date_dir
    filename=$(tr -d '[:space:]' < "$pointer")
    # `|| true`: under `set -e -o pipefail`, if grep finds no match the
    # pipeline's exit status is 1, and — a real, easy-to-miss bash gotcha —
    # an assignment whose sole content is a command substitution propagates
    # that status to the assignment itself, which set -e treats as fatal.
    # Without the guard, a malformed pointer file would silently kill the
    # script right here instead of ever reaching the friendly die() below.
    date_dir=$(echo "$filename" | grep -oE '[0-9]{8}' | head -n1) || true
    [[ -n "$date_dir" ]] || die "Couldn't parse a date out of '${filename}' from ${pointer}"
    image="${OUTPUT_DIR}/${profile}/${date_dir}/${filename}"
  else
    image=$(find "${OUTPUT_DIR}/${profile}/${date_sel}" -maxdepth 1 -name "*-${profile}.zst" | head -n1)
    [[ -n "$image" ]] || die "No .zst found under ${OUTPUT_DIR}/${profile}/${date_sel}"
  fi

  [[ -f "$image" ]] || die "Image not found: $image"
  echo "$image"
}

# ------------------------------------------------------------------
# bootstrap   (was 01-bootstrap-rootfs.sh)
# ------------------------------------------------------------------
cmd_bootstrap() {
  # This used to be a fast, hand-rolled alternative to a real install —
  # receiving a pre-built .zst directly and snapshotting it, skipping
  # install.sh entirely, then separately reimplementing install.sh's own
  # create_subvolumes()/create_swapfile() lists, configure.sh's gen-efi
  # invocation, AND shani-deploy.sh's own loader-entry-writing conventions
  # by hand. Three separate parallel reimplementations of real production
  # logic living in this ONE file, none of them able to notice when the
  # real thing they were copying changed. Replaced entirely: this now
  # just calls the REAL install.sh/configure.sh via cmd_install/
  # cmd_configure — slower (a genuine partition+format+extract, not a
  # quick btrfs receive), but this now genuinely IS what a real install
  # produces, not a hand-maintained lookalike of it. The only step kept
  # here is the one thing that's genuinely test-only and has no
  # production equivalent to call instead: trust-anchoring this session's
  # throwaway CA into each slot, so cmd_serve's local HTTPS mirror
  # verifies for real inside a booted/entered slot.
  local usage_bootstrap="Usage: $(basename "$0") bootstrap -p <profile> [-d latest|stable|<date>] [--encrypted]"
  local encrypted=0
  local -a rest=()
  local a
  for a in "$@"; do
    case "$a" in
      --encrypted) encrypted=1 ;;
      *) rest+=("$a") ;;
    esac
  done
  set -- "${rest[@]}"

  local profile="" date_sel="latest" opt OPTARG OPTIND=1
  while getopts "p:d:" opt "$@"; do
    case "$opt" in
      p) profile="$OPTARG" ;;
      d) date_sel="$OPTARG" ;;
      *) die "$usage_bootstrap" ;;
    esac
  done
  [[ -n "$profile" ]] || die "$usage_bootstrap"

  local ca_crt="${CA_DIR}/ca.crt"
  [[ -f "$ca_crt" ]] || die "Test CA not found at ${ca_crt} — run '$(basename "$0") ca' first."

  local -a install_args=(-p "$profile" -d "$date_sel")
  (( encrypted )) && install_args+=(--encrypted)
  cmd_install "${install_args[@]}"
  local -a configure_args=(-p "$profile")
  (( encrypted )) && configure_args+=(--encrypted)
  cmd_configure "${configure_args[@]}"

  log "Trust-anchoring this session's throwaway CA into @blue/@green (test-only — no production equivalent)"
  _mount_root
  local slot
  for slot in @blue @green; do
    if [[ -x "$MNT/$slot/usr/bin/trust" ]]; then
      btrfs property set -f -ts "$MNT/$slot" ro false
      cp "$ca_crt" "$MNT/$slot/etc/ca-certificates/trust-source/anchors/shanios-test-ca.crt"
      chroot "$MNT/$slot" trust extract-compat
      btrfs property set -f -ts "$MNT/$slot" ro true
    else
      warn "'trust' not found in @${slot#@} — local-mirror TLS verification will fail."
    fi
  done

  log "Bootstrap complete (via real install.sh + configure.sh)."
  log "Next: $(basename "$0") enter blue"
}

# ------------------------------------------------------------------
# serve   [port] [docroot] [cert-host]   (was 02-serve-update.sh)
# ------------------------------------------------------------------
# Defaults (port 443, OUTPUT_DIR, downloads.shani.dev) are unchanged from
# before this took extra args — every existing call site keeps working
# untouched. To stand in for a SECOND external hostname with genuinely
# different content (e.g. raw.githubusercontent.com serving a self-update
# payload while downloads.shani.dev keeps serving OUTPUT_DIR), run a second,
# independent `serve` in its own session on a different port with that
# hostname's own docroot and cert-host:
#   ./run_in_container.sh build.sh test ca raw.githubusercontent.com
#   ./run_in_container.sh build.sh test serve 8443 /some/other/docroot raw.githubusercontent.com &
# `cmd_enter`'s hosts file (_ensure_test_hosts_file) resolves
# raw.githubusercontent.com to 127.0.0.1 automatically once it's been `ca`'d
# — the two servers just need to listen on different ports since they share
# one loopback (or run one at a time on 443 if the scripts under test only
# ever hit one external host per invocation, like self-update-test.sh does).
# ------------------------------------------------------------------
cmd_serve() {
  local port="${1:-443}"
  local docroot="${2:-$OUTPUT_DIR}"
  local cert_host="${3:-downloads.shani.dev}"

  local crt key
  if [[ "$cert_host" == "downloads.shani.dev" ]]; then
    crt="${CA_DIR}/server.crt"; key="${CA_DIR}/server.key"
  else
    crt="${CA_DIR}/${cert_host}.crt"; key="${CA_DIR}/${cert_host}.key"
  fi
  [[ -f "$crt" && -f "$key" ]] \
    || die "No leaf cert for '${cert_host}' under ${CA_DIR} — run '$(basename "$0") ca ${cert_host}' first."
  [[ -d "$docroot" ]] \
    || die "${docroot} not found."

  # Bind to loopback by default: this server hands out full system images and
  # uses a self-signed CA, so exposing it on all interfaces is a footgun.
  # Opt into 0.0.0.0 explicitly (e.g. containers on a bridge network) with
  # SHANIOS_TEST_SERVE_ALL=1.
  local bind_host="127.0.0.1"
  if [[ "${SHANIOS_TEST_SERVE_ALL:-0}" == "1" ]]; then
    bind_host="0.0.0.0"
  fi

  log "Serving ${docroot} on https://${bind_host}:${port} (CN=${cert_host})"
  log "Available profiles: $(find "$docroot" -maxdepth 1 -mindepth 1 -type d -printf '%f ' 2>/dev/null)"

  cd "$docroot" && exec python3 - "$port" "$crt" "$key" "$bind_host" <<'PYEOF'
import http.server, ssl, sys

port, certfile, keyfile, bind_host = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("  " + (fmt % args) + "\n")

httpd = http.server.HTTPServer((bind_host, int(port)), QuietHandler)
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

# install.sh/configure.sh (os-installer-config) call every privileged
# operation through `sudo <cmd>`, on the assumption they're run as an
# unprivileged user during a real install. Inside this container we're
# already root — `sudo` as UID 0 normally succeeds anyway via pam_rootok.so
# (no password, no sudoers entry needed), but the published builder image is
# built for image/ISO assembly, not for running an installer, so `sudo`
# itself may not even be installed (check_dependencies_install handles
# that) and its default sudoers may be more restrictive in some base image
# variant. Belt-and-suspenders: add an explicit NOPASSWD entry for root too,
# idempotently — this only ever touches the throwaway container's own
# /etc/sudoers, never anything that leaves the container.
_ensure_root_sudo() {
  command -v sudo &>/dev/null || return 0
  grep -qxF 'root ALL=(ALL) NOPASSWD: ALL' /etc/sudoers 2>/dev/null \
    || echo 'root ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers
}

# configure.sh's setup_hostname_target/setup_locale_target/
# setup_keyboard_target/setup_timezone_target all end each `run_in_target`
# command with a real hostnamectl/localectl/timedatectl call in a `&&`
# chain — on a genuinely booted live-ISO install these succeed because the
# live session's own already-running systemd/hostnamed/localed/timedated get
# rbind-mounted into the chroot along with /run. Two things are missing here
# for that to work: (1) sd_booted() — which every one of those tools checks
# FIRST, unconditionally — only returns true if /run/systemd/system exists,
# which no real systemd instance in this container ever creates since none
# is running as PID 1; and (2) an actual hostnamed/localed/timedated
# registered on the bus to answer the D-Bus call itself. Faking both here
# (rather than in configure.sh, which must stay unmodified) is enough: the
# preceding half of each chained command (a plain `echo ... > /etc/...`
# inside the chroot) already writes the REAL value into the target
# correctly regardless — these three daemons only need to make the SECOND
# half of the chain return 0 instead of aborting the whole script via
# configure.sh's ERR trap. They're started unchrooted (this container's own
# /etc, thrown away on exit) since configure.sh's mount_target() runs later
# and would make a pre-chroot invocation moot anyway.
_ensure_systemd_target_services() {
  _ensure_dbus
  mkdir -p /run/systemd/system

  # Docker bind-mounts this container's own /etc/hostname as a single-file
  # mount point (a normal Docker behavior, unrelated to anything test.sh
  # does) — systemd-hostnamed (see below) writes a NEW static hostname via
  # unlink+rename, which fails with EBUSY against a live mount point.
  # systemd-hostnamed only ever touches the outer container's OWN /etc here
  # (see the comment above), which this harness has no use for anyway, so
  # freeing that mountpoint is harmless.
  umount -l /etc/hostname 2>/dev/null || true

  local svc bin
  for svc in hostnamed localed timedated; do
    bin="/usr/lib/systemd/systemd-${svc}"
    pgrep -f "systemd-${svc}" &>/dev/null && continue
    if [[ -x "$bin" ]]; then
      "$bin" &>/dev/null &
      disown
    else
      warn "$bin not found — hostnamectl/localectl/timedatectl inside configure.sh's chroot may fail"
    fi
  done
  sleep 1
}

# ------------------------------------------------------------------
# enter   (was 03-enter-slot.sh)
# ------------------------------------------------------------------
# ------------------------------------------------------------------
# Shared enter/boot preparation
# ------------------------------------------------------------------
# Prepares mounts + overlay for entering/booting a slot. Sets globals:
#   SLOT_DIR, ROOT_LOOP, ESP_LOOP, NSPAWN_WORK
#
# Overlay hygiene matters: every run_in_container.sh invocation is a fresh
# container that dies without cleanup, so a previous overlay mount may still
# be present, and an overlay workdir that still holds another mount's
# index/journal MUST NOT be reused — remounting with a dirty workdir yields
# missing/stale views of upper-layer files (files written into upper/ from
# outside appear to vanish). Always tear down leftovers and reset the
# journal before mounting.
#
# NOTE: nspawn-overlay-<slot>/upper and /work are INTERNAL overlay state.
# Do not stage files there from the host — inject scripts via /mnt/repo
# (read-only repo bind) or SHANIOS_TEST_EXTRA_BINDS instead.
_enter_prep() {
  local slot="$1"

  _mount_root

  SLOT_DIR="$MNT/@${slot}"
  [[ -d "$SLOT_DIR" ]] || die "@${slot} does not exist — run '$(basename "$0") bootstrap' first"

  mkdir -p "$ESP_MNT"
  mountpoint -q "$ESP_MNT" || mount /dev/disk/by-label/shani_boot "$ESP_MNT"

  # Resolve directly from the by-label symlinks rather than a cached
  # .root_loop/.esp_loop file — those were only ever written by cmd_disk's
  # root.img/esp.img path, never by cmd_install's install.img path (which
  # cmd_bootstrap now always uses), and this naturally does the right thing
  # for an encrypted install too: shani_root then points at the open LUKS
  # mapper (/dev/mapper/shani_root), which is what needs to be bound into
  # nspawn, not the raw underlying partition. _ensure_disk_attached already
  # guarantees both symlinks resolve before this point.
  ROOT_LOOP=$(readlink -f /dev/disk/by-label/shani_root)
  ESP_LOOP=$(readlink -f /dev/disk/by-label/shani_boot)

  NSPAWN_WORK="${DATA_DIR}/nspawn-overlay-${slot}"

  if mountpoint -q "$NSPAWN_WORK/merged" 2>/dev/null; then
    log "Unmounting stale overlay at ${NSPAWN_WORK}/merged"
    umount -R "$NSPAWN_WORK/merged" 2>/dev/null || warn "Failed to unmount ${NSPAWN_WORK}/merged"
  fi
  rm -rf "$NSPAWN_WORK/work"
  mkdir -p "$NSPAWN_WORK/upper" "$NSPAWN_WORK/work" "$NSPAWN_WORK/merged"
  mount -t overlay overlay -o "lowerdir=${SLOT_DIR},upperdir=${NSPAWN_WORK}/upper,workdir=${NSPAWN_WORK}/work" "$NSPAWN_WORK/merged"
}

# Synthesizes an /etc/hosts to bind-mount into a slot: the container's own
# /etc/hosts (which already has run_in_container.sh's own
# --add-host=downloads.shani.dev:127.0.0.1 baked in) plus one
# "127.0.0.1 <host>" line for every extra hostname `cmd_ca` has minted a
# leaf cert for (any *.crt under CA_DIR besides ca.crt/server.crt — see
# cmd_ca). This is what makes "the next person testing something that calls
# out to an external URL" only need `ca <that-host>` — no manual /etc/hosts
# surgery, and nothing ever touches the actual host's /etc/hosts (this file
# lives under DATA_DIR and is bind-mounted BY PATH into the slot, same
# principle as _ensure_inhibit_stub). Regenerated on every call so a host
# `ca`'d after the slot was last entered is picked up on the next `enter`.
# Prints the generated file's path to stdout.
_ensure_test_hosts_file() {
  local out="${DATA_DIR}/.etc-hosts-test"
  cp /etc/hosts "$out"
  local crt host
  for crt in "${CA_DIR}"/*.crt; do
    [[ -e "$crt" ]] || continue
    host="$(basename "$crt" .crt)"
    [[ "$host" == "ca" || "$host" == "server" ]] && continue
    grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+${host}([[:space:]]|\$)" "$out" \
      || echo "127.0.0.1 ${host}" >> "$out"
  done
  echo "$out"
}

# Builds nspawn bind arrays shared by `enter` and `verify-boot`.
# Sets globals: FUSE_BIND, REPO_BIND, EXTRA_BIND_ARR, HOSTS_BIND
_nspawn_binds() {
  FUSE_BIND=()
  [[ -e /dev/fuse ]] && FUSE_BIND=(--bind=/dev/fuse)

  # Read-only view of this repo inside the slot — the supported way to run
  # repo scripts against the installed system (e.g. /mnt/repo/test-scripts/foo.sh).
  REPO_BIND=(--bind-ro="${REPO_ROOT}:/mnt/repo")

  HOSTS_BIND=(--bind="$(_ensure_test_hosts_file):/etc/hosts")

  # Host-persistent cache for shani-deploy's downloaded update images —
  # run_in_container.sh bind-mounts a host dir at /var/cache/shani-downloads
  # (same convention/path as its own CONTAINER_DOWNLOAD_CACHE; keep both in
  # sync if this ever changes), and this binds it over the slot's real
  # /data/downloads. Without it, a full cmd_bootstrap/cmd_install re-run
  # wipes install.img's @data subvolume from scratch, forcing a full
  # multi-GB re-download every time even though the downloaded image itself
  # has nothing to do with any particular install session. A no-op if that
  # container path isn't present (e.g. running test.sh directly on the host
  # rather than through run_in_container.sh).
  DOWNLOAD_CACHE_BIND=()
  [[ -d /var/cache/shani-downloads ]] && DOWNLOAD_CACHE_BIND=(--bind=/var/cache/shani-downloads:/data/downloads)

  EXTRA_BIND_ARR=()
  if [[ -n "$EXTRA_BINDS" ]]; then
    local pair rest="$EXTRA_BINDS"
    while [[ -n "$rest" ]]; do
      pair="${rest%%,*}"
      if [[ "$rest" == *,* ]]; then rest="${rest#*,}"; else rest=""; fi
      [[ "$pair" == *:* ]] || die "SHANIOS_TEST_EXTRA_BINDS entry '${pair}' must be host_path:container_path"
      EXTRA_BIND_ARR+=(--bind="$pair")
    done
  fi
}

# Injects a test-only systemd unit that bind-mounts the REAL generated
# cmdline file (/data/overlay/etc/upper/kernel/install_cmdline_<slot> —
# the same real file cmd_enter's non-boot $setup already uses) over
# /proc/cmdline, inside the slot about to be --boot'd. Needed because
# nspawn shares the HOST kernel and never populates a Shanios-real
# /proc/cmdline on its own — without this, get_booted_subvol()-dependent
# real code (check-boot-failure.service, mark-boot-success's
# boot-success-cleanup) always hits its "cannot detect booted subvolume"
# fallback during a --boot test, which doesn't exercise the logic actually
# being tested.
#
# Ordering: nspawn/systemd always mounts a FRESH procfs for the
# container's own PID namespace as part of very-early startup — a
# pre-boot bind-mount at /proc/cmdline (the trick cmd_enter's non-boot
# path uses) would just get shadowed the moment that happens. This unit
# instead runs INSIDE the booted container, ordered after systemd's own
# early mount setup but before sysinit.target — generously early relative
# to mark-boot-success.service (After=multi-user.target) and
# check-boot-failure.timer (WantedBy=timers.target), the two real
# consumers, so both see the fake value already in place whenever they
# actually run. /data itself needs no ordering dependency — it's already
# present from the moment this container's PID 1 starts (an nspawn-level
# --bind, not something systemd mounts itself).
#
# Written to /etc/systemd/system/ (the standard place for host/admin-
# added units, never a real packaged unit name) in the merged overlay,
# not /usr/lib/systemd/system/ (reserved for what --local-src overlays as
# a stand-in for real packaged units).
_inject_fake_cmdline_unit() {
  local slot="$1"
  local unit_dir="${NSPAWN_WORK}/merged/etc/systemd/system"
  local unit_name="shani-test-fake-cmdline.service"
  mkdir -p "$unit_dir" "${unit_dir}/sysinit.target.wants"
  cat > "${unit_dir}/${unit_name}" <<EOF
[Unit]
Description=TEST-ONLY: fake /proc/cmdline from the real generated cmdline file (nspawn shares the host kernel, never populates a real one)
DefaultDependencies=no
After=systemd-remount-fs.service
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'mount --bind /data/overlay/etc/upper/kernel/install_cmdline_${slot} /proc/cmdline 2>/dev/null || true'

[Install]
WantedBy=sysinit.target
EOF
  ln -sf "../${unit_name}" "${unit_dir}/sysinit.target.wants/${unit_name}"
}

# Injects a REAL (not generator-synthesized) data.mount unit file so
# `systemd-analyze verify` can resolve it as a dependency for
# mark-boot-in-progress.service/mark-boot-success.service/
# check-boot-failure.service/shani-auto-rollback.service (all
# Requires=data.mount) — confirmed live this session that
# systemd-fstab-generator refuses to generate ANY unit for
# `LABEL=shani_root ... subvol=@data` under nspawn ("is read-only
# (running in a container?), ignoring mount for
# /dev/disk/by-label/shani_root" — its own built-in container-detection
# skipping device-label lookups it assumes a container can't safely do),
# even during a genuine --boot session. At RUNTIME this is harmless —
# `/data` is already bind-mounted by nspawn's own --bind before systemd
# starts, and systemd's automatic mountinfo-to-transient-unit mechanism
# creates a live, active data.mount reflecting that reality regardless
# (confirmed live: `systemctl status data.mount` shows "Loaded: loaded
# (/proc/self/mountinfo)", "Active: active (mounted)") — so real units
# depending on it work fine under --boot. The gap is purely in STATIC
# analysis: systemd-analyze verify never consults a live manager for
# dependency resolution, only on-disk unit files, so it reports "Unit
# data.mount not found" even though the live unit genuinely exists and
# works. This stub closes that gap for the static tool without touching
# runtime mount behavior at all: `Where=/data` matches what's already
# mounted, so systemd recognizes it as already-satisfied rather than
# attempting a real mount syscall that would conflict with the existing
# nspawn bind-mount.
_inject_data_mount_unit() {
  local unit_dir="${NSPAWN_WORK}/merged/etc/systemd/system"
  mkdir -p "$unit_dir"
  cat > "${unit_dir}/data.mount" <<EOF
[Unit]
Description=TEST-ONLY: real data.mount unit file so systemd-analyze verify can resolve it as a dependency (see comment above _inject_data_mount_unit in test.sh) — /data is already bind-mounted by nspawn itself before systemd starts, this unit performs no mount action of its own at runtime

[Mount]
What=LABEL=shani_root
Where=/data
Type=btrfs
Options=subvol=@data,noatime,compress=zstd,space_cache=v2,autodefrag
EOF
}

# Injects a test-only early-boot unit that creates the
# /dev/disk/by-label/shani_root and /dev/disk/by-label/shani_boot symlinks
# real hardware gets for free from udev. Needed because a --boot session
# has no real udev managing these loop-backed devices' labels — confirmed
# live via shani-auto-rollback.service genuinely running under a real
# --boot probe and shani-deploy --rollback's own `mount ... /dev/disk/
# by-label/shani_root /mnt` failing with "special device ... does not
# exist" (dmesg: no such symlink). The device nodes themselves ARE already
# present inside the container at these exact paths (`--bind="$ROOT_LOOP"`/
# `--bind="$ESP_LOOP"` in both NSPAWN_ENTER_ARGS and
# NSPAWN_FULL_BOOT_ARGS bind them in unchanged, source path == dest path)
# — only the conventional by-label symlink is missing. cmd_enter's
# non-boot $setup already does exactly this same trick for that path; this
# is the --boot-session equivalent, needed because a full boot has no
# single pre-exec shell hook to run it from.
_inject_by_label_unit() {
  local unit_dir="${NSPAWN_WORK}/merged/etc/systemd/system"
  local unit_name="shani-test-by-label.service"
  mkdir -p "$unit_dir" "${unit_dir}/sysinit.target.wants"
  cat > "${unit_dir}/${unit_name}" <<EOF
[Unit]
Description=TEST-ONLY: /dev/disk/by-label/shani_root + shani_boot symlinks (no real udev for these loop-backed devices under nspawn)
DefaultDependencies=no
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'mkdir -p /dev/disk/by-label && ln -sf ${ROOT_LOOP} /dev/disk/by-label/shani_root && ln -sf ${ESP_LOOP} /dev/disk/by-label/shani_boot'

[Install]
WantedBy=sysinit.target
EOF
  ln -sf "../${unit_name}" "${unit_dir}/sysinit.target.wants/${unit_name}"
}

# Populates NSPAWN_FULL_BOOT_ARGS — the common systemd-nspawn flag block
# shared by every "boot this slot with full systemd" invocation. Found
# duplicated near-verbatim (18 flags, byte-for-byte) in 3 separate places
# (cmd_enter's --boot branch, verify-boot, desktop) — exactly the class of
# drift risk get_booted_subvol's duplication in shani-deploy already
# proved real: fix/extend one copy (a new required --bind, a changed
# --system-call-filter), forget the other two. Call _nspawn_binds first
# (this reads its FUSE_BIND/HOSTS_BIND/REPO_BIND/EXTRA_BIND_ARR globals).
# Also injects the fake-/proc/cmdline unit above — every real "boot this
# slot" caller wants it, so it lives here instead of being called
# separately at each of the same 3 call sites.
# cmd_enter's *non*-boot branch is a real variant, not folded in here — it
# has no --boot/--machine=/--private-users=no/FUSE_BIND/--system-call-
# filter at all, plus its own --bind for the systemd-inhibit stub and a
# trailing exec command; forcing it through this same helper would need
# more parameters than it'd save lines. It fakes /proc/cmdline its own
# way already (a runtime `mount --bind` in $setup, safe there since
# nothing re-mounts /proc afterward in non-boot mode).
# Usage: _nspawn_full_boot_args <machine-name> <slot>
_nspawn_full_boot_args() {
  local machine="$1" slot="$2"
  _inject_fake_cmdline_unit "$slot"
  _inject_data_mount_unit
  _inject_by_label_unit
  NSPAWN_FULL_BOOT_ARGS=(
    --quiet
    --register=no
    --keep-unit
    --boot
    --machine="$machine"
    --directory="$NSPAWN_WORK/merged"
    --capability=all
    --private-users=no
    "${FUSE_BIND[@]}"
    --bind="$ROOT_LOOP"
    --bind="$ESP_LOOP"
    --bind="$MNT/@data:/data"
    "${DOWNLOAD_CACHE_BIND[@]}"
    --bind="$MNT/@swap:/swap"
    --bind="$ESP_MNT:/boot/efi"
    "${HOSTS_BIND[@]}"
    "${REPO_BIND[@]}"
    "${EXTRA_BIND_ARR[@]}"
    --resolv-conf=bind-host
    --system-call-filter='add_key keyctl bpf'
  )
}

# ------------------------------------------------------------------
# Local source overlay for `enter --local-src=<dir>`
# ------------------------------------------------------------------
# Copies edited shani-deploy/gen-efi/shani-update/check-boot-failure scripts
# over the package-installed versions inside the slot that's about to be
# entered — the thing both agents used to do by hand (stage files under
# test-env/edited-*/, then `cp` them into the running slot from inside an
# nspawn session) every time they needed to test an unreleased fix.
#
# Naming convention: <dir>/<name>.sh, where <name> matches EXACTLY what
# shani-pkgbuilds/shani-deploy/PKGBUILD installs at /usr/local/bin/<name> —
# its package() step strips the .sh extension at build time. So:
#   shani-deploy.sh        -> /usr/local/bin/shani-deploy
#   shani-update.sh        -> /usr/local/bin/shani-update
#   gen-efi.sh             -> /usr/local/bin/gen-efi
#   check-boot-failure.sh  -> /usr/local/bin/check-boot-failure
# run_in_container.sh bind-mounts the sibling shani-deploy checkout
# read-only at /opt/shani-deploy (same optional convention as
# /opt/os-installer-config) — always current, nothing to keep in sync by
# hand. Pass its scripts/ dir directly:
#   enter blue --local-src=/opt/shani-deploy/scripts
# Any other *.sh file in the directory is applied the same way (basename
# minus .sh) IF a same-named file already exists at /usr/local/bin in the
# slot; anything that doesn't match an existing installed script is skipped
# with a warning rather than silently ignored (protects against a typo'd
# filename looking like it worked).
#
# Lands in the nspawn overlay's upper layer (via _enter_prep, same as any
# other write made from inside a session) — NOT the real @blue/@green
# subvolume, and NOT test-env/edited-*/ itself. Plain `cp -f`, so running
# this twice (or twenty times) just re-copies the same files: no doubling,
# no error, no state to reset — genuinely idempotent.
# ------------------------------------------------------------------
_overlay_local_src() {
  local slot="$1" src_dir="$2"
  [[ -d "$src_dir" ]] || die "--local-src=${src_dir}: not a directory"

  local target_bin="${NSPAWN_WORK}/merged/usr/local/bin"
  [[ -d "$target_bin" ]] || die "${target_bin} not found inside @${slot} — run '$(basename "$0") bootstrap' first"

  log "Overlaying local sources from ${src_dir} onto @${slot}'s /usr/local/bin:"
  local applied=0 f base dest
  shopt -s nullglob
  for f in "$src_dir"/*.sh; do
    base="$(basename "$f" .sh)"
    dest="${target_bin}/${base}"
    if [[ -e "$dest" || -L "$dest" ]]; then
      cp -f "$f" "$dest"
      chmod 755 "$dest"
      log "  ${f} -> /usr/local/bin/${base}"
      applied=$((applied + 1))
    elif [[ "${SHANIOS_TEST_ALLOW_NEW_LOCAL_SRC:-0}" == "1" ]]; then
      # Opt-in only (SHANIOS_TEST_ALLOW_NEW_LOCAL_SRC=1) — deliberately not
      # the default: introducing a name that was never in the image is
      # indistinguishable, in the default path, from a typo'd filename
      # silently no-op'ing (the exact case the default warn-and-skip below
      # protects against). Genuinely useful for testing an in-progress,
      # not-yet-packaged new script (e.g. one that a real PKGBUILD's
      # scripts/* glob would pick up once committed, but hasn't been
      # committed yet) — confirmed live: caught mark-boot-success.service's
      # real ExecStart=/usr/local/bin/boot-success-cleanup failing with
      # "No such file" precisely because the extracted script existed only
      # as an untracked local file, never overlaid by the default path.
      cp -f "$f" "$dest"
      chmod 755 "$dest"
      log "  [NEW] ${f} -> /usr/local/bin/${base} (did not previously exist in @${slot} — SHANIOS_TEST_ALLOW_NEW_LOCAL_SRC=1)"
      applied=$((applied + 1))
    else
      warn "  skipping ${f}: no existing /usr/local/bin/${base} in @${slot} (not a recognized package-installed script name — set SHANIOS_TEST_ALLOW_NEW_LOCAL_SRC=1 to overlay it anyway, e.g. for a new script that hasn't been packaged/committed yet)"
    fi
  done
  shopt -u nullglob
  (( applied > 0 )) || warn "--local-src=${src_dir}: nothing overlaid (no *.sh under it matched an existing /usr/local/bin script in @${slot})"
  log "Local source overlay complete: ${applied} file(s) applied (this session's overlay only, see ${NSPAWN_WORK}/upper)"

  # Also overlay systemd unit files, if the caller's repo follows the
  # convention `<repo>/scripts/*.sh` + `<repo>/systemd/{system,user}/*` —
  # i.e. $src_dir's own parent has a sibling `systemd/` dir (shani-deploy's
  # actual real layout). Found the hard way: a *.sh-only overlay tests
  # edited *script logic* under `--boot`/`verify-boot`, but any edit to a
  # unit file itself (a hardening directive, a Requires=/After= change)
  # was silently invisible to those same commands — the real, packaged
  # unit files baked into the image are what systemd actually reads at
  # boot, and no verification command touched them. Same safety rule as
  # scripts: only overlay a unit whose name already exists in the image
  # (never introduce a unit that wasn't already packaged there).
  local systemd_root="$(dirname "$src_dir")/systemd"
  [[ -d "$systemd_root" ]] || return 0
  local scope target_units applied_units=0
  for scope in system user; do
    [[ -d "${systemd_root}/${scope}" ]] || continue
    target_units="${NSPAWN_WORK}/merged/usr/lib/systemd/${scope}"
    [[ -d "$target_units" ]] || continue
    for f in "${systemd_root}/${scope}"/*; do
      [[ -f "$f" ]] || continue
      base="$(basename "$f")"
      dest="${target_units}/${base}"
      if [[ -e "$dest" ]]; then
        cp -f "$f" "$dest"
        log "  ${f} -> /usr/lib/systemd/${scope}/${base}"
        applied_units=$((applied_units + 1))
      elif [[ "${SHANIOS_TEST_ALLOW_NEW_LOCAL_SRC:-0}" == "1" ]]; then
        # Same opt-in as the scripts loop above — see its comment.
        cp -f "$f" "$dest"
        log "  [NEW] ${f} -> /usr/lib/systemd/${scope}/${base} (did not previously exist in @${slot})"
        applied_units=$((applied_units + 1))
      else
        warn "  skipping ${f}: no existing /usr/lib/systemd/${scope}/${base} in @${slot} (not a recognized packaged unit — set SHANIOS_TEST_ALLOW_NEW_LOCAL_SRC=1 to overlay it anyway)"
      fi
    done
  done
  if (( applied_units > 0 )); then
    log "Local systemd unit overlay complete: ${applied_units} file(s) applied — takes effect on the next --boot/verify-boot (fresh PID 1 reads units from disk at startup, no daemon-reload needed since nothing is running yet)"
  fi
}

# Shared by cmd_enter's plain (non---boot) path and cmd_upgrade: does every
# bit of prep a non-boot nspawn entry needs (mount/overlay setup, inhibit
# stub, --local-src overlay, the real-cmdline bind-mount, nspawn binds) and
# sets global array NSPAWN_ENTER_ARGS, without executing anything — the
# caller decides how to actually run it (cmd_enter execs it directly and
# replaces this process; cmd_upgrade needs to run it, get a real exit code,
# AND return control to its own caller for cmd_cycle's subsequent
# cmd_reboot step, so it can't use exec).
_prepare_enter_args() {
  local slot="$1"; shift
  local local_src="$1"; shift

  _enter_prep "$slot"

  _ensure_inhibit_stub

  [[ -n "$local_src" ]] && _overlay_local_src "$slot" "$local_src"

  if [[ ${#} -eq 0 ]]; then
    set -- /bin/bash
  fi

  # /proc/cmdline is bind-mounted from the REAL generated cmdline file —
  # not fabricated content, the exact string gen-efi/configure.sh actually
  # write and that would really be embedded in this slot's UKI. Needed
  # because nspawn shares the HOST kernel and was never going to reflect
  # Shanios's real boot cmdline here on its own — without this,
  # get_booted_subvol()-dependent real code (check-boot-failure.service,
  # mark-boot-success's boot-success-cleanup) always hits its "cannot
  # detect booted subvolume" fallback during a test boot, which doesn't
  # exercise anything about the logic actually being tested. Source is
  # `/data/overlay/etc/upper/kernel/install_cmdline_<slot>`, NOT the plain
  # `/etc/kernel/install_cmdline_<slot>` path a real running system would
  # use — confirmed live that the latter only resolves correctly once the
  # real /etc overlay (a dracut pre-pivot hook on real hardware) is
  # actually mounted, which a plain `enter`/`--boot` session here does not
  # set up on its own; the /data bind-mount (already present in every
  # session) reaches the same real file directly regardless.
  local setup='mkdir -p /dev/disk/by-label && ln -sf '"$ROOT_LOOP"' /dev/disk/by-label/shani_root && ln -sf '"$ESP_LOOP"' /dev/disk/by-label/shani_boot && mount --bind /data/overlay/etc/upper/kernel/install_cmdline_'"$slot"' /proc/cmdline 2>/dev/null || true && exec "$@"'

  _nspawn_binds

  # --register=no: skip registering the new machine with systemd-machined
  # over D-Bus (see _ensure_dbus above for why a bus needs to exist at all).
  # --keep-unit: place the container in the CALLING process's own cgroup
  # instead of asking systemd (over that same bus) to allocate a transient
  # scope unit for it — there's no real systemd manager listening as
  # org.freedesktop.systemd1 on this bus, so that request would otherwise
  # fail with "Failed to allocate scope: Failed to execute program
  # org.freedesktop.systemd1: Permission denied".
  NSPAWN_ENTER_ARGS=(
      --quiet
      --register=no
      --keep-unit
      --directory="$NSPAWN_WORK/merged"
      --capability=all
      --bind="$ROOT_LOOP"
      --bind="$ESP_LOOP"
      --bind="$MNT/@data:/data"
      "${DOWNLOAD_CACHE_BIND[@]}"
      --bind="$MNT/@swap:/swap"
      --bind="$ESP_MNT:/boot/efi"
      "${HOSTS_BIND[@]}"
      --bind="${INHIBIT_STUB}:/usr/bin/systemd-inhibit"
      "${REPO_BIND[@]}"
      "${EXTRA_BIND_ARR[@]}"
      --resolv-conf=bind-host
      --
      /bin/bash -c "$setup" -- "$@"
  )
}

# ------------------------------------------------------------------
# enter   <blue|green> [--boot] [--local-src=<dir>] [cmd...]
# ------------------------------------------------------------------
cmd_enter() {
  _ensure_host_machine_id
  _ensure_dbus
  local slot="${1:?Usage: $(basename "$0") enter <blue|green> [--boot] [--local-src=<dir>] [command...]}"
  shift || true
  [[ "$slot" =~ ^(blue|green)$ ]] || die "slot must be 'blue' or 'green'"

  local boot=0 local_src=""
  while [[ "${1:-}" == "--boot" || "${1:-}" == --local-src=* ]]; do
    case "$1" in
      --boot) boot=1; shift ;;
      --local-src=*) local_src="${1#--local-src=}"; shift ;;
    esac
  done

  if (( boot )); then
    _enter_prep "$slot"
    _ensure_inhibit_stub
    [[ -n "$local_src" ]] && _overlay_local_src "$slot" "$local_src"
    _nspawn_binds
    log "Booting @${slot} (full systemd boot via nspawn --boot)"
    _nspawn_full_boot_args "shanios-${slot}" "$slot"
    exec systemd-nspawn "${NSPAWN_FULL_BOOT_ARGS[@]}"
  fi

  _prepare_enter_args "$slot" "$local_src" "$@"
  log "Entering @${slot} via systemd-nspawn (writable overlay, ephemeral upper layer persists across runs in ${NSPAWN_WORK}/upper)"
  exec systemd-nspawn "${NSPAWN_ENTER_ARGS[@]}"
}

# ------------------------------------------------------------------
# Console output during --boot shows each unit's Description= text, never
# its raw file basename (confirmed live: "Finished Mark Boot In Progress
# for Shani OS.", never "Finished mark-boot-in-progress.service.") — so
# aggregate target-reached + failed-unit-count (what verify-boot already
# checked) can't tell you whether a SPECIFIC shani-deploy unit actually
# ran; a WantedBy= symlink typo or a missing enablement would pass that
# check silently. This greps for each one's real Description= text
# instead — never a hard failure on its own (`die` stays reserved for
# emergency-mode/target-not-reached).
#
# IMPORTANT CAVEAT, found the hard way with `probe` (see cmd_probe below):
# the console-log CAPTURE is not a fully reliable proxy for what actually
# happened — mark-boot-success.service and bless-boot.service both
# genuinely started AND failed (confirmed directly via `systemctl status`
# through a live probe), yet NEITHER their "Starting..." nor their
# "Failed to start..." lines appear anywhere in the captured console log.
# So "not observed" here means exactly that — not seen in this capture —
# never "confirmed absent". Treat every "not observed" below as "run
# `probe <slot> --exec=\"systemctl status <unit> --no-pager -l\"` for a
# real answer", not as proof of a problem.
#
# Real, confirmed-via-probe status of the two that never show up here:
#   - mark-boot-success.service DOES start, and fails on its third
#     ExecStart= line: `Unable to locate executable
#     '/usr/local/bin/boot-success-cleanup': No such file or directory`.
#     Not a hardening-directive issue (ProtectSystem=full only blocks
#     WRITES under /usr, never hides or blocks executing a file that's
#     actually there — this is a plain ENOENT) — it's the same image-
#     staleness case as the "boot-success-cleanup.sh skipped" --local-src
#     warning: this script is real and present in the current shani-deploy
#     checkout, but the currently-bootstrapped test image predates it, and
#     --local-src correctly refuses to introduce a binary that isn't
#     already installed. A fresh `build.sh image` would include it.
#   - bless-boot.service DOES start, and fails with
#     `systemd-bless-boot[…]: Marking a boot is not supported in
#     containers.` — systemd-bless-boot's own explicit, deliberate
#     container-refusal (virtualization detection, not a permission
#     check) — would fail identically with zero hardening directives, in
#     any container runtime. Matches the extensive comment already in
#     bless-boot.service about the known upstream systemd-boot regression;
#     not fixable from this side.
# Both confirm multi-user.target IS genuinely reached in this environment
# (also confirmed via probe: "Reached target Multi-User System." in the
# journal) even on boots where the console-log capture doesn't show that
# exact line either.
_verifyboot_check_units() {
  local logfile="$1"
  # unit description; NOTE-if-absent (empty = warn like the others)
  local -a checks=(
    "mark-boot-in-progress.service|Finished Mark Boot In Progress for Shani OS.|"
    "beesd-setup.service|Finished Bees BTRFS deduplication setup.|"
    "shani-user-setup.path|Started Watch for new users and skel changes.|"
    "check-boot-failure.timer|Started Run Boot Failure Check 15 Minutes After Boot.|"
    "flatpak-update-system.timer|Started Periodic Flatpak Update (System).|"
    "mark-boot-success.service|Finished Mark Boot Success for Shani OS.|console capture unreliable for this one — confirmed via probe it actually starts then fails on a missing /usr/local/bin/boot-success-cleanup (image staleness, not a hardening issue)"
    "bless-boot.service|Finished Bless Current Boot - Shani OS Boot Counting.|console capture unreliable for this one — confirmed via probe it actually starts then fails: systemd-bless-boot refuses inside any container (expected, not fixable here)"
  )
  log "── shani-deploy unit checks (by Description=, not file basename — see comment above) ──"
  local entry unit desc note
  for entry in "${checks[@]}"; do
    IFS='|' read -r unit desc note <<<"$entry"
    if grep -aqF "$desc" "$logfile"; then
      log "  [confirmed]     ${unit}"
    elif [[ -n "$note" ]]; then
      warn "  [not observed]  ${unit} (${note})"
    else
      warn "  [not observed]  ${unit} — expected to fire in every boot reaching this point; check its WantedBy= enablement and ConditionPathExists= gates"
    fi
  done
}

# ------------------------------------------------------------------
# verify-boot   [blue|green] [seconds] [--local-src=<dir>]
# ------------------------------------------------------------------
# Headless boot smoke test: boots the slot with full systemd (--boot),
# captures the console to disk for <seconds> (default 90), then reports
# whether the system reached Multi-User/Graphical target and whether any
# units failed. Designed for CI/non-interactive use — never opens a window,
# never needs a TTY. rc=124 from `timeout` is EXPECTED (a healthy boot keeps
# running until the cutoff); any other non-zero rc is a hard failure.
#
# --local-src=<dir> (same flag as `enter`): overlays edited *.sh scripts
# from <dir> onto /usr/local/bin, AND — if <dir>'s parent has a sibling
# systemd/{system,user}/ directory (e.g. pass shani-deploy's scripts/ and
# its systemd/ siblings come along automatically) — overlays edited unit
# files onto /usr/lib/systemd/{system,user} too. Without this, verify-boot
# only ever exercises whatever scripts/units are baked into the bootstrapped
# image, which can be stale relative to a repo's current working tree —
# confirmed live: an image built before a script/unit fix silently boots
# the OLD behavior here with no indication anything is out of date.
cmd_verifyboot() {
  # --local-src=<dir> can appear anywhere among the positional args —
  # pull it out first, then treat what's left as [slot] [seconds] as before.
  local local_src=""
  local -a rest=()
  local a
  for a in "$@"; do
    case "$a" in
      --local-src=*) local_src="${a#--local-src=}" ;;
      *) rest+=("$a") ;;
    esac
  done
  set -- "${rest[@]}"

  local slot="${1:-blue}"
  local timeout_secs="${2:-90}"
  [[ "$slot" =~ ^(blue|green)$ ]] || die "slot must be 'blue' or 'green'"
  [[ "$timeout_secs" =~ ^[0-9]+$ ]] || die "timeout must be numeric seconds"

  _ensure_host_machine_id
  _ensure_dbus

  _enter_prep "$slot"
  [[ -n "$local_src" ]] && _overlay_local_src "$slot" "$local_src"
  _nspawn_binds
  _ensure_inhibit_stub

  local logfile="${DATA_DIR}/boot-${slot}-console.log"
  log "Booting @${slot} headless (max ${timeout_secs}s) — console captured to ${logfile}"

  local rc=0
  _nspawn_full_boot_args "shanios-${slot}" "$slot"
  timeout "$timeout_secs" systemd-nspawn "${NSPAWN_FULL_BOOT_ARGS[@]}" \
      >"$logfile" 2>&1 || rc=$?

  if [[ $rc -ne 0 && $rc -ne 124 ]]; then
    warn "systemd-nspawn exited with rc=$rc before the timeout elapsed"
    tail -30 "$logfile" || true
    die "boot of @${slot} failed (nspawn rc=$rc)"
  fi
  # Health heuristics (distro-target agnostic): a slot may boot a custom
  # default.target (e.g. shanios-vm-guest.target) that never prints
  # "Multi-User System" or "Graphical Interface". Accept any of:
  #   - the two standard final targets, or
  #   - evidence of full userspace: Basic System + Network both reached.
  # A clean halt right at the cutoff is ALSO success: timeout's SIGTERM makes
  # nspawn power the machine off gracefully (rc=0), so the console ends with
  # a shutdown sequence even for perfectly healthy boots.
  local reached="no" failures=0 emergency=0
  if grep -aq "Reached target Graphical Interface" "$logfile" \
     || grep -aq "Reached target Multi-User System" "$logfile" \
     || { grep -aq "Reached target Basic System" "$logfile" \
          && grep -aq "Reached target Network" "$logfile"; }; then
    reached="yes"
  fi
  failures=$(grep -ac "\[FAILED\]" "$logfile" 2>/dev/null || true)
  grep -aqE "Reached target (Emergency|Rescue) Mode" "$logfile" && emergency=1

  log "── verify-boot @${slot} ──────────────────────────────"
  log "  target reached : ${reached}"
  log "  failed units   : ${failures}"
  log "  emergency mode : ${emergency}"
  log "  nspawn rc      : ${rc} (0 after clean halt at cutoff / 124 = still running, both expected)"
  log "  full console   : ${logfile}"

  if [[ "$emergency" == "1" || "$reached" == "no" ]]; then
    tail -40 "$logfile" || true
    die "verify-boot FAILED for @${slot}"
  fi
  if [[ "${failures:-0}" -gt 0 ]]; then
    warn "${failures} unit(s) reported [FAILED] during boot — review ${logfile}"
  fi

  _verifyboot_check_units "$logfile"

  log "verify-boot PASSED for @${slot}"
}

# ------------------------------------------------------------------
# desktop   <blue|green> — real desktop verification via nspawn, no VM
#
# Answers the same question `gui` (QEMU) does — did a GUI app or theme
# change actually render — but runs entirely inside the build container:
# no host GPU/display, no /dev/kvm, no sudo/permission dance over root-owned
# disk images (see `gui`'s own comment above for why that bit HOST-side).
# Confirmed live before writing this: gdm.service genuinely starts under a
# real `--boot` nspawn session and survives 90-180s with zero crashes or
# [FAILED] markers, logging only "Gdm: It appears that your system does not
# have a primary GPU! Proceeding with any GPU" — but GDM's own greeter
# session doesn't log to the systemd journal at all, so this doesn't hook
# into GDM's session. Instead it boots the slot for real (so
# systemd-logind genuinely exists — a plain, non-`--boot` `enter` crashed
# gnome-shell's own JS init on a missing logind connection when this was
# tried first), nsenter's into the live container's namespaces once boot
# settles, and runs its own controlled `gnome-shell --headless
# --virtual-monitor=WxH` session (proven standalone before this: it starts
# a real Wayland compositor with a software/surfaceless renderer, no GPU
# needed) — then screenshots THAT session over its own D-Bus
# (org.gnome.Shell.Screenshot), avoiding GDM's private session bus
# entirely. Plasma/Cosmic would need this same recipe's compositor swapped
# for kwin_wayland --virtual / cosmic-comp's own headless mode respectively
# — not yet done, only GNOME has been proven end-to-end.
# ------------------------------------------------------------------

# ------------------------------------------------------------------
# probe   <blue|green> --exec="cmd" [--timeout=N] [--settle=N] [--local-src=<dir>]
# ------------------------------------------------------------------
# Generic live-boot diagnostic: boots a slot for real (--boot), waits for
# a Multi-User/Graphical target, then nsenter's into the live container's
# namespaces and runs an arbitrary command — e.g. `systemctl status
# data.mount mark-boot-success.service --no-pager -l`. Same
# leader-pid-finding/nsenter mechanism as `desktop`, generalized to any
# command instead of hardcoding a gnome-shell session. Built to
# investigate why a specific unit doesn't show up in a plain verify-boot
# console log — aggregate target-reached/failed-count (and even grepping
# the console for a unit's Description=) can't tell you WHY a unit never
# started, only THAT it didn't; this can actually ask systemd.
cmd_probe() {
  local slot="${1:?Usage: $(basename "$0") probe <blue|green> --exec=\"cmd\" [--timeout=N] [--settle=N] [--local-src=<dir>]}"
  shift || true
  [[ "$slot" =~ ^(blue|green)$ ]] || die "slot must be 'blue' or 'green'"
  command -v nsenter >/dev/null 2>&1 || die "nsenter is required (util-linux) — should already be present."

  local exec_cmd="" boot_timeout=180 settle=15 local_src="" arg
  for arg in "$@"; do
    case "$arg" in
      --exec=*)      exec_cmd="${arg#--exec=}" ;;
      --timeout=*)   boot_timeout="${arg#--timeout=}" ;;
      --settle=*)    settle="${arg#--settle=}" ;;
      --local-src=*) local_src="${arg#--local-src=}" ;;
      *) die "Usage: $(basename "$0") probe <blue|green> --exec=\"cmd\" [--timeout=N] [--settle=N] [--local-src=<dir>]" ;;
    esac
  done
  [[ -n "$exec_cmd" ]] || die "probe requires --exec=\"cmd\""

  _ensure_host_machine_id
  _ensure_dbus
  _enter_prep "$slot"
  [[ -n "$local_src" ]] && _overlay_local_src "$slot" "$local_src"
  _nspawn_binds
  _ensure_inhibit_stub

  local logfile="${DATA_DIR}/probe-${slot}-console.log"
  log "Booting @${slot} in the background (real systemd, no display) for a live probe..."
  _nspawn_full_boot_args "shanios-probe-${slot}" "$slot"
  systemd-nspawn "${NSPAWN_FULL_BOOT_ARGS[@]}" \
      >"$logfile" 2>&1 &
  local boot_pid=$!
  trap 'kill "$boot_pid" 2>/dev/null || true' EXIT

  # Same pgrep-under-set-e gotcha documented above cmd_desktop's identical
  # loop — the `|| true` here is load-bearing, not decorative.
  local leader_pid="" i
  for (( i=0; i<20; i++ )); do
    leader_pid=$(pgrep -x systemd -P "$boot_pid" 2>/dev/null | head -1) || true
    [[ -n "$leader_pid" ]] && break
    kill -0 "$boot_pid" 2>/dev/null || die "boot process exited early — see ${logfile}"
    sleep 1
  done
  [[ -n "$leader_pid" ]] || die "could not find the container's init PID within 20s — see ${logfile}"
  log "Container init is PID ${leader_pid} — waiting up to ${boot_timeout}s for Multi-User/Graphical target..."

  local waited=0
  while (( waited < boot_timeout )); do
    # Same three-way heuristic as verify-boot's own target-reached check —
    # a slot may boot a custom default.target that never prints "Multi-User
    # System"/"Graphical Interface" text at all, only Basic System+Network.
    if grep -aq "Reached target Graphical Interface" "$logfile" \
       || grep -aq "Reached target Multi-User System" "$logfile" \
       || { grep -aq "Reached target Basic System" "$logfile" \
            && grep -aq "Reached target Network" "$logfile"; }; then
      break
    fi
    kill -0 "$boot_pid" 2>/dev/null || die "boot process exited early — see ${logfile}"
    sleep 1
    waited=$((waited + 1))
  done
  if (( waited >= boot_timeout )); then
    tail -30 "$logfile" || true
    die "never reached Multi-User/Graphical target within ${boot_timeout}s — see ${logfile}"
  fi
  sleep "$settle"

  log "Running probe command inside the live container via nsenter: ${exec_cmd}"
  local probe_rc=0
  nsenter --target "$leader_pid" --all -- bash -c "$exec_cmd" || probe_rc=$?

  kill "$boot_pid" 2>/dev/null || true
  wait "$boot_pid" 2>/dev/null || true
  trap - EXIT
  return "$probe_rc"
}

cmd_desktop() {
  local slot="${1:?Usage: $(basename "$0") desktop <blue|green> [--exec=\"cmd\"] [--out=<file.png>] [--timeout=N] [--settle=N]}"
  shift || true
  [[ "$slot" =~ ^(blue|green)$ ]] || die "slot must be 'blue' or 'green'"

  command -v nsenter >/dev/null 2>&1 || die "nsenter is required (util-linux) — should already be present."

  local exec_cmd="" out_file="" boot_timeout=180 settle=25 arg
  for arg in "$@"; do
    case "$arg" in
      --exec=*)    exec_cmd="${arg#--exec=}" ;;
      --out=*)     out_file="${arg#--out=}" ;;
      --timeout=*) boot_timeout="${arg#--timeout=}" ;;
      --settle=*)  settle="${arg#--settle=}" ;;
      *)
        echo "Usage: $(basename "$0") desktop <blue|green> [--exec=\"cmd\"] [--out=<file.png>] [--timeout=N] [--settle=N]" >&2
        exit 1
        ;;
    esac
  done
  [[ -n "$out_file" ]] || out_file="${DATA_DIR}/desktop-screenshot-${slot}-$(date +%s).png"

  _ensure_host_machine_id
  _ensure_dbus
  _enter_prep "$slot"
  _nspawn_binds
  _ensure_inhibit_stub

  local logfile="${DATA_DIR}/desktop-${slot}-console.log"
  local container_out="/data/.desktop-probe-$$.png"

  # NOTE: deliberately NOT wrapped in `timeout` here — nsenter needs the
  # direct PID of the systemd-nspawn process we background ($!) so it can
  # walk that PID's own /proc/<pid>/ns/* to find the container's leader
  # (systemd-nspawn forks a child that becomes the container's real PID 1
  # inside the new namespaces; $! is the outer supervisor). A manual
  # deadline + explicit `kill "$boot_pid"` in the trap below does the
  # bounding instead.
  log "Booting @${slot} in the background (real systemd/logind, no display) for a live desktop probe..."
  _nspawn_full_boot_args "shanios-desktop-${slot}" "$slot"
  systemd-nspawn "${NSPAWN_FULL_BOOT_ARGS[@]}" \
      >"$logfile" 2>&1 &
  local boot_pid=$!
  local boot_pid_file="${DATA_DIR}/desktop-boot.pid"
  echo "$boot_pid" > "$boot_pid_file"

  # NOTE: an EXIT trap runs after bash unwinds the function's call frame, so
  # it can't see cmd_desktop's own `local $boot_pid` (confirmed live —
  # exact same class of bug already found and fixed in `gui`'s
  # `_gui_cleanup` above) — read it back from a pidfile under the global
  # $DATA_DIR instead.
  #
  # Gives the container up to 30s to shut down GRACEFULLY (SIGTERM to
  # systemd-nspawn propagates a clean poweroff request to the real systemd
  # inside) before escalating to SIGKILL. This matters: confirmed live that
  # an outer wrapper cutting this off too early (this command's own caller
  # using a shorter timeout than boot_timeout + this grace period) hard-kills
  # a REAL, live systemd instance mid-write to a REAL btrfs filesystem —
  # one run of this during development left BOTH @blue and @green missing
  # afterward (`enter`/`bootstrap`-requiring die), needing a fresh
  # `bootstrap` to recover. Any caller of `desktop` (CI included) MUST budget
  # its own outer timeout comfortably above --timeout plus ~30s for this.
  _desktop_cleanup() {
    local _bp
    _bp=$(cat "${DATA_DIR}/desktop-boot.pid" 2>/dev/null) || return 0
    [[ -n "$_bp" ]] || return 0
    if ! kill -0 "$_bp" 2>/dev/null; then
      rm -f "${DATA_DIR}/desktop-boot.pid"
      return 0
    fi
    kill "$_bp" 2>/dev/null || true
    local waited=0
    while kill -0 "$_bp" 2>/dev/null; do
      if (( waited >= 30 )); then
        warn "boot process ${_bp} did not shut down gracefully within 30s — force-killing." \
             "This can leave @blue/@green missing if it was still mid-write; if a later" \
             "enter/desktop run dies with '@<slot> does not exist', re-run bootstrap."
        kill -9 "$_bp" 2>/dev/null || true
        break
      fi
      sleep 1
      waited=$((waited + 1))
    done
    wait "$_bp" 2>/dev/null || true
    rm -f "${DATA_DIR}/desktop-boot.pid"
  }
  trap _desktop_cleanup EXIT

  kill -0 "$boot_pid" 2>/dev/null || die "boot process failed to start — see ${logfile}"

  log "Locating the container's init PID (child of ${boot_pid})..."
  # NOTE: both loops below use `if grep/[[ ... ]]; then break; fi` rather than
  # a bare `cmd && break` — a bare `cmd1 && cmd2` statement (not inside an
  # `if`) IS subject to `set -e`, and grep/[[ -n ]] fail on every iteration
  # until the condition is actually met, which would abort the whole script
  # the first time through. This exact class of bug was found and reverted
  # in shani-deploy/scripts/check-boot-failure.sh earlier this session —
  # not repeating it here.
  #
  # The `|| true` on the assignment below is a DIFFERENT, easy-to-miss `set
  # -e` gotcha, found live by adding heartbeat debug prints after this loop
  # appeared to silently "hang" on 2 of 3 real runs with zero error output:
  # an assignment whose sole content is a command substitution propagates
  # that substitution's exit status to the assignment itself. With
  # `pipefail` set, `pgrep (no match) | head -1` is a failing pipeline (exit
  # 1) even though `head` itself succeeds — so on any iteration before the
  # child has actually forked yet (a normal, expected race, not an error),
  # this single assignment statement would silently kill the whole script
  # right here. What looked like a hang was actually instant death here,
  # with the ~30s delay before the "did not shut down gracefully" warning
  # coming from `_desktop_cleanup`'s own grace period for the (still fine,
  # still booting) container — not from this loop at all. One run out of
  # three "worked" purely because `pgrep` happened to find the child on its
  # very first try that time.
  local leader_pid="" i
  for (( i=0; i<20; i++ )); do
    leader_pid=$(pgrep -x systemd -P "$boot_pid" 2>/dev/null | head -1) || true
    if [[ -n "$leader_pid" ]]; then
      break
    fi
    kill -0 "$boot_pid" 2>/dev/null || die "boot process exited early — see ${logfile}"
    sleep 1
  done
  [[ -n "$leader_pid" ]] || die "could not find the container's init PID within 20s — see ${logfile}"
  log "Container init is PID ${leader_pid} — waiting up to ${boot_timeout}s for a login prompt..."

  local waited=0
  while (( waited < boot_timeout )); do
    if grep -aq "Reached target Login Prompts" "$logfile" 2>/dev/null; then
      break
    fi
    kill -0 "$boot_pid" 2>/dev/null || die "boot process exited early — see ${logfile}"
    sleep 1
    waited=$((waited + 1))
  done
  if (( waited >= boot_timeout )); then
    tail -30 "$logfile" || true
    die "never reached Login Prompts within ${boot_timeout}s — see ${logfile}"
  fi

  log "Running the desktop probe inside the live container via nsenter..."
  local probe_rc=0
  nsenter --target "$leader_pid" --all -- bash -s -- "$exec_cmd" "$container_out" "$settle" <<'PROBE_EOF' || probe_rc=$?
set -uo pipefail
exec_cmd="$1"; out_file="$2"; settle="$3"

# gdm.service's own real greeter session already runs its own gnome-shell
# in this real --boot — confirmed live: running our own separate headless
# instance alongside it made the fresh instance crash off the bus about a
# second after finishing D-Bus activation (no segfault message captured,
# just a clean disappearance — consistent with resource/seat contention
# between two concurrent Wayland compositors, not a bug in the retry loop
# below). Stop GDM's session first so ours is the only compositor running.
systemctl stop gdm.service >/dev/null 2>&1 || true

cat > /tmp/desktop-probe-inner.sh <<'INNER_EOF'
#!/bin/bash
set -uo pipefail
# Root cause found live (matches the Xwayland/EGL crash seen much earlier
# testing plain `gnome-shell --headless` standalone): this environment has
# a broken/conflicting NVIDIA EGL vendor library even though there's no
# real NVIDIA GPU anywhere in this path. Mutter eagerly starts Xwayland for
# X11-client compat; Xwayland's glamor init walks into that library and
# crashes, and losing its own embedded Xwayland takes gnome-shell down with
# it a moment later ("Gdk-Message: Error reading events from display:
# Broken pipe" right before org.gnome.Shell disappears from the bus). We
# only need the native Wayland compositor + its Screenshot D-Bus API, no
# X11 client support, so disable Xwayland entirely via Mutter's own debug
# env var instead of fixing the EGL library.
MUTTER_NO_XWAYLAND=1 gnome-shell --headless --virtual-monitor=1280x800 >/tmp/desktop-probe-shell.log 2>&1 &
GSPID=$!
ready=0
for i in $(seq 1 "$DESKTOP_PROBE_SETTLE"); do
  gdbus introspect --session --dest org.gnome.Shell --object-path /org/gnome/Shell >/dev/null 2>&1 \
    && { ready=1; break; }
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "gnome-shell never registered on the session bus" >&2
  cat /tmp/desktop-probe-shell.log >&2 || true
  kill "$GSPID" 2>/dev/null; wait 2>/dev/null
  exit 1
fi
if [ -n "${DESKTOP_PROBE_EXEC:-}" ]; then
  bash -c "$DESKTOP_PROBE_EXEC" || echo "probe --exec command exited non-zero (continuing)" >&2
fi
# Introspecting /org/gnome/Shell/Screenshot succeeds (false-positive "ready")
# before the Screenshot method is actually callable — confirmed live: the
# introspect check passed immediately, yet the very next call still hit
# "Object does not exist at path /org/gnome/Shell/Screenshot" every time.
# Retry the REAL call itself instead of trusting introspection as a proxy.
rc=1
for i in $(seq 1 "$DESKTOP_PROBE_SETTLE"); do
  call_err=$(gdbus call --session --dest org.gnome.Shell \
    --object-path /org/gnome/Shell/Screenshot \
    --method org.gnome.Shell.Screenshot.Screenshot \
    false false "$DESKTOP_PROBE_OUT" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    break
  fi
  echo "screenshot attempt $i/$DESKTOP_PROBE_SETTLE failed: $call_err" >&2
  sleep 1
done
kill "$GSPID" 2>/dev/null
wait 2>/dev/null
exit $rc
INNER_EOF
chmod +x /tmp/desktop-probe-inner.sh

export XDG_RUNTIME_DIR="/run/probe-$$"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export DESKTOP_PROBE_EXEC="$exec_cmd"
export DESKTOP_PROBE_OUT="$out_file"
export DESKTOP_PROBE_SETTLE="$settle"
dbus-run-session -- /tmp/desktop-probe-inner.sh
PROBE_EOF

  if [[ $probe_rc -ne 0 ]]; then
    warn "desktop probe exited non-zero (rc=${probe_rc}) — see above for gnome-shell's own log"
  fi

  local host_container_out="${MNT}/@data/$(basename "$container_out")"
  if [[ -f "$host_container_out" ]]; then
    cp -f "$host_container_out" "$out_file"
    rm -f "$host_container_out"
    log "Screenshot saved: ${out_file}"
  else
    die "probe finished but no screenshot was produced at ${host_container_out} (rc=${probe_rc})"
  fi
}

# ------------------------------------------------------------------
# install / configure
# ------------------------------------------------------------------
# Closes the exact gap this README used to call out under "What this does
# NOT simulate": cmd_bootstrap used to fabricate @blue/@green directly
# (btrfs receive + snapshot, then a manual gen-efi call and a hand-rolled
# copy of shani-deploy.sh's loader-entry conventions) and skip
# install.sh/configure.sh entirely — fine for exercising shani-deploy/
# shani-update/gen-efi against an already-installed system, but it never
# actually ran the real install path, and left three separate hand-
# maintained reimplementations of real production logic in this file with
# no way to notice when the real thing they copied changed. cmd_install/
# cmd_configure instead run THOSE two scripts — unmodified, from the
# sibling os-installer-config checkout — driven purely by OSI_*
# environment variables, exactly how the real os-installer GUI invokes
# them. No GUI is involved or needed; every OSI_* variable each command
# sets was found by reading install.sh/configure.sh in full (see the
# comments below), not guessed. cmd_bootstrap is now just these two
# commands plus one genuinely test-only step (see cmd_bootstrap itself).
#
# Unlike cmd_disk's pre-partitioned ESP+root image pair, install.sh does its
# OWN partitioning (bits/part.sfdisk via sfdisk) against a whole-disk device
# — so this needs its own blank disk image, loop-attached with partition
# scanning (`losetup -P`) so /dev/loopNp1 / p2 appear once install.sh's own
# sfdisk+partprobe run.
# ------------------------------------------------------------------

# Resolves the os-installer-config checkout providing install.sh/
# configure.sh. run_in_container.sh bind-mounts it (read-only) at a fixed
# container path if it finds the sibling checkout on the host; falls back to
# the literal sibling-directory path for anyone running test.sh directly
# on the host. Override with SHANIOS_TEST_OSI_HOST_DIR (host side, read by
# run_in_container.sh) and/or SHANIOS_TEST_OSI_ROOT (this side). Sets global
# OSI_ROOT; dies with where it looked if nothing matches.
#
# Deliberately NOT under /mnt: the real install.sh/configure.sh hardcode
# /mnt (and /mnt/boot/efi) as their own install target and mount over it —
# a checkout bind-mounted under /mnt would be silently shadowed as soon as
# install.sh runs, breaking a same-session cmd_configure call right after
# cmd_bootstrap's cmd_install. Once resolved, OSI_ROOT is cached for the
# rest of this process/container invocation (rather than re-probed) for the
# same reason: caching just the string wouldn't be enough if the path were
# still under /mnt, but since it never is, a resolved OSI_ROOT stays valid
# for the whole run regardless of what install.sh mounts afterward.
_find_osi_root() {
  [[ -n "${OSI_ROOT:-}" && -f "${OSI_ROOT}/scripts/install.sh" && -f "${OSI_ROOT}/scripts/configure.sh" ]] && return 0
  local candidate
  for candidate in "${SHANIOS_TEST_OSI_ROOT:-}" /opt/os-installer-config "${REPO_ROOT}/../os-installer-config"; do
    [[ -n "$candidate" && -f "${candidate}/scripts/install.sh" && -f "${candidate}/scripts/configure.sh" ]] || continue
    OSI_ROOT="$(realpath "$candidate")"
    return 0
  done
  die "os-installer-config not found (checked \$SHANIOS_TEST_OSI_ROOT, /opt/os-installer-config, ${REPO_ROOT}/../os-installer-config) — check it out as a sibling of this repo (or set SHANIOS_TEST_OSI_HOST_DIR on the run_in_container.sh invocation / SHANIOS_TEST_OSI_ROOT here to point elsewhere)."
}

# install.sh's get_partition_prefix() only special-cases nvme*/mmcblk*
# device names (appending a 'p' before the partition number) — every other
# device path, including /dev/loopN, falls through to the bare
# "${OSI_DEVICE_PATH}<N>" form (e.g. /dev/loop71), which is NOT how the
# kernel actually names loop-device partitions (/dev/loop7p1). Real installs
# never hit this — physical disks are sd*/nvme*/mmcblk* only — but a loop
# device is exactly what this harness has to offer, so bridge the gap with
# compatibility symlinks rather than patch install.sh (the entire point is
# to run it UNMODIFIED). Symlinks resolve lazily, so it's safe to create
# these before the partitions they point at actually exist.
_make_loop_partition_compat() {
  local loop="$1"
  ln -sf "${loop}p1" "${loop}1"
  ln -sf "${loop}p2" "${loop}2"
}

# install.sh/configure.sh mount both partitions exclusively via
# /dev/disk/by-label/{shani_boot,shani_root} (BOOTLABEL/ROOTLABEL, hardcoded
# in both scripts and in bits/part.sfdisk) — on real hardware a live udevd
# creates those from each filesystem's on-disk label; this container runs no
# udevd, same reason cmd_disk creates shani_root/shani_boot's by-label
# symlinks by hand instead of relying on one (see _ensure_disk_attached).
# Safe to create/refresh before the partitions or LUKS mapping actually
# exist — symlinks resolve lazily, and by the time install.sh/configure.sh
# actually dereference them (mount_boot_partition, mount_target), the real
# targets are already in place. shani_root points at the LUKS mapper if one
# is already open (an encrypted install: install.sh opens it as mapper name
# "shani_root", i.e. exactly $ROOTLABEL, and never closes it) or at the raw
# partition otherwise — so this is correct whether called before install.sh
# has run at all or reattaching to an already-encrypted disk later.
_ensure_install_by_label_symlinks() {
  local loop="$1"
  mkdir -p /dev/disk/by-label
  ln -sf "${loop}p1" /dev/disk/by-label/shani_boot
  if [[ -e /dev/mapper/shani_root ]]; then
    ln -sf /dev/mapper/shani_root /dev/disk/by-label/shani_root
  else
    ln -sf "${loop}p2" /dev/disk/by-label/shani_root
  fi
}

# Re-attaches install.img's loop device across separate run_in_container.sh
# invocations (same principle, and same _ensure_single_loop machinery, as
# _ensure_disk_attached uses for root.img/esp.img), and recreates the
# loop-partition compat symlinks + by-label symlinks above (they live under
# /dev, so device NUMBERS don't survive a fresh container, even though the
# symlink files themselves would via the host /dev bind mount). Prints the
# loop device path to stdout.
_ensure_install_attached() {
  [[ -f "$INSTALL_IMG" ]] || die "install.img not found under $DATA_DIR — run '$(basename "$0") install' first"
  local loop
  loop="$(_ensure_single_loop "$INSTALL_IMG")"
  echo "$loop" > "${DATA_DIR}/.install_loop"
  _make_loop_partition_compat "$loop"
  _ensure_install_by_label_symlinks "$loop"
  echo "$loop"
}

# ------------------------------------------------------------------
# install   -p <profile> [-d latest|stable|<date>] [--encrypted]
# ------------------------------------------------------------------
cmd_install() {
  check_dependencies_install

  local encrypted=0
  local -a rest=()
  local a
  for a in "$@"; do
    case "$a" in
      --encrypted) encrypted=1 ;;
      *) rest+=("$a") ;;
    esac
  done
  set -- "${rest[@]}"

  local profile="" date_sel="latest" opt OPTARG OPTIND=1
  while getopts "p:d:" opt "$@"; do
    case "$opt" in
      p) profile="$OPTARG" ;;
      d) date_sel="$OPTARG" ;;
      *) ;;
    esac
  done
  [[ -n "$profile" ]] || die "Usage: $(basename "$0") install -p <profile> [-d latest|stable|<date>] [--encrypted]"

  local image
  image="$(_resolve_build_image "$profile" "$date_sel")"

  _find_osi_root
  local sfdisk_layout="${OSI_ROOT}/bits/part.sfdisk"
  [[ -f "$sfdisk_layout" ]] || die "part.sfdisk not found at ${sfdisk_layout}"

  _ensure_root_sudo

  # Fresh whole-disk image (NOT cmd_disk's pre-partitioned pair — see the
  # comment above this section) — always wiped and recreated, so detach
  # whatever loop devices (if any, however many) are already attached to it
  # first, same preflight principle as cmd_disk.
  local size="${INSTALL_DISK_SIZE:-24G}"
  mkdir -p "$DATA_DIR"
  _detach_all_loops "$INSTALL_IMG"
  rm -f "$INSTALL_IMG"
  truncate -s "$size" "$INSTALL_IMG"
  local disk_loop
  disk_loop=$(losetup -P --find --show "$INSTALL_IMG") || die "Failed to attach loop device for $INSTALL_IMG"
  echo "$disk_loop" > "${DATA_DIR}/.install_loop"
  _make_loop_partition_compat "$disk_loop"
  log "install.img attached at ${disk_loop} (partitions land at ${disk_loop}p1/${disk_loop}p2, aliased to ${disk_loop}1/${disk_loop}2 for install.sh's loop-naming gap — see _make_loop_partition_compat)"

  # By-label symlinks install.sh/configure.sh mount through — see
  # _ensure_install_by_label_symlinks for why this container can't rely on
  # udev to create them. This call is the "before encryption is even set up"
  # case: shani_root aliases the raw partition for now; a later
  # `configure`'s _ensure_install_attached call re-points it at the LUKS
  # mapper automatically once install.sh (with --encrypted) has opened it.
  _ensure_install_by_label_symlinks "$disk_loop"

  # Stage the fixed paths install.sh hardcodes and can't be pointed
  # elsewhere via env — OSIDIR=/etc/os-installer, and
  # ROOTFSZST_SOURCE=/run/archiso/bootmnt/<os>/x86_64/rootfs.zst (normally
  # provided by the live ISO environment). Faked at the exact paths
  # install.sh reads, same principle as _ensure_inhibit_stub faking
  # systemd-inhibit for shani-deploy.sh.
  mkdir -p /etc/os-installer/bits
  cp -f "$sfdisk_layout" /etc/os-installer/bits/part.sfdisk
  [[ -f "${OSI_ROOT}/config.yaml" ]] && cp -f "${OSI_ROOT}/config.yaml" /etc/os-installer/config.yaml

  # Bind-mount, don't symlink: install.sh's extract_image() pipes each source
  # straight through `zstd -d` (no -f/--force), which refuses to follow a
  # symlink at all ("... is a symbolic link, ignoring") and silently feeds
  # btrfs receive an empty stream instead — confirmed live. A bind mount
  # looks like a plain regular file at that path, which is all zstd needs,
  # with no multi-GB copy.
  local archiso_dir="/run/archiso/bootmnt/${OS_NAME}/x86_64"
  mkdir -p "$archiso_dir"
  local profile_dir
  profile_dir="$(dirname "$image")"
  : > "${archiso_dir}/rootfs.zst"
  mount --bind "$image" "${archiso_dir}/rootfs.zst"
  if [[ -f "${profile_dir}/flatpakfs.zst" ]]; then
    : > "${archiso_dir}/flatpakfs.zst"
    mount --bind "${profile_dir}/flatpakfs.zst" "${archiso_dir}/flatpakfs.zst"
  fi
  if [[ -f "${profile_dir}/snapfs.zst" ]]; then
    : > "${archiso_dir}/snapfs.zst"
    mount --bind "${profile_dir}/snapfs.zst" "${archiso_dir}/snapfs.zst"
  fi

  # The full, realistic OSI_* environment install.sh reads (enumerated by
  # reading install.sh itself, not guessed): OSI_DEVICE_PATH,
  # OSI_DEVICE_IS_PARTITION, OSI_USE_ENCRYPTION, and (only when encryption is
  # on) OSI_ENCRYPTION_PIN. OSI_DEVICE_EFI_PARTITION is read only when
  # OSI_DEVICE_IS_PARTITION=1 — not our case, we hand it the whole disk.
  export OSI_DEVICE_PATH="$disk_loop"
  export OSI_DEVICE_IS_PARTITION=0
  unset OSI_DEVICE_EFI_PARTITION
  export OSI_USE_ENCRYPTION=0
  unset OSI_ENCRYPTION_PIN
  local test_pin="${SHANIOS_TEST_LUKS_PIN:-shanios-test-passphrase}"
  if (( encrypted )); then
    export OSI_USE_ENCRYPTION=1
    export OSI_ENCRYPTION_PIN="$test_pin"
    log "Encryption requested — LUKS passphrase for this disk: '${test_pin}' (override with SHANIOS_TEST_LUKS_PIN)"
  fi

  log "Running the REAL install.sh from ${OSI_ROOT} against ${disk_loop} (profile=${profile}, image=$(basename "$image"), encrypted=${encrypted})"
  bash "${OSI_ROOT}/scripts/install.sh"

  log "install.sh finished — /mnt holds the freshly-partitioned target (a real GPT disk, $( (( encrypted )) && echo "LUKS-encrypted " )Btrfs @blue/@green, exactly like a real install)."
  log "Next: $(basename "$0") configure -p ${profile}$( (( encrypted )) && echo ' --encrypted')"
}

# ------------------------------------------------------------------
# configure   -p <profile> [--encrypted]
# ------------------------------------------------------------------
# configure.sh does its own chrooting internally — run_in_target() is
# `sudo chroot "$TARGET" /bin/bash -c ...` per command — so this just needs
# to invoke the real script with a realistic environment, not wrap it in an
# outer arch-chroot of its own.
# ------------------------------------------------------------------
cmd_configure() {
  check_dependencies_install

  # configure.sh's mount_target() rbinds the CALLING environment's /run into
  # the chroot target (`mount --rbind /run "${TARGET}/run"`) — on a real
  # install this is the live ISO's already-booted systemd/dbus, which is how
  # hostnamectl/localectl/timedatectl (all D-Bus calls) work from inside a
  # plain `chroot`, no nspawn involved. This container has no live systemd
  # either, so without a bus at /run/dbus/system_bus_socket BEFORE
  # configure.sh runs, every one of those calls dies with "Failed to connect
  # to system scope bus via local transport: Host is down" — confirmed live.
  # Same class of fix cmd_enter already needed for systemd-nspawn
  # (_ensure_dbus) — see _ensure_systemd_target_services for the rest of it.
  _ensure_systemd_target_services

  local encrypted=0
  local -a rest=()
  local a
  for a in "$@"; do
    case "$a" in
      --encrypted) encrypted=1 ;;
      *) rest+=("$a") ;;
    esac
  done
  set -- "${rest[@]}"

  local profile="" opt OPTARG OPTIND=1
  while getopts "p:" opt "$@"; do
    case "$opt" in
      p) profile="$OPTARG" ;;
      *) ;;
    esac
  done

  _find_osi_root
  _ensure_root_sudo

  local disk_loop
  disk_loop="$(_ensure_install_attached)"

  export OSI_DEVICE_PATH="$disk_loop"
  export OSI_DEVICE_IS_PARTITION=0
  export OSI_DEVICE_EFI_PARTITION="${disk_loop}p1"
  export OSI_USE_ENCRYPTION=0
  unset OSI_ENCRYPTION_PIN
  local test_pin="${SHANIOS_TEST_LUKS_PIN:-shanios-test-passphrase}"
  if (( encrypted )); then
    export OSI_USE_ENCRYPTION=1
    export OSI_ENCRYPTION_PIN="$test_pin"
  fi

  # Every other OSI_* variable configure.sh reads — its own required_vars
  # list (OSI_LOCALE/OSI_FORMATS/OSI_TIMEZONE/OSI_KEYBOARD_LAYOUT/
  # OSI_USER_NAME/OSI_USER_AUTOLOGIN) plus OSI_USER_USERNAME/
  # OSI_USER_PASSWORD/OSI_ROOT_PASSWORD read later in setup_user_target/
  # set_root_password — realistic defaults, all overridable via env for
  # anyone testing something specific (a particular locale, keyboard
  # layout, autologin, ...).
  export OSI_LOCALE="${SHANIOS_TEST_OSI_LOCALE:-en_US.UTF-8}"
  export OSI_FORMATS="${SHANIOS_TEST_OSI_FORMATS:-en_US.UTF-8}"
  export OSI_TIMEZONE="${SHANIOS_TEST_OSI_TIMEZONE:-UTC}"
  export OSI_KEYBOARD_LAYOUT="${SHANIOS_TEST_OSI_KEYBOARD:-us}"
  export OSI_USER_NAME="${SHANIOS_TEST_OSI_USER_NAME:-Test User}"
  export OSI_USER_USERNAME="${SHANIOS_TEST_OSI_USERNAME:-testuser}"
  export OSI_USER_PASSWORD="${SHANIOS_TEST_OSI_USER_PASSWORD:-testpass123}"
  export OSI_USER_AUTOLOGIN="${SHANIOS_TEST_OSI_AUTOLOGIN:-0}"
  export OSI_ROOT_PASSWORD="${SHANIOS_TEST_OSI_ROOT_PASSWORD:-}"

  log "Running the REAL configure.sh from ${OSI_ROOT} (user=${OSI_USER_USERNAME}, locale=${OSI_LOCALE}, encrypted=${encrypted})"
  bash "${OSI_ROOT}/scripts/configure.sh"

  log "configure.sh finished. Verify, e.g.:"
  log "  mount -o subvol=@blue /dev/disk/by-label/shani_root /mnt && grep ^${OSI_USER_USERNAME}: /mnt/etc/passwd && cat /mnt/etc/hostname; umount /mnt"
  if (( encrypted )); then
    log "  cryptsetup open --test-passphrase /dev/disk/by-label/shani_root   (passphrase: ${test_pin})"
  fi
}

# ------------------------------------------------------------------
# upgrade / reboot / rollback   (was 04/05/06-*.sh)
# ------------------------------------------------------------------
cmd_upgrade() {
  # --local-src=<dir> can appear anywhere among the args — same convention
  # as cmd_enter/cmd_verifyboot: pull it out, forward everything else
  # straight through to shani-deploy. Without it, this only ever exercises
  # whatever shani-deploy got baked into the bootstrapped image at build
  # time, which can be stale relative to a repo's current working tree —
  # pass --local-src=/opt/shani-deploy/scripts (the sibling checkout
  # run_in_container.sh bind-mounts) to always run the current one, units
  # included (_overlay_local_src picks up its sibling systemd/ dir too).
  local local_src=""
  local -a rest=()
  local a
  for a in "$@"; do
    case "$a" in
      --local-src=*) local_src="${a#--local-src=}" ;;
      *) rest+=("$a") ;;
    esac
  done
  set -- "${rest[@]}"

  local current_slot
  current_slot="$(_current_slot)"
  log "Current slot marker: @${current_slot}"

  _ensure_host_machine_id
  _ensure_dbus
  # Calls shani-deploy directly, not shani-update: shani-update is only an
  # interactive front-end (GUI dialog / console prompt) that then pkexecs
  # shani-deploy — and unconditionally wraps that in a gnome-terminal
  # window for user visibility, which needs a real display even after the
  # prompt is approved (confirmed live: "Cannot open display" once
  # shani-update tried to launch it, even after the console-approval path
  # was fully proven to work via an allocated pty). shani-deploy is the
  # real script that does the actual work, and its own check_root() only
  # pkexecs/sudo's when EUID != 0 — since this nspawn session already runs
  # as root, calling it directly needs none of that, and shani-deploy has
  # no interactive prompts of its own (verified: no `read -rp` anywhere in
  # it) — it's designed to run fully unattended already, same as
  # shani-update's pkexec'd child and the production systemd timer units.
  # --skip-self-update is essential here, not optional: without it,
  # shani-deploy's OWN self_update() would fetch and exec the "official"
  # published script mid-run, silently discarding the --local-src-overlaid
  # edited copy we're trying to test.
  # Doesn't use cmd_enter directly (which ends in exec, replacing this
  # process) — cmd_cycle needs cmd_upgrade to actually return so its own
  # cmd_reboot afterward still runs. _prepare_enter_args is the same prep
  # cmd_enter itself uses (single source of truth for the nspawn args).
  _prepare_enter_args "$current_slot" "$local_src" shani-deploy --force --channel latest --skip-self-update "$@"
  log "Running shani-deploy inside @${current_slot} (real deploy — this will actually switch slots on success)"
  systemd-nspawn "${NSPAWN_ENTER_ARGS[@]}"
}

# ------------------------------------------------------------------
# update-check   [--local-src=<dir>] [extra shani-update args...]
# ------------------------------------------------------------------
# cmd_upgrade calls shani-deploy directly and never touches shani-update.sh
# at all — this command exists specifically to exercise shani-update.sh
# itself for real: its GUI-dialog fallback chain, its console-approval
# prompt, and its decision logic (install/postpone). Complements
# cmd_upgrade, doesn't replace it.
cmd_updatecheck() {
  local local_src=""
  local -a rest=()
  local a
  for a in "$@"; do
    case "$a" in
      --local-src=*) local_src="${a#--local-src=}" ;;
      *) rest+=("$a") ;;
    esac
  done
  set -- "${rest[@]}"

  local current_slot
  current_slot="$(_current_slot)"
  log "Current slot marker: @${current_slot}"

  _ensure_host_machine_id
  _ensure_dbus
  _prepare_enter_args "$current_slot" "$local_src" shani-update --force --skip-self-update "$@"

  # shani-update.sh is real and unmodified — it tries a GUI dialog first
  # (no display here, so yad/zenity/kdialog all correctly fail over), then
  # falls back to a genuine console prompt, but ONLY when
  # `[[ -t 0 && -t 1 ]]` — confirmed live that a plain non-tty invocation
  # always logs "No interactive interface — defaulting to postpone" and
  # never even reaches its decision logic. There's no flag to skip this
  # (by design), so give it exactly what a human at a real terminal would:
  # `script` allocates a genuine pty and relays its own stdin into it like
  # a real keystroke, so feeding it "y\n" is the same input a person
  # approving the update would type.
  #
  # NOTE what this does NOT prove: shani-update's own _launch_deploy (the
  # actual shani-deploy hand-off, and its --rollback path too) always
  # wraps that in a gnome-terminal window for visibility — confirmed live
  # this fails with "Cannot open display" even right after the approval
  # prompt succeeds, in a container with no real display. This command
  # proves shani-update's own dialog/prompt/decision code works; it does
  # NOT complete an actual deploy — use `upgrade` for that (it calls
  # shani-deploy directly, skipping this whole layer).
  if ! command -v script &>/dev/null; then
    warn "'script' (util-linux) not found — can't allocate a pty for shani-update's console approval; it will default to postponing"
    systemd-nspawn "${NSPAWN_ENTER_ARGS[@]}"
    return $?
  fi

  log "Running shani-update inside @${current_slot} via an allocated pty, answering the update-approval prompt with 'y' (the same input a real interactive session would give)"
  local cmd_str
  printf -v cmd_str '%q ' systemd-nspawn "${NSPAWN_ENTER_ARGS[@]}"
  printf 'y\n' | script -qec "$cmd_str" /dev/null
}

cmd_reboot() {
  local current_slot
  current_slot="$(_current_slot)"
  log "'Rebooting' into @${current_slot} (per /data/current-slot)"
  cmd_enter "$current_slot" "$@"
}

cmd_rollback() {
  # --local-src=<dir> — same convention as cmd_upgrade, see there for why.
  local local_src=""
  local -a rest=()
  local a
  for a in "$@"; do
    case "$a" in
      --local-src=*) local_src="${a#--local-src=}" ;;
      *) rest+=("$a") ;;
    esac
  done
  set -- "${rest[@]}"

  local current_slot
  current_slot="$(_current_slot)"
  log "Rolling back FROM @${current_slot} (this restores the *other* slot and repoints boot at it)"

  _ensure_host_machine_id
  _ensure_dbus
  # shani-deploy --rollback directly, not shani-update --rollback: same
  # reason as cmd_upgrade — shani-update's _run_rollback() ALSO routes
  # through _launch_deploy (the gnome-terminal wrapper that needs a real
  # display), even though it's not asking for any interactive approval
  # first. shani-deploy's own -r/--rollback flag does the identical real
  # work directly.
  _prepare_enter_args "$current_slot" "$local_src" shani-deploy --rollback "$@"
  systemd-nspawn "${NSPAWN_ENTER_ARGS[@]}"
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
  # --vnc[=port]: serve the real framebuffer over VNC-over-websocket (QEMU's
  # own built-in `websocket=` vnc suboption — confirmed live, no separate
  # websockify proxy needed) instead of opening a local GTK window, so a
  # browser-based noVNC client (see `watch`, below) can show the actual
  # live boot/desktop remotely. Raw VNC (TCP 5900+N) is always also listening
  # alongside the websocket port, for a native VNC client if you'd rather use one.
  local vnc_ws_port="" arg
  for arg in "$@"; do
    case "$arg" in
      --vnc)        vnc_ws_port=5700 ;;
      --vnc=*)      vnc_ws_port="${arg#--vnc=}" ;;
    esac
  done

  # The GTK-window path genuinely needs the HOST's GPU/display. `--vnc` needs
  # neither — just a network socket, which `run_in_container.sh`'s
  # `--network=host` already shares straight through to the host's own
  # 127.0.0.1 — so let `--vnc` run through the container instead, where it's
  # already root and doesn't hit root.img/esp.img's host-side permissions
  # (those land root:root from the privileged container that created them;
  # confirmed live: running plain `qemu`/`--vnc` as the unprivileged host
  # user hits "Could not open root.img: Permission denied" otherwise).
  if [[ -z "$vnc_ws_port" ]] && _in_container; then
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

  local -a display_args=(-display "${QEMU_DISPLAY:-gtk}")
  if [[ -n "$vnc_ws_port" ]]; then
    display_args=(-vnc ":0,websocket=${vnc_ws_port}")
    echo "==> Booting root.img + esp.img via OVMF — VNC on :5900, websocket on ${vnc_ws_port} (open the 'watch' UI, or point any VNC client at localhost:5900)"
  else
    echo "==> Booting root.img + esp.img via OVMF (close the window / send SIGTERM to stop)"
  fi

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
      "${display_args[@]}" \
      -device virtio-net-pci,netdev=net0 \
      -netdev user,id=net0 \
      -device qemu-xhci -device usb-kbd -device usb-tablet \
      -chardev socket,path="$qga_sock",server=on,wait=off,id=qga0 \
      -device virtio-serial \
      -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
      -serial mon:stdio
}

# ------------------------------------------------------------------
# watch   [--port=N] — HOST-ONLY local dashboard: "see the boot"
#
# One local page, two panels:
#   - Console: live-tails whichever *-console.log is most recently written
#     (desktop-<slot>-console.log from `desktop`, boot-<slot>-console.log
#     from `verify-boot`, or any future *-console.log) — a plain polling
#     fetch loop, no dependency beyond python3's stdlib http.server.
#   - Desktop (VNC): a noVNC viewer (loaded from a CDN, since this is a
#     plain local page you open yourself — not a claude.ai artifact, so
#     none of that sandbox's CDN allowlist applies here) pointed at a
#     ws://127.0.0.1:<port> you type in, matching `qemu --vnc[=port]`'s
#     websocket port. Confirmed live: `qemu-system-x86_64 -vnc
#     :0,websocket=5700` really does open both raw VNC (5900) and a
#     websocket bridge (5700) on this host's QEMU (8.2.2) — no separate
#     websockify proxy needed.
# Entirely local: nothing here is uploaded or exposed beyond 127.0.0.1.
# ------------------------------------------------------------------
cmd_watch() {
  if _in_container; then
    echo "watch opens a local port for your browser — run it on the HOST instead:" >&2
    echo "  test-env/test.sh watch [--port=N] [--vnc-port=N]" >&2
    exit 1
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 is required for watch (should already be present)."

  local port=8090 vnc_port=5700 arg
  for arg in "$@"; do
    case "$arg" in
      --port=*)     port="${arg#--port=}" ;;
      --vnc-port=*) vnc_port="${arg#--vnc-port=}" ;;
      *) echo "Usage: $(basename "$0") watch [--port=N] [--vnc-port=N]" >&2; exit 1 ;;
    esac
  done

  log "Boot-watch UI: http://127.0.0.1:${port}/  (Ctrl+C to stop — local only, nothing leaves this machine)"
  python3 - "$port" "$vnc_port" <<'PYEOF'
import http.server, socketserver, sys

PORT, VNC_PORT = int(sys.argv[1]), int(sys.argv[2])

# Desktop-only, full-bleed view — no split-screen scaling, which is also
# what was making the remote cursor render tiny/misaligned before. noVNC
# expects its target container to be a plain block/relative box (no
# flex-centering) so it can size and scale its own canvas correctly.
PAGE = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>ShaniOS test-env — watch</title>
<style>
  html,body{{background:#000;margin:0;height:100%;overflow:hidden}}
  #bar{{position:fixed;top:0;left:0;right:0;z-index:2;display:flex;gap:8px;align-items:center;
       padding:6px 10px;background:#181818;font:12px ui-monospace,Menlo,Consolas,monospace;color:#ddd}}
  #bar input,#bar button{{background:#222;color:#ddd;border:1px solid #444;padding:3px 6px;font:inherit}}
  #status{{color:#777}}
  #screen{{position:absolute;top:28px;left:0;right:0;bottom:0;background:#000;outline:none}}
</style></head>
<body>
  <div id="bar">
    <input id="wsUrl" size="24" value="ws://127.0.0.1:{VNC_PORT}">
    <button onclick="connectVnc()">Connect</button>
    <span id="status">not connected — run `qemu --vnc[=port]` on the host first</span>
  </div>
  <div id="screen"></div>
<script type="module">
window.connectVnc = async () => {{
  const status = document.getElementById('status');
  const screen = document.getElementById('screen');
  try {{
    const {{ default: RFB }} = await import('https://cdn.jsdelivr.net/npm/@novnc/novnc@1.4.0/core/rfb.js');
    screen.innerHTML = '';
    const url = document.getElementById('wsUrl').value;
    const rfb = new RFB(screen, url);
    rfb.viewOnly = false;
    rfb.scaleViewport = true;
    rfb.resizeSession = false;
    rfb.showDotCursor = true;
    rfb.addEventListener('connect', () => status.textContent = 'connected');
    rfb.addEventListener('disconnect', () => status.textContent = 'disconnected');
    status.textContent = 'connecting...';
    screen.tabIndex = 0;
    screen.addEventListener('click', () => screen.focus());
    screen.focus();
  }} catch (e) {{
    status.textContent = 'noVNC failed to load: ' + e;
  }}
}};
window.addEventListener('load', () => setTimeout(connectVnc, 300));
</script>
</body></html>"""

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    print(f"serving on http://127.0.0.1:{PORT}/", file=sys.stderr)
    httpd.serve_forever()
PYEOF
}

# ------------------------------------------------------------------
# QMP / qemu-guest-agent JSON helpers for `gui` — tiny inline python3
# clients, no sibling script (see "One file, no sibling scripts" in
# README.md). QGA needs no capabilities handshake, just JSON lines; QMP
# needs a greeting read + qmp_capabilities before any real command.
# ------------------------------------------------------------------
_qga_wait_ready() {
  local sock="$1" timeout="${2:-300}" waited=0
  log "Waiting for qemu-guest-agent to respond (timeout ${timeout}s)..."
  while (( waited < timeout )); do
    if python3 - "$sock" <<'PYEOF' >/dev/null 2>&1
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
try:
    s.connect(sys.argv[1])
    s.sendall(json.dumps({"execute": "guest-ping"}).encode() + b"\n")
    sys.exit(0 if s.recv(4096) else 1)
except Exception:
    sys.exit(1)
PYEOF
    then
      log "guest-agent responded after ${waited}s."
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

# Runs a shell command inside the live guest via guest-exec, blocks for its
# exit, prints its stdout/stderr on this side. Real command execution inside
# the booted desktop — e.g. launch a GUI app or flip a theme setting — not a
# simulation of one.
_qga_exec() {
  local sock="$1" cmd="$2" gtimeout="${3:-60}"
  python3 - "$sock" "$cmd" "$gtimeout" <<'PYEOF'
import base64, json, socket, sys, time

sock_path, cmd, gtimeout = sys.argv[1], sys.argv[2], float(sys.argv[3])

def rpc(s, payload):
    s.sendall(json.dumps(payload).encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    return json.loads(buf.splitlines()[0])

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(30)
s.connect(sock_path)

resp = rpc(s, {"execute": "guest-exec", "arguments": {
    "path": "/bin/bash", "arg": ["-c", cmd], "capture-output": True}})
if "error" in resp:
    print("guest-exec error: %s" % resp["error"], file=sys.stderr)
    sys.exit(1)
pid = resp["return"]["pid"]

deadline = time.time() + gtimeout
status = {}
while time.time() < deadline:
    resp = rpc(s, {"execute": "guest-exec-status", "arguments": {"pid": pid}})
    status = resp.get("return", {})
    if status.get("exited"):
        break
    time.sleep(1)

if not status.get("exited"):
    print("guest-exec: command did not finish within %.0fs" % gtimeout, file=sys.stderr)
    sys.exit(1)

out = base64.b64decode(status.get("out-data", "")).decode(errors="replace")
err = base64.b64decode(status.get("err-data", "")).decode(errors="replace")
if out:
    sys.stdout.write(out)
if err:
    sys.stderr.write(err)
sys.exit(status.get("exitcode") or 0)
PYEOF
}

# Real framebuffer screendump via QMP — works with `-display none` because
# it reads the graphics device's internal surface, not a window/backend.
_qmp_screendump() {
  local sock="$1" outfile="$2"
  python3 - "$sock" "$outfile" <<'PYEOF'
import json, socket, sys

sock_path, outfile = sys.argv[1], sys.argv[2]

def readline(s):
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    return buf

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(30)
s.connect(sock_path)
readline(s)  # greeting
s.sendall(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\n")
readline(s)  # ack
s.sendall(json.dumps({"execute": "screendump",
                       "arguments": {"filename": outfile}}).encode() + b"\n")
resp = json.loads(readline(s))
if "error" in resp:
    print("QMP screendump error: %s" % resp["error"], file=sys.stderr)
    sys.exit(1)
print("screendump OK: %s" % outfile)
PYEOF
}

# ------------------------------------------------------------------
# gui   (headless real-desktop verification) — HOST-ONLY
#
# Boots disk/root.img + disk/esp.img exactly like `cmd_qemu` (same real
# UKI/kernel/bootloader), but with `-display none` instead of a GTK window,
# plus a QMP control socket alongside the qemu-guest-agent one `cmd_qemu`
# already wires up. This is the answer to "can we verify a GUI app or a
# desktop theme change actually renders, without a distrobox dependency":
#   1. wait for qemu-guest-agent to respond (boot reached a running desktop)
#   2. optionally run --exec="..." inside the live guest over guest-exec —
#      launch a real GUI app, flip a real theme setting via its real config
#      tool, whatever the check calls for
#   3. let the compositor settle briefly, then QMP screendump the real
#      framebuffer to a .ppm file
# No new runtime dependency on the guest side (qemu-guest-agent is already
# shipped and enabled — see cmd_qemu's comment above); only the HOST needs
# python3 (already required by run_in_container.sh's own tooling) to speak
# the QMP/QGA JSON protocols — no socat, no separate helper script.
# ------------------------------------------------------------------
cmd_gui() {
  if _in_container; then
    echo "gui boots a real headless QEMU instance — it can't run inside the build container." >&2
    echo "Run this file directly on the HOST instead, from the repo root:" >&2
    echo "  test-env/test.sh gui [--exec=\"shell command\"] [--out=<file.ppm>] [--timeout=N]" >&2
    exit 1
  fi

  command -v python3 >/dev/null 2>&1 \
    || die "python3 is required for gui's QMP/guest-agent control (pacman -S python / apt install python3)."

  [[ -f "$ROOT_IMG" && -f "$ESP_IMG" ]] || {
    echo "Expected $ROOT_IMG and $ESP_IMG — run this first:" >&2
    echo "  ./run_in_container.sh build.sh test disk   (from the repo root)" >&2
    exit 1
  }

  local exec_cmd="" out_file="" boot_timeout=300 arg
  for arg in "$@"; do
    case "$arg" in
      --exec=*)    exec_cmd="${arg#--exec=}" ;;
      --out=*)     out_file="${arg#--out=}" ;;
      --timeout=*) boot_timeout="${arg#--timeout=}" ;;
      *)
        echo "Usage: $(basename "$0") gui [--exec=\"shell command\"] [--out=<file.ppm>] [--timeout=N]" >&2
        exit 1
        ;;
    esac
  done
  [[ -n "$out_file" ]] || out_file="${DATA_DIR}/gui-screenshot-$(date +%s).ppm"

  _locate_ovmf
  local ovmf_code="$OVMF_CODE_PATH"

  # Separate NVRAM copy from cmd_qemu's own — headless/unattended, shouldn't
  # share (or clobber) the interactive session's EFI vars.
  local vars_copy="${DATA_DIR}/OVMF_VARS_gui.fd"
  [[ -f "$vars_copy" ]] || cp "$OVMF_VARS_TEMPLATE_PATH" "$vars_copy"

  local kvm_args=()
  [[ -e /dev/kvm && -w /dev/kvm ]] && kvm_args=(-enable-kvm -cpu host) \
    || echo "no /dev/kvm access — falling back to (slow) TCG emulation" >&2

  local qga_sock="${DATA_DIR}/qga-gui.sock"
  local qmp_sock="${DATA_DIR}/qmp-gui.sock"
  local pid_file="${DATA_DIR}/qemu-gui.pid"
  local console_log="${DATA_DIR}/gui-console.log"
  rm -f "$qga_sock" "$qmp_sock" "$pid_file"

  # NOTE: an EXIT trap runs after bash unwinds the function's call frame, so
  # it can't see cmd_gui's own `local` variables (confirmed live: reusing
  # the local $pid_file here raised "pid_file: unbound variable" under
  # `set -u` the moment qemu failed and this trap fired) — recompute the
  # path from the global $DATA_DIR instead.
  _gui_cleanup() {
    local _pid_file="${DATA_DIR}/qemu-gui.pid"
    if [[ -f "$_pid_file" ]]; then
      kill "$(cat "$_pid_file")" 2>/dev/null || true
      rm -f "$_pid_file"
    fi
  }
  trap _gui_cleanup EXIT

  log "Booting headless (no display window, QMP+guest-agent control only)..."
  qemu-system-x86_64 \
      -machine q35 \
      -smp 4 \
      -m "${QEMU_MEM:-4096}" \
      "${kvm_args[@]}" \
      -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
      -drive if=pflash,format=raw,file="$vars_copy" \
      -drive if=virtio,format=raw,file="$ROOT_IMG" \
      -drive if=virtio,format=raw,file="$ESP_IMG" \
      -device virtio-gpu-pci \
      -display none \
      -device virtio-net-pci,netdev=net0 \
      -netdev user,id=net0 \
      -device qemu-xhci -device usb-kbd -device usb-tablet \
      -chardev socket,path="$qga_sock",server=on,wait=off,id=qga0 \
      -device virtio-serial \
      -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
      -qmp unix:"$qmp_sock",server=on,wait=off \
      -serial file:"$console_log" \
      -daemonize -pidfile "$pid_file"

  if ! _qga_wait_ready "$qga_sock" "$boot_timeout"; then
    die "guest-agent never responded within ${boot_timeout}s — see ${console_log}"
  fi

  if [[ -n "$exec_cmd" ]]; then
    log "Running inside guest: ${exec_cmd}"
    _qga_exec "$qga_sock" "$exec_cmd" || warn "guest-exec exited non-zero (output above, if any)"
  fi

  log "Letting the compositor settle for 5s before screendump..."
  sleep 5

  _qmp_screendump "$qmp_sock" "$out_file" || die "screendump failed"
  log "Screenshot saved: ${out_file}"
}

# ------------------------------------------------------------------
# main dispatch
# ------------------------------------------------------------------
[[ $# -lt 1 ]] && usage

COMMAND="$1"
shift

case "$COMMAND" in
  disk)      cmd_disk "$@" ;;
  pacstrap)  cmd_pacstrap "$@" ;;
  ca)        cmd_ca "$@" ;;
  bootstrap) cmd_bootstrap "$@" ;;
  serve)     cmd_serve "$@" ;;
  enter)     cmd_enter "$@" ;;
  verify-boot) cmd_verifyboot "$@" ;;
  desktop)   cmd_desktop "$@" ;;
  probe)     cmd_probe "$@" ;;
  install)   cmd_install "$@" ;;
  configure) cmd_configure "$@" ;;
  upgrade)   cmd_upgrade "$@" ;;
  update-check) cmd_updatecheck "$@" ;;
  reboot)    cmd_reboot "$@" ;;
  rollback)  cmd_rollback "$@" ;;
  cycle)
    PROFILE="$(_get_profile "$@")"
    [[ -n "$PROFILE" ]] || die "cycle requires -p <profile>"

    # No cmd_disk preflight here: cmd_bootstrap now runs the real
    # install.sh via cmd_install, which creates and attaches its own
    # install.img and repoints the shani_root/shani_boot by-label
    # symlinks at it — a prior cmd_disk's root.img/esp.img would just be
    # dead work, immediately superseded.
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
  gui)       cmd_gui "$@" ;;
  watch)     cmd_watch "$@" ;;
  iso)       cmd_iso "$@" ;;
  clean)     cmd_clean "$@" ;;
  *)
    usage
    ;;
esac
