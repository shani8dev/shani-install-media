# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- LICENSE file (GPLv3)
- CHANGELOG.md
- CONTRIBUTING.md
- Discord build/promotion notifications (build-ami.yml, notify-discord.yml)
- Base-image package-list change detection (`-c` to force rebuild) and
  branch/channel support (`-b`) in build-base-image.sh
- scripts/build-parallel.sh: build multiple profiles concurrently with flock
- scripts/generate-manifest.sh: SHA256SUMS + manifest.json per dated build

### Changed
- Fixed GPG key generation: removed `%no-protection` from keys/create-gpg-keys.sh to require passphrase protection
- Fixed SSH key generation: added passphrase prompt to keys/create-ssh-keys.sh

### Fixed
- config.sh no longer skipped creating OUTPUT_DIR/TEMP_DIR/MOK_DIR/GPG_DIR
  (a rewrite of the cache-dir setup accidentally dropped the line) — was
  silently breaking every script that writes under those paths on a fresh
  checkout, including the new build-parallel.sh.
- config.sh's new `unmount_tree()` compared a whole `/proc/self/mounts` line
  (source device first) against a bare mountpoint prefix, so it could never
  match and silently unmounted nothing.
- build-base-image.sh's new package-list-hash cache was keyed under the
  BUILD_DATE-stamped output directory, so a hash written today could never
  be found by tomorrow's build — the "skip if unchanged" check never hit
  across a day boundary, the most common case it exists to speed up. Moved
  to a stable, date-independent path.
- build-base-image.sh's new branch support nested output under
  `${profile}/${branch}/${date}/`, which upload.sh, build-iso.sh, and
  repack-iso.sh (unmodified) don't know about — reverted to the shared
  `${profile}/${date}/` layout; branch is still distinguishable via the
  branch-qualified filename (`shanios-DATE-BRANCH-PROFILE.zst`).
- The `builder_ami_id` Packer variable was declared inside the
  `source "amazon-ebssurrogate"` block in shanios-ami.pkr.hcl — Packer/HCL2
  requires `variable` blocks at the top level; moved to common.pkr.hcl
  alongside every other variable declaration in this project.
- build-parallel.sh sourced config.sh via the wrong relative path
  (`$SCRIPT_DIR/config/config.sh` instead of `$SCRIPT_DIR/../config/config.sh`)
  — the script could not even start.
- build-parallel.sh's default profile list was space-separated
  (`"gnome plasma ..."`) but split on comma (`IFS=','`), so a build with no
  `-p` flag tried to build one bogus profile named after all six concatenated,
  instead of six separate profiles.
- build-parallel.sh's `--from-r2` and `--minimal` flags were accepted and
  logged but had no effect: `${FROM_R2:+--from-r2}` expands unconditionally
  since FROM_R2 is always a non-empty string ("true" or "false"), and
  build-base-image.sh has no matching flags or minimal-package-list concept
  at all. Both now fail fast with a clear "not implemented yet" error instead
  of silently doing a full build while claiming otherwise.
- generate-manifest.sh sourced config.sh via the same wrong relative path as
  build-parallel.sh, and its directory-scanning logic assumed a
  `${profile}/${branch}/${date}/` layout that never matched reality (see the
  build-base-image.sh branch-layout fix above) — rewritten to scan
  `${profile}/${date}/` directly, with `-b` filtering by branch-qualified
  filename within each date directory instead of selecting a branch
  subdirectory.
- generate-manifest.sh's invented `latest.txt` writer removed:
  build-base-image.sh already writes the per-date one and upload.sh already
  maintains the central profile-level one — a third writer risked the two
  falling out of sync.

## [0.0.0] - 2026-09-15
### Added
- Initial version (placeholder)