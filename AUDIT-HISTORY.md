# shani-install-media — audit/fix history

This file is the full narrative behind every entry in `AGENTS.md`'s
"Audit-verified known issues" section — the verification methodology,
before/after evidence, and reasoning for each fix. **Read `AGENTS.md`
first** — that file is the current-state summary; this one is why and how.

This file is append-only in spirit: when `AGENTS.md`'s summary is updated
for a new fix, the full narrative for that fix should land here, not
inflate the main file back to unreadable length.

---

- **MOK private key in base image (Critical).**
  `scripts/build-base-image.sh:165-167` installs `MOK.key` into the image —
  by design, needs human architecture decision.
- **`SigLevel = Never` for non-server profiles (High) — FIXED.**
  `image_profiles/{kiosk,gnome,plasma}/pacman.conf` used
  `SigLevel = Never DatabaseOptional`; cosmic and server already used
  `SigLevel = Required DatabaseOptional`. Changed all three to `Required
  DatabaseOptional` to match. Verified for real, not just by reading the
  config: the builder image's pacman keyring is already populated (checked
  live with `pacman-key --list-keys` inside the container), and a real
  `./run_in_container.sh build.sh test pacstrap -p gnome` run succeeded —
  actual packages pulled and signature-verified under the new `SigLevel`,
  all 14 post-install hooks ran, `/usr/bin/bash` ended up installed. See
  "Testing pacman.conf/signing changes: `cmd_pacstrap`" below for the
  reusable pattern this now is.
- **GPG key passphrase is operator-supplied (High — residual).**
  `keys/create-gpg-keys.sh:66-68` prompts interactively for the signing
  key's passphrase; it lands in the batch file at `:87` (`Passphrase:`) and
  is applied via `--passphrase` at `:104`/`:130`. No `%no-protection`
  directive remains in the file. Residual risk: an empty passphrase entered
  at the prompt still yields an unencrypted key.
- **SSH key passphrase is operator-supplied (High — residual).**
  `keys/create-ssh-keys.sh:135-137` prompts "leave empty for no passphrase";
  `SSH_PASSPHRASE=""` is only the `:127` default reset before the prompt,
  applied via `-N` at `:146`. An operator can still choose an empty
  passphrase (passphrase-less deploy key).
- **6 profiles:** cosmic, gnome, kiosk, plasma, server, shared.
- **CI status.** 1 CI workflow (`build-ami.yml`).
- **`promote-stable.sh` connect-timeout config drift (Low) — FIXED.**
  `scripts/promote-stable.sh:123,138,191,194,209,212` hardcoded
  `--connect-timeout 10`/`20` while only `scripts/promote-stable.sh:265` used
  `--connect-timeout "$NETWORK_CONNECT_TIMEOUT"` — changing
  `config/config.sh`'s `NETWORK_CONNECT_TIMEOUT` silently wouldn't affect 6
  of 7 curl calls. All 7 now use `"$NETWORK_CONNECT_TIMEOUT"`. Verified with
  `bash -n`; default value (10) unchanged so behavior is identical unless
  the setting is deliberately overridden.
- **Inconsistent customization-script shebangs (Low) — FIXED, but the
  original finding undersold it.** `image_profiles/cosmic/cosmic-customization.sh`,
  `image_profiles/gnome/gnome-customization.sh`, and
  `image_profiles/plasma/plasma-customization.sh` weren't "missing a
  shebang" — they were **0-byte files** (`git cat-file -s` confirmed empty
  blobs in HEAD), harmless no-ops when `scripts/build-base-image.sh:131`
  invokes them via explicit `bash <script>`. A `sed -i '1i ...'` insert is
  a silent no-op on a truly empty file (no line 1 to address), which is
  worth knowing if you try to patch one the same way — used `printf
  '#!/bin/bash\n' > file` instead. All three now contain just a shebang
  line, matching `kiosk-customization.sh`'s convention (`server-customization.sh`
  uses `#!/usr/bin/env bash` instead — left as-is, not worth an unrelated
  flip). Verified with `bash -n`.
- **Real MOK private key reachable in git history (Critical).** Commits
  `16c6f3a` (2024-11-05, "init") and `458b442` (2025-02-10, "some changes
  to make the iso ready") each committed a full, distinct RSA PEM private
  key as `mok/MOK.key`; it was removed from the tree in `6bb7045` ("Delete
  mok/MOK.key") but both key blobs remain fully retrievable via
  `git log --all -p` / `git show <sha>:mok/MOK.key` since history was
  never rewritten. Treat both keys as burned; rotating them is a human
  decision, but the repo's history still leaks them regardless of what's
  in `keys/mok/` today.
- **No LICENSE file despite README claiming one (fact).** `README.md:775-777`
  states "GNU General Public License v3.0 — see individual script headers
  for authorship details," but there is no `LICENSE`/`COPYING` file at the
  repo root, and sampled script headers (`build.sh:1-15`,
  `scripts/build-base-image.sh:1-4`) contain no license or authorship text
  at all — the README's pointer resolves to nothing.
- **No CHANGELOG.md or CONTRIBUTING.md (fact).** Neither file exists
  anywhere in the repo (checked root and recursively); nothing to check
  for staleness since there's nothing to be stale.
- **Base ShaniOS image is never version-pinned for AMI builds (reproducibility).**
  `packer/scripts/00-bootstrap-shanios.sh:69-82` always resolves
  `${ARTIFACT_BASE}/${SHANIOS_PROFILE}/latest.txt` to pick the image to
  bake into an AMI, with no variable or override to pin a specific
  `BUILD_DATE`/filename — two AMI builds run on different days will
  silently embed different ShaniOS base images, and a past AMI can't be
  reproduced on demand. (Distinct from the already-known checksum
  soft-fail issue in Supply-chain discipline above.)
- **Builder host AMI floats to "most recent" (minor, reproducibility).**
  `packer/templates/shanios-ami.pkr.hcl:36-43` — `source_ami_filter` for
  the AL2023 builder instance uses `most_recent = true` with no pinned AMI
  ID. Lower severity since that AL2023 root is discarded after the build
  (only `/dev/xvdf` becomes the AMI, per the file's own comments at
  line 23), but it's still an unpinned dependency and could shift build
  behavior (tool versions on the builder host) between runs.
- **Stray root-owned build artifact escapes `.gitignore` — pattern FIXED,
  artifact itself still needs manual cleanup (repo hygiene).**
  A nested `./shani-install-media/test-env/disk/nspawn-overlay-blue/...`
  directory tree (root-owned, e.g.
  `shani-install-media/test-env/disk/nspawn-overlay-blue/upper/root/shani-deploy.sh`)
  sat untracked in the working tree and wasn't matched by the `.gitignore`
  rule `test-env/disk/*` because it landed one level too deep, under a
  spurious subdirectory named after the repo itself rather than at the
  repo's own `test-env/disk/`. Added `**/test-env/disk/*` /
  `!**/test-env/disk/.gitkeep` to `.gitignore` alongside the existing
  root-only rule, so any future recurrence at any nesting depth is ignored.
  **The existing artifact itself is still on disk** — it's root-owned
  (`root:root`, dated 2026-08-25), so a plain `rm -rf shani-install-media`
  as the normal user fails with "Permission denied" on every file inside;
  removing it needs `sudo rm -rf shani-install-media` run by a human, not
  done here.
- **`image_profiles/kiosk/` has never been committed (fact, found
  2026-08-28).** `git ls-files image_profiles/kiosk/` returns nothing and
  `git log --all -- image_profiles/kiosk/` shows zero commits ever touching
  this path — the entire kiosk profile (`pacman.conf`, `package-list.txt`,
  `overlay/`, `kiosk-customization.sh`) exists only in this working tree.
  A fresh clone of this repo is missing the kiosk profile entirely, and any
  edit made to a file under it (e.g. the `SigLevel` fix above) is sitting
  in an untracked file until someone runs `git add`. Not fixed here —
  whether/when to stage and commit a profile is a decision for whoever owns
  this working tree, not something to do silently mid-audit.
- **20 uncommitted changes at audit time (fact, not necessarily a problem).**
  `git status --porcelain | wc -l` = 20 (6 modified tracked files, 14
  untracked paths/dirs) as of 2026-08-28 — normal for an active working
  tree, noted here only as a snapshot.

