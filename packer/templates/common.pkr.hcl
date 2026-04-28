# common.pkr.hcl – Variable declarations and computed locals shared across all
# ShaniOS Packer templates. Keep this file alongside shanios-ami.pkr.hcl.

# ── AWS ──────────────────────────────────────────────────────────────────────
variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region to build in. Choose the same region as your R2/S3 artifact bucket to reduce transfer time."
}

variable "aws_profile" {
  type        = string
  default     = "default"
  description = "AWS CLI named profile. Alternatively export AWS_PROFILE, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY."
}

variable "instance_type" {
  type        = string
  default     = "t3.xlarge"
  description = "Builder instance type. Minimum 4 vCPU / 8 GiB RAM — btrfs receive and zstd decompression are CPU-intensive. c6a.2xlarge gives ~2× faster builds."
}

variable "builder_subnet_id" {
  type        = string
  default     = ""
  description = "Subnet ID for the builder instance. Leave blank to let Packer use the default VPC. Set to a private subnet ID when associate_public_ip = false."
}

variable "associate_public_ip" {
  type        = bool
  default     = true
  description = "Assign a public IP to the builder. Set false when running in a private VPC with a NAT gateway and a Packer bastion or SSM tunnel."
}

# ── ShaniOS source artifact ───────────────────────────────────────────────────
variable "r2_base_url" {
  type        = string
  default     = ""
  description = "Public Cloudflare R2 base URL with no trailing slash. e.g. https://downloads.shani.dev. Takes precedence over s3_base_url."
}

variable "s3_base_url" {
  type        = string
  default     = ""
  description = "S3 base URL with no trailing slash. e.g. https://my-bucket.s3.us-east-1.amazonaws.com/shanios. Requires the builder instance to have S3 read access (IAM role or creds)."
}

variable "shanios_profile" {
  type        = string
  default     = "gnome"
  description = "ShaniOS image profile to download: gnome | plasma | cosmic. Must match a profile that has been uploaded to the CDN."
}

variable "gpg_key_id" {
  type        = string
  default     = "7B927BFFD4A9EAAA8B666B77DE217F3DA8014792"
  description = "Fingerprint of the GPG key that signed the base image. Used only when gpg_public_key is also set."
}

variable "gpg_public_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "ASCII-armored GPG public key block for verifying the downloaded image. Leave blank to skip GPG verification (not recommended in production). Pass via PKR_VAR_gpg_public_key env variable or a secrets manager — never commit the key to the vars file."
}

# ── AMI metadata ─────────────────────────────────────────────────────────────
variable "ami_name_prefix" {
  type        = string
  default     = "shanios"
  description = "Prefix for the AMI name. The full name is: <prefix>-<profile>-<timestamp>."
}

variable "ami_description" {
  type        = string
  default     = "ShaniOS – immutable Arch-based OS with blue-green Btrfs deployment"
  description = "Human-readable AMI description shown in the AWS console."
}

variable "tags" {
  type = map(string)
  default = {
    OS        = "ShaniOS"
    ManagedBy = "Packer"
  }
  description = "Tags applied to the AMI and its snapshot. Merged with build-time tags (BuildTimestamp, ShaniProfile)."
}

# ── Disk ──────────────────────────────────────────────────────────────────────
variable "root_volume_size_gb" {
  type        = number
  default     = 30
  description = "Size in GiB of the ShaniOS EBS volume (becomes AMI root). Must hold: rootfs (~4 GiB) + flatpakfs (~3 GiB) + snapfs (~2 GiB) + @data + @swap (RAM-capped at 4 GiB) + headroom. 30 GiB is sufficient for server profiles; use 50+ for desktop profiles with many Flatpaks."
}

variable "efi_volume_size_mb" {
  type        = number
  default     = 512
  description = "Size in MiB of the FAT32 EFI System Partition inside the ShaniOS volume. 512 MiB accommodates multiple UKIs. Increase to 1024 if you generate signed UKIs for many kernels."
}

# ── SSH ───────────────────────────────────────────────────────────────────────
variable "ssh_username" {
  type        = string
  default     = "ec2-user"
  description = "SSH user Packer connects as on the builder instance. AL2023 default is ec2-user; use root only if the AMI grants root SSH."
}

variable "ssh_timeout" {
  type        = string
  default     = "10m"
  description = "How long Packer waits for the SSH connection to become available after the builder instance starts."
}

# ── Computed locals ───────────────────────────────────────────────────────────
locals {
  # Timestamp embedded in the AMI name to guarantee uniqueness across builds.
  timestamp = formatdate("YYYYMMDDHHmmss", timestamp())

  # Artifact base URL — R2 takes precedence; at least one must be set.
  artifact_base = var.r2_base_url != "" ? var.r2_base_url : var.s3_base_url

  # Build-time tags merged with the user-supplied tag map.
  common_tags = merge(var.tags, {
    BuildTimestamp = local.timestamp
    ShaniProfile   = var.shanios_profile
  })
}
