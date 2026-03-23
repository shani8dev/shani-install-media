#!/bin/bash
# module-setup.sh — dracut module descriptor for the ShaniOS boot failure hook.
#
# Install THREE files to /usr/lib/dracut/modules.d/99shanios/:
#   module-setup.sh
#   shanios-boot-failure-hook.sh
#   shanios-boot-success-clear.sh
#
# shanios-overlay-etc.sh has been removed. The /etc OverlayFS is now mounted
# via fstab with x-initrd.mount, which is processed by systemd inside the
# initramfs before pivot_root. This is more reliable than a shell hook because
# systemd handles dependency ordering via x-systemd.requires-mounts-for=/data,
# ensuring @data is mounted before the overlay is attempted.
#
# Then rebuild the initramfs:
#   dracut --force --kver "$(uname -r)"
#   (shani-deploy runs this automatically via gen-efi)

check() {
    # Always include this module in ShaniOS initramfs.
    return 0
}

depends() {
    # base is always present and provides warn(), getarg(), dracut-lib.sh.
    # No additional module dependencies needed.
    return 0
}

install() {
    # pre-mount hook: writes boot_hard_failure marker before mount is attempted.
    inst_hook pre-mount 90 "$moddir/shanios-boot-failure-hook.sh"

    # pre-pivot hook: clears the marker on successful root mount + pivot.
    # If root never mounts, pre-pivot is never reached, so the marker persists.
    inst_hook pre-pivot 90 "$moddir/shanios-boot-success-clear.sh"

    # Binaries the hooks use. warn() and getarg() are dracut shell functions
    # sourced automatically — do not pass them to inst_multiple.
    inst_multiple blkid mount umount mountpoint mkdir rmdir rm printf sed
}

installkernel() {
    return 0
}
