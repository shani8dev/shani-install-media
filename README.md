# Shani OS ISO Build and Configuration

Welcome to the Shani OS project! This repository contains scripts and configurations for building and customizing an Arch Linux ISO tailored to your needs. Below you will find detailed instructions on how to use the provided scripts.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Directory Structure](#directory-structure)
- [Scripts Overview](#scripts-overview)
  - [1. `build-iso.sh`](#1-build-iso.sh)
  - [2. `build-iso-docker.sh`](#2-build-iso-docker.sh)
  - [3. `create-keys.sh`](#3-create-keys.sh)
  - [4. `profiledef.sh`](#4-profiledef.sh)
- [How to Use the Scripts](#how-to-use-the-scripts)
- [Contributing](#contributing)
- [License](#license)

## Prerequisites

Before running the scripts, ensure you have the following installed:

- **Arch Linux** or an Arch-based distribution.
- **Required Packages**: Make sure you have `mkarchiso`, `flatpak`, `sbsigntools`, `mtools`, `xorriso`, and `mokutil` installed.

To install the required packages, you can run:

```bash
sudo pacman -S mkarchiso flatpak sbsigntools mtools xorriso mokutil
```

## Directory Structure

Here's a brief overview of the important directories in this project:

```
.
├── build-iso-docker.sh          # Script to build ISO using Docker
├── build-iso.sh                 # Main script for building the ISO
├── LICENSE                       # Project license
├── mok                           # Directory containing MOK keys
│   ├── create-keys.sh           # Script to create MOK keys
│   ├── MOK.cer                   # MOK certificate
│   ├── MOK.crt                   # MOK certificate file
│   └── MOK.key                   # MOK private key
├── README.md                     # Project documentation
└── shanios                       # Directory containing the ISO build configurations
    ├── airootfs                 # Root filesystem for the live ISO
    ├── efiboot                  # EFI boot configurations
    ├── LICENSE                   # License for the shanios directory
    ├── packages.x86_64          # List of packages to install in the ISO
    ├── pacman.conf              # Pacman configuration file
    └── profiledef.sh            # Profile definition file for mkarchiso
```

## Scripts Overview

### 1. `build-iso.sh`

This script is the main entry point for building the Arch Linux ISO. It handles the creation of the ISO, installs required packages, signs the boot files, and repacks the ISO.

**Usage:**
```bash
sudo ./build-iso.sh
```

### 2. `build-iso-docker.sh`

This script allows you to build the ISO within a Docker container, ensuring a clean and isolated environment.

**Usage:**
```bash
./build-iso-docker.sh
```

### 3. `create-keys.sh`

This script generates the Machine Owner Key (MOK) files used for signing the bootloader binaries.

**Usage:**
```bash
cd mok
./create-keys.sh
```

### 4. `profiledef.sh`

This file defines the profile for mkarchiso, specifying the configuration for the ISO build process.

**Usage:**
- This script is automatically used by `build-iso.sh` and does not require direct execution.

## How to Use the Scripts

1. **Set Up MOK Keys:**
   Before building the ISO, create the MOK keys using the `create-keys.sh` script.

   ```bash
   cd mok
   ./create-keys.sh
   ```

2. **Build the ISO:**
   Run the main build script to create your custom Arch Linux ISO.

   ```bash
   cd ..
   sudo ./build-iso.sh
   ```

3. **Run the Docker Build (Optional):**
   If you prefer building in a Docker container, use the following command:

   ```bash
   ./build-iso-docker.sh
   ```

4. **Customize Your Build:**
   Edit the `packages.x86_64` file in the `shanios` directory to add or remove packages that you want to include in the ISO.

5. **Profile Configuration:**
   Modify `profiledef.sh` in the `shanios` directory to customize the build process as needed.

## Contributing

Contributions are welcome! Please fork the repository and submit a pull request with your changes.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

