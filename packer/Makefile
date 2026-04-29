# packer/Makefile — ShaniOS AMI build wrapper
#
# Quick start:
#   cp packer/templates/variables.pkrvars.hcl local.pkrvars.hcl
#   # Edit local.pkrvars.hcl: set aws_region, r2_base_url
#   make init
#   make build               # server profile, 20 GiB
#   make build-gnome         # gnome profile,  40 GiB
#
# Prerequisites:
#   packer >= 1.10.0   https://developer.hashicorp.com/packer/install
#   AWS credentials    env vars or ~/.aws/credentials or IAM instance role

PACKER       := packer
TEMPLATE_DIR := packer/templates
VARS_FILE    := local.pkrvars.hcl
PROFILE      ?= server
LOG_LEVEL    ?= info

PACKER_ARGS  := -var-file=$(VARS_FILE) -var "shanios_profile=$(PROFILE)"

.PHONY: all init validate build \
        build-server build-gnome build-plasma build-cosmic \
        clean help

all: help

## init: Download required Packer plugins (run once per machine)
init:
	$(PACKER) init $(TEMPLATE_DIR)/

## validate: Validate template and var files without building
validate: init
	$(PACKER) validate $(PACKER_ARGS) $(TEMPLATE_DIR)/

## build: Build the AMI for PROFILE (default: server). Example: make build PROFILE=gnome
build: validate
	@echo "Building ShaniOS AMI: profile=$(PROFILE)"
	@if [ "$(PROFILE)" != "server" ] && grep -q "root_volume_size_gb = 20" $(VARS_FILE) 2>/dev/null; then \
	    echo "WARNING: root_volume_size_gb=20 may be too small for desktop profile '$(PROFILE)'."; \
	    echo "         Set root_volume_size_gb=40 in $(VARS_FILE) for desktop profiles."; \
	fi
	PACKER_LOG=1 \
	PACKER_LOG_PATH=packer-$(PROFILE)-$$(date +%Y%m%d-%H%M%S).log \
	$(PACKER) build \
		-timestamp-ui \
		$(PACKER_ARGS) \
		$(TEMPLATE_DIR)/

## build-server: Build the headless server / AMI profile (20 GiB, cloud-init, SSM)
build-server:
	$(MAKE) build PROFILE=server

## build-gnome: Build the GNOME desktop profile (40+ GiB recommended)
build-gnome:
	$(MAKE) build PROFILE=gnome

## build-plasma: Build the KDE Plasma desktop profile (40+ GiB recommended)
build-plasma:
	$(MAKE) build PROFILE=plasma

## build-cosmic: Build the COSMIC desktop profile (40+ GiB recommended)
build-cosmic:
	$(MAKE) build PROFILE=cosmic

## clean: Remove build logs and manifest
clean:
	rm -f packer-*.log packer-manifest.json

## help: Show this help
help:
	@echo ""
	@echo "ShaniOS AMI Builder"
	@echo "==================="
	@echo ""
	@echo "Setup (one time):"
	@echo "  1. cp packer/templates/variables.pkrvars.hcl local.pkrvars.hcl"
	@echo "  2. Edit local.pkrvars.hcl — set aws_region + r2_base_url at minimum"
	@echo "  3. make init"
	@echo ""
	@echo "Build targets:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'
	@echo ""
	@echo "Variables:"
	@echo "  PROFILE    Profile to build: server (default) | gnome | plasma | cosmic"
	@echo "  LOG_LEVEL  Packer log level: debug | info | warn | error  (default: info)"
	@echo ""
	@echo "Volume sizing guidance:"
	@echo "  server profile  → root_volume_size_gb = 20"
	@echo "  desktop profiles→ root_volume_size_gb = 40"
	@echo ""
	@echo "Pass GPG key (recommended for production):"
	@echo "  export PKR_VAR_gpg_public_key=\"\$$(gpg --armor --export <fingerprint>)\""
