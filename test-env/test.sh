#!/usr/bin/env bash
# test.sh – Dispatcher for the shanios-test-env rig
#
# ============================================================
# FLOW OVERVIEW
# ============================================================
#
# disk       → scripts/00-create-disk.sh
#                writes: disk/root.img, disk/esp.img
# ca         → scripts/00b-generate-test-ca.sh
#                writes: disk/ca/{ca.crt,ca.key,server.crt,server.key}
# bootstrap  → scripts/01-bootstrap-rootfs.sh -p <profile> [-d latest|stable|<date>]
#                reads:  OUTPUT_DIR/<profile>/... (config.sh — this repo's own build output)
#                writes: @blue / @green subvolumes on disk/root.img
# serve      → scripts/02-serve-update.sh [port]
#                serves OUTPUT_DIR over HTTPS as downloads.shani.dev (blocks)
# enter      → scripts/03-enter-slot.sh <blue|green> [--boot] [cmd...]
# upgrade    → scripts/04-simulate-upgrade.sh   (real shani-update, inside current slot)
# reboot     → scripts/05-simulate-reboot.sh    (re-enter whichever slot is now current)
# rollback   → scripts/06-simulate-rollback.sh  (real shani-update --rollback)
# cycle      disk (if missing) → ca (if missing) → bootstrap -p <profile> → serve (background)
#            → upgrade → reboot
#              requires -p <profile>
# qemu       Genuine UEFI boot via OVMF — HOST-ONLY, cannot run inside this container
#              (needs your GPU/display and, optionally, /dev/kvm directly)
#
# ============================================================
# Invoked as: ./run_in_container.sh build.sh test <command> [options]
#   (build.sh's `test` case execs this script — see its dispatch table)
set -Eeuo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
# NOTE: deliberately NOT cd-ing into $SCRIPT_DIR (test-env/) — config.sh
# resolves OUTPUT_DIR etc. relative to CWD ("./cache/output"), so CWD must
# stay at the repo root (../run_in_container.sh already sets -w to the
# mounted repo root), same as build.sh never cd's away from it either.
source "${SCRIPT_DIR}/../config/config.sh"

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

qemu runs on the HOST, not through build.sh test — from the repo root:
  test-env/scripts/07-boot-qemu.sh
EOF
  exit 1
}

[[ $# -lt 1 ]] && usage

COMMAND="$1"
shift

_get_profile() {
  local _prev="" _profile=""
  for _arg in "$@"; do
    [[ "${_prev}" == "-p" ]] && { _profile="$_arg"; _prev="$_arg"; continue; }
    _prev="$_arg"
  done
  echo "$_profile"
}

case "$COMMAND" in
  disk)
    exec "${SCRIPT_DIR}/scripts/00-create-disk.sh" "$@"
    ;;
  ca)
    exec "${SCRIPT_DIR}/scripts/00b-generate-test-ca.sh" "$@"
    ;;
  bootstrap)
    exec "${SCRIPT_DIR}/scripts/01-bootstrap-rootfs.sh" "$@"
    ;;
  serve)
    exec "${SCRIPT_DIR}/scripts/02-serve-update.sh" "$@"
    ;;
  enter)
    exec "${SCRIPT_DIR}/scripts/03-enter-slot.sh" "$@"
    ;;
  upgrade)
    exec "${SCRIPT_DIR}/scripts/04-simulate-upgrade.sh" "$@"
    ;;
  reboot)
    exec "${SCRIPT_DIR}/scripts/05-simulate-reboot.sh" "$@"
    ;;
  rollback)
    exec "${SCRIPT_DIR}/scripts/06-simulate-rollback.sh" "$@"
    ;;
  cycle)
    PROFILE="$(_get_profile "$@")"
    [[ -n "$PROFILE" ]] || die "cycle requires -p <profile>"

    [[ -f "${SCRIPT_DIR}/disk/root.img" && -f "${SCRIPT_DIR}/disk/esp.img" ]] || "${SCRIPT_DIR}/scripts/00-create-disk.sh"
    [[ -f "${SCRIPT_DIR}/disk/ca/ca.crt" ]] || "${SCRIPT_DIR}/scripts/00b-generate-test-ca.sh"
    "${SCRIPT_DIR}/scripts/01-bootstrap-rootfs.sh" "$@"

    "${SCRIPT_DIR}/scripts/02-serve-update.sh" &
    SERVE_PID=$!
    trap 'kill "$SERVE_PID" 2>/dev/null || true' EXIT
    sleep 1

    "${SCRIPT_DIR}/scripts/04-simulate-upgrade.sh"
    "${SCRIPT_DIR}/scripts/05-simulate-reboot.sh"
    ;;
  qemu)
    echo "qemu runs on the HOST, not through build.sh test." >&2
    echo "From the repo root, run: test-env/scripts/07-boot-qemu.sh" >&2
    exit 1
    ;;
  *)
    usage
    ;;
esac
