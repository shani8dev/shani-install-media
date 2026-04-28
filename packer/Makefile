# Makefile — ShaniOS Packer AMI build wrapper
#
# Quick start:
#   cp packer/templates/variables.pkrvars.hcl local.pkrvars.hcl
#   # Edit local.pkrvars.hcl
#   make build PROFILE=gnome
#
# Prerequisites:
#   - packer >= 1.10.0       (https://developer.hashicorp.com/packer/install)
#   - AWS credentials        (env vars or ~/.aws/credentials)
#   - r2_base_url or s3_base_url set in local.pkrvars.hcl

PACKER       := packer
TEMPLATE_DIR := packer/templates
VARS_FILE    := local.pkrvars.hcl
PROFILE      ?= gnome
LOG_LEVEL    ?= info   # debug | info | warn | error

# Derived
PACKER_ARGS  := -var-file=$(VARS_FILE) -var "shanios_profile=$(PROFILE)"

.PHONY: all init validate build build-gnome build-plasma build-cosmic clean help

all: help

## init: Download required Packer plugins (run once)
init:
	$(PACKER) init $(TEMPLATE_DIR)/

## validate: Validate the Packer template and variable files
validate: init
	$(PACKER) validate $(PACKER_ARGS) $(TEMPLATE_DIR)/

## build: Build the AMI for PROFILE (default: gnome). Example: make build PROFILE=plasma
build: validate
	PACKER_LOG=1 PACKER_LOG_PATH=packer-$(PROFILE)-$$(date +%Y%m%d-%H%M%S).log \
	$(PACKER) build \
		-timestamp-ui \
		$(PACKER_ARGS) \
		$(TEMPLATE_DIR)/

## build-gnome: Build the gnome profile AMI
build-gnome:
	$(MAKE) build PROFILE=gnome

## build-plasma: Build the plasma profile AMI
build-plasma:
	$(MAKE) build PROFILE=plasma

## build-cosmic: Build the cosmic profile AMI
build-cosmic:
	$(MAKE) build PROFILE=cosmic

## clean: Remove Packer log files and manifest
clean:
	rm -f packer-*.log packer-manifest.json

## help: Show this help message
help:
	@echo ""
	@echo "ShaniOS AMI Builder"
	@echo "==================="
	@echo ""
	@echo "Setup:"
	@echo "  1. cp packer/templates/variables.pkrvars.hcl local.pkrvars.hcl"
	@echo "  2. Edit local.pkrvars.hcl with your AWS region and CDN URL"
	@echo "  3. make init"
	@echo ""
	@echo "Targets:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'
	@echo ""
	@echo "Variables:"
	@echo "  PROFILE    Image profile to build (default: gnome)"
	@echo "  LOG_LEVEL  Packer log level: debug|info|warn|error (default: info)"
	@echo ""
	@echo "Examples:"
	@echo "  make build"
	@echo "  make build PROFILE=plasma"
	@echo "  make build-cosmic"
	@echo "  make validate PROFILE=gnome"
