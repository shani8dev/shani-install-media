# Shani OS Install Media Builder

A fully automated build system for **Shani OS** — a secure, immutable, Arch-based Linux distribution. The pipeline builds Btrfs system images, optional Flatpak/Snap images, and Secure Boot–signed ISOs for GNOME, Plasma, and COSMIC desktop profiles. All steps run inside a Docker container so your host system is never modified.

The container image is maintained in [shani-builder](https://github.com/shani8dev/shani-builder).

---

## How It All Fits Together

```
run_in_container.sh                  ← sets up Docker, injects all secrets
└── build.sh <command> -p <profile>  ← dispatcher
    ├── scripts/build-base-image.sh   pacstrap → Btrfs snapshot → .zst + .asc + .sha256
    ├── scripts/build-flatpak-image.sh  (only if flatpak-packages.txt exists for profile)
    ├── scripts/build-snap-image.sh     (only if snap-packages.txt exists for profile)
    ├── scripts/build-iso.sh          mkarchiso → unsigned ISO
    │                                   copies flatpakfs.zst / snapfs.zst if present
    ├── scripts/repack-iso.sh         sbsign EFI + shim + MOK.der → signed ISO + torrent
    ├── scripts/release.sh            write central latest.txt or stable.txt
    ├── scripts/promote-stable.sh     download latest.txt from SF → publish as stable.txt
    └── scripts/upload.sh             rsync → SourceForge  +  rclone → Cloudflare R2
                                        (flatpakfs.zst / snapfs.zst are never uploaded)
```

All output lands in `cache/output/<profile>/<YYYYMMDD>/`.

---

## Prerequisites

### Host requirements

- Docker (or Podman — the wrapper auto-detects it and disables pacman signature verification to work around gpg-agent socket issues inside rootless Podman)
- `openssl` — only needed if you generate MOK keys locally (see below)
- `gpg` — only needed if you generate GPG keys locally
- `ssh-keygen` — only needed if you generate SSH keys locally

### Secrets / credentials

`run_in_container.sh` reads from a `.env` file in the project root, or directly from environment variables (GitHub Actions injects them from repository secrets):

| Variable | Required for | Description |
|----------|-------------|-------------|
| `GPG_PRIVATE_KEY` | `image`, `repack` | Armored GPG private key for signing `.zst` and ISO artifacts |
| `GPG_PASSPHRASE` | `image`, `repack` | Passphrase to unlock the GPG key |
| `GPG_KEY_ID` | `image`, `repack` | Full GPG key fingerprint (40-char hex) |
| `SSH_PRIVATE_KEY` | `upload`, `promote-stable` | ED25519 private key with SSH access to SourceForge |
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
GPG_KEY_ID=7B927BFFD4A9EAAA8B666B77DE217F3DA8014792
SSH_PRIVATE_KEY="-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----"
R2_ACCESS_KEY_ID=abc123
R2_SECRET_ACCESS_KEY=secret
R2_ACCOUNT_ID=0123456789abcdef0123456789abcdef
R2_BUCKET=shanios-releases
```

---

## Key Management

All cryptographic keys live under `keys/` and are organised into three subdirectories — one per key type. Each subdirectory has its own generation script and produces a `github-*-secrets.env` file containing values formatted for direct paste into GitHub Actions secrets.

```
keys/
├── create-gpg-keys.sh      ← GPG signing key generator
├── create-mok-keys.sh      ← Secure Boot MOK keypair generator
├── create-ssh-keys.sh      ← SSH keypair generator
├── gpg/
│   ├── gpg-private.asc          GPG armored private key   ← never commit
│   ├── gpg-public.asc           GPG armored public key
│   └── github-gpg-secrets.env   Generated — delete after uploading secrets
├── mok/
│   ├── MOK.key                  RSA-2048 private key      ← never commit
│   ├── MOK.crt                  X.509 PEM certificate
│   ├── MOK.der                  X.509 DER certificate (embedded in ISO)
│   └── github-mok-secrets.env   Generated — delete after uploading secrets
└── ssh/
    ├── ssh-private              ED25519 private key       ← never commit
    ├── ssh-public               ED25519 public key
    └── github-ssh-secrets.env   Generated — delete after uploading secrets
```

> **Never commit** any private key or `*.env` file. All three are covered by `.gitignore`.

---

### GPG Signing Key

The GPG key signs every build artifact: base images (`.zst.asc`), signed ISOs (`.iso.asc`), and the public key is embedded in the base image at `/etc/shani-keys/signing.asc` so installed systems can verify future updates.

#### Generate

```bash
cd keys/
bash create-gpg-keys.sh
```

To also upload the public key to the OpenPGP, Ubuntu, and MIT keyservers immediately:

```bash
bash create-gpg-keys.sh --upload
```

The script will:
- Prompt for a passphrase (with confirmation)
- Generate a 4096-bit RSA key (`Shani OS <shani@shani.dev>`, 5-year expiry) in an isolated temporary GNUPG home so your personal keyring is untouched
- Export `gpg/gpg-private.asc` (passphrase-protected, `chmod 0600`) and `gpg/gpg-public.asc`
- Write `gpg/github-gpg-secrets.env` containing `GPG_PRIVATE_KEY`, `GPG_PASSPHRASE`, `GPG_KEY_ID`, and `GPG_PUBLIC_KEY`

The script is **idempotent** — if `gpg/gpg-private.asc` already exists it skips key generation, re-reads the fingerprint from the existing key (prompting for the passphrase), and only regenerates `github-gpg-secrets.env`.

#### Add secrets to GitHub

Open `gpg/github-gpg-secrets.env`. Add the following at **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Description |
|--------|-------------|
| `GPG_PRIVATE_KEY` | Armored private key block |
| `GPG_PASSPHRASE` | Key passphrase |
| `GPG_KEY_ID` | Full 40-char fingerprint |

#### Embed the public key in the base image

Copy the public key into the shared overlay so it is baked into every base image:

```bash
cp keys/gpg/gpg-public.asc \
   image_profiles/shared/overlay/rootfs/etc/shani-keys/signing.asc
```

`build-base-image.sh` imports this key into the chroot's `/root/.gnupg` and sets ultimate trust during the build.

#### Shred after use

```bash
shred -u keys/gpg/gpg-private.asc keys/gpg/gpg-public.asc keys/gpg/github-gpg-secrets.env
rmdir keys/gpg 2>/dev/null || true
```

---

### MOK Keys (Secure Boot)

Machine Owner Keys (MOK) are an RSA-2048 keypair used to:

1. **Sign EFI binaries** — GRUB (`grubx64.efi`), the EFI shell (`shellx64.efi`), and the kernel (`vmlinuz-linux`) are signed with `sbsign` inside `repack-iso.sh`
2. **Embed `MOK.der` in the ISO** — placed at the EFI partition root and the ISO filesystem root so the end user can enroll it via MokManager on first boot
3. **Install keys into the base image** — `build-base-image.sh` copies all three files into `<chroot>/etc/secureboot/keys/`

| File | Purpose | Permissions |
|------|---------|-------------|
| `mok/MOK.key` | RSA private key — used by `sbsign` to sign EFI binaries | `0600` — **never commit** |
| `mok/MOK.crt` | X.509 certificate (PEM) — paired with `MOK.key` | `0644` |
| `mok/MOK.der` | X.509 certificate (DER) — embedded in the ISO for enrollment | `0644` |

#### Generate

```bash
cd keys/
bash create-mok-keys.sh
```

The script will:
- Generate `mok/MOK.key` (RSA-2048, no passphrase, `chmod 0600`), `mok/MOK.crt` (X.509 PEM, 10-year validity, `CN=Shani OS Secure Boot Key`)
- Export `mok/MOK.der` (DER format) and validate it immediately — a corrupt DER causes `mokutil` to abort at enrollment time
- Write `mok/github-mok-secrets.env` with `MOK_KEY`, `MOK_CRT`, and `MOK_DER_B64`

The script is **idempotent** — if all three files exist it skips key generation, regenerates `MOK.der` from the existing `MOK.crt`, and rewrites `github-mok-secrets.env`.

#### Add secrets to GitHub

Open `mok/github-mok-secrets.env` and add these secrets:

| Secret | Description |
|--------|-------------|
| `MOK_KEY` | Multiline PEM private key block |
| `MOK_CRT` | Multiline PEM certificate block |
| `MOK_DER_B64` | Single-line base64-encoded DER |

The workflow reconstructs the files at build time:

```yaml
- name: Setup MOK keys
  run: |
    mkdir -p keys/mok
    echo "${{ secrets.MOK_KEY }}"                    > keys/mok/MOK.key
    echo "${{ secrets.MOK_CRT }}"                    > keys/mok/MOK.crt
    echo "${{ secrets.MOK_DER_B64 }}" | base64 --decode > keys/mok/MOK.der
```

#### Shred after use

```bash
shred -u keys/mok/MOK.key keys/mok/MOK.crt keys/mok/MOK.der keys/mok/github-mok-secrets.env
rmdir keys/mok 2>/dev/null || true
```

#### What `repack-iso.sh` does with the MOK keys

1. Extracts `grubx64.efi`, `shellx64.efi`, and `vmlinuz-linux` from the unsigned ISO using `osirrox`
2. Waits up to 30 seconds for the eltorito EFI image (`eltorito_img1_uefi.img`) to appear
3. Mounts the eltorito image and copies out the kernel
4. Copies `shimx64.efi` → `BOOTx64.EFI` and `mmx64.efi` from `cache/temp/<profile>/x86_64/airootfs/usr/share/shim-signed/`
5. Signs `grubx64.efi`, `shellx64.efi`, and `vmlinuz-linux` with `sbsign --key mok/MOK.key --cert mok/MOK.crt`
6. Injects everything back via `mcopy`:
   - `vmlinuz-linux` → `::/shanios/boot/x86_64/vmlinuz-linux`
   - `MOK.der` and signed `shellx64.efi` → `::/ ` (EFI partition root)
   - `BOOTx64.EFI` (shim), `grubx64.efi`, `mmx64.efi` → `::/EFI/BOOT/`
7. Rebuilds the full ISO with `xorriso`, also mapping `MOK.der` to `/MOK.der` in the ISO filesystem
8. GPG-signs the final ISO → `signed_*.iso.asc` using `--import-ownertrust` to set key trust non-interactively
9. SHA-256 checksums → `signed_*.iso.sha256`
10. Creates a `.torrent` with two webseeds (`https://downloads.shani.dev/...` and `https://downloads.sourceforge.net/...`) and six public trackers

#### End-user enrollment

On first boot, UEFI loads `BOOTx64.EFI` (shim). Shim detects the key is not yet enrolled and launches **MokManager** (`mmx64.efi`) automatically:

1. Select **"Enroll key from disk"**
2. Navigate to the EFI partition root and select `MOK.der`
3. Confirm enrollment and reboot — all subsequent boots proceed silently through shim → signed GRUB → signed kernel

---

### SSH Key

The SSH key authenticates `rsync` uploads to SourceForge in `upload.sh` and `promote-stable.sh`.

#### Generate

```bash
cd keys/
bash create-ssh-keys.sh
```

To also upload the public key to remote platforms immediately:

```bash
bash create-ssh-keys.sh --upload               # GitHub + GitLab + SourceForge
bash create-ssh-keys.sh --upload=github        # GitHub only
bash create-ssh-keys.sh --upload=gitlab        # GitLab only
bash create-ssh-keys.sh --upload=sourceforge   # SourceForge only
```

The script will:
- Generate `ssh/ssh-private` (ED25519, no passphrase, `chmod 0600`) and `ssh/ssh-public` (`chmod 0644`)
- Write `ssh/github-ssh-secrets.env` containing `SSH_PRIVATE_KEY`, `SSH_PASSPHRASE` (empty), and `SSH_PUBLIC_KEY`

For GitHub and GitLab uploads the script prompts for a personal access token (`admin:public_key` scope for GitHub, `api` scope for GitLab) and an optional key title, then calls the platform API and prints the assigned key ID on success. SourceForge has no API for key upload — the script prints the public key and links to `https://sourceforge.net/auth/preferences/` for manual paste.

The script is **idempotent** — if `ssh/ssh-private` already exists it skips key generation and only regenerates `github-ssh-secrets.env`.

#### Add secrets to GitHub

Open `ssh/github-ssh-secrets.env` and add:

| Secret | Description |
|--------|-------------|
| `SSH_PRIVATE_KEY` | ED25519 private key block |

#### Add public key to SourceForge

Go to `https://sourceforge.net/auth/preferences/` → **SSH Public Keys** and paste the contents of `keys/ssh/ssh-public`.

#### Shred after use

```bash
shred -u keys/ssh/ssh-private keys/ssh/github-ssh-secrets.env
rm -f keys/ssh/ssh-public
rmdir keys/ssh 2>/dev/null || true
```

---

## Profiles

Each profile has its own subdirectory under both `image_profiles/` and `iso_profiles/`:

| Profile | Desktop | Notes |
|---------|---------|-------|
| `gnome` | GNOME | No special Flatpak overrides |
| `plasma` | KDE Plasma | Adds `Kvantum` filesystem override and `QT_STYLE_OVERRIDE=kvantum` |
| `cosmic` | COSMIC | Same structure, no special overrides |

**`image_profiles/<profile>/` contains:**

- `package-list.txt` — packages installed by `pacstrap` into the base image (**required**)
- `flatpak-packages.txt` — Flathub app IDs; **optional** — if absent the Flatpak build step is skipped entirely
- `snap-packages.txt` — Snap package names; **optional** — if absent the Snap build step is skipped entirely
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

`all` runs the complete pipeline in sequence:

1. `build-base-image.sh` — always
2. `build-flatpak-image.sh` — only if `image_profiles/<profile>/flatpak-packages.txt` exists
3. `build-snap-image.sh` — only if `image_profiles/<profile>/snap-packages.txt` exists
4. `build-iso.sh` — copies `flatpakfs.zst` and `snapfs.zst` into the ISO if they were built
5. `repack-iso.sh` — signs EFI binaries and rebuilds the ISO for Secure Boot
6. `release latest` — writes the central `latest.txt` pointer
7. `upload all` — uploads base image artifacts and the signed ISO to SourceForge and R2

> `flatpakfs.zst` and `snapfs.zst` are **never uploaded** as standalone artifacts. They are embedded into the ISO only.

---

### Individual steps

#### `image` — Build the base system image

```bash
./run_in_container.sh build.sh image -p gnome
```

- Calls `check_mok_keys` — auto-generates keys if any of `keys/mok/MOK.{key,crt,der}` are missing
- Calls `check_dependencies` — verifies `btrfs`, `pacstrap`, `losetup`, `arch-chroot`, `gpg`, `sha256sum`, `zstd`, `rsync`, `openssl`, and related tools
- Allocates a 10 GB Btrfs loop image at `cache/build/base.img`
- Creates Btrfs subvolume `shanios_base` and mounts it
- Copies `keys/gpg/gpg-public.asc` → `<chroot>/etc/shani-keys/signing.asc`
- Installs `MOK.key` (mode `0600`), `MOK.crt`, and `MOK.der` into `<chroot>/etc/secureboot/keys/`
- Runs `pacstrap -cC image_profiles/gnome/pacman.conf <chroot> $(< package-list.txt)`
- Applies overlay files from `image_profiles/shared/overlay/rootfs/`
- Runs `image_profiles/gnome/gnome-customization.sh <chroot>`
- `arch-chroot`s to configure: locale (`en_US.UTF-8`), keymap (`us`), timezone (`UTC`), hostname (`shanios`), machine-id, `/etc/hosts`, `/etc/shani-version`, `/etc/shani-profile`, `/etc/shani-channel` (`stable`), `/etc/shani-extra-groups` (`sys,cups,lp,scanner,realtime,input,video,kvm,libvirt,lxd,nixbld`), mount point directories, system groups with static GIDs, `subuid`/`subgid` for root, and imports the Shani signing public key with ultimate trust
- Marks subvolume read-only, streams it with `btrfs send | zstd --ultra --long=31 -T0 -22` → `cache/output/gnome/<DATE>/shanios-<DATE>-gnome.zst`
- GPG-signs → `.zst.asc`, SHA-256 checksums → `.zst.sha256`
- Writes `cache/output/gnome/<DATE>/latest.txt` containing the `.zst` filename

#### `flatpak` — Build the Flatpak image (optional)

```bash
./run_in_container.sh build.sh flatpak -p gnome
```

Skipped automatically by `all` if `image_profiles/gnome/flatpak-packages.txt` does not exist. When run directly, exits cleanly with a log message if the file is absent.

- Reads `image_profiles/gnome/flatpak-packages.txt`, adds Flathub remote if needed
- Installs all listed apps with `flatpak install --system --or-update`
- Builds a dependency map using four strategies: runtime queries, metadata parsing, related-refs queries, and a filesystem scan of `/var/lib/flatpak/runtime` — to determine what runtimes and extensions to keep
- Removes apps not in the profile list, then removes unneeded runtimes/extensions (with a dry-run safety check before each removal), runs `flatpak uninstall --unused` and `flatpak repair`
- Plasma: applies `--filesystem=xdg-config/Kvantum:ro` and `QT_STYLE_OVERRIDE=kvantum`
- Any profile with Steam, Heroic, Lutris, RetroArch, or Bottles: applies `--filesystem=~/Games:create` and `/mnt`, `/media`, `/run/media` permissions
- Allocates a 14 GB Btrfs loop image at `cache/build/flatpak.img`, creates subvolume `flatpak_subvol`
- Copies `/var/lib/flatpak` into the subvolume with `tar -cf - | tar -xf -`
- Streams the read-only subvolume → `cache/output/gnome/<DATE>/flatpakfs.zst`

#### `snap` — Build the Snap seed image (optional)

```bash
./run_in_container.sh build.sh snap -p gnome
```

Skipped automatically by `all` if `image_profiles/gnome/snap-packages.txt` does not exist. When run directly, exits cleanly with a log message if the file is absent.

- Reads `image_profiles/gnome/snap-packages.txt`
- Creates account, account-key, and model assertions in a staging seed directory
- Runs `snap prepare-image --classic` to download snaps and assertions
- Installs the seed into `/var/lib/snapd/seed`
- Allocates a 10 GB Btrfs loop image at `cache/build/snap.img`, creates subvolume `snapd_subvol`
- Copies `/var/lib/snapd` into the subvolume with `tar -cf - | tar -xf -`
- Verifies the model assertion is present inside the image before snapshotting
- Streams the read-only subvolume → `cache/output/gnome/<DATE>/snapfs.zst`

#### `iso` — Build the bootable ISO

```bash
./run_in_container.sh build.sh iso -p gnome
```

- Requires `cache/output/gnome/<DATE>/latest.txt` (written by `image`)
- Copies the `.zst` → `cache/temp/gnome/iso/shanios/x86_64/rootfs.zst`
- Copies `flatpakfs.zst` into the ISO directory if present — skips silently if not
- Copies `snapfs.zst` into the ISO directory if present — skips silently if not
- Runs `mkarchiso -v -w cache/temp/gnome -o cache/output/gnome/<DATE> iso_profiles/gnome`
- Produces `cache/output/gnome/<DATE>/shanios-gnome-<VER>-x86_64.iso`

#### `repack` — Sign the ISO for Secure Boot

```bash
./run_in_container.sh build.sh repack -p gnome
```

See [What `repack-iso.sh` does with the MOK keys](#what-repack-isosh-does-with-the-mok-keys) above.

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
- **Checks that the artifact (`.zst`) and its signature (`.zst.asc`) are reachable on SourceForge** — aborts if either is missing, preventing promotion of an incomplete upload
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
- `*.zst` — base image only (`flatpakfs.zst` and `snapfs.zst` are always excluded)
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

After all uploads complete the R2 cleanup routine deletes old dated folders under the profile prefix, keeping only the 2 most recent dated folders and the folder pinned by `stable.txt` on R2. Central `latest.txt` and `stable.txt` are never deleted.

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
| `flatpak` | `build-flatpak-image.sh` | Build Flatpak image — skipped if `flatpak-packages.txt` absent |
| `snap` | `build-snap-image.sh` | Build Snap seed image — skipped if `snap-packages.txt` absent |
| `iso` | `build-iso.sh` | Assemble bootable ISO; includes flatpakfs/snapfs if present |
| `repack` | `repack-iso.sh` | Sign EFI binaries + rebuild ISO + generate torrent |
| `release` | `release.sh` | Write `latest.txt` or `stable.txt` |
| `upload` | `upload.sh` | Push artifacts to SourceForge and/or R2 (never uploads flatpakfs/snapfs) |
| `promote-stable` | `promote-stable.sh` | Fetch `latest.txt` from SF, verify artifact exists, publish as `stable.txt` |
| `publish` | — | `release` + `upload` |
| `all` | — | Full pipeline: image → flatpak? → snap? → iso → repack → release latest → upload all |

---

## Build Artifacts

All artifacts are written to `cache/output/<profile>/<YYYYMMDD>/`:

| File | Produced by | Uploaded | Description |
|------|------------|---------|-------------|
| `shanios-<DATE>-<profile>.zst` | `image` | ✅ | Compressed Btrfs base image |
| `shanios-<DATE>-<profile>.zst.asc` | `image` | ✅ | GPG detached signature |
| `shanios-<DATE>-<profile>.zst.sha256` | `image` | ✅ | SHA-256 checksum |
| `flatpakfs.zst` | `flatpak` | ❌ ISO only | Compressed Btrfs Flatpak image |
| `snapfs.zst` | `snap` | ❌ ISO only | Compressed Btrfs Snap seed image |
| `latest.txt` | `image` | ✅ | Filename of this build's `.zst` |
| `shanios-<profile>-<VER>-x86_64.iso` | `iso` | ❌ | Unsigned bootable ISO (intermediate) |
| `signed_shanios-<profile>-<VER>-x86_64.iso` | `repack` | ✅ | Secure Boot–signed ISO |
| `signed_*.iso.sha256` | `repack` | ✅ | ISO checksum |
| `signed_*.iso.asc` | `repack` | ✅ | ISO GPG signature |
| `signed_*.iso.torrent` | `repack` | ✅ | Torrent with R2 + SF webseeds |

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

The `workflow_dispatch` trigger accepts three optional inputs:

| Input | Default | Description |
|-------|---------|-------------|
| `profile` | _(empty — builds all)_ | Override to build a single profile, e.g. `gnome` |
| `build_mode` | `image` | `image` = base image only; `all` = full pipeline |
| `promote_stable` | `false` | If `true`, runs `promote-stable` after upload |

In `image` mode (default + scheduled), each matrix run performs: `image` → `release latest` → `upload image` → optionally `promote-stable`.

In `all` mode (manual dispatch), each matrix run calls `build.sh all` which runs the complete pipeline: `image` → `flatpak`? → `snap`? → `iso` → `repack` → `release latest` → `upload all`.

The workflow injects all secrets as environment variables so every `sudo --preserve-env` call inside the container sees them without re-declaration:

```yaml
env:
  SSH_PRIVATE_KEY:      ${{ secrets.SSH_PRIVATE_KEY }}
  GPG_PRIVATE_KEY:      ${{ secrets.GPG_PRIVATE_KEY }}
  GPG_PASSPHRASE:       ${{ secrets.GPG_PASSPHRASE }}
  GPG_KEY_ID:           ${{ secrets.GPG_KEY_ID }}
  R2_ACCESS_KEY_ID:     ${{ secrets.R2_ACCESS_KEY_ID }}
  R2_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
  R2_ACCOUNT_ID:        ${{ secrets.R2_ACCOUNT_ID }}
  R2_BUCKET:            ${{ secrets.R2_BUCKET }}
```

MOK keys are written to `keys/mok/` at build time:

```yaml
- name: Setup MOK keys
  run: |
    mkdir -p shani-install-media/keys/mok
    echo "${{ secrets.MOK_KEY }}"                        > shani-install-media/keys/mok/MOK.key
    echo "${{ secrets.MOK_CRT }}"                        > shani-install-media/keys/mok/MOK.crt
    echo "${{ secrets.MOK_DER_B64 }}" | base64 --decode  > shani-install-media/keys/mok/MOK.der
```

### Required secrets

| Secret | Description |
|--------|-------------|
| `MOK_KEY` | PEM private key — from `keys/create-mok-keys.sh` |
| `MOK_CRT` | PEM certificate — from `keys/create-mok-keys.sh` |
| `MOK_DER_B64` | Base64-encoded DER certificate — from `keys/create-mok-keys.sh` |
| `GPG_PRIVATE_KEY` | Armored GPG private key — from `keys/create-gpg-keys.sh` |
| `GPG_PASSPHRASE` | Passphrase for the GPG key |
| `GPG_KEY_ID` | Full 40-char key fingerprint — from `keys/create-gpg-keys.sh` |
| `SSH_PRIVATE_KEY` | ED25519 private key — from `keys/create-ssh-keys.sh` |
| `R2_ACCESS_KEY_ID` | Cloudflare R2 access key ID (optional) |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 secret access key (optional) |
| `R2_ACCOUNT_ID` | Cloudflare account ID, 32-char hex (optional) |
| `R2_BUCKET` | R2 bucket name (optional) |

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
│   ├── build-snap-image.sh
│   ├── build-iso.sh
│   ├── repack-iso.sh
│   ├── release.sh
│   ├── promote-stable.sh
│   └── upload.sh
├── image_profiles/
│   ├── gnome/
│   │   ├── package-list.txt        # pacstrap package list (required)
│   │   ├── flatpak-packages.txt    # Flathub app IDs (optional)
│   │   ├── snap-packages.txt       # Snap package names (optional)
│   │   ├── pacman.conf
│   │   ├── gnome-customization.sh
│   │   └── overlay -> ../shared/overlay
│   ├── plasma/                     # Same structure
│   ├── cosmic/                     # Same structure
│   └── shared/
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
│       │   ├── etc/
│       │   ├── root/
│       │   │   ├── customize_airootfs.sh
│       │   │   └── watermark.png
│       │   └── usr/share/
│       └── efiboot/loader/         # systemd-boot loader.conf + entries
├── keys/
│   ├── create-gpg-keys.sh
│   ├── create-mok-keys.sh
│   ├── create-ssh-keys.sh
│   ├── gpg/
│   │   ├── gpg-private.asc         # ← never commit
│   │   ├── gpg-public.asc
│   │   └── github-gpg-secrets.env  # Generated — delete after uploading
│   ├── mok/
│   │   ├── MOK.key                 # ← never commit
│   │   ├── MOK.crt
│   │   ├── MOK.der
│   │   └── github-mok-secrets.env  # Generated — delete after uploading
│   └── ssh/
│       ├── ssh-private             # ← never commit
│       ├── ssh-public
│       └── github-ssh-secrets.env  # Generated — delete after uploading
└── cache/                          # Generated at build time — not committed
    ├── build/                      # Btrfs loop image files (base.img, flatpak.img, snap.img)
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
