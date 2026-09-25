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

## Empirical verification (mandatory)

**Reading code is analysis; running code is verification.** A change is not
verified by reading the diff, running `bash -n`, or confirming it "looks
correct." It is verified by observing the actual behavior of the real
thing in the real environment — built, served, deployed, signed, running.
If you haven't seen it work (or fail) for real, it isn't verified.

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
longer needs a separate `disk` step first; that command sets up a
different, faster fabricate-only disk pair (`root.img`/`esp.img`)
`bootstrap` doesn't touch anymore (it creates and uses its own
`install.img`, exactly like a real install would).

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

If two consecutive `run_in_container.sh` invocations show a stale loop
device attached to `root.img`/`esp.img`/`install.img` (`losetup -a`),
that's a known harness quirk from separate `--rm`'d containers not
detaching each other's loop devices — `_ensure_disk_attached`/
`_ensure_install_attached` should self-heal this; if it doesn't, that's a
regression in the harness itself, not something to work around by hand
every time.

## Testing shani-deploy/gen-efi changes for real

`run_in_container.sh` bind-mounts the sibling `shani-deploy` checkout
read-only at `/opt/shani-deploy` (same optional, no-op-if-missing
convention as `/opt/os-installer-config` below; override with
`SHANIOS_TEST_DEPLOY_HOST_DIR`). Pass `--local-src=/opt/shani-deploy/scripts`
to `enter`/`upgrade`/`verify-boot`/`desktop` to overlay that checkout's
*current* scripts and systemd units onto the slot — not a hand-copied
snapshot that drifts, and not whatever got baked into the image at build
time. `upgrade` calls `shani-deploy` directly (not through the retired
`shani-update` wrapper, which needed a real display to open its progress
terminal) with `--force
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

## Fully-automated GUI test harness: `gui --click/--type/--key/...`

`cmd_gui` (host-only, boots root.img/esp.img headless via OVMF+QMP+
guest-agent, no display window — see its own header comment) now runs an
**ordered sequence of real UI-driving actions**, not just a single `--exec`
+ final screenshot:

```
test-env/test.sh gui --click=100,200 --type="hello" --key=ret \
    --screenshot=out.ppm --exec="gsettings get org.gnome.desktop.interface gtk-theme"
```

Actions run in the exact order given on the command line (click → type →
key → screenshot → exec, for the example above). Flags: `--exec=`,
`--click=X,Y[:button]`, `--doubleclick=X,Y`, `--move=X,Y`, `--type="text"`,
`--key=COMBO` (`ret`, `tab`, `ctrl+alt+t`, `alt+F4`, ...), `--sleep=SECS`,
`--screenshot=<file.ppm>` (repeatable), plus the existing `--out=`/`--timeout=`.

**Why QMP `input-send-event` instead of xdotool/ydotool:** it injects real
HID events at the guest's emulated USB keyboard/tablet
(`-device usb-kbd -device usb-tablet`, already wired up) — the same path a
physical keyboard/mouse takes. This makes it **display-server-agnostic by
construction**: it works identically whether the guest desktop is running
X11 or Wayland, since the guest OS itself translates the HID reports, not
us. This is *why* it's the right approach here and not the nspawn+X11/
Wayland-socket-forwarding path explored earlier in this investigation: that
path hit a real, confirmed dead end — a headless `gnome-shell --headless`
compositor crashes on any real GL/EGL-touching Wayland client (root-caused
to this host's broken NVIDIA EGL vendor file sorting before mesa's), and
neither `xdotool` (X11-only) nor `ydotool`/`wtype`/`wlrctl` (need
`/dev/uinput`, confirmed absent in the nspawn container, or a running
Wayland compositor) are installed in the shanios image at all — confirmed
live via `pacman -Qi ydotool xdotool wtype` all returning "was not found",
and `pacman` itself isn't even present in a *booted* shanios instance
(immutable image — packages are baked in at build time only, not
installable live). QMP input injection sidesteps this whole class of
problem: nothing new to install anywhere, works the same for every desktop
environment this repo tests (GNOME/Plasma/Cosmic), X11 or Wayland.

Coordinates are real framebuffer pixels, resolved against the **current**
resolution automatically (a screendump is taken to read the PPM header's
width/height) on every `click`/`move` call — correct even if the desktop
resizes between actions, at the cost of one extra screendump round-trip per
click.

**Verified live, this session:**
- `_qmp_click`/`_qmp_key`/`_qmp_type` (the exact functions shipped in
  `test.sh`, sourced and called directly) all executed against a real,
  running QEMU instance with zero QMP protocol errors. `_qmp_click`
  correctly auto-detected a 1280×800 framebuffer and computed exact
  normalized abs coordinates (400,300 → abs(10240,12288), matching
  `x/w*32767` exactly).
- Sending `_qmp_key esc` produced a **visually confirmed, screendump-
  captured change** in the guest's own rendered output (OVMF's PXE fallback
  text changed from `PXE-E16: No valid offer received` to `PXE-E21: Remote
  boot cancelled` after the Esc keypress) — real proof the HID injection
  path reaches and affects real guest firmware/OS, not just that the QMP
  call returns success.

**NOT yet verified: a full real-desktop click/type test (e.g. clicking a
  real GNOME/yad button and confirming the app reacts).** Blocked by two
  separate, pre-existing environment facts, not by anything wrong in the new
  code:
  1. **This host has no `/dev/kvm` at all** (`vmx`/`svm` absent from
    `/proc/cpuinfo` — no hardware virtualization exposed, likely itself a
    VM/container without nested-virt). `cmd_gui`/`cmd_qemu` fall back to
    TCG (pure software emulation), which makes a full GNOME boot
    impractically slow to iterate on here.
  2. **The test-env's current `disk/esp.img` is a genuinely empty FAT32
    volume** — confirmed by loop-mounting it read-only via
    `udisksctl loop-setup -r -f` (no root needed) and finding zero files,
    not even `\EFI\BOOT\BOOTX64.EFI`. This is why `cmd_gui`/`cmd_qemu` hit
    OVMF's PXE fallback instead of booting shanios at all: these disk images
    were only ever taken through `bootstrap` (writes straight to the
    `@blue`/`@green` subvolumes for nspawn testing) and never through a real
    `install`+`configure` pass, which is what actually runs
    `gen-efi.sh`/`finalize_boot_entries` to populate the ESP with a bootable
    UKI. **`cmd_gui`/`cmd_qemu` appear to have never been exercised
    end-to-end in this environment before this session.** To get a real
    bootable image for a full desktop-level UI-automation test: run
    `test-env/test.sh install -p <profile>` then `configure -p <profile>`
    (needs the sibling `os-installer-config` checkout, confirmed present at
    `../os-installer-config`) against a fresh whole-disk image, *not* just
    `bootstrap`.

  **Reconciled with the boot-path change (2026-09-19):** `cmd_qemu`/
  `cmd_gui` no longer boot `disk/esp.img` unconditionally — they resolve
  their backing image through the shared `_resolve_qemu_boot_drives()`
  helper (env `SHANIOS_TEST_QEMU_DISK`, default `auto`), which **prefers
  `disk/install.img`** (the whole-disk image `install`+`configure`/
  `bootstrap` actually produce and populate with a signed UKI) and only
  falls back to the empty `root.img`+`esp.img` pair when `install.img` is
  absent, emitting a warning so the empty-pair case is never silent. The
  empty-pair hazard itself is **not removed** — `disk` still creates both
  images blank and nothing in the supported flow populates them, so
  `SHANIOS_TEST_QEMU_DISK=root` (or an absent `install.img` under `auto`)
  still boots to firmware PXE exactly as documented above; the fix is that
  the default path no longer lands there by accident. `cmd_iso` still uses
  `root.img`+`esp.img` directly as blank install targets (the live
  installer writes its own), bypassing the helper entirely.

## Host-side fix: `run_in_container.sh` now hands build output back to the invoking user

Found while chasing the `esp.img` investigation above: the container
`run_in_container.sh` launches runs as root (`--privileged`, no `--user` —
real `losetup`/`mount`/`nspawn`/`cryptsetup` work inside it needs that), so
everything it writes under the bind-mounted repo root — most importantly
`test-env/disk/*.img` — came back **root-owned on the host** (confirmed
live: a freshly bootstrapped `root.img` was `644 root:root`). That silently
blocks every HOST-ONLY command needing write access to those images
(`qemu`, `gui`, `iso` — deliberately run outside the container, on real
host hardware/display) the instant they're run as a normal user: `gui`
couldn't even open `root.img` for the write-mode boot it needs to perform.
A plain host-side `chown` after the fact can't fix this either — only root
can `chown` to an arbitrary UID, and `run_in_container.sh` itself runs
unprivileged. Fixed by appending a `chown -R $(id -u):$(id -g)
test-env/disk output` to the container's own command string, run from
*inside* the container (where it genuinely is root) right before it exits,
regardless of the user command's own exit code. Verified live: a no-op
`run_in_container.sh /usr/bin/true` invocation flipped `test-env/disk/{root,esp}.img`
from `root:root` back to the real invoking user.

**Correction (2026-09-24): that chown must not reach the slot overlays.**
As first written (`chown -R test-env/disk`) it also recursed into
`test-env/disk/nspawn-overlay-*/upper`, the slots' copied-up system files:
all of them became host-user-owned with setuid stripped (`sudo`,
`dbus-daemon-launch-helper`, a user-owned `/etc/shadow`), and cupsd's
retry loop over its "insecure" notifier wrote a 107 GB log into the slot.
It now skips `nspawn-overlay-*`. See shani-testbed/AGENTS.md for the rest,
including the removal of the never-bootable `root.img`/`esp.img` pair:
`install.img` (GPT: ESP + btrfs) is the only disk now.

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

## Boundaries

- ✅ **Always**: run the real test harness (`clean`→`ca`→`bootstrap`→...→
  `clean`) for any build/boot logic change — `bash -n` and a source read
  have both missed real, shipped bugs here before.
- ⚠️ **Ask first**: rotating the MOK key, rewriting git history to scrub
  the leaked MOK key blobs, or regenerating the GPG/SSH signing keys — all
  four are re-verified present as of 2026-09-18 and explicitly documented
  as needing a human architecture decision, not a code patch.
- 🚫 **Never**: enumerate, grep, or read anything under `test-env/disk/` or
  `cache/` — these are build artifacts and loop-mounted images (hundreds
  of thousands of files, partly permission-restricted), not source.

## Audit-verified known issues (confirmed present)

**For the full narrative, verification methodology, and before/after
evidence behind every line below, see `AUDIT-HISTORY.md`.** This section
is deliberately just the current-state summary.

- **Server profile could never build: `Packages-Extras` listed two packages
  no configured repo has — FIXED (2026-09-23).** `amazon-ssm-agent` is
  AUR-only (stale 3.1.x) and `amazon-ec2-utils` isn't in the AUR at all;
  neither is in `[shani]`/`[core]`/`[extra]`, the only repos
  `image_profiles/server/pacman.conf` configures. `build-base-image.sh`
  installs Base+Desktop+Extras in ONE `pacstrap` call, so "target not
  found" killed every server build (added in `a4a4170`, 2026-09-18; CI only
  builds gnome/plasma, and there is no server image in `cache/output/`).
  Verified with a real resolve against the live repos using the server
  `pacman.conf` in the builder container (`pacman --dbpath <tmp> -Sp` over
  the list filtered exactly as `build-base-image.sh` filters it): before,
  `error: target not found` for both; after, rc=0 with 563 packages
  resolved. Both were removed with a comment; `server-customization.sh` and
  `packer/scripts/01-configure-aws.sh` already treat `amazon-ssm-agent` as
  optional. **Still needs a human:** to actually ship them, add PKGBUILDs to
  `shani-pkgbuilds` so they land in `[shani]`, then re-list them.
- **Server profile: `openresolv` → `systemd-resolvconf` (2026-09-23).** The
  server profile runs systemd-resolved (the `etc/resolv.conf` →
  `stub-resolv.conf` symlink in its overlay) but shipped openresolv as its
  `resolvconf`. Verified in a booted `archlinux:latest` container with real
  systemd-resolved and a dummy `wg0`: with openresolv,
  `resolvconf -a wg0` (what `wg-quick`'s `DNS=` does; `wireguard-tools` is
  in the server set) printed "run `resolvconf -u` to update" and
  `resolvectl dns wg0` stayed **empty**, so VPN DNS was silently dropped.
  With `systemd-resolvconf` (`resolvconf` → `resolvectl`), `resolvectl dns
  wg0` = `10.9.0.1`. The stub symlink stayed intact in both cases, so this
  is about DNS reaching resolved, not about clobbering the file. The real
  server set still resolves with it (563 packages, no `openresolv` pulled
  in by anything else). Checked against the ArchWiki (systemd-resolved):
  stub mode is the recommended mode, and `systemd-resolvconf` is the
  documented way to serve `resolvconf`-using VPN/DHCP clients. It only works
  while `systemd-resolved.service` runs (true on server; desktop profiles
  keep NetworkManager + openresolv, untouched), and its `resolvconf`
  compatibility is "limited" (`resolvectl(1)`), so clients other than
  `wg-quick` need their own check. The wiki's warning that the symlink
  can't be *created* inside `arch-chroot` doesn't apply here: the overlay
  `cp -r` runs from outside (tested: `cp -r` replaces the `filesystem`
  package's regular file with the symlink), and a real `arch-chroot`
  (arch-install-scripts 31) over both the absolute target ShaniOS uses and
  the wiki's relative `../run/...` form gave working in-chroot DNS, left the
  symlink intact, and touched nothing on the host. Not verified: a full
  `bootstrap -p server` (no server image exists to bootstrap from yet, see
  the entry above).
- **`systemd-vmspawn` works on this host WITHOUT `/dev/kvm` — verified
  (2026-09-23).** Inside a privileged `archlinux:latest` container booted
  with systemd as PID 1 (vmspawn needs a system D-Bus, and `openssh` for its
  default vsock SSH setup), plus `qemu-base edk2-ovmf swtpm`:
  `systemd-vmspawn --kvm=no --tpm=yes --secure-boot=no --register=no
  --console=read-only -i <copy of the ISO>` booted the real
  `shanios-gnome-2026.08.21` ISO through OVMF → systemd-boot menu →
  Linux 7.1.8 → live-session login prompt, with the swtpm TPM detected as
  `/dev/tpm0`. That took about 4 minutes of container uptime, package
  install included, so a software-emulated UEFI boot is minutes here, not
  hours. This is the missing tool for the real UEFI tests nspawn can't do:
  the `+3-0` hard-failure fallback (`shani-deploy/AGENTS.md`), TPM2/pcrlock
  enrollment, and booting a rebuilt ISO. The same boot also exposed 3 dead
  D-Bus alias links (next entry).
- **ISO airootfs: dead/broken systemd enablement cleaned up — FIXED
  (2026-09-23).** Mapped every `iso_profiles/shared/airootfs/etc/systemd/system/*.wants/`
  link to its owning package (`pacman -F`) and resolved the real ISO
  package set (`pacman -Sp` against `iso_profiles/gnome/pacman.conf`, 416
  packages). (1) **`sysinit.target.wants/systemd-timesyncd.service` was a
  symlink to itself**, so the live ISO never started timesyncd. Proven in a
  booted `archlinux:latest` container: with the old link,
  `systemctl is-enabled` still said "enabled" but `sysinit.target` pulled it
  in 0 times; with the link re-pointed at
  `/usr/lib/systemd/system/systemd-timesyncd.service`, 1 time. (2) Removed
  15 links to units no ISO package provides (apparmor, bluez, cloud-init ×4,
  cups, firewalld, ModemManager, NetworkManager ×2, reflector, sshd,
  switcheroo-control, a nonexistent `vboxclient.service`), all inherited
  from archiso `releng`. (3) Removed `choose-mirror.service`,
  `livecd-talk.service`, `livecd-alsa-unmuter.service` and their links:
  their `/usr/local/bin/{choose-mirror,livecd-sound}` scripts were never
  shipped, `espeakup`/`alsa-utils` aren't installed, and no boot entry
  passes the `mirror=`/`accessibility=on` options that gate them. After:
  all 11 remaining links map to an installed package, 0 dead. **Not
  done:** an ISO build + QEMU boot (no `/dev/kvm`). The change only
  removes files mkarchiso copies verbatim, plus one symlink target. If
  live-ISO screen-reader support is ever wanted, add releng's scripts
  **and** `espeakup`/`alsa-utils` together. `etc/ssh/sshd_config` in the
  airootfs is also dead (no openssh in the ISO) but was left alone.
  **Follow-up from the vmspawn boot above:** every live boot logged
  "Failed to preset all unit: Unit dbus-org.freedesktop.ModemManager1.service
  is an unresolvable alias" (and nm-dispatcher). Cause: dead
  `etc/systemd/system/dbus-org.{freedesktop.ModemManager1,freedesktop.nm-dispatcher,bluez}.service`
  alias links for packages the ISO doesn't install. Removed; the
  `network1`/`resolve1` aliases are systemd's own and stay. Next step to
  close this out: rebuild the ISO and boot it with vmspawn.
- **Harness review — duplication and drift in `test-env/test.sh` (full read,
  2026-09-23; refactor staged, applied only when no harness run has the file
  open, since bash reads a script as it executes).** Real defects, not just
  tidiness: (a) **`probe` hard-kills a live systemd on btrfs.** Only
  `desktop` has the 30s graceful-shutdown guard, the one added after a hard
  kill left both slots missing; `probe` just `kill`s. (b) **`--local-src`
  overlays leak into later runs:** they're copied into the persistent
  `nspawn-overlay-<slot>/upper`, so a later run *without* `--local-src`
  still boots the old overlaid scripts/units (hit live: a "baseline" probe
  still had `OnFailure=` from the previous run). (c) `desktop` lacks
  `--local-src` although the docs list it. (d) `watch`'s usage/header/this
  file describe a console-log panel the code no longer has (VNC only).
  (e) `cycle` runs `upgrade` without `--local-src`. Duplicates:
  `--local-src` parsing ×5, `--boot` prep block ×4, reached-target
  heuristic ×2, leader-PID wait ×2, overlay copy/ALLOW_NEW/warn ×2,
  upgrade/update-check/rollback bodies ×3, `--encrypted` parsing ×3 + OSI
  encryption env ×2, host→leaf-cert naming ×3, QEMU base args + KVM
  detection ×3, QMP/QGA Python client ×5 across 9 heredocs (`gui move`
  re-implements `_qmp_click`), `cmd_clean` re-implementing
  `_detach_all_loops`; in `run_in_container.sh`, the two optional
  sibling-checkout mount blocks. Images: `root.img`/`esp.img` only serve
  `qemu`/`gui`'s PXE-bound fallback and `iso`'s optional blank target;
  proposal (not applied): make `install.img` the single disk and let ISO
  boots use `test-env/vmspawn.sh`, which keeps its overlay/NVRAM/TPM
  inside a throwaway container. Also: an agent this session listed/read
  under `test-env/disk/` and `cache/` despite the rule below; no harm, but
  don't repeat it.
- **`cmd_pacstrap` ignores extra package names (harness bug, 2026-09-23).**
  `test-env/test.sh`'s `cmd_pacstrap` hard-codes `pacstrap -cC "$conf"
  "$target" base`, even though this file's "Testing pacman.conf/signing
  changes" section and `test-env/README.md` both document
  `pacstrap -p <profile> [extra-pkg ...]`. Found by running
  `pacstrap -p server <full server list>`: it installed only `base` (137
  packages). The extra-package slice described above has therefore never
  actually been exercised.

- **Two `test-env` harness gaps fixed, both needed to genuinely test
  `shani-deploy`'s new system-level auto-rollback service under a real
  `--boot` session (2026-09-19).** Both are test-only, real-hardware
  behavior is unaffected:
  1. `systemd-analyze verify` always reported "Unit data.mount not found"
     for anything `Requires=data.mount` (`mark-boot-in-progress.service`,
     `mark-boot-success.service`, `check-boot-failure.service`, and the
     new `shani-auto-rollback.service`) — confirmed live this was NOT a
     real runtime problem (`/data` is genuinely mounted and active,
     `systemctl status data.mount` shows it; `systemd-fstab-generator`
     just refuses to generate a *unit file* for a device-label mount when
     it detects a container — "is read-only (running in a container?),
     ignoring mount for /dev/disk/by-label/shani_root" — even under a
     real `--boot` nspawn session, since nspawn is a container regardless
     of `--boot`). `systemd-analyze verify` never consults a live
     manager for dependency resolution, only on-disk unit files, so it
     never found the transient unit systemd creates for an
     already-mounted filesystem either. Fixed with a new
     `_inject_data_mount_unit` (`test-env/test.sh`) that writes a real,
     static `data.mount` unit file matching what's already
     bind-mounted — resolves the dependency for static analysis without
     touching runtime mount behavior at all (verified: `/data` still
     genuinely mounted and writable after this, real units depending on
     it still start correctly).
  2. `shani-deploy --rollback` (and anything else doing
     `mount .../by-label/shani_root ...`) failed under a full `--boot`
     session specifically — "`special device /dev/disk/by-label/shani_root
     does not exist`" — confirmed this symlink is created by `cmd_enter`'s
     own non-boot `$setup` script, but nothing equivalent existed for a
     full `--boot`/`probe` session (no real udev for these loop-backed
     devices under nspawn either way). Fixed with a new
     `_inject_by_label_unit`, the `--boot`-session equivalent of the
     existing `_inject_fake_cmdline_unit` pattern. Both new injectors are
     wired into the single shared `_nspawn_full_boot_args` (used by every
     "boot this slot" caller: `enter --boot`, `verify-boot`, `desktop`,
     `probe`), so the fix applies everywhere at once, matching how the
     cmdline fake unit is already shared. Verified end-to-end with the
     `probe` command: `shani-auto-rollback.service` now runs correctly
     under a genuine `--boot` session for both a same-slot failure
     (`switch_to_sibling_slot()`) and a genuine hard-failure fallback
     (full repair-from-backup, real UKI regeneration, real boot-entry
     writes) — see `shani-deploy/AGENTS.md`'s matching entry for the full
     story of what this harness fix was needed to prove.

- **New: real host-display forwarding (X11 and Wayland) into `test-env`
  containers, replacing the need for a separate headless compositor for
  GUI verification (2026-09-19).** The existing `desktop` command's
  `gnome-shell --headless --virtual-monitor=...` approach has a genuine
  GTK3/Wayland client compatibility gap: a real client (`yad`) connects
  to the compositor socket and gets partway through real protocol setup
  (cursor theme buffer creation) before failing or crashing the whole
  compositor — root-caused to this image's broken nvidia EGL vendor file
  (`10_nvidia.json` sorts before `50_mesa.json` in
  `/usr/share/glvnd/egl_vendor.d/`, and `systemd-fstab-generator`-style
  container detection makes things worse, not better, here) even after
  forcing `__EGL_VENDOR_LIBRARY_FILENAMES` to mesa's explicitly. The fix
  isn't to keep patching that path — it's to not need it at all: bind the
  HOST's real X11 socket (`/tmp/.X11-unix`) or Wayland socket
  (`$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`, just the one file, not the whole
  runtime dir) through both the Docker layer (`run_in_container.sh`'s new
  `X11_FORWARD_ARGS`/`WAYLAND_FORWARD_ARGS`, conditional on the host
  actually having one set) and the nspawn layer (`test.sh`'s new
  `X11_BIND`/`WAYLAND_BIND` in `_nspawn_binds()`, wired into both
  `NSPAWN_ENTER_ARGS` and `NSPAWN_FULL_BOOT_ARGS`) — this is the standard,
  long-established way to run a container GUI app on the host's real
  display (see e.g. systemd/systemd#12671), needs no GPU/EGL for a plain
  2D dialog, and required no changes to any real (non-test) code at all.
  Requires the host to have run `xhost +local:` beforehand for X11 (not
  done automatically — a host-wide access-control change, not this
  script's call to make). Verified end-to-end: a real `yad` dialog
  rendered and was captured via `import -window root` (ImageMagick,
  already in the image) into a file bound out through the existing
  `SHANIOS_TEST_EXTRA_BINDS` mechanism — this is what caught the real
  `--image-on-top` bug documented in `shani-deploy/AGENTS.md` (impossible
  to find by reading `show_dialog()`'s source; it looked completely
  correct until an actual dialog was actually rendered).

- **MOK private key in base image (Critical) — re-verified present
  2026-09-18.** `scripts/build-base-image.sh:179` (line number shifted,
  behavior unchanged) still does
  `install -m 600 "${MOK_DIR}/MOK.key" "$secureboot_target/MOK.key"` — by
  design, needs human architecture decision. Not touched this session.
- **Real MOK private key reachable in git history (Critical) — re-verified
  present 2026-09-18.** Confirmed both `16c6f3a` and `458b442` still
  contain a `mok/MOK.key` blob (`git show <sha> --stat`), and neither
  commit has been rewritten out of history. Two distinct RSA PEM private
  keys, later deleted in `6bb7045` but still fully retrievable via
  `git log --all -p`. Treat both keys as burned; rotation/history-rewrite
  is a human decision — not touched this session.
- **`%no-protection` GPG key generation — re-checked 2026-09-18, appears
  RESOLVED but unconfirmed for the currently-deployed key.**
  `keys/create-gpg-keys.sh` no longer contains any `%no-protection` batch
  directive — it now *requires* an interactively-entered passphrase (no
  empty-passphrase path exists for GPG, unlike the SSH script below) before
  generating a key. This contradicts the line-79 reference this section
  used to cite (the file has changed since). Not independently verified
  whether the specific GPG key currently in production use
  (`GPG_KEY_ID=7B927BFFD4A9EAAA8B666B77DE217F3DA8014792`, seen live in this
  session's container runs) was itself generated with an older,
  unprotected version of this script — that's a separate historical
  question this session didn't investigate. Human should confirm the live
  key's protection status directly (`gpg --list-secret-keys` shows
  protection algorithm) before downgrading this from "known issue."
- **`SSH_PASSPHRASE=""` (High) — re-verified present 2026-09-18.**
  `keys/create-ssh-keys.sh:127` sets the default to empty; an interactive
  prompt (lines 135-137) can override it, but any non-interactive/headless
  run still gets an unprotected key. Not touched this session.
- **`SigLevel = Never` for non-server profiles — FIXED.** All three of
  `image_profiles/{kiosk,gnome,plasma}/pacman.conf` now read `SigLevel =
  Required DatabaseOptional`, matching cosmic/server — verified with a
  real `pacstrap -p gnome` build under the new setting, not just by
  reading the config. See "Testing pacman.conf/signing changes" below for
  the reusable verification pattern this produced.
- **`promote-stable.sh` connect-timeout config drift — FIXED.** All 7 curl
  calls now honor `config/config.sh`'s `NETWORK_CONNECT_TIMEOUT` (was 6 of
  7 hardcoded).
- **`promote-stable.sh` could never succeed — FIXED 2026-09-24.** It
  required `<image>.zst.packages.txt`; the build publishes
  `<os>-<date>-<profile>.packages.txt` (validate-image.sh has the right
  name), so every promotion aborted on a 404. Also: with `--no-sf` a failed
  R2 upload printed "SUCCESS" (now fatal), and `--expect=<file>` refuses
  unless `latest.txt` names the build shani-testbed's `gate` tested
  (`promote-stable.yml` runs the gate first). Careful when testing it:
  `R2_BUCKET=` empty is reset to `shanios` by the script — run it from a
  scratch copy on a machine with no rclone remote, or it really promotes.
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
- **LICENSE / CHANGELOG.md / CONTRIBUTING.md — CLOSED.** All three
  exist at the repo root and are committed (added in `a32ed96`; verified
  present 2026-09-18). `LICENSE` matches the canonical GPL-3.0 text used
  across the shani ecosystem, so `README.md:775-777`'s reference is now
  accurate.
- **6 profiles:** cosmic, gnome, kiosk, plasma, server, shared.
- **CI status.** 2 workflow files: `build-ami.yml` (Packer AMI builds,
  triggered on pushes touching `packer/**` — runs `packer init`/`packer
  validate templates/`, then a real `packer build` against AWS to produce a
  genuine AMI), and `ai-ci-fixer.yml` (auto-retry on failed builds;
  watches only `Build ShaniOS AMI` — the image/ISO builds live in
  shani-builder). The local build workflows `build-image.yml` and
  `build.yml` were removed 2026-09-20 — both duplicated shani-builder's
  `Build Image and Upload` pipeline (the `build-image.yml` one was a
  keyless duplicate; `build.yml`'s `Container build` step was a silent
  no-op because it never passed `build-type` to the shared workflow, so
  every build step was `skipped`). `notify-telegram.yml` was removed
  2026-09-20 — it was a
  duplicate of shani-builder's (only the default display name differed) and
  the `TELEGRAM_*` secrets it needs live there, not here; use that repo's
  copy for a manual-dispatch notification.
  `build-ami.yml` is a *different* verification path from `test-env`'s local
  loop-disk harness used elsewhere in this file — a `packer` template
  change is only truly verified by this workflow (or a manual
  `packer validate`/`packer build` run), not by `test-env`.
- **20 uncommitted changes at audit time (fact, snapshot only as of
  2026-08-28, not necessarily a problem).**
- **AMI/packer bootstrap soft-failed open on a missing SHA-256 sidecar —
  FIXED (2026-09-18).** `packer/scripts/00-bootstrap-shanios.sh`'s SHA-256
  verification step downloaded `${SHA256_URL}` and, if that curl failed for
  any reason (bad URL, transient network issue, missing sidecar), only
  logged `warn "SHA-256 sidecar not reachable — skipping checksum
  verification"` and continued the AMI build with a completely unverified
  base image — the exact soft-fail-open pattern this file's own "Supply-chain
  discipline" section above warns has been a real, shipped bug on this
  path before. GPG verification (below it) is independently fail-closed
  when `GPG_PUBLIC_KEY` is set, but that variable is optional, so a
  transient sidecar-fetch failure with no GPG key configured meant zero
  integrity verification, silently. Since `build-base-image.sh` always
  writes a `.sha256` sidecar next to every published base image, an
  unreachable sidecar here means something is genuinely wrong. Changed the
  `warn`+continue to `die`, matching `scripts/build-iso.sh`'s existing
  hard-failure policy for the same class of check. Not yet re-verified with
  a live `packer build` (that requires AWS credentials/`build-ami.yml` CI,
  out of scope for the local `test-env` harness used elsewhere in this
  file) — verified with `bash -n` and a manual read of the control flow
  only; a human should confirm with a real `packer validate`/`packer build`
  run before treating this as fully proven.

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
