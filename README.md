# Shani OS ISO Builder

This repository contains scripts to build a secure, immutable base system ISO with Flatpak support. All steps run inside a Docker container to keep your host clean.

## Features

- Build a base system image using pacstrap/chroot
- Build a Flatpak image from installed packages
- Assemble a bootable ISO (using mkarchiso)
- Repackage/sign the ISO for Secure Boot
- Upload build artifacts (base image and signed ISO) to SourceForge FRS
- Create central release files (latest.txt & stable.txt)

## Usage

Run any command inside the container using the generic wrapper:

```bash
./run_in_container.sh build.sh all -p gnome
