#!/bin/bash
# Module setup for encrypted Btrfs with overlayfs

check() { 
    require_binaries btrfs mount || return 1
    return 0 
}

depends() {
    echo "systemd fs-lib btrfs crypt"
    return 0
}

install() {
    inst_hook pre-mount 99 "$moddir/mount-all.sh"
    inst_script "$moddir/mount-all.sh" /sbin/mount-shani
    inst_multiple -o /etc/crypttab
}
