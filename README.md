# Shani OS Install Media Builder

A fully automated build system for **Shani OS** — a secure, immutable, Arch-based Linux distribution. The pipeline builds Btrfs system images, Flatpak images, and Secure Boot–signed ISOs for GNOME, Plasma, and COSMIC desktop profiles. All steps run inside a Docker container so your host system is never modified.

The container image is maintained in [shani-builder](https://github.com/shani8dev/shani-builder).

---

## How It All Fits Together

```
run_in_container.sh                  ← sets up Docker, injects all secrets
└── build.sh <command> -p <profile>  ← dispatcher
    ├── scripts/build-base-image.sh   pacstrap → Btrfs snapshot → .zst + .asc + .sha256
    ├── scripts/build-flatpak-image.sh install/prune Flatpaks → Btrfs snapshot → flatpakfs.zst
    ├── scripts/build-iso.sh          mkarchiso → unsigned ISO
    ├── scripts/repack-iso.sh         sbsign EFI + shim + MOK.der → signed ISO + torrent
    ├── scripts/release.sh            write central latest.txt or stable.txt
    ├── scripts/promote-stable.sh     download latest.txt from SF → publish as stable.txt
    └── scripts/upload.sh             rsync → SourceForge  +  rclone → Cloudflare R2
```

All output lands in `cache/output/<profile>/<YYYYMMDD>/`.

---

## Prerequisites

### Host requirements

- Docker (or Podman — the wrapper auto-detects it and disables pacman signature verification to work around gpg-agent socket issues inside rootless Podman)
- `openssl` — only needed if you generate MOK keys locally (see below)

### Secrets / credentials

`run_in_container.sh` reads from a `.env` file in the project root, or directly from environment variables (GitHub Actions injects them from repository secrets):

| Variable | Required for | Description |
|----------|-------------|-------------|
| `GPG_PRIVATE_KEY` | `image`, `repack` | Armored GPG private key for signing `.zst` and ISO artifacts |
| `GPG_PASSPHRASE` | `image`, `repack` | Passphrase to unlock the GPG key |
| `SSH_PRIVATE_KEY` | `upload`, `promote-stable` | PEM private key with SSH access to SourceForge |
| `R2_ACCESS_KEY_ID` | `upload` (optional) | Cloudflare R2 access key ID |
| `R2_SECRET_ACCESS_KEY` | `upload` (optional) | Cloudflare R2 secret access key |
| `R2_ACCOUNT_ID` | `upload` (optional) | 32-char hex Cloudflare account ID (from the R2 dashboard) |
| `R2_BUCKET` | `upload` (optional) | R2 bucket name |
| `DOCKER_IMAGE` | optional | Override builder image (default: `docker.io/shrinivasvkumbhar/shani-builder`) |
| `CUSTOM_MIRROR` | optional | Override Arch Linux pacman mirror |

All R2 variables are optional — if any are absent, R2 mirroring is silently skipped and SourceForge is used as the sole upload target. `--no-sf` and `--no-r2` flags (or `NO_SF=true` / `NO_R2=true` env vars) skip individual destinations selectively.

**Local `.env` example:**

```env
GPG_PRIVATE_KEY="-----BEGIN PGP PRIVATE KEY BLOCK-----
...
-----END PGP PRIVATE KEY BLOCK-----"
GPG_PASSPHRASE=your-passphrase
SSH_PRIVATE_KEY="-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----"
R2_ACCESS_KEY_ID=abc123
R2_SECRET_ACCESS_KEY=secret
R2_ACCOUNT_ID=0123456789abcdef0123456789abcdef
R2_BUCKET=shanios-releases
```

---

## MOK Keys (Secure Boot)

Machine Owner Keys (MOK) are an RSA-2048 keypair used to:

1. **Sign the EFI binaries** — GRUB (`grubx64.efi`), the EFI shell (`shellx64.efi`), and the kernel (`vmlinuz-linux`) are signed with `sbsign` inside `repack-iso.sh`
2. **Embed `MOK.der` into the ISO** — placed at the EFI partition root and the ISO filesystem root so the end user can enroll it via MokManager on first boot
3. **Install the keys into the base image** — `build-base-image.sh` copies all three files into `<chroot>/etc/secureboot/keys/` during the `image` step

The key files live in the `mok/` directory:

| File | Purpose | Permissions |
|------|---------|-------------|
| `mok/MOK.key` | RSA private key — used by `sbsign` to sign EFI binaries | `0600` — **never commit** |
| `mok/MOK.crt` | X.509 certificate (PEM) — paired with `MOK.key` | `0644` |
| `mok/MOK.der` | X.509 certificate (DER) — embedded in the ISO for end-user enrollment | `0644` |

`config/config.sh` sets `MOK_DIR=$(realpath ./mok)`. `build-base-image.sh` calls `check_mok_keys` before doing anything else — if any of the three files are missing it auto-generates a new keypair via `openssl`. You should generate your own keys **once** and keep them stable across builds so enrolled users do not have to re-enroll after a system update.

### Step 1 — Generate keys locally

Run `create-keys.sh` **once** from inside the `mok/` directory:

```bash
cd mok/
bash create-keys.sh
```

This will:
- Generate `MOK.key` (RSA-2048, `chmod 0600`)
- Generate `MOK.crt` (X.509 PEM, 10-year validity, `CN=Shani OS Secure Boot Key`)
- Export `MOK.der` (DER format) and validate it immediately — a corrupt DER file will cause `gen-efi enroll-mok` to fail, so validation happens at generation time
- Write `github-secrets.env` with all three values formatted for pasting into GitHub Actions secrets

The script is **idempotent** — if all three key files already exist it skips generation and only regenerates `github-secrets.env`.

### Step 2 — Add secrets to GitHub

Open `mok/github-secrets.env`. It contains three entries:

```
MOK_KEY<<EOF_VAL
-----BEGIN PRIVATE KEY-----
...
EOF_VAL

MOK_CRT<<EOF_VAL
-----BEGIN CERTIFICATE-----
...
EOF_VAL

MOK_DER_B64=<single-line base64>
```

Go to **Settings → Secrets and variables → Actions → New repository secret** and create one secret per entry:

| Secret name | Value |
|-------------|-------|
| `MOK_KEY` | The multiline PEM private key block |
| `MOK_CRT` | The multiline PEM certificate block |
| `MOK_DER_B64` | The single-line base64-encoded DER string |

The `build-image.yml` workflow reconstructs the files at build time:

```yaml
- name: Setup MOK keys
  run: |
    mkdir -p mok
    echo "${{ secrets.MOK_KEY }}"          > mok/MOK.key
    echo "${{ secrets.MOK_CRT }}"          > mok/MOK.crt
    echo "${{ secrets.MOK_DER_B64 }}" | base64 --decode > mok/MOK.der
```

### Step 3 — Shred the local files

After uploading secrets, destroy the key files from your machine:

```bash
shred -u mok/MOK.key mok/MOK.crt mok/MOK.der mok/github-secrets.env
```

### What `repack-iso.sh` does with the keys

1. Extracts `grubx64.efi`, `shellx64.efi`, and `vmlinuz-linux` from the unsigned ISO using `osirrox`
2. Waits up to 30 seconds for the eltorito EFI image (`eltorito_img1_uefi.img`) to appear
3. Mounts the eltorito image and copies out the kernel
4. Copies `shimx64.efi` → `BOOTx64.EFI` and `mmx64.efi` from the airootfs at `cache/temp/<profile>/x86_64/airootfs/usr/share/shim-signed/` (installed via the `shim-signed` package in the builder image)
5. Signs `grubx64.efi`, `shellx64.efi`, and `vmlinuz-linux` with `sbsign --key mok/MOK.key --cert mok/MOK.crt`
6. Injects everything back via `mcopy`:
   - `vmlinuz-linux` → `::/shanios/boot/x86_64/vmlinuz-linux`
   - `MOK.der` and signed `shellx64.efi` → `::/ ` (EFI partition root)
   - `BOOTx64.EFI` (shim), `grubx64.efi`, `mmx64.efi` → `::/EFI/BOOT/`
7. Rebuilds the full ISO with `xorriso`, additionally mapping `MOK.der` to `/MOK.der` in the ISO filesystem
8. GPG-signs the final ISO → `signed_*.iso.asc`
9. SHA-256 checksums it → `signed_*.iso.sha256`
10. Creates a `.torrent` with two webseeds (`https://downloads.shani.dev/...` and `https://downloads.sourceforge.net/...`) and six public trackers

### End-user enrollment

On first boot, UEFI loads `BOOTx64.EFI` which is shim. Shim detects the key is not yet enrolled and launches **MokManager** (`mmx64.efi`) automatically. The user then:

1. Selects **"Enroll key from disk"** in the MokManager UI
2. Navigates to the EFI partition root where `MOK.der` was placed by `mcopy` (`\MOK.der`)
3. Selects `MOK.der` and confirms enrollment
4. Reboots — all subsequent boots proceed silently through shim → signed GRUB → signed kernel

---

## Profiles

Each profile has its own subdirectory under both `image_profiles/` and `iso_profiles/`:

| Profile | Desktop | Notes |
|---------|---------|-------|
| `gnome` | GNOME | No special Flatpak overrides |
| `plasma` | KDE Plasma | Adds `Kvantum` filesystem override and `QT_STYLE_OVERRIDE=kvantum` |
| `cosmic` | COSMIC | Same structure, no special overrides |

**`image_profiles/<profile>/` contains:**

- `package-list.txt` — packages installed by `pacstrap` into the base image
- `flatpak-packages.txt` — Flathub app IDs installed into the Flatpak image
- `snap-packages.txt` — Snap package names (used by `build-snap-image.sh`, optional)
- `pacman.conf` — pacman configuration passed to `pacstrap`
- `<profile>-customization.sh` — shell script run after `pacstrap`, receives the chroot path as `$1`
- `overlay -> ../shared/overlay` — symlink; its `rootfs/` contents are `cp -r`'d verbatim into the base image root

**`iso_profiles/<profile>/` contains:**

- `profiledef.sh` — mkarchiso profile definition
- `packages.x86_64` — packages included in the ISO live environment
- `pacman.conf` — pacman config for the ISO environment
- `airootfs -> ../shared/airootfs` — symlink to shared live-environment files
- `efiboot -> ../shared/efiboot` — symlink to systemd-boot config

---

## Usage

All commands are run via `run_in_container.sh`, which starts a privileged Docker container, volume-mounts the project, injects all credentials, and runs the given command inside it.

```bash
./run_in_container.sh build.sh <command> -p <profile> [args]
```

### Full pipeline

```bash
./run_in_container.sh build.sh all -p gnome
```

`all` runs these steps in sequence:
1. `build-base-image.sh -p gnome`
2. `build-flatpak-image.sh -p gnome`
3. `build-iso.sh -p gnome`
4. `repack-iso.sh -p gnome`
5. `release.sh -p gnome latest`
6. `upload.sh -p gnome all`

---

### Individual steps

#### `image` — Build the base system image

```bash
./run_in_container.sh build.sh image -p gnome
```

- Calls `check_mok_keys` — auto-generates keys if any of `mok/MOK.{key,crt,der}` are missing
- Calls `check_dependencies` — verifies `btrfs`, `pacstrap`, `losetup`, `arch-chroot`, `gpg`, etc.
- Allocates a 10 GB Btrfs loop image at `cache/build/base.img`
- Creates Btrfs subvolume `shanios_base` and mounts it
- Installs `MOK.key` (mode `0600`), `MOK.crt`, and `MOK.der` into `<chroot>/etc/secureboot/keys/`
- Runs `pacstrap -cC image_profiles/gnome/pacman.conf <chroot> $(< package-list.txt)`
- Applies overlay files from `image_profiles/shared/overlay/rootfs/`
- Runs `image_profiles/gnome/gnome-customization.sh <chroot>`
- `arch-chroot`s to configure: locale (`en_US.UTF-8`), keymap (`us`), timezone (`UTC`), hostname (`shanios`), machine-id, `/etc/hosts`, `/etc/shani-version`, `/etc/shani-profile`, `/etc/shani-channel` (`stable`), `/etc/shani-extra-groups` (`sys,cups,lp,scanner,realtime,input,video,kvm,libvirt,lxd,nixbld`), mount point directories, system groups with static GIDs, `subuid`/`subgid` for root, and imports the Shani signing public key if `/etc/shani-keys/signing.asc` exists
- Marks subvolume read-only, streams it with `btrfs send | zstd --ultra --long=31 -T0 -22` → `cache/output/gnome/<DATE>/shanios-<DATE>-gnome.zst`
- GPG-signs → `.zst.asc`, SHA-256 checksums → `.zst.sha256`
- Writes `cache/output/gnome/<DATE>/latest.txt` containing the `.zst` filename

#### `flatpak` — Build the Flatpak image

```bash
./run_in_container.sh build.sh flatpak -p gnome
```

- Reads `image_profiles/gnome/flatpak-packages.txt`, adds Flathub remote if needed
- Installs all listed apps with `flatpak install --system --or-update`
- Builds a dependency map using four strategies: runtime queries, metadata parsing, related-refs queries, and a filesystem scan of `/var/lib/flatpak/runtime` — to determine what runtimes and extensions to keep
- Removes apps not in the profile list, then removes unneeded runtimes/extensions (with a dry-run safety check before each removal), runs `flatpak uninstall --unused` and `flatpak repair`
- Plasma: applies `--filesystem=xdg-config/Kvantum:ro` and `QT_STYLE_OVERRIDE=kvantum`
- Any profile with Steam, Heroic, Lutris, RetroArch, or Bottles: applies `--filesystem=~/Games:create` and `/mnt`, `/media`, `/run/media` permissions
- Allocates a 14 GB Btrfs loop image at `cache/build/flatpak.img`, creates subvolume `flatpak_subvol`
- Copies `/var/lib/flatpak` into the subvolume with `tar -cf - | tar -xf -`
- Streams the read-only subvolume → `cache/output/gnome/<DATE>/flatpakfs.zst`

#### `iso` — Build the bootable ISO

```bash
./run_in_container.sh build.sh iso -p gnome
```

- Requires `cache/output/gnome/<DATE>/latest.txt` (written by `image`)
- Copies the `.zst` → `cache/temp/gnome/iso/shanios/x86_64/rootfs.zst`
- Copies `flatpakfs.zst` → same directory if present, warns and skips if not
- Runs `mkarchiso -v -w cache/temp/gnome -o cache/output/gnome/<DATE> iso_profiles/gnome`
- Produces `cache/output/gnome/<DATE>/shanios-gnome-<VER>-x86_64.iso`

#### `repack` — Sign the ISO for Secure Boot

```bash
./run_in_container.sh build.sh repack -p gnome
```

See [What `repack-iso.sh` does with the keys](#what-repack-isosh-does-with-the-keys) above.

Output: `signed_shanios-gnome-<VER>-x86_64.iso` + `.sha256` + `.asc` + `.torrent`

#### `release` — Write the release pointer

```bash
# Mark today's build as latest
./run_in_container.sh build.sh release -p gnome latest

# Mark today's build as stable
./run_in_container.sh build.sh release -p gnome stable
```

Copies `cache/output/gnome/<DATE>/latest.txt` to `cache/output/gnome/latest.txt` (or `stable.txt`). If no `<DATE>` folder exists for today it automatically uses the most recent dated folder.

#### `promote-stable` — Promote latest to stable

```bash
./run_in_container.sh build.sh promote-stable -p gnome
```

- Downloads `https://sourceforge.net/projects/shanios/files/gnome/latest.txt/download` with 3 retries and a 30-second timeout
- Verifies the file is non-empty
- Copies it to `cache/output/gnome/stable.txt`
- Uploads `stable.txt` to SourceForge via `rsync`
- Mirrors `stable.txt` to R2 if `R2_BUCKET` is set

#### `upload` — Push artifacts

```bash
# Upload base image artifacts only (default)
./run_in_container.sh build.sh upload -p gnome

# Upload base image + signed ISO + torrent
./run_in_container.sh build.sh upload -p gnome all

# Skip SourceForge, mirror to R2 only
./run_in_container.sh build.sh upload -p gnome --no-sf

# Skip R2, upload to SourceForge only
./run_in_container.sh build.sh upload -p gnome --no-r2
```

In `image` mode (default), uploads from `cache/output/gnome/<DATE>/`:
- `*.zst` (excludes `flatpakfs.zst` and `snapfs.zst`)
- `*.zst.asc`
- `*.zst.sha256`
- `latest.txt`

Plus central files from `cache/output/gnome/` if present:
- `latest.txt`
- `stable.txt`

In `all` mode, additionally uploads:
- `signed_*.iso`
- `signed_*.iso.sha256`
- `signed_*.iso.asc`
- `signed_*.iso.torrent`

SourceForge path: `librewish@frs.sourceforge.net:/home/frs/project/shanios/<profile>/<DATE>/`
R2 path: `r2:<R2_BUCKET>/<profile>/<DATE>/`

After all uploads complete the R2 cleanup routine deletes old dated folders under the profile prefix, keeping only the most recent folder and the folder pinned by `stable.txt` on R2. Central `latest.txt` and `stable.txt` are never deleted.

#### `publish` — Release + upload in one call

```bash
./run_in_container.sh build.sh publish -p gnome stable
```

Equivalent to running `release` then `upload` in sequence.

---

## Command Reference

| Command | Script | Description |
|---------|--------|-------------|
| `image` | `build-base-image.sh` | Build Btrfs base image via pacstrap |
| `flatpak` | `build-flatpak-image.sh` | Build Flatpak image from profile app list |
| `snap` | `build-snap-image.sh` | Build Snap seed image (optional) |
| `iso` | `build-iso.sh` | Assemble bootable ISO via mkarchiso |
| `repack` | `repack-iso.sh` | Sign EFI binaries + rebuild ISO + generate torrent |
| `release` | `release.sh` | Write `latest.txt` or `stable.txt` |
| `upload` | `upload.sh` | Push artifacts to SourceForge and/or R2 |
| `promote-stable` | `promote-stable.sh` | Fetch `latest.txt` from SF and publish as `stable.txt` |
| `publish` | — | `release` + `upload` |
| `all` | — | Full pipeline: image → flatpak → iso → repack → release latest → upload all |

---

## Build Artifacts

All artifacts are written to `cache/output/<profile>/<YYYYMMDD>/`:

| File | Produced by | Description |
|------|------------|-------------|
| `shanios-<DATE>-<profile>.zst` | `image` | Compressed Btrfs base image |
| `shanios-<DATE>-<profile>.zst.asc` | `image` | GPG detached signature |
| `shanios-<DATE>-<profile>.zst.sha256` | `image` | SHA-256 checksum |
| `flatpakfs.zst` | `flatpak` | Compressed Btrfs Flatpak image |
| `snapfs.zst` | `snap` | Compressed Btrfs Snap seed image |
| `latest.txt` | `image` | Filename of this build's `.zst` |
| `shanios-<profile>-<VER>-x86_64.iso` | `iso` | Unsigned bootable ISO |
| `signed_shanios-<profile>-<VER>-x86_64.iso` | `repack` | Secure Boot–signed ISO |
| `signed_*.iso.sha256` | `repack` | ISO checksum |
| `signed_*.iso.asc` | `repack` | ISO GPG signature |
| `signed_*.iso.torrent` | `repack` | Torrent with R2 + SF webseeds |

Central release pointers at `cache/output/<profile>/`:

| File | Description |
|------|-------------|
| `latest.txt` | Points to the most recent build's `.zst` filename |
| `stable.txt` | Points to the promoted stable build's `.zst` filename |

---

## Volumes Mounted by `run_in_container.sh`

| Host path | Container path | Purpose |
|-----------|---------------|---------|
| `./` | `/home/builduser/build` | Entire project (read/write) |
| `cache/pacman_cache/` | `/var/cache/pacman` | Persistent pacman package cache |
| `cache/flatpak_data/` | `/var/lib/flatpak` | Persistent Flatpak installation |
| `cache/snapd_data/` | `/var/lib/snapd` | Persistent snapd data |
| `cache/snapd_seed/` | `/tmp/snap-seed` | Snap seed staging area |
| `/sys/fs/cgroup` | `/sys/fs/cgroup` (ro) | Required for systemd inside container |
| `/lib/modules` | `/lib/modules` (ro) | Kernel modules for loop devices and Btrfs |

The container runs `--privileged --cap-add SYS_ADMIN --device=/dev/fuse` because the build requires loop devices, Btrfs mounts, `arch-chroot`, and Flatpak's FUSE access.

---

## GitHub Actions

The workflow at `.github/workflows/build-image.yml` runs on a schedule (every Friday at 20:30 UTC) and supports manual dispatch via `workflow_dispatch`. It builds `gnome` and `plasma` in parallel with `fail-fast: false` so a failure in one profile does not cancel the other.

Each profile runs three steps: `image`, `release latest`, and `upload image`.

### Required secrets

| Secret | Description |
|--------|-------------|
| `MOK_KEY` | PEM private key — from `create-keys.sh` |
| `MOK_CRT` | PEM certificate — from `create-keys.sh` |
| `MOK_DER_B64` | Base64-encoded DER certificate — from `create-keys.sh` |
| `GPG_PRIVATE_KEY` | Armored GPG private key for artifact signing |
| `GPG_PASSPHRASE` | Passphrase for the GPG key |
| `SSH_PRIVATE_KEY` | SSH key for SourceForge rsync uploads |
| `R2_ACCESS_KEY_ID` | Cloudflare R2 access key ID |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 secret access key |
| `R2_ACCOUNT_ID` | Cloudflare account ID (32-char hex) |
| `R2_BUCKET` | R2 bucket name |

R2 secrets are optional — if unset, all uploads go to SourceForge only.

---

## Project Structure

```
├── build.sh                        # Main dispatcher
├── run_in_container.sh             # Docker/Podman wrapper; injects secrets
├── config/
│   └── config.sh                   # Global vars, log/warn/die helpers,
│                                   # setup_btrfs_image, detach_btrfs_image,
│                                   # btrfs_send_snapshot, check_mok_keys,
│                                   # check_dependencies
├── scripts/
│   ├── build-base-image.sh
│   ├── build-flatpak-image.sh
│   ├── build-iso.sh
│   ├── build-snap-image.sh
│   ├── repack-iso.sh
│   ├── release.sh
│   ├── promote-stable.sh
│   └── upload.sh
├── image_profiles/
│   ├── gnome/
│   │   ├── package-list.txt        # pacstrap package list
│   │   ├── flatpak-packages.txt    # Flathub app IDs
│   │   ├── pacman.conf
│   │   ├── gnome-customization.sh
│   │   └── overlay -> ../shared/overlay
│   ├── plasma/                     # Same structure
│   ├── cosmic/                     # Same structure
│   └── shared/
│       ├── flatpak-packages.txt
│       ├── snap-packages.txt
│       └── overlay/rootfs/         # Copied verbatim into every base image
│           ├── etc/
│           └── usr/
├── iso_profiles/
│   ├── gnome/
│   │   ├── profiledef.sh           # mkarchiso profile definition
│   │   ├── packages.x86_64         # Live ISO packages
│   │   ├── pacman.conf
│   │   ├── airootfs -> ../shared/airootfs
│   │   └── efiboot -> ../shared/efiboot
│   ├── plasma/                     # Same structure
│   ├── cosmic/                     # Same structure
│   └── shared/
│       ├── airootfs/               # Overlaid into the ISO live environment
│       │   ├── etc/                # hostname, locale, greetd, mkinitcpio, etc.
│       │   ├── root/
│       │   │   ├── customize_airootfs.sh
│       │   │   └── watermark.png
│       │   └── usr/share/
│       └── efiboot/loader/         # systemd-boot loader.conf + entries
├── mok/
│   ├── create-keys.sh              # Generates keypair + github-secrets.env
│   ├── MOK.key                     # RSA private key  ← never commit
│   ├── MOK.crt                     # X.509 PEM certificate
│   ├── MOK.der                     # X.509 DER certificate (embedded in ISO)
│   └── github-secrets.env          # Generated — delete after uploading secrets
└── cache/                          # Generated at build time — not committed
    ├── build/                      # Btrfs loop image files (base.img, flatpak.img)
    ├── output/                     # Final artifacts per profile/date
    ├── temp/                       # mkarchiso working directory
    ├── flatpak_data/               # Volume-mounted Flatpak installation
    ├── pacman_cache/               # Volume-mounted pacman cache
    ├── snapd_data/                 # Volume-mounted snapd data
    └── snapd_seed/                 # Volume-mounted snap seed staging
```

---

## Build Environment

All steps run inside the `shrinivasvkumbhar/shani-builder` Docker image from [shani-builder](https://github.com/shani8dev/shani-builder). It is based on `archlinux:base-devel` and pre-installs `archiso`, `btrfs-progs`, `sbsigntools`, `shim-signed`, `mokutil`, `mtools`, `flatpak`, `snapd`, `rclone`, `rsync`, `openssh`, `mktorrent`, `zsync`, and more. It also imports the Shani OS signing GPG key and registers the `[shani]` custom pacman repository at `https://repo.shani.dev/x86_64`.

---

## Related Repositories

| Repository | Description |
|------------|-------------|
| [shani-builder](https://github.com/shani8dev/shani-builder) | Docker build environment and automated package builder |
| [shani-pkgbuilds](https://github.com/shani8dev/shani-pkgbuilds) | PKGBUILD sources for Shani OS custom packages |
| [shani-repo](https://github.com/shani8dev/shani-repo) | Published Arch-compatible package repository (`https://repo.shani.dev`) |

---

## License

GNU General Public License v3.0 — see individual script headers for authorship details.
