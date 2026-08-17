# ShaniOS Packer AMI Builder

Builds an AWS AMI from a pre-built ShaniOS base image (`.zst` Btrfs send-stream)
hosted on Cloudflare R2 or S3. The AMI uses the same blue-green Btrfs layout as
the physical/ISO installer — `@blue` and `@green` subvolumes, systemd-boot,
cloud-init, and a swapfile.

---

## Prerequisites

| Tool | Minimum version | Install |
|------|-----------------|---------|
| [Packer](https://developer.hashicorp.com/packer/install) | 1.10.0 | `brew install packer` or package manager |
| AWS CLI | any | configured with credentials or OIDC role |
| GNU Make | any | standard on Linux/macOS |

AWS credentials must have the permissions in [`iam-policy.json`](iam-policy.json).

---

## Quick Start

```bash
# 1. Copy the example vars file and fill in your values
cp packer/templates/variables.pkrvars.hcl local.pkrvars.hcl
$EDITOR local.pkrvars.hcl   # set r2_base_url and aws_region at minimum

# 2. Download Packer plugins (once per machine)
make init

# 3. Validate the template
make validate

# 4. Build (default profile: gnome)
make build

# Build a different profile
make build PROFILE=plasma
make build PROFILE=cosmic
```

The build takes approximately **15–25 minutes** depending on instance type and
CDN download speed. The resulting AMI ID is written to `packer-manifest.json`.

---

## Repository Layout

```
packer/
├── Makefile                          # build targets (make help)
├── iam-policy.json                   # minimum IAM permissions for Packer
├── packer-manifest.json              # generated after a successful build
├── templates/
│   ├── shanios-ami.pkr.hcl           # main Packer template (amazon-ebssurrogate)
│   ├── common.pkr.hcl                # variable declarations + locals
│   └── variables.pkrvars.hcl         # example var values (copy → local.pkrvars.hcl)
└── scripts/
    ├── 00-bootstrap-shanios.sh       # Stage 1: partition disk, receive btrfs image
    ├── 01-configure-aws.sh           # Stage 2: fstab, cloud-init, bootloader, swap
    └── 02-verify.sh                  # Stage 3: sanity checks before AMI snapshot
```

---

## How It Works

### Volume strategy — `amazon-ebssurrogate`

Standard `amazon-ebs` can only snapshot the instance's root device, which is
already formatted as ext4 with Amazon Linux 2023. ShaniOS requires a from-scratch
GPT layout (FAT32 EFI + Btrfs root).

`amazon-ebssurrogate` is the correct Packer source for this use case:

```
Builder instance (AL2023)          Target volume /dev/xvdf
        ┌──────────────┐                 ┌──────────────────────────────┐
        │  AL2023 root │                 │ p1: FAT32 EFI  (shani_boot)  │
        │  /dev/xvda   │                 │ p2: Btrfs root (shani_root)  │
        │  (builder OS)│                 │   @blue  @green  @home ...   │
        └──────────────┘                 └──────────────────────────────┘
                                                      │
                             Packer stops instance, snapshots /dev/xvdf,
                             registers snapshot as AMI root (/dev/xvda)
                                                      │
                                               ┌──────▼──────┐
                                               │  ShaniOS AMI │
                                               └─────────────┘
```

### Three-stage provisioner pipeline

| Stage | Script | What it does |
|-------|--------|--------------|
| 1 | `00-bootstrap-shanios.sh` | Installs tools, downloads + verifies the `.zst` image, partitions `/dev/xvdf`, creates all Btrfs subvolumes, receives the send-stream, snapshots `@blue`/`@green` |
| 2 | `01-configure-aws.sh` | Writes `/etc/fstab` (by UUID), configures cloud-init, SSH, systemd-boot, generates initrd via dracut, creates swapfile |
| 3 | `02-verify.sh` | Checks subvolumes, slot markers, fstab, kernel, loader entries — fails the build if anything critical is missing |

Stages share context via `/tmp/shanios-env.sh` written at the end of Stage 1.

---

## Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-east-1` | Build region |
| `instance_type` | `t3.xlarge` | Builder instance (≥4 vCPU / 8 GiB recommended) |
| `r2_base_url` | — | CDN base URL for the base image (e.g. `https://downloads.shani.dev`) |
| `s3_base_url` | — | S3 base URL (fallback if r2 not set) |
| `shanios_profile` | `gnome` | Profile: `gnome` \| `plasma` \| `cosmic` |
| `gpg_public_key` | — | ASCII-armored signing key (pass via `PKR_VAR_gpg_public_key`) |
| `root_volume_size_gb` | `30` | AMI root volume size in GiB |
| `efi_volume_size_mb` | `512` | EFI partition size in MiB |

See [`common.pkr.hcl`](templates/common.pkr.hcl) for the full list with descriptions.

---

## Passing the GPG Key Securely

The GPG key should **never** be stored in the vars file. Pass it at build time:

```bash
# From your local keyring
export PKR_VAR_gpg_public_key="$(gpg --armor --export 7B927BFFD4A9EAAA8B666B77DE217F3DA8014792)"
make build

# Or from a file
export PKR_VAR_gpg_public_key="$(cat path/to/signing-key.asc)"
make build
```

In GitHub Actions, store the key as a repository secret (`GPG_PUBLIC_KEY`) — the
workflow reads it automatically.

---

## CI / GitHub Actions

The workflow in [`.github/workflows/build-ami.yml`](.github/workflows/build-ami.yml)
builds an AMI on every push to `main` that touches Packer files. It uses OIDC
(no long-lived AWS keys) — configure these repository secrets:

| Secret | Description |
|--------|-------------|
| `AWS_PACKER_ROLE_ARN` | IAM role ARN for OIDC assumption |
| `AWS_REGION` | Target region |
| `R2_BASE_URL` | CDN base URL |
| `GPG_KEY_ID` | Key fingerprint |
| `GPG_PUBLIC_KEY` | ASCII-armored public key |

---

## Requirements for the Base Image

For a fully functional AMI, the base image profile must include:

| Package | Purpose |
|---------|---------|
| `dracut` | initrd generation inside the chroot |
| `cloud-init` | EC2 user data, SSH key injection, hostname |
| `openssh` | Remote access |
| `systemd-boot` (via `systemd`) | Bootloader (`bootctl`) |

Server/headless profiles that omit the desktop stack can safely also omit
`flatpak`, `snapd`, and related packages to produce a leaner AMI.
