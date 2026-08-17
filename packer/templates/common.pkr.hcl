# packer/templates/common.pkr.hcl
# Shared variable declarations and computed locals for all ShaniOS AMI templates.

# ── AWS ──────────────────────────────────────────────────────────────────────
variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region. Choose the same region as your R2/S3 bucket to reduce transfer time."
}

variable "aws_profile" {
  type        = string
  default     = "default"
  description = "AWS CLI named profile. Alternatively set AWS_PROFILE, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY in environment."
}

variable "instance_type" {
  type        = string
  default     = "c6a.xlarge"
  description = <<-DESC
    Builder instance type.
    Minimum: 4 vCPU / 8 GiB RAM (btrfs receive + zstd decompression are CPU-intensive).
    Recommended choices:
      c6a.xlarge  — 4 vCPU / 8 GiB  / ~$0.15/hr  (good default, AMD, fast zstd)
      c6a.2xlarge — 8 vCPU / 16 GiB / ~$0.31/hr  (2× faster for large images)
      t3.xlarge   — 4 vCPU / 16 GiB / ~$0.17/hr  (burstable, fine for occasional builds)
  DESC
}

variable "builder_subnet_id" {
  type        = string
  default     = ""
  description = "Subnet ID for the builder instance. Leave blank to use the default VPC. Set when associate_public_ip = false (private subnet + NAT)."
}

variable "associate_public_ip" {
  type        = bool
  default     = true
  description = "Assign a public IP to the builder. Set false for private VPC with NAT gateway."
}

# ── ShaniOS source artifact ───────────────────────────────────────────────────
variable "r2_base_url" {
  type        = string
  default     = ""
  description = "Cloudflare R2 public base URL, no trailing slash. e.g. https://downloads.shani.dev. Takes precedence over s3_base_url."
}

variable "s3_base_url" {
  type        = string
  default     = ""
  description = "S3 base URL, no trailing slash. e.g. https://my-bucket.s3.us-east-1.amazonaws.com/shanios. Requires IAM S3 read access on the builder."
}

variable "shanios_profile" {
  type        = string
  default     = "server"
  description = "ShaniOS image profile to download and AMI-ify: server | gnome | plasma | cosmic."
  validation {
    condition     = contains(["server", "gnome", "plasma", "cosmic"], var.shanios_profile)
    error_message = "shanios_profile must be one of: server, gnome, plasma, cosmic."
  }
}

variable "gpg_key_id" {
  type        = string
  default     = "7B927BFFD4A9EAAA8B666B77DE217F3DA8014792"
  description = "Fingerprint of the GPG key that signed the base image."
}

variable "gpg_public_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "ASCII-armored GPG public key. Blank = skip GPG verification (not recommended in production). Pass via PKR_VAR_gpg_public_key — never commit to vars files."
}

# ── AMI metadata ─────────────────────────────────────────────────────────────
variable "ami_name_prefix" {
  type        = string
  default     = "shanios"
  description = "Prefix for the AMI name. Full name: <prefix>-<profile>-<timestamp>."
}

variable "ami_description" {
  type        = string
  default     = "ShaniOS – immutable Arch-based OS with blue-green Btrfs deployment"
}

variable "tags" {
  type = map(string)
  default = {
    OS        = "ShaniOS"
    ManagedBy = "Packer"
  }
  description = "Tags applied to the AMI and snapshot. Merged with build-time tags (BuildTimestamp, ShaniProfile)."
}

# ── Disk ──────────────────────────────────────────────────────────────────────
variable "root_volume_size_gb" {
  type        = number
  default     = 20
  description = <<-DESC
    AMI root volume size in GiB.
    server profile:         20 GiB  (OS + containers, no flatpak/snap desktop stack)
    gnome/plasma/cosmic:    40 GiB  (OS + Flatpak apps + snap packages + media)
    Increase if users will run heavy workloads or store data on the root volume.
    (Users should attach separate EBS volumes for /data in production.)
  DESC
}

variable "efi_volume_size_mb" {
  type        = number
  default     = 512
  description = "FAT32 EFI System Partition size in MiB. 512 MiB fits multiple UKIs."
}

# ── SSH ───────────────────────────────────────────────────────────────────────
variable "ssh_username" {
  type        = string
  default     = "ec2-user"
  description = "SSH user Packer connects as on the builder (AL2023 default: ec2-user)."
}

variable "ssh_timeout" {
  type        = string
  default     = "10m"
  description = "How long Packer waits for SSH to become available after the builder starts."
}

# ── Computed locals ───────────────────────────────────────────────────────────
locals {
  timestamp = formatdate("YYYYMMDDHHmmss", timestamp())

  # R2 takes precedence; at least one of r2_base_url / s3_base_url must be set.
  artifact_base = var.r2_base_url != "" ? var.r2_base_url : var.s3_base_url

  common_tags = merge(var.tags, {
    BuildTimestamp = local.timestamp
    ShaniProfile   = var.shanios_profile
  })
}
