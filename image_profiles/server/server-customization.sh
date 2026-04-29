#!/usr/bin/env bash
# image_profiles/server/server-customization.sh
#
# Applied by build-base-image.sh inside the pacstrapped chroot.
# Called as: bash server-customization.sh <SUBVOL_MOUNT>
#
# This script contains ONLY operations that cannot be expressed as static
# overlay files: systemctl enable/disable, chsh, conditional logic.
#
# Everything else (static configs, masks, symlinks) lives in:
#   image_profiles/server/overlay/rootfs/
#
# What this script does:
#   1. Enable networking services (systemd-networkd, resolved, timesyncd)
#   2. Enable core server services (sshd, firewalld, fail2ban, apparmor, etc.)
#   3. Enable cloud-init services
#   4. Enable EC2 serial console getty
#   5. Conditionally enable amazon-ssm-agent
#   6. Disable services that install enabled by default but don't belong on server
#   7. Remove shared overlay desktop artifacts (rm — can't do in overlay)
#   8. Set zsh as default shell (chsh + sed on useradd defaults)

set -Eeuo pipefail

CHROOT="${1:?Usage: server-customization.sh <chroot_mount>}"

log()  { echo "[SERVER-CUSTOM][INFO]  $*"; }
warn() { echo "[SERVER-CUSTOM][WARN]  $*" >&2; }
die()  { echo "[SERVER-CUSTOM][ERROR] $*" >&2; exit 1; }

[[ -d "${CHROOT}" ]] || die "Chroot directory not found: ${CHROOT}"

in_chroot() { arch-chroot "${CHROOT}" /bin/bash -c "$1"; }

log "Applying server profile customizations to ${CHROOT}..."

# ─────────────────────────────────────────────────────────────────────────────
# 1. Networking services
#    The network config files (20-cloud-dhcp.network, resolved.conf, resolv.conf
#    symlink) are already in place via the overlay. We just need to enable the
#    units so their wants/ symlinks are created.
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
# 4. EC2 serial console (ttyS0)
#    The kernel cmdline is already set via overlay/rootfs/etc/kernel/install_cmdline.
#    We just need the wants/ symlink for the getty instance.
# ─────────────────────────────────────────────────────────────────────────────
log "Enabling EC2 serial console getty..."
in_chroot "systemctl enable serial-getty@ttyS0.service"

# ─────────────────────────────────────────────────────────────────────────────
# 5. amazon-ssm-agent (conditional — only if the package installed successfully)
# ─────────────────────────────────────────────────────────────────────────────
if in_chroot "command -v amazon-ssm-agent" &>/dev/null; then
    in_chroot "systemctl enable amazon-ssm-agent.service 2>/dev/null || true"
    log "  enabled: amazon-ssm-agent.service"
else
    warn "amazon-ssm-agent not found — skipping (add to package-list.txt via Chaotic-AUR)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. Disable services that install themselves enabled but don't belong on server
#    (tailscaled, cloudflared, caddy all require user configuration first)
# ─────────────────────────────────────────────────────────────────────────────
log "Disabling services that need user configuration before use..."
for svc in tailscaled.service cloudflared.service caddy.service; do
    in_chroot "systemctl disable ${svc} 2>/dev/null || true"
done
log "  tailscaled, cloudflared, caddy disabled — enable after configuring"

# ─────────────────────────────────────────────────────────────────────────────
# 7. Remove shared overlay desktop artifacts
#    These are drop-in files or assets from the shared overlay that make no
#    sense on a headless server. They cannot be removed via the server overlay
#    (overlay only adds files, it cannot remove files placed by other overlays).
# ─────────────────────────────────────────────────────────────────────────────
log "Removing desktop-only shared overlay artifacts..."

# snapd service drop-ins — snap has no role server-side
rm -f "${CHROOT}/usr/lib/systemd/system/snapd.service.d/"*  2>/dev/null || true
rm -f "${CHROOT}/usr/lib/systemd/system/snapd.socket.d/"*   2>/dev/null || true

# GPaste GNOME clipboard — no GNOME on server
rm -f "${CHROOT}/etc/systemd/user/org.gnome.GPaste.service.d/override.conf" 2>/dev/null || true

# Plymouth boot splash bitmap
rm -f "${CHROOT}/usr/share/systemd/bootctl/splash-shani.bmp" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# 8. Set zsh as default shell
#    /etc/skel/.zshrc and root/.zshrc are already in place via overlay.
#    We need chsh (runtime binary) and sed on /etc/default/useradd.
# ─────────────────────────────────────────────────────────────────────────────
log "Setting zsh as default shell..."
if in_chroot "command -v zsh" &>/dev/null; then
    ZSH_PATH=$(in_chroot "command -v zsh")

    # Register zsh in /etc/shells
    in_chroot "grep -qF '${ZSH_PATH}' /etc/shells || echo '${ZSH_PATH}' >> /etc/shells"

    # Set root's login shell
    in_chroot "chsh -s '${ZSH_PATH}' root"
    log "  root shell → ${ZSH_PATH}"

    # Pre-set the default shell for users created by cloud-init on first boot
    sed -i "s|^SHELL=.*|SHELL=${ZSH_PATH}|" "${CHROOT}/etc/default/useradd" 2>/dev/null || true
    log "  /etc/default/useradd SHELL → ${ZSH_PATH}"
else
    warn "zsh not found — skipping shell defaults"
fi

log "Server profile customization complete."
