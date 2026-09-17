# Security Policy

## Trust Model

`shani-install-media` builds and boot-tests Shanios OS images. The trust chain
is:

1. **Builder image** pulled and verified (checksum + signature where configured).
2. **Packages** installed inside the container from the signed `[shani]` repo.
3. **Base image** `.zst` stream verified SHA256 + GPG before `btrfs receive`.
4. **ISO** signed and the signature verified before publication.
5. **Deployed system** verifies the ISO's GPG signature before applying updates
   (`shani-deploy`).

Secure Boot is enabled via MOK-signed UKIs. The MOK signing key is generated
per-build and **shipped inside the base image** (`scripts/build-base-image.sh:165-167`)
— a deliberate trade-off for convenience; see Known Limitations.

## Key Security Mechanisms

| Mechanism | Implementation |
|-----------|----------------|
| Image verification | SHA256 + GPG on `.zst` base images and ISOs (`scripts/build-iso.sh`) |
| Atomic boot entries | `shani-deploy` writes temp-file-then-atomic-`mv` to prevent zero-entry boot failures |
| Secure Boot | MOK-signed UKIs; shim + systemd-boot |
| Test harness | Real Btrfs slots, loop-backed disks, OVMF UEFI boot (`test-env/`) |

## Known Limitations

- **MOK private key in base image.** `scripts/build-base-image.sh:165-167` installs
  `MOK.key` into `/etc/secureboot/keys/MOK.key` inside the image. A copied ISO
  or any root on a deployed system can read it and forge trusted bootloaders.
  This is a **deliberate architecture decision** — move on-device re-signing to
  a per-machine key or signing service to close.
- **Podman path disables signature verification.** `run_in_container.sh:93` sets
  `SigLevel = Never` in the container's `pacman.conf`, disabling package
  signature verification for builds using Podman. The Docker path is unaffected.
- **GPG signing-key passphrase is operator-supplied.** `keys/create-gpg-keys.sh:66-67`
  prompts interactively; `Passphrase:` is written to the batch file at `:87` and
  applied via `--passphrase` at `:104`/`:130`. No `%no-protection` directive is
  used. Residual risk: an empty passphrase entered at the prompt still yields an
  unencrypted key.
- **SSH deploy-key passphrase is operator-supplied.** `keys/create-ssh-keys.sh:135-137`
  prompts "leave empty for no passphrase"; `SSH_PASSPHRASE=""` at `:127` is only
  the default reset before the prompt, applied via `-N` at `:146`. Residual risk:
  an operator can still choose an empty passphrase (passphrase-less deploy key).
- **Soft-fail verification.** `packer/scripts/00-bootstrap-shanios.sh:125-158`
  warns and continues on SHA256/GPG mismatch; GPG is skipped if
  `GPG_PUBLIC_KEY` is unset. Make both mandatory for production builds.

## Reporting a Vulnerability

If you discover a security vulnerability in any Shanios project, please report it
responsibly by opening a private security advisory on GitHub.

Please include:
- A description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

We will acknowledge receipt within 72 hours and provide a detailed response
within 7 days. Thank you for helping keep Shanios secure.
