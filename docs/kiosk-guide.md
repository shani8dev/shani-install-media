# Kiosk Profile Guide

## What the kiosk profile is for

The kiosk profile is a single-purpose, locked-down image built for digital signage, information displays, and self-service kiosks. It boots straight into a full-screen Firefox browser with no desktop environment, no taskbar, and no user-accessible shell. The `kiosk` user's home directory lives entirely in tmpfs, so nothing written during a session survives a reboot. There is no ISO build for this profile; it is image-only, intended to be written directly to a device or deployed as an AMI.

## Architecture

The kiosk session is built from four cooperating layers:

**Display server.** `labwc` provides a minimal Wayland compositor. It is not a full desktop environment; it only manages windows and outputs so that Firefox has a surface to draw on.

**Kiosk wrapper.** `cage` is a Wayland kiosk shell. It starts `labwc` internally and then launches a single child application. The session entry point runs:

```
cage -s firefox --kiosk
```

The `-s` flag tells Cage to spawn the compositor and the application in the same session. Firefox receives `--kiosk`, which forces full-screen mode, hides the address bar and tabs, and disables most keyboard shortcuts.

**Session launch.** GDM autologin drops the `kiosk` user straight into the Cage/LabWC session defined in `/usr/share/wayland-sessions/kiosk.desktop`. There is no greeter interaction, no session picker, and no desktop menu.

**Ephemeral home.** The `kiosk` user's home at `/home/kiosk` is a tmpfs mount (`home-kiosk.mount`). On every boot, `systemd-kiosk-config.service` copies `/etc/skel/` into the fresh tmpfs and chowns it to `kiosk:users`. Any downloads, cookies, cache, or files created during the session vanish on reboot.

## Package list

The kiosk profile installs the following packages via `pacstrap`:

| Package | Role |
|---------|------|
| `shani-keyring` | Shanios GPG keyring for package verification |
| `shani-settings` | Shared system defaults (firewall, audit, etc.) |
| `shani-core` | Core system configuration and base services |
| `shani-deploy` | Image deployment and update tooling |
| `shani-network` | Network management and firewall |
| `shani-tools-network` | Additional network utilities |
| `shani-fonts` | Shanios font collection |
| `noto-fonts` | Noto font family for broad Unicode coverage |
| `gdm` | GNOME Display Manager for autologin |
| `firefox` | Web browser, run in kiosk mode |
| `cage` | Wayland kiosk shell |
| `labwc` | Minimal Wayland compositor |
| `waypaper` | Wallpaper utility (included but not used by default) |
| `xprintidle` | X11 idle-time query tool (available for idle-detection scripts) |
| `dracut` | Initramfs generator |
| `openresolv` | DNS resolver management |
| `desktop-entry-hider` | Hides desktop entries from menus |

The `shani-*` base packages pull in the standard Shanios stack: `firewalld`, `fail2ban`, `audit`, `apparmor`, and other security services are installed transitively and enabled by their `.install` scripts during `pacstrap`.

## Configuration

### GDM autologin

`/etc/gdm/custom.conf` is installed from the kiosk overlay:

```ini
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=kiosk
```

GDM starts on boot, waits for the display, and logs in the `kiosk` user without prompting. The session type is resolved from `/usr/share/wayland-sessions/kiosk.desktop`, which points to the Cage command.

### Wayland session

`/usr/share/wayland-sessions/kiosk.desktop` defines the session:

```ini
[Desktop Entry]
Name=Shani Kiosk (cage)
Comment=Single-application Wayland kiosk session
Exec=cage -s firefox --kiosk
Type=Application
DesktopNames=kiosk
```

GDM reads this file to know which session to start. The `Exec` line is the only thing that runs after login.

### Ephemeral home (tmpfs)

Three systemd units work together to make the `kiosk` home transient:

**`home-kiosk.mount`** mounts tmpfs on `/home/kiosk` with restrictive options:

```
mode=0750,uid=kiosk,gid=users,strictatime,nosuid,nodev
```

- `mode=0750` — only the owner and group can access the directory.
- `uid=kiosk,gid=users` — ownership is set at mount time.
- `strictatime` — every access is logged to the inode (useful for audit trails).
- `nosuid` — setuid/setgid bits are ignored.
- `nodev` — device files cannot be created.

**`systemd-kiosk-user.service`** creates the `kiosk` user if it does not already exist. It runs before `systemd-tmpfiles-setup.service` so the user exists when tmpfiles would otherwise try to create the home directory. The user is created with no password (`passwd -d kiosk`), which is required for GDM autologin.

**`systemd-kiosk-config.service`** runs after the tmpfs mount and copies `/etc/skel/` into `/home/kiosk/`, then chowns everything to `kiosk:users`. This gives the session a clean baseline on every boot.

### Systemd wiring

`kiosk-customization.sh` runs after `pacstrap` and creates symlinks in `sysinit.target.wants`:

```bash
ln -sfn ../systemd-kiosk-user.service   sysinit.target.wants/systemd-kiosk-user.service
ln -sfn ../systemd-kiosk-config.service sysinit.target.wants/systemd-kiosk-config.service
```

Wiring into `sysinit.target` ensures the user is created and the home is populated before any graphical session starts.

## Build instructions

The kiosk profile is image-only; there is no `iso_profiles/kiosk/` directory and no ISO is produced.

Build the base image:

```bash
./run_in_container.sh build.sh image -p kiosk
```

This runs `build-base-image.sh`, which:

1. Allocates a 10 GB Btrfs loop image at `cache/build/base.img`.
2. Creates the `shanios_base` subvolume and mounts it.
3. Installs the GPG signing public key and MOK keys into the chroot.
4. Runs `pacstrap` with `image_profiles/kiosk/pacman.conf` and the package list.
5. Copies the kiosk overlay files into the image root.
6. Runs `image_profiles/kiosk/kiosk-customization.sh` to wire the systemd units.
7. Configures locale, keymap, timezone, hostname, machine-id, and static GIDs inside the chroot.
8. Snapshots the read-only subvolume and streams it to `cache/output/kiosk/<YYYYMMDD>/shanios-<DATE>-kiosk.zst`.
9. GPG-signs the artifact and writes SHA-256 checksums.

Release and upload:

```bash
./run_in_container.sh build.sh release -p kiosk latest
./run_in_container.sh build.sh upload -p kiosk
```

## Deployment

Write the `.zst` image to a target device using `shani-deploy` or `btrfs send`/`receive`. The image is a raw Btrfs send-stream compressed with zstd; extract it with:

```bash
zstd -d shanios-<DATE>-kiosk.zst | btrfs receive /mnt/target
```

The target must have a Btrfs filesystem with the standard Shanios subvolume layout (`@`, `@home`, `@var`, `@log`, `@cache`, etc.). For physical hardware, use the Shanios installer or a custom deployment script that handles partitioning and subvolume creation.

For AWS, the kiosk profile is supported by the Packer AMI build path in `packer/`. Set `profile=kiosk` in the Packer variables.

## Customization

### Changing the startup URL

The URL Firefox opens is not hardcoded in the image. Set it at runtime by placing a `user.js` or `policies.json` in `/etc/skel/` (which gets copied into the tmpfs home on every boot), or by pushing a configuration file via your content management system after the device is online.

To bake a default URL into the image, add a file to `image_profiles/kiosk/overlay/rootfs/etc/skel/`:

```
etc/skel/.mozilla/firefox/*.default/prefs.js
```

with:

```javascript
user_pref("browser.startup.homepage", "https://your-url.example.com");
```

### Changing browser behavior

Edit `/usr/share/wayland-sessions/kiosk.desktop` in the overlay to adjust the Cage/Firefox invocation. Common flags:

- `--kiosk` — full-screen, no chrome.
- `--private-window` — no persistent cookies or cache (redundant with tmpfs home, but adds Firefox-level isolation).
- `--no-remote` — prevents Firefox from connecting to an existing desktop session.

### Changing the session user

The `kiosk` user is created by `systemd-kiosk-user.service` with no password. If you need a different username, update:

1. `systemd-kiosk-user.service` — the `useradd` and `usermod` commands.
2. `/etc/gdm/custom.conf` — `AutomaticLogin`.
3. `home-kiosk.mount` — the `uid=` and `gid=` mount options.
4. `systemd-kiosk-config.service` — the `chown` target.

### Adding or removing packages

Edit `image_profiles/kiosk/Packages-Base`, `Packages-Desktop`, or
`Packages-Extras` and rebuild. Each file is a plain list — blank lines and
lines starting with `#` are ignored, so use `#` to comment out a package
without renumbering anything. Packages that enable systemd services in their
`.install` scripts (like `shani-network` enabling `firewalld`) will be active
automatically.

`image_profiles/kiosk/package-list.txt` is a legacy artifact and is no longer
read by the build; delete it to prevent drift.

## Security considerations

The kiosk profile is intentionally locked down:

- **No persistent storage.** The home directory is tmpfs. Nothing survives a reboot unless explicitly written to a mounted persistent volume.
- **No shell access.** The `kiosk` user has a passwordless account, but GDM autologin drops straight into Cage. There is no terminal emulator installed by default, and the session does not expose a TTY.
- **Restrictive tmpfs options.** `nosuid` and `nodev` prevent privilege escalation via setuid binaries or device nodes in the home directory.
- **Firefox kiosk mode.** The `--kiosk` flag disables the address bar, bookmarks menu, and most keyboard shortcuts. Right-click context menus are suppressed.
- **Underlying security stack.** `shani-core` and `shani-network` enable `auditd`, `apparmor`, `firewalld`, and `fail2ban` during `pacstrap`. These run regardless of profile.
- **What an attacker can do.** If Firefox is compromised via a malicious page, the attacker gains the `kiosk` user's privileges inside the Wayland session. They cannot write to disk, but they can access the network, make HTTP requests, and interact with the Cage window. The tmpfs home limits the blast radius to the current session only.
- **What users cannot do.** There is no package manager available to the `kiosk` user (no `sudo`, no `su`, no terminal). They cannot install software, modify system files, or change systemd units without physical access and a reboot from rescue media.

## Troubleshooting

**Firefox does not start.** Check that `cage` and `firefox` are installed and that `/usr/share/wayland-sessions/kiosk.desktop` exists. GDM logs are at `/var/log/gdm/`. Run `journalctl -u gdm` from a root shell.

**GDM shows a login prompt instead of autologin.** Verify `/etc/gdm/custom.conf` has `AutomaticLoginEnable=true` and `AutomaticLogin=kiosk`. The `kiosk` user must exist; check `id kiosk`. If the user is missing, `systemd-kiosk-user.service` may have failed. Check `journalctl -u systemd-kiosk-user.service`.

**Home directory is empty on login.** `systemd-kiosk-config.service` copies `/etc/skel/` into `/home/kiosk/`. Check `journalctl -u systemd-kiosk-config.service` and verify `home-kiosk.mount` is active with `systemctl status home-kiosk.mount`.

**Screen goes blank after boot.** `labwc` may have failed to start or Firefox may have crashed. Switch to a TTY with `Ctrl+Alt+F3` and inspect `journalctl -b`. If Firefox is crashing on a specific page, test with a simple local page first.

**Network does not work.** `shani-network` manages NetworkManager or systemd-networkd depending on the base image. Check `networkctl` or `nmcli` from a root shell. `openresolv` is installed for DNS management.

**System reboots into emergency mode.** A missing or misconfigured Btrfs subvolume will cause `systemd` to drop to emergency mode. Check `/etc/fstab` and verify the target disk has the expected subvolume layout.

## See Also

- `README.md` — full build pipeline, command reference, artifact layout, and key management.
- `test-env/README.md` — test harness for installing, booting, upgrading, and rolling back built images on loop-mounted disks.
