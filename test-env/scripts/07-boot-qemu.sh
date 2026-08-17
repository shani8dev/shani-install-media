#!/bin/bash
# 07-boot-qemu.sh
#
# Run this on the HOST, NOT inside the container — it needs your GPU/display
# and (optionally) /dev/kvm directly.
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
set -euo pipefail

DISK_DIR="${SHANIOS_TEST_DISK_DIR:-$(dirname "$0")/../disk}"
ROOT_IMG="${DISK_DIR}/root.img"
ESP_IMG="${DISK_DIR}/esp.img"

[[ -f "$ROOT_IMG" && -f "$ESP_IMG" ]] || {
    echo "Expected $ROOT_IMG and $ESP_IMG — run this first:" >&2
    echo "  ./run_in_container.sh build.sh test disk   (from the repo root)" >&2
    exit 1
}

# Locate OVMF firmware + a per-VM copy of the vars file (writable NVRAM store
# — bootctl's `set-default` EFI-var write and any MOK enrollment land here;
# copied once so re-running this script doesn't reset it).
OVMF_CODE="${OVMF_CODE:-}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-}"
for candidate in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd; do
    [[ -z "$OVMF_CODE" && -f "$candidate" ]] && OVMF_CODE="$candidate"
done
for candidate in \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
    /usr/share/edk2/x64/OVMF_VARS.fd; do
    [[ -z "$OVMF_VARS_TEMPLATE" && -f "$candidate" ]] && OVMF_VARS_TEMPLATE="$candidate"
done
[[ -n "$OVMF_CODE" && -n "$OVMF_VARS_TEMPLATE" ]] || {
    echo "Couldn't find OVMF firmware. Install it (see header of this script)" >&2
    echo "or set \$OVMF_CODE / \$OVMF_VARS_TEMPLATE explicitly." >&2
    exit 1
}

VARS_COPY="${DISK_DIR}/OVMF_VARS.fd"
[[ -f "$VARS_COPY" ]] || cp "$OVMF_VARS_TEMPLATE" "$VARS_COPY"

KVM_ARGS=()
[[ -e /dev/kvm && -w /dev/kvm ]] && KVM_ARGS=(-enable-kvm -cpu host) || echo "no /dev/kvm access — falling back to (slow) TCG emulation" >&2

echo "==> Booting root.img + esp.img via OVMF (close the window / send SIGTERM to stop)"
exec qemu-system-x86_64 \
    -machine q35 \
    -smp 4 \
    -m "${QEMU_MEM:-4096}" \
    "${KVM_ARGS[@]}" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VARS_COPY" \
    -drive if=virtio,format=raw,file="$ROOT_IMG" \
    -drive if=virtio,format=raw,file="$ESP_IMG" \
    -device virtio-gpu-pci \
    -display "${QEMU_DISPLAY:-gtk}" \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0 \
    -device qemu-xhci -device usb-kbd -device usb-tablet \
    -serial mon:stdio
