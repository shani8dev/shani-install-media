# packer/templates/variables.pkrvars.hcl
# Example variable values for ShaniOS AMI builds.
#
# Usage:
#   cp variables.pkrvars.hcl local.pkrvars.hcl
#   # Edit local.pkrvars.hcl — set aws_region and r2_base_url at minimum
#   make build                          # server profile (default)
#   make build PROFILE=gnome            # desktop profile
#
# NEVER commit local.pkrvars.hcl — it is in .gitignore
# Pass gpg_public_key via environment:
#   export PKR_VAR_gpg_public_key="$(gpg --armor --export <fingerprint>)"

# ── AWS ──────────────────────────────────────────────────────────────────────
aws_region          = "us-east-1"
aws_profile         = "default"

# c6a.xlarge: 4 vCPU / 8 GiB / AMD — fast zstd decompress, good value
# Upgrade to c6a.2xlarge for large desktop profile images
instance_type       = "c6a.xlarge"
builder_subnet_id   = ""
associate_public_ip = true

# ── ShaniOS artifact ──────────────────────────────────────────────────────────
r2_base_url     = "https://downloads.shani.dev"
s3_base_url     = ""

# Default: server profile for AMI use.
# Desktop profiles (gnome/plasma/cosmic) are larger and take longer to build.
shanios_profile = "server"

# ── GPG verification ──────────────────────────────────────────────────────────
gpg_key_id     = "7B927BFFD4A9EAAA8B666B77DE217F3DA8014792"
gpg_public_key = ""   # set via PKR_VAR_gpg_public_key in environment

# ── AMI metadata ─────────────────────────────────────────────────────────────
ami_name_prefix = "shanios"
ami_description = "ShaniOS – immutable Arch-based OS with blue-green Btrfs deployment"

tags = {
  OS         = "ShaniOS"
  ManagedBy  = "Packer"
  Repository = "https://github.com/shani8dev/shani-install-media"
}

# ── Disk ──────────────────────────────────────────────────────────────────────
# server: 20 GiB is fine (no Flatpak/Snap desktop stack)
# gnome/plasma/cosmic: use 40 GiB
root_volume_size_gb = 20
efi_volume_size_mb  = 512

# ── SSH ───────────────────────────────────────────────────────────────────────
ssh_username = "ec2-user"
ssh_timeout  = "10m"
