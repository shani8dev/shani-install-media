# Agent instructions — shani-install-media

This file applies to any AI coding assistant working in this repository
(Claude Code, opencode, Kilo Code, Cursor, Aider, or similar). Read this
before editing, and follow the verification steps before calling any change
done.

## What this repo is

The fully automated build system for Shanios — builds Btrfs system images,
optional Flatpak/Snap images, and Secure Boot-signed ISOs for GNOME,
Plasma, COSMIC, kiosk, and headless Server profiles, plus AWS AMIs. Builds
run inside the `shani-builder` Docker container so the host is never
modified. This is also the repo that owns build/boot verification for the
whole OS pipeline — see "Before claiming a package/service is missing"
below before assuming a fix belongs elsewhere.

## This repo builds and boot-tests real OS images — use the real harness

Don't `bash -n` a build script and call it done. `test-env/` is a genuine
test rig: real Btrfs slots, real loop-backed disks, a real received OS
image, real `systemd-nspawn`, and (for boot-level changes) a real UEFI boot
via OVMF. Read `test-env/README.md` in full before touching anything in
`scripts/`, `image_profiles/`, `iso_profiles/`, or `test-env/` itself — it
explains exactly what each command does and why.

**Never enumerate, grep, or read anything under `test-env/disk/` or
`cache/`** — these are build artifacts and loop-mounted images (hundreds of
thousands of files, partly permission-restricted), not source.

## Environment facts that affect what you can test here

- Docker is available; you may also use podman, distrobox, lxd,
  apptainer, or install anything via `apt` if a better tool fits — pick
  what's actually appropriate, don't assume Docker is the only option.
- **There is no `/dev/kvm` on this host** — no hardware-accelerated
  virtualization. `test-env/test.sh qemu` and `build.sh test iso` (full
  UEFI boots via OVMF) work but are very slow under software emulation.
  Prefer the nspawn-based commands (`disk`, `ca`, `bootstrap`, `enter`,
  `upgrade`, `reboot`, `rollback`) for anything that doesn't specifically
  need a full firmware boot — they exercise real `shani-deploy` logic
  without needing virtualization at all. Reserve a full QEMU boot for a
  final check, not the default verification step, and say plainly if you
  skipped one for this reason.
- A real built image usually already exists under `cache/output/<profile>/`
  — check there before spending 30+ minutes on `./build.sh image`.

## If you have Superpowers / oh-my-opencode / ultrawork / similar available

If your environment provides Claude Code's **Superpowers** plugin (TDD,
debugging, and verification-discipline skills), OpenCode's
**oh-my-opencode** (parallel/async subagents, LSP/AST tooling), an
**ultrawork**-style high-autonomy parallel execution mode, or an
equivalent skill/subagent framework in whatever tool you're running as —
use its parallel-subagent capability to run independent `test-env`
sessions concurrently (e.g. one profile's `bootstrap`→`enter` cycle while
another checks a `pkgbuilds`/`os-installer-config` change) instead of
serializing everything through one slow container session. Don't let a
skill framework's plan-and-report output substitute for actually running
the harness commands below — and given there's no `/dev/kvm` here, use any
parallelism you have to offset the lack of hardware acceleration rather
than trying to make a single QEMU boot faster.

## Required verification for a change to build/boot logic

```bash
./run_in_container.sh build.sh test ca
./run_in_container.sh build.sh test bootstrap -p <profile> -d latest
# ... exercise whatever you changed via `enter`, `upgrade`, `reboot`,
#     `rollback`, `install`, `configure` as applicable — see the command
#     table in test-env/README.md ...
./run_in_container.sh build.sh test clean   # always, when done
```

`bootstrap` runs the REAL `install.sh`+`configure.sh` from the sibling
`os-installer-config` checkout (plus one genuinely test-only step:
trust-anchoring this session's throwaway CA into both slots) — it no

## 🧪 MANDATORY: Full Test Harness Sequence (non-negotiable)

**You MUST run the full test harness. Do not skip it. Do not substitute
static checks for it. Do not say "this should work" without evidence.**

Every change to build/boot/deploy logic must be verified with the real
test harness. This is the ONLY way to prove things actually work.

### The complete test sequence (run ALL of these)

```bash
# 1. Clean any stale loop devices from previous sessions
./run_in_container.sh build.sh test clean

# 2. Generate throwaway CA + leaf cert
./run_in_container.sh build.sh test ca

# 3. Bootstrap: REAL install.sh + configure.sh into @blue/@green
./run_in_container.sh build.sh test bootstrap -p gnome -d latest

# 4. REAL deploy (download → SHA256+GPG verify → extract → UKI sign → boot entry write)
#    --local-src overlays the sibling shani-deploy checkout's current scripts
./run_in_container.sh build.sh test upgrade --local-src=/opt/shani-deploy/scripts

# 5. REAL rollback
./run_in_container.sh build.sh test rollback --local-src=/opt/shani-deploy/scripts

# 6. ALWAYS clean up when done
./run_in_container.sh build.sh test clean
```

### What each step actually proves

| Step | Proves |
|------|--------|
| `clean` | No stale loop devices break the next run |
| `ca` | Test CA + leaf cert generation works |
| `bootstrap` | install.sh + configure.sh produce a bootable slot with signed EFI |
| `upgrade` | shani-deploy does download → verify → extract → UKI sign → boot entry write |
| `rollback` | Snapshot + restore mechanism works |
| `clean` | Loop devices released, no resource leaks |

### Prerequisites

- Docker must be running (`docker info`)
- The `shani-builder` Docker image must be built (`shrinivasvkumbhar/shani-builder:latest`)
- Pre-built images should exist at `cache/output/<profile>/` — check there first
- No `/dev/kvm` on this host — QEMU boots are very slow, use nspawn commands

### If a step fails

Do NOT skip it. Do NOT say "it probably works." Investigate the failure:
- Check the log file referenced in the error
- Run the step again with verbose output
- If it's a stale loop device issue, run `clean` first
- If it's a corrupted cached package, the error will say so explicitly
longer needs a separate `disk` step first; that command sets up a
different, faster fabricate-only disk pair (`root.img`/`esp.img`)
`bootstrap` doesn't touch anymore (it creates and uses its own
`install.img`, exactly like a real install would).

If two consecutive `run_in_container.sh` invocations show a stale loop
device attached to `root.img`/`esp.img`/`install.img` (`losetup -a`),
that's a known harness quirk from separate `--rm`'d containers not
detaching each other's loop devices — `_ensure_disk_attached`/
`_ensure_install_attached` should self-heal this; if it doesn't, that's a
regression in the harness itself, not something to work around by hand
every time.

## Testing shani-deploy/gen-efi/shani-update changes for real

`run_in_container.sh` bind-mounts the sibling `shani-deploy` checkout
read-only at `/opt/shani-deploy` (same optional, no-op-if-missing
convention as `/opt/os-installer-config` below; override with
`SHANIOS_TEST_DEPLOY_HOST_DIR`). Pass `--local-src=/opt/shani-deploy/scripts`
to `enter`/`upgrade`/`verify-boot`/`desktop` to overlay that checkout's
*current* scripts and systemd units onto the slot — not a hand-copied
snapshot that drifts, and not whatever got baked into the image at build
time. `upgrade` calls `shani-deploy` directly (not through `shani-update`,
which needs a real display to open its progress terminal) with `--force
--channel latest --skip-self-update`, so it drives a REAL, complete deploy
(download → SHA256+GPG verify → extract → UKI generation/signing →
boot-entry write), not just a dry-run of the approval flow:

```bash
./run_in_container.sh build.sh test bootstrap -p gnome -d latest
./run_in_container.sh build.sh test upgrade --local-src=/opt/shani-deploy/scripts
```

Downloaded update images are cached at a host-persistent path
(`cache/download_cache/`, bind-mounted over the slot's `/data/downloads`)
so a repeat run — or even a fresh `bootstrap` that wipes `install.img`
entirely — doesn't force a multi-GB re-download of the same real image.

## Testing pacman.conf/signing changes: `cmd_pacstrap`

Don't trust a `pacman.conf` / `SigLevel` / keyring change by reading it —
`test-env/test.sh` has a real, first-class command for this:

```bash
./run_in_container.sh build.sh test pacstrap -p <profile> [extra-pkg ...]
```

This runs a genuine `pacstrap` into a throwaway root using that profile's
actual `image_profiles/<profile>/pacman.conf`, so it proves the builder's
keyring really satisfies that profile's `SigLevel` against real packages
and real signatures — not just that the file parses. Defaults to
installing `base`; pass extra package names (e.g. `shani-core`, `flatpak`,
`podman`) to exercise a deeper slice of a profile's real dependency set
through the same real signature-verification path. This is what verified
the `SigLevel = Required` fix above — a live run against `gnome` completed
with all 14 post-install hooks firing and a real signature-verified
`/usr/bin/bash` on disk.

This is the standard pattern for this repo now: any future change to a
profile's `pacman.conf`, keyring, or `SigLevel` should be verified with
`cmd_pacstrap` before being called done, the same way build/boot logic
changes are verified with `disk`/`bootstrap`/`enter` above.

**Why this, and not driving podman/distrobox/flatpak/snap/apptainer/lxd
directly:** those are real upstream projects Shanios ships as packages
(`shani-core`'s `depends=()`), each with its own test suite — this harness
isn't the place to re-verify that Podman itself can run a container. What
*is* this repo's job is confirming those packages install and get enabled
correctly from a profile's real package list, which is exactly what
`cmd_pacstrap` (the install) plus each package's own `.install`
`post_install`/`post_upgrade` hooks (the enablement — see "Before claiming
a package/service is missing" below) already cover. `systemd-nspawn`
(`cmd_enter`) and `qemu`/OVMF (`cmd_qemu`, `cmd_iso`) are this harness's two
real *execution* layers; docker/podman are already the **outer**
orchestration layer via `run_in_container.sh`'s own runtime detection.
AppImage isn't a systemd-managed package at all, so there's nothing at this
layer to verify for it.

## Verifying GUI/desktop changes: `desktop`, `watch`, `qemu --vnc`

Three commands answer "does a GUI app or theme change actually render",
without a distrobox dependency:

- **`desktop <blue|green> [--exec="cmd"] [--out=<file.png>]`** — real
  desktop verification via nspawn, no VM. Boots the slot for real (`--boot`,
  so `systemd-logind` genuinely exists — a plain non-`--boot` `enter`
  crashed gnome-shell's own JS init on a missing logind connection when this
  was tried first), `nsenter`'s into the live container once it settles,
  and runs a controlled `gnome-shell --headless --virtual-monitor=WxH`
  session — proven live to start a real Wayland compositor with a
  software/surfaceless renderer, no GPU needed. `--exec` runs a command
  inside that session (e.g. flip a theme setting) before screenshotting via
  GNOME Shell's own D-Bus `org.gnome.Shell.Screenshot` API. Only GNOME is
  proven end-to-end — Plasma/Cosmic would need `kwin_wayland --virtual` /
  cosmic-comp's own headless mode in the same recipe.
  - **Known intermittent issue, not yet root-caused:** two runs in a row
    stalled silently right after "Locating the container's init PID..."
    with no further progress output, yet the console log confirmed the
    real boot underneath completed fine (reached the login prompt) both
    times — the *wrapper's* own logging/leader-detection path went dark
    before the 30s graceful-shutdown grace elapsed and force-killed. A
    synthetic repro of the `pgrep -P` mechanism worked fine, and a separate
    run right before this one succeeded completely end-to-end (real boot →
    nsenter → headless gnome-shell → screenshot attempt), so the mechanism
    itself isn't fundamentally broken — likely either host resource
    pressure from several repeated real `--boot` cycles in one sitting, or
    an output-buffering quirk. If you hit this, retry after a `clean`; if
    it becomes reproducible, add timestamped heartbeat logging with
    explicit flushes to the wait loops to disambiguate "hung" from "output
    lost" before investigating further.
  - **Real risk found live, now guarded against:** an *outer* wrapper
    (a CI timeout, an impatient `timeout N` around the whole invocation)
    cutting this off before its own `--timeout` plus ~30s grace elapses
    hard-kills a REAL, live systemd instance mid-write to a REAL btrfs
    filesystem — one run during development left **both** `@blue` and
    `@green` missing afterward (recovered with a fresh `bootstrap`).
    `_desktop_cleanup` now gives the container up to 30s to shut down
    gracefully (SIGTERM → nspawn forwards a clean poweroff) before
    escalating to SIGKILL, with an explicit warning if it has to — but
    **any caller (including CI) must budget its own outer timeout
    comfortably above `--timeout` plus that 30s**, or risk the same thing.
- **`qemu --vnc[=port]`** (default port 5700) — serves the real QEMU
  framebuffer over VNC-over-websocket instead of a local GTK window (QEMU's
  own `websocket=` vnc suboption — confirmed live on this host's QEMU
  8.2.2, opens both raw VNC on 5900 and the websocket bridge together, no
  separate `websockify` proxy needed).
- **`watch [--port=N]`** — host-only local dashboard
  (`http://127.0.0.1:8090/` by default): one panel live-tails whichever
  `*-console.log` is newest (from `desktop` or `verify-boot`), the other
  embeds a noVNC viewer for a `qemu --vnc` session. Plain `python3
  http.server` stdlib, nothing leaves `127.0.0.1`. Verified live: served
  real, correct content from an actively-written console log across
  process boundaries via simple byte-offset polling.

## For changes to `install.sh`/`configure.sh` (in the sibling `os-installer-config` repo)

Those scripts are fully driven by `OSI_*` environment variables — no GUI
required. Use `build.sh test install [--encrypted]` and
`build.sh test configure` to actually run them end-to-end against fresh
loop-backed disks and verify the result (LUKS unlockable with the test
passphrase, user account created, etc.) — this is real coverage that used
to not exist at all; don't quietly let it regress back to "a human has to
click through the installer to test this."

## Supply-chain discipline

Every download this pipeline does — the builder image, packages inside
the container, the base image, the ISO, an AMI — should be checksum- and
signature-verified with a **hard failure** on mismatch, matching the
existing ISO path's policy (`scripts/build-iso.sh`). If you add a new
fetch step, make it fail closed by default; a soft-fail "warn and
continue" on a missing/mismatched signature has been a real, shipped bug
here before (the AMI/packer path).

## Audit-verified known issues (confirmed present)

**For the full narrative, verification methodology, and before/after
evidence behind every line below, see `AUDIT-HISTORY.md`.** This section
is deliberately just the current-state summary.

- **MOK private key in base image (Critical).**
  `scripts/build-base-image.sh:100` installs `MOK.key` into the image —
  by design, needs human architecture decision.
- **Real MOK private key reachable in git history (Critical).** Two
  distinct RSA PEM private keys were committed as `mok/MOK.key` in
  `16c6f3a`/`458b442`, later deleted in `6bb7045` — but both blobs remain
  fully retrievable via `git log --all -p` since history was never
  rewritten. Treat both keys as burned; rotation is a human decision.
- **`%no-protection` (High).** `keys/create-gpg-keys.sh:79` — unencrypted
  signing key.
- **`SSH_PASSPHRASE=""` (High).** `keys/create-ssh-keys.sh:134` — SSH
  deploy key without passphrase.
- **`SigLevel = Never` for non-server profiles — FIXED.** All three of
  `image_profiles/{kiosk,gnome,plasma}/pacman.conf` now read `SigLevel =
  Required DatabaseOptional`, matching cosmic/server — verified with a
  real `pacstrap -p gnome` build under the new setting, not just by
  reading the config. See "Testing pacman.conf/signing changes" below for
  the reusable verification pattern this produced.
- **`promote-stable.sh` connect-timeout config drift — FIXED.** All 7 curl
  calls now honor `config/config.sh`'s `NETWORK_CONNECT_TIMEOUT` (was 6 of
  7 hardcoded).
- **Inconsistent customization-script shebangs — FIXED.** The three
  profile customization scripts were actually 0-byte files, not merely
  missing a shebang; each now contains just a shebang line. Worth knowing:
  a `sed -i '1i...'` insert is a silent no-op on a truly empty file — use
  `printf` to a fresh write instead.
- **Stray root-owned build artifact escapes `.gitignore` — pattern FIXED,
  artifact still needs manual cleanup.** `.gitignore` now catches
  `test-env/disk/*` at any nesting depth. The existing root-owned artifact
  on disk still needs a human to run `sudo rm -rf` — not done here.
- **`image_profiles/kiosk/` has never been committed (fact).** The entire
  kiosk profile exists only in this working tree — a fresh clone is
  missing it entirely. Staging/committing it is a decision for whoever
  owns this working tree.
- **Base ShaniOS image is never version-pinned for AMI builds
  (reproducibility).** `packer/scripts/00-bootstrap-shanios.sh:69-82`
  always resolves `latest.txt` — two AMI builds on different days can
  silently embed different base images, and a past AMI can't be
  reproduced on demand.
- **Builder host AMI floats to "most recent" (minor, reproducibility).**
  `packer/templates/shanios-ami.pkr.hcl:36-43` — no pinned AMI ID for the
  AL2023 builder instance (lower severity: that root is discarded after
  the build).
- **No LICENSE file despite README claiming one (fact).**
  `README.md:775-777` points to a GPLv3 license that doesn't exist
  anywhere in the repo.
- **No CHANGELOG.md or CONTRIBUTING.md (fact).**
- **6 profiles:** cosmic, gnome, kiosk, plasma, server, shared.
- **CI status.** 1 workflow (`build-ami.yml`), triggered on pushes
  touching `packer/**`. Runs `packer init`/`packer validate templates/`
  (catches template syntax errors before any real build), then a real
  `packer build` against AWS to produce a genuine AMI — this is not a
  cheap syntax-only check, it actually provisions real cloud resources.
  This is a *different* verification path from `test-env`'s local
  loop-disk harness used elsewhere in this file — a `packer` template
  change is only truly verified by this workflow (or a manual
  `packer validate`/`packer build` run), not by `test-env`.
- **20 uncommitted changes at audit time (fact, snapshot only as of
  2026-08-28, not necessarily a problem).**

## Before claiming a package/service is "missing" — check the whole chain first

A real mistake, made and caught in this session: it looked like desktop
profiles (gnome/plasma/cosmic) had no firewall, no audit daemon, no
AppArmor, because `grep`ing each profile's own `package-list.txt` for
`firewalld`/`audit`/`apparmor` found nothing. That grep only checked one
layer of a five-layer chain, and the other four already had it fully
covered:

1. `image_profiles/<profile>/package-list.txt` — what gets `pacstrap`'d
   directly.
2. **`shani-pkgbuilds/<pkg>/PKGBUILD`'s `depends=()`** — packages
   listed in (1) often pull in dozens more transitively. `shani-network`
   (already depended on by every desktop profile) depends on `firewalld`
   and `fail2ban`; `shani-core` (same) depends on `audit` and `apparmor`.
   **A `grep` against `package-list.txt` alone will never find these —
   you have to open the sibling `shani-pkgbuilds` repo and read the actual
   `depends=()` arrays of everything in the list.**
3. **`shani-pkgbuilds/<pkg>/<pkg>.install`'s `post_install`/`post_upgrade`** —
   this is where services actually get *enabled* on this project, via
   plain `systemctl enable ...` calls that pacman runs automatically the
   moment the package installs during `pacstrap`. `shani-network.install`
   already enables `firewalld` and `fail2ban`; `shani-core.install`
   already enables `apparmor` and `auditd.service`. **This is the layer
   most likely to already do what you think is missing — check it before
   writing a "fix" anywhere else.**
4. `image_profiles/shared/overlay/rootfs/` (or a profile's own
   `overlay/rootfs/`) — static config files copied into the image
   verbatim.
5. `image_profiles/<profile>/<profile>-customization.sh` — reserved for
   what (2)-(4) genuinely cannot do: conditional logic, `chsh`, editing an
   already-installed file, or removing a shared-overlay artifact that
   doesn't apply to this profile. **If a service just needs enabling and
   its package already has a `.install` that does it, a customization
   script doing it again is redundant, not defense-in-depth** — the
   server profile's `server-customization.sh` re-enabling
   `firewalld`/`fail2ban`/`apparmor`/`auditd` is itself a (harmless, but
   real) instance of this same redundancy, pre-existing before this
   session.

**The rule:** before writing anything that "enables X" or "installs X" in
this repo, `grep -rn "X" ../shani-pkgbuilds/*/PKGBUILD ../shani-pkgbuilds/*/*.install`
first. If a `.install` file already does it, the fix (if there really is
one) is a config/zone/rule *content* change, not another enable call.

See `../shani-settings/AGENTS.md`'s "Where a given config file actually
belongs" section for the fuller decision framework. Default to
`shani-settings` for anything that's correct for every profile that
depends on it (`gnome`/`plasma`/`cosmic`/`kiosk`); only use this repo's
`<profile>/overlay/` (a profile's own, or `shared/overlay/` for
`gnome`/`plasma`/`cosmic`) when a profile genuinely needs *different*
content than the `shani-settings` default (like `server`'s own firewalld
zone — `server` doesn't depend on `shani-settings` at all) or for
image-assembly mechanics `shani-settings` can't express. Don't reach for
an overlay file as the default just because it's this repo — check
whether it could just be one `shani-settings` file first.

## Cross-repo impact — check before calling a fix complete

- `install.sh`/`configure.sh` are owned by the sibling `os-installer-config`
  repo; this repo only tests them (`build.sh test install`/`configure`). A
  fix belongs in that repo, not a local patched copy here.
- `shani-deploy`'s scripts are packaged and tested here but owned by that
  sibling repo — same rule.
- `run_in_container.sh` is symlinked from `shani-pkgbuilds/run_in_container.sh` → `../shani-install-media/run_in_container.sh`. Uses `BASH_SOURCE`-aware `HOST_WORK_DIR` so bind-mounts resolve to the calling repo's directory. Fix here covers both repos.
- This repo's builder container image comes from the sibling
  `shani-builder` repo. If a build starts failing in a way that traces
  back to the image itself (a missing tool, a changed base), the fix
  belongs in `shani-builder`, and any other consumer of that same image
  (`shani-pkgbuilds`'s `run_in_container.sh`) should be checked too.

## Where things are documented

`README.md` for the overall pipeline, `SECURITY.md` for the trust model,
`test-env/README.md` for the test harness itself — keep the command table
and "What this does NOT simulate" section there in sync with reality when
you add or close a testing gap. `AUDIT-HISTORY.md` has the full narrative
behind every entry in "Audit-verified known issues" above.
