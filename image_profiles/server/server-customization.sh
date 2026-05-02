#!/usr/bin/env bash
# image_profiles/server/server-customization.sh
#
# Called by build-base-image.sh as:
#   bash server-customization.sh "${SUBVOL_MOUNT}"
#
# Static config files (network, sysctl, SSH, cloud-init, etc.) are already
# in place via the overlay copy that runs BEFORE this script.
#
# This script handles ONLY what overlay files cannot express:
#   - systemctl enable  (creates wants/ symlinks — requires running binary)
#   - systemctl disable (same)
#   - chsh              (modifies /etc/passwd — requires running binary)
#   - sed on /etc/default/useradd
#   - rm of shared overlay desktop artifacts
#
# NOTE: hostname, shani-profile, shani-channel, locale, machine-id are written
# by build-base-image.sh's own chroot block which runs AFTER this script.
# Do NOT set them here.

set -Eeuo pipefail

CHROOT="${1:?Usage: server-customization.sh <chroot_mount>}"

log()  { echo "[SERVER-CUSTOM][INFO]  $*"; }
warn() { echo "[SERVER-CUSTOM][WARN]  $*" >&2; }
die()  { echo "[SERVER-CUSTOM][ERROR] $*" >&2; exit 1; }

[[ -d "${CHROOT}" ]] || die "Chroot directory not found: ${CHROOT}"

in_chroot() { arch-chroot "${CHROOT}" /bin/bash -c "$1"; }

log "Applying server profile customizations..."

# ─────────────────────────────────────────────────────────────────────────────
# 1. Networking services
#    Config files (20-cloud-dhcp.network, resolved.conf, resolv.conf symlink)
#    are already in place via the overlay.
# ─────────────────────────────────────────────────────────────────────────────
log "Enabling networking services..."
in_chroot "systemctl enable systemd-networkd.service"
in_chroot "systemctl enable systemd-resolved.service"
in_chroot "systemctl enable systemd-timesyncd.service"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Core server services
# ─────────────────────────────────────────────────────────────────────────────
log "Enabling core server services..."
for svc in \
    sshd.service \
    firewalld.service \
    fail2ban.service \
    apparmor.service \
    auditd.service \
    cronie.service \
    fwupd.service; do
    in_chroot "systemctl enable ${svc} 2>/dev/null || true"
    log "  enabled: ${svc}"
done

# ─────────────────────────────────────────────────────────────────────────────
# 3. cloud-init services
# ─────────────────────────────────────────────────────────────────────────────
log "Enabling cloud-init services..."
for svc in \
    cloud-init-local.service \
    cloud-init.service \
    cloud-config.service \
    cloud-final.service; do
    in_chroot "systemctl enable ${svc} 2>/dev/null || true"
    log "  enabled: ${svc}"
done

# ─────────────────────────────────────────────────────────────────────────────
# 4. EC2 serial console
#    Kernel cmdline (console=ttyS0,115200n8) is set via overlay
#    /etc/kernel/install_cmdline. We just need the getty wants/ symlink.
# ─────────────────────────────────────────────────────────────────────────────
log "Enabling EC2 serial console..."
in_chroot "systemctl enable serial-getty@ttyS0.service"

# ─────────────────────────────────────────────────────────────────────────────
# 5. amazon-ssm-agent (conditional — only if package installed)
# ─────────────────────────────────────────────────────────────────────────────
if in_chroot "command -v amazon-ssm-agent" &>/dev/null; then
    in_chroot "systemctl enable amazon-ssm-agent.service 2>/dev/null || true"
    log "  enabled: amazon-ssm-agent.service"
else
    warn "amazon-ssm-agent not found — skipping (install via Chaotic-AUR)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. Disable services that auto-enable on install but need user config first
# ─────────────────────────────────────────────────────────────────────────────
log "Disabling services that require user configuration before use..."
for svc in tailscaled.service cloudflared.service caddy.service; do
    in_chroot "systemctl disable ${svc} 2>/dev/null || true"
done

# ─────────────────────────────────────────────────────────────────────────────
# 7. Remove shared overlay desktop artifacts
#    The overlay copy in build-base-image.sh uses cp -r and cannot remove files.
#    Files placed by the shared overlay that do not apply to a server build
#    must be deleted here.
# ─────────────────────────────────────────────────────────────────────────────
log "Removing desktop-only shared overlay artifacts..."
rm -f "${CHROOT}/usr/lib/systemd/system/snapd.service.d/"*     2>/dev/null || true
rm -f "${CHROOT}/usr/lib/systemd/system/snapd.socket.d/"*      2>/dev/null || true
rm -f "${CHROOT}/etc/systemd/user/org.gnome.GPaste.service.d/override.conf" 2>/dev/null || true
rm -f "${CHROOT}/usr/share/systemd/bootctl/splash-shani.bmp"  2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# 8. Set zsh as default shell
#    /etc/skel/.zshrc and /root/.zshrc are already in place via the overlay.
# ─────────────────────────────────────────────────────────────────────────────
log "Setting zsh as default shell..."
if in_chroot "command -v zsh" &>/dev/null; then
    ZSH_PATH=$(in_chroot "command -v zsh")
    in_chroot "grep -qF '${ZSH_PATH}' /etc/shells || echo '${ZSH_PATH}' >> /etc/shells"
    in_chroot "chsh -s '${ZSH_PATH}' root"
    sed -i "s|^SHELL=.*|SHELL=${ZSH_PATH}|" "${CHROOT}/etc/default/useradd" 2>/dev/null || true
    log "  root → ${ZSH_PATH}, useradd default updated"
else
    warn "zsh not found — skipping shell default"
fi

log "Server profile customization complete."
