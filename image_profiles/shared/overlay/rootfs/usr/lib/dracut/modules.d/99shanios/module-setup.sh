#!/bin/bash
# module-setup.sh — dracut module descriptor for the ShaniOS boot failure hook.
#
# Install ALL FOUR files to /usr/lib/dracut/modules.d/99shanios/:
#   module-setup.sh
#   shanios-boot-failure-hook.sh
#   shanios-boot-success-clear.sh
#   shanios-overlay-etc.sh
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

    # pre-pivot hook: mounts the /etc OverlayFS onto the new root before pivot_root.
    # Priority 50 — runs before the boot-success-clear hook at priority 90, so
    # the overlay is live before we declare success.
    inst_hook pre-pivot 50 "$moddir/shanios-overlay-etc.sh"

    # pre-pivot hook: clears the marker on successful root mount + pivot.
    # If root never mounts, pre-pivot is never reached, so the marker persists.
    inst_hook pre-pivot 90 "$moddir/shanios-boot-success-clear.sh"

    # Binaries the hooks use. warn() and getarg() are dracut shell functions
    # sourced automatically — do not pass them to inst_multiple.
    # overlay: the kernel module is auto-loaded; 'overlay' here is the fs-type
    # name passed to mount -t, which needs no binary — but we do need mount to
    # accept it, so ensure the overlay kernel module is present.
    #
    # The list must cover EVERY external command the hooks actually run, not
    # just the ones the first version of the failover happened to use. A
    # command missing here is not an error at build time and not an error at
    # boot: the hook runs, the shell prints nothing useful, and the logic
    # silently does nothing. That is exactly what happened — six boots logged
    # "boot_hard_failure written" (printf IS installed) and no DIAG line and no
    # default rewrite (cat, ls, readlink, tr, cp are NOT), which reads from the
    # console exactly like a hook that never ran.
    #
    #   printf  writes the marker          -> the one line that did appear
    #   cat     reads it back (PRIOR_FAILURE)
    #   cp      backs up + rewrites loader.conf  -> the failover itself
    #   ls      DIAG
    #   readlink DIAG
    #   tr      DIAG
    #   head    parsing the default line
    #   basename the fallback-entry scan
    inst_multiple blkid mount umount mountpoint mkdir rmdir rm printf sed \
                  cat cp ls readlink tr head basename

    # Ensure the overlay kernel module is packed into the initramfs so
    # 'mount -t overlay' works before the real root's modules are available.
    instmods overlay

    # vfat, and this is the failover's whole mechanism. The pre-mount hook has
    # to mount the ESP to rewrite loader.conf's default line - and `mount -t
    # vfat` fails without the module, silently, because the hook redirects
    # mount's stderr. Measured on a real boot: every hook line was correct and
    # the run died on
    #
    #   prior failure (@blue) but could not mount the ESP (/dev/vda1)
    #
    # with `overlay.ko` present and `vfat.ko` ABSENT from the very initramfs
    # that was about to be booted. `fat` and the nls_* charset modules come
    # along as dependencies of vfat; blkid -L already resolves the label
    # without them, since that is read from the superblock.
    instmods vfat
}

installkernel() {
    return 0
}
