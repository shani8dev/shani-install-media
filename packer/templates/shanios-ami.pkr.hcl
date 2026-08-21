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
# Why amazon-ebssurrogate?
#
# amazon-ebs can only snapshot the builder instance's root device.
# That root device is already running Amazon Linux 2023 (ext4).
# ShaniOS requires a from-scratch GPT layout: FAT32 EFI + Btrfs root.
#
# amazon-ebssurrogate solves this:
#   1. Launches a builder (AL2023) with a secondary EBS volume (/dev/xvdf)
#   2. Provisioners write ShaniOS onto /dev/xvdf
#   3. Packer stops the instance, snapshots /dev/xvdf, registers it as AMI root
#
# The builder's AL2023 root is discarded. /dev/xvdf becomes the AMI.
# ─────────────────────────────────────────────────────────────────────────────

source "amazon-ebssurrogate" "shanios" {

  # ── AWS placement ──────────────────────────────────────────────────────────
  region        = var.aws_region
  profile       = var.aws_profile != "" ? var.aws_profile : null
  instance_type = var.instance_type
  subnet_id     = var.builder_subnet_id != "" ? var.builder_subnet_id : null
  associate_public_ip_address = var.associate_public_ip

  # ── Builder host AMI: latest Amazon Linux 2023 x86_64 ────────────────────
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
  # amazon-ebssurrogate has no `root_block_device` block (confirmed via
  # `packer validate`: "Blocks of type root_block_device are not expected
  # here" — an earlier version of this template had one and it silently
  # never validated). The builder host's own AL2023 boot volume size is
  # inherited entirely from the source_ami_filter AMI's own root mapping
  # and cannot be resized here; only the surrogate volume below (which
  # becomes the final AMI root) is configurable.

  # ── ShaniOS target volume ─────────────────────────────────────────────────
  # Attached as /dev/xvdf. Bootstrap writes ShaniOS here.
  # ebssurrogate snapshots this and registers it as the AMI root.
  launch_block_device_mappings {
    device_name           = "/dev/xvdf"
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    iops                  = 3000
    throughput            = 500
    delete_on_termination = true
    encrypted             = false
    no_device             = false
  }

  # ── AMI root device registration ──────────────────────────────────────────
  # `ami_root_device` (RootBlockDevice) doesn't support `throughput` — only
  # launch_block_device_mappings' (BlockDevice) does; confirmed via
  # `packer validate`: "An argument named throughput is not expected here."
  ami_root_device {
    source_device_name    = "/dev/xvdf"
    device_name           = "/dev/xvda"
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    iops                  = 3000
    delete_on_termination = true
  }

  # ── AMI metadata ──────────────────────────────────────────────────────────
  ami_name        = "${var.ami_name_prefix}-${var.shanios_profile}-${local.timestamp}"
  ami_description = "${var.ami_description} (profile: ${var.shanios_profile})"

  ami_architecture        = "x86_64"
  ami_virtualization_type = "hvm"

  # Enhanced networking: the correct packer-plugin-amazon field names are
  # `ena_support`/`sriov_support`, NOT `ami_ena_support`/`ami_sriov_net_support`
  # (those don't exist and fail `packer validate` with "An argument named ...
  # is not expected here" — the same failure mode noted below for the GPT
  # offset field). SR-IOV net support is the pre-Nitro enhanced-networking
  # mechanism; every instance type this template targets (c6a, t3, m5, c5, r5)
  # is Nitro-based and uses ENA exclusively, so sriov_support is omitted
  # rather than set to a no-op false. Enabling ena_support requires
  # ec2:ModifyInstanceAttribute in the builder's IAM policy (see iam-policy.json).
  ena_support = true

  # uefi-preferred: works on Nitro (UEFI) and legacy instances (BIOS fallback)
  # Use "uefi" if you target only Nitro (t3, m5, c5, r5 and newer)
  boot_mode = "uefi-preferred"

  # GPT partition alignment (1MiB start offset) is handled by `parted` in
  # 00-bootstrap-shanios.sh's mkpart calls — amazon-ebssurrogate has no
  # config field for this (there is no ami_gpt_root_device_start_offset;
  # an earlier version of this template had one and it would fail
  # `packer validate` with "An argument named ... is not expected here").

  tags          = local.common_tags
  snapshot_tags = local.common_tags

  # Uncomment to grant the builder S3 access for private artifact buckets:
  # iam_instance_profile = "packer-shanios-builder"
}

# ─────────────────────────────────────────────────────────────────────────────
build {
  name    = "shanios-ami"
  sources = ["source.amazon-ebssurrogate.shanios"]

  # All three stages partition disks, run mkfs/mount/chroot, or read a
  # root-owned mount — none of that works as the default `ec2-user` login,
  # and none of the scripts self-elevate with sudo. AL2023's ec2-user has
  # passwordless sudo by default, so root it via execute_command instead of
  # peppering every command in every script with `sudo`.
  # ── Stage 1: Partition /dev/xvdf, receive ShaniOS, create @blue/@green ────
  provisioner "shell" {
    script          = "${path.root}/../scripts/00-bootstrap-shanios.sh"
    execute_command = "sudo -E -S sh -c '{{ .Vars }} {{ .Path }}'"

    environment_vars = [
      "ARTIFACT_BASE=${local.artifact_base}",
      "SHANIOS_PROFILE=${var.shanios_profile}",
      "GPG_KEY_ID=${var.gpg_key_id}",
      "GPG_PUBLIC_KEY=${var.gpg_public_key}",
      "ROOT_VOLUME_DEV=/dev/xvdf",
      "EFI_SIZE_MB=${var.efi_volume_size_mb}",
    ]

    # Large image download + btrfs receive; allow generous time.
    timeout     = "45m"
    max_retries = 2
  }

  # ── Stage 2: AWS-specific system configuration ────────────────────────────
  provisioner "shell" {
    script          = "${path.root}/../scripts/01-configure-aws.sh"
    execute_command = "sudo -E -S sh -c '{{ .Vars }} {{ .Path }}'"
    timeout         = "20m"
  }

  # ── Stage 3: Verify ───────────────────────────────────────────────────────
  # Separate script so runtime shell vars (sourced from /tmp/shanios-env.sh)
  # are expanded by bash at execution time, not by HCL at parse time.
  provisioner "shell" {
    script          = "${path.root}/../scripts/02-verify.sh"
    execute_command = "sudo -E -S sh -c '{{ .Vars }} {{ .Path }}'"
    timeout         = "5m"
  }

  # ── Manifest ──────────────────────────────────────────────────────────────
  post-processor "manifest" {
    output     = "${path.root}/../packer-manifest.json"
    strip_path = true
  }
}
