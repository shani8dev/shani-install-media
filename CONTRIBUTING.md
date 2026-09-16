# Contributing to shani-install-media

Thank you for considering contributing to shani-install-media! This document outlines the process for contributing to this repository.

## How to Contribute

1. **Fork the repository** on GitHub.
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/your-username/shani-install-media.git
   ```
3. **Create a branch** for your changes:
   ```bash
   git checkout -b feature-or-fix-name
   ```
4. **Make your changes** in the new branch.
5. **Ensure your changes pass verification** (see below).
6. **Commit your changes** with a clear and descriptive commit message.
7. **Push your branch** to your fork on GitHub.
8. **Open a Pull Request** against the `main` branch of this repository.

## Verification

Before submitting your changes, please run the following verification steps to ensure your changes do not break existing functionality:

### Build/Boot Logic Changes
If your change affects build or boot logic, run:
```bash
./run_in_container.sh build.sh test ca
./run_in_container.sh build.sh test bootstrap -p <profile> -d latest
# ... exercise whatever you changed via `enter`, `upgrade`, `reboot`,
#     `rollback`, `install`, `configure` as applicable — see the command
#     table in test-env/README.md ...
./run_in_container.sh build.sh test clean   # always, when done
```

### pacman.conf/SigLevel Changes
If your change affects a profile's pacman.conf or SigLevel, verify with:
```bash
./run_in_container.sh build.sh test pacstrap -p <profile> [extra-pkg ...]
```

### GUI/Desktop Changes
If your change affects a GUI app or theme, verify with:
- `desktop <blue|green> [--exec="cmd"] [--out=<file.png>]`
- `watch [--port=N]`
- `qemu --vnc[=port]`

### General Changes
For any change, ensure that:
- The build still succeeds
- The resulting images ISOs boot correctly
- No regressions are introduced in existing functionality

## Coding Style

- Follow the existing code style in the repository.
- Shell scripts should use `set -Eeuo pipefail` at the top.
- Ensure proper error handling and logging.
- Keep lines to a reasonable length (typically 80-100 characters).

## Reporting Issues

If you find a bug or have a feature request, please open an issue on the GitHub issue tracker. Include as much detail as possible, including steps to reproduce, expected behavior, and actual behavior.

## License

By contributing to this project, you agree that your contributions will be licensed under the GPLv3 license (see LICENSE file).

Thank you for your contribution!