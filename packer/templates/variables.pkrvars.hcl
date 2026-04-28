# variables.pkrvars.hcl – Example variable values for ShaniOS AMI builds.
#
# Usage:
#   cp variables.pkrvars.hcl local.pkrvars.hcl
#   # Edit local.pkrvars.hcl with your values
#   packer build -var-file=local.pkrvars.hcl templates/
#
# IMPORTANT: local.pkrvars.hcl is in .gitignore.
# Never commit secrets (gpg_public_key) to version control.
# Pass gpg_public_key via: PKR_VAR_gpg_public_key="$(cat public.asc)" packer build ...

# ── AWS credentials ───────────────────────────────────────────────────────────
aws_region          = "us-east-1"
aws_profile         = "default"    # or set AWS_PROFILE env var

# ── Builder instance ──────────────────────────────────────────────────────────
# t3.xlarge:   4 vCPU / 16 GiB / ~$0.17/hr  — good default
# c6a.2xlarge: 8 vCPU / 16 GiB / ~$0.31/hr  — ~2× faster for zstd decompress + btrfs receive
# m6i.xlarge:  4 vCPU / 16 GiB / ~$0.19/hr  — balanced alternative
instance_type       = "t3.xlarge"
builder_subnet_id   = ""           # blank = Packer picks from default VPC
associate_public_ip = true         # set false for private VPC + NAT gateway

# ── ShaniOS artifact ──────────────────────────────────────────────────────────
# Exactly one of r2_base_url or s3_base_url must be non-empty.
# r2_base_url takes precedence.
r2_base_url     = "https://downloads.shani.dev"
s3_base_url     = ""     # e.g. "https://my-bucket.s3.us-east-1.amazonaws.com/shanios"

shanios_profile = "gnome"   # gnome | plasma | cosmic

# ── GPG verification ──────────────────────────────────────────────────────────
# gpg_key_id is the fingerprint used for trust assignment.
# gpg_public_key should be passed as an environment variable, not stored here:
#   export PKR_VAR_gpg_public_key="$(gpg --armor --export 7B927BFFD4A9EAAA8B666B77DE217F3DA8014792)"
gpg_key_id     = "7B927BFFD4A9EAAA8B666B77DE217F3DA8014792"
gpg_public_key = ""   # intentionally blank — pass via PKR_VAR_gpg_public_key

# ── AMI metadata ─────────────────────────────────────────────────────────────
ami_name_prefix = "shanios"
ami_description = "ShaniOS – immutable Arch-based OS with blue-green Btrfs deployment"

tags = {
  OS         = "ShaniOS"
  ManagedBy  = "Packer"
  Repository = "https://github.com/your-org/shanios"
}

# ── Disk layout ───────────────────────────────────────────────────────────────
# 30 GiB for server/minimal; 50 GiB for gnome/plasma with flatpaks + snaps.
root_volume_size_gb = 30
efi_volume_size_mb  = 512

# ── SSH ───────────────────────────────────────────────────────────────────────
ssh_username = "ec2-user"   # AL2023 default user
ssh_timeout  = "10m"
