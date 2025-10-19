#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="shanios-plasma"
iso_label="SHANI_$(date +%Y%m)"
iso_publisher="Shani OS <https://shani.dev>"
iso_application="Shani OS Live/Rescue CD"
iso_version="$(date +%Y.%m.%d)"
install_dir="shanios"
buildmodes=('iso')
bootmodes=('uefi.systemd-boot')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
#airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '100%')
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '22' '-b' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/etc/sudoers"]="0:0:400"
  ["/root"]="0:0:750"
)
