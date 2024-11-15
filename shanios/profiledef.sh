#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="shanios"
iso_label="SHANI_$(date +%Y%m)"
iso_publisher="Shani OS <https://shani.dev>"
iso_application="Shani OS Live/Rescue CD"
iso_version="$(date +%Y.%m.%d)"
install_dir="shani"
buildmodes=('iso')
bootmodes=('uefi-ia32.systemd-boot.esp' 'uefi-x64.systemd-boot.esp'
           'uefi-ia32.systemd-boot.eltorito' 'uefi-x64.systemd-boot.eltorito')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '19' '-b' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/etc/sudoers"]="0:0:400"
  ["/root"]="0:0:750"
)
