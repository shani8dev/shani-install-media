packer {
  required_version = ">= 1.10.0"
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Why amazon-ebssurrogate (not amazon-ebs)?
#
# amazon-ebs can ONLY snapshot and register the instance's root EBS device as
# the AMI root. ShaniOS requires a from-scratch GPT partition table with a
# FAT32 EFI partition + Btrfs root — we cannot write that layout on top of the
# running AL2023 root device that Packer is SSH'd into.
#
# amazon-ebssurrogate solves this:
#   1. Launches a builder instance (AL2023) with a secondary EBS volume (/dev/xvdf)
#   2. Provisioners write ShaniOS onto /dev/xvdf (partitioning, Btrfs, blue/green)
#   3. On build completion, Packer stops the instance, snapshots /dev/xvdf,
#      and registers that snapshot as the AMI root device (/dev/xvda)
#
# The builder's own root volume (AL2023) is destroyed; /dev/xvdf becomes the AMI.
# ─────────────────────────────────────────────────────────────────────────────

source "amazon-ebssurrogate" "shanios" {

  # ── AWS placement ──────────────────────────────────────────────────────────
  region        = var.aws_region
  profile       = var.aws_profile
  instance_type = var.instance_type
  subnet_id     = var.builder_subnet_id != "" ? var.builder_subnet_id : null
  associate_public_ip_address = var.associate_public_ip

  # ── Builder host AMI: latest Amazon Linux 2023 x86_64 ────────────────────
  # AL2023 ships with a kernel that has Btrfs support, plus dnf and partprobe.
  source_ami_filter {
    filters = {
      name                = "al2023-ami-*-x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  ssh_username = var.ssh_username
  ssh_timeout  = var.ssh_timeout

  # ── Builder root volume ───────────────────────────────────────────────────
  # Needs to hold: AL2023 OS (~3 GiB) + the downloaded ShaniOS .zst (~4 GiB)
  # + build tools. 20 GiB is ample. This volume is DELETED after the build.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
    encrypted             = false
  }

  # ── ShaniOS target volume ─────────────────────────────────────────────────
  # Attached as /dev/xvdf. The bootstrap script partitions this disk, writes
  # Btrfs subvolumes, and receives the ShaniOS base image into it.
  # ebssurrogate snapshots this volume and registers it as the AMI root.
  launch_block_device_mappings {
    device_name           = "/dev/xvdf"
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    iops                  = 3000
    throughput            = 500   # fast I/O for the large btrfs receive
    delete_on_termination = true  # ebssurrogate snapshots before termination
    encrypted             = false
    no_device             = false
  }

  # ── AMI root device registration ──────────────────────────────────────────
  # ebssurrogate reads this block to know which secondary volume to snapshot
  # and what device name to give it in the finished AMI.
  ami_root_device {
    source_device_name    = "/dev/xvdf"  # the volume we wrote ShaniOS onto
    device_name           = "/dev/xvda"  # device name in the registered AMI
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    iops                  = 3000
    throughput            = 500
    delete_on_termination = true
  }

  # ── AMI metadata ──────────────────────────────────────────────────────────
  ami_name        = "${var.ami_name_prefix}-${var.shanios_profile}-${local.timestamp}"
  ami_description = "${var.ami_description} (profile: ${var.shanios_profile})"

  ami_architecture        = "x86_64"
  ami_virtualization_type = "hvm"
  ami_ena_support         = true
  ami_sriov_net_support   = true

  # ShaniOS uses systemd-boot with a UEFI EFI System Partition.
  # "uefi-preferred" allows instances without UEFI support to fall back to BIOS
  # (systemd-boot won't work there, but the instance will at least start).
  # Use "uefi" if you only target Nitro-based instance types.
  boot_mode = "uefi-preferred"

  # GPT is required for the EFI System Partition. Inform the ebssurrogate
  # source so it registers the AMI with the correct partition table type.
  ami_gpt_root_device_start_offset = 2048

  tags          = local.common_tags
  snapshot_tags = local.common_tags

  # ── IAM (optional) ────────────────────────────────────────────────────────
  # Uncomment if the builder instance needs to pull the image from a private S3
  # bucket or write build artifacts to S3.
  # iam_instance_profile = "packer-shanios-builder"
}

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────
build {
  name    = "shanios-ami"
  sources = ["source.amazon-ebssurrogate.shanios"]

  # ── Stage 1: Bootstrap ────────────────────────────────────────────────────
  # Downloads the base image, partitions /dev/xvdf (EFI + Btrfs),
  # creates all subvolumes, receives the btrfs send-stream, creates @blue/@green,
  # and writes /tmp/shanios-env.sh for subsequent stages.
  provisioner "shell" {
    script = "${path.root}/../scripts/00-bootstrap-shanios.sh"

    environment_vars = [
      "ARTIFACT_BASE=${local.artifact_base}",
      "SHANIOS_PROFILE=${var.shanios_profile}",
      "GPG_KEY_ID=${var.gpg_key_id}",
      "GPG_PUBLIC_KEY=${var.gpg_public_key}",
      "ROOT_VOLUME_DEV=/dev/xvdf",
      "EFI_SIZE_MB=${var.efi_volume_size_mb}",
    ]

    timeout     = "45m"
    max_retries = 2
  }

  # ── Stage 2: AWS configuration ────────────────────────────────────────────
  # Sources /tmp/shanios-env.sh; writes fstab (by UUID), configures cloud-init,
  # SSH hardening, systemd-boot entries for @blue and @green, and swapfile.
  provisioner "shell" {
    script  = "${path.root}/../scripts/01-configure-aws.sh"
    timeout = "20m"
  }

  # ── Stage 3: Verify ───────────────────────────────────────────────────────
  # Runs as a separate script so it can source /tmp/shanios-env.sh at runtime.
  # (Inline provisioners are interpolated by HCL at parse time, so
  #  ${SHANIOS_BTRFS_MOUNT} would be treated as a Packer variable, not a
  #  shell variable — a subtle but hard-to-debug failure mode.)
  provisioner "shell" {
    script  = "${path.root}/../scripts/02-verify.sh"
    timeout = "5m"
  }

  # ── Post-processor: build manifest ────────────────────────────────────────
  post-processor "manifest" {
    output     = "${path.root}/../packer-manifest.json"
    strip_path = true
  }
}
