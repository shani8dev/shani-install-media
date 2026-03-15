#!/bin/bash
# module-setup.sh — dracut module descriptor for the ShaniOS boot failure hook.
#
# Install ALL THREE files to /usr/lib/dracut/modules.d/99shanios/:
#   module-setup.sh
#   shanios-boot-failure-hook.sh
#   shanios-boot-success-clear.sh
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
    inst_multiple blkid mount umount mkdir rmdir rm printf sed
}

installkernel() {
    return 0
}
