#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="shanios-gamescope"
iso_label="SHANI_$(date +%Y%m)"
iso_publisher="Shani OS <https://shani.dev>"
iso_application="Shani OS Live/Rescue CD"
# The ISO filename carries this date and the dated folder it is published to is
# computed by build.sh from BUILD_DATE - they must agree, or the release gate
# reconstructs a filename that does not exist (20261016 folder shipping a
# 2026.10.17 ISO stranded the plasma ISO promotion). mkarchiso sources this file
# inside the same pipeline that exports BUILD_DATE, so deriving the version from
# it keeps the two clocks identical even across a midnight boundary; fall back to
# the wall clock for any caller that did not pin one.
if [ -n "${BUILD_DATE:-}" ]; then
    iso_version="${BUILD_DATE:0:4}.${BUILD_DATE:4:2}.${BUILD_DATE:6:2}"
else
    iso_version="$(date +%Y.%m.%d)"
fi
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