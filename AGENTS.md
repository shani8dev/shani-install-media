# Agent instructions — shani-install-media

This file applies to any AI coding assistant working in this repository
(Claude Code, opencode, Kilo Code, Cursor, Aider, or similar). Read this
before editing, and follow the verification steps before calling any change
done.

## Start here (fast path)

This file covers both the rules for changing build/boot logic and a dated
record of every defect found here. Read what your change touches; don't
page through the rest.

**Always read these first:**
- `What this repo is` and `Empirical verification (mandatory)`
- `Environment facts that affect what you can test here` — KVM, caches, and
  what can/can't be tested on this host
- `Required verification for a change to build/boot logic`
- `MANDATORY: Full Test Harness Sequence (non-negotiable)` — not skippable
- `Boundaries`
- `Cross-repo impact — check before calling a fix complete`

**Read when your change touches them:**
- `Testing shani-deploy/gen-efi changes for real`
- `Testing pacman.conf/signing changes` (the `cmd_pacstrap` section)
- `Verifying GUI/desktop changes` and the automated `gui` harness
- the install.sh/configure.sh section (sibling `os-installer-config`)
- `Supply-chain discipline`
- `Host-side fix:` (`run_in_container.sh`)

**Current known issues — read this before you start:**
- `Audit-verified known issues (confirmed present)` — ~386 lines. **Grep it
  for the subsystem you are changing.** Per-bug
  verification methodology lives in `AUDIT-HISTORY.md`.

  This section mixes fixed history with issues that are **still open**,
  including Critical security ones. Grep it for `not fixed`,
  `still open`, and your subsystem name before you touch anything.

**Background reference — skippable, pure survey material:**
- `Before claiming a package/service is "missing"` — a diagnostic checklist
  worth reading whenever something looks absent, since it is a known trap.

**Never skip:** the full harness. A build that "looks right" is not a booted
image.

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

## Test harness: shani-testbed (use it - and improve it, never invent around it)

The ecosystem's real test harness is the sibling repo **`../shani-testbed`**
(read its `README.md` and `AGENTS.md`). It installs a real ShaniOS image with
the real installer, boots its slots (`systemd-nspawn`, and UEFI + TPM VMs),
runs real deploys and rollbacks, drives GUI apps through their accessibility
tree, and checks web pages in a real headless browser. Every command runs from
`../shani-install-media`, which provides the builder container:

```bash
cd ../shani-install-media
./run_in_container.sh build.sh test <command> ...   # `... test help` lists them all
```

**If the check you need does not exist, add it to shani-testbed - do not invent
around it.** A one-off script in this repo, a scratchpad, or a heredoc piped
into a container is lost when the session ends, and the next agent re-derives
it. Extend the harness instead (see "Extend the harness" in its AGENTS.md):

- an in-slot check -> `shani-testbed/slot-tests/<name>.sh` (`# slot-test-mode: boot`,
  prints `RESULT <name> PASS|FAIL|SKIP` lines), run by `slot-test <slot> <name>`;
- a GUI interaction or assertion -> an `app` action in `lib/app.sh`, or a walk
  through a real app as `app-scripts/<app>.actions`;
- a web check -> `lib/web_client.py`;
- a new way to boot, drive or observe -> a command or option in `lib/`;

each with a negative control (a check that cannot fail is not a check), its
self-test (`tests/run-app-actions.sh`, `tests/run-web-client.sh`, ...), and the
`usage` + README updated. One harness run at a time: disk-touching commands
take `disk/.testbed.lock` and a second run is refused. Plain nspawn boots see
the image's whole `/var`; real boots have an empty tmpfs `/var`
(`systemd.volatile=state`) - use `slot-test --volatile`, or a real UEFI boot
with `iso-install --boot-only --console-exec=CMD`, for anything touching `/var`.

### What to run for this repo

- The mandatory sequence is above. Also: `slot-test <slot> all` and, for
  anything touching `/var`, `slot-test <slot> service-start unit-verify --volatile`;
  `slot-diff` to see what an image change does to a machine; `desktop <slot> --tour`
  for desktop/theme changes; `iso-install --boot-only --console-exec=...` for a
  real UEFI + TPM boot of whatever `install.img` holds.

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
- **`cache/pacman_cache/` is a ~6.0G pacman package cache (4343 files) and the
  largest in the workspace — reuse it, and know it is not private to this
  repo.** `run_in_container.sh` already mounts it at `/var/cache/pacman`, so
  every `./run_in_container.sh build.sh test …` run installs from it. It
  covers the full KDE Plasma stack (`kwin`, `plasma-workspace`,
  `plasma-desktop`, `dolphin`, `konsole`, `yakuake`, `kvantum`, `breeze-gtk`,
  `kde-gtk-config`) plus `xorg-server-xvfb`, `xdotool`, `imagemagick` and
  `fish`. The sibling `shani-pkgbuilds/cache/pacman_cache/pkg` (~3.2G) is
  complementary — this one has `xorg-server-xvfb`/`xdotool` and that one does
  not, so **mount both** when some other harness needs the union (symlink the
  two `pkg/` dirs together; do not copy). Measured 2026-09-26: mounting the
  caches cut a from-scratch Plasma install from ~2G of downloads to 681 MiB.
  Anything that runs `pacman -S` in an ad-hoc container should mount it too.
- When verifying changes here, run the whole `suite`/harness sequence in
  **one** container invocation rather than one per step, and mount any output
  path you want to keep — a `--rm` container discards whatever it wrote to
  its own `/tmp`.

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

- **All six profile package lists resolve cleanly against the live repos —
  VERIFIED (2026-10-06), closing the last standing verification gap.** The
  `server` profile had never been resolved at all: CI only builds gnome/plasma,
  there is no server image in `cache/output/`, and the only server check in
  history was a one-off for the two packages removed in 2026-09-23. Resolved
  every profile against its own `pacman.conf` in the builder container:
  gnome 1066, plasma 1185, cosmic 1007, kiosk 578, server 336, gamescope 732 —
  **0 unresolvable in all six.**
  **Two ways to run this that both silently lie, both hit while producing
  this result — worth knowing before trusting any "profile resolves" claim:**
  **(a)** `pacman --dbpath <tmp> -Sp` reports *every* package as
  `target not found`, `base` included. `SyncDbs` defaults to `$DBPath/sync`, so
  the override leaves it pointing at an empty directory (measured: 0 sync dbs
  under the override vs 3 in the image). The resolve is read-only, so just omit
  `--dbpath`. This is the invocation this file previously recorded as the
  verification method; it is corrected in place below.
  **(b)** Omitting `pacman -Sy` first reports `target not found: shani-core` on
  all five desktop profiles, because the builder image's sync dbs predate
  anything published since it was built — the same trap
  `scripts/check-pacman-cache.sh` handles internally.

- **`run_in_container.sh` forwarded only an explicit list of variables, so four
  environment variables the build scripts read were silently ignored -
  FIXED (2026-10-06, `ee6285d` + `e17b8d3`).** Found by auditing every
  `${VAR:-}` read by `build.sh` / `scripts/*.sh` against the forwarding list,
  after `FLATPAK_IMG_SIZE_GIB` turned out to be documented but dead. Three more
  in that class, of two different severities:
  **`CUSTOM_MIRROR_BASE_URL` / `CUSTOM_GPG_KEY_ID`** — the OEM/private-mirror
  injection in `build-base-image.sh` (rewrites the image's `shani-deploy`
  `R2_BASE_URL` and `GPG_KEY_ID` constants). These are **env-only**: there is no
  `getopts` flag for them anywhere, so with no forwarding the feature was
  completely unreachable through `run_in_container.sh`.
  **`BRANCH` / `SHANIOS_CHANNEL`** — `build-base-image.sh` resolves
  `BRANCH="${BRANCH:-${SHANIOS_CHANNEL:-stable}}"`, so `BRANCH=unstable` on the
  host arrived as unset and the build silently produced a **stable** image.
  This one is worse than a dead knob: the artifact is correctly signed and looks
  entirely fine, and `BRANCH` also feeds `compute_variant_name()`, so the wrong
  per-channel cache entry gets written. The `-b` flag *does* work (args are
  passed through), which is what made this easy to miss — the flag path and the
  env path disagreed and only one of them did anything.
  All four default to empty when unset and the scripts use `:-` defaults, so
  unset behaviour is unchanged.
  **Worth reusing as a habit:** when adding a knob to a build script, confirm it
  survives `run_in_container.sh`. A variable set in the host shell but not in
  that forwarding list is not "ignored" in any visible way — the build proceeds
  and produces a plausible wrong result. The cheapest check is the one that
  caught these: `VAR=x ./run_in_container.sh /bin/bash -c 'echo $VAR'`.

- **The snap layer was skipped in TWO places, and fixing only one would have
  left CI broken - FIXED (2026-10-06, `266adca` + `cff2a17`).** Same root cause
  twice, and the order matters if you are reading this to work on it:
  **(1)** `build-snap-image.sh` looked for
  `image_profiles/<profile>/snap-packages.txt`, which no profile has - the list
  is at `image_profiles/shared/snap-packages.txt`. It printed `No Snap package
  list ... Exiting...` and `exit 0`. **(2)** `build.sh`'s `full` **and
  `iso-release` branches each gate on the same profile-local path before
  calling the builder at all**, so the script in (1) was never invoked. Fixing
  only the script leaves both compound commands still skipping the build.
  Checked across all six profiles: the old gate resolves `SKIP` for every one,
  the new gate `BUILD` for every one.
  **Why it stayed invisible:** `build-iso.sh` genuinely treats the layer as
  optional and logs `No snapfs.zst for profile '<p>' - skipping.` at INFO, and
  the old gate logged `No snap-packages.txt ... skipping Snap build.` also at
  INFO. Every log line said "skipping", which reads as a decision rather than
  as a file being looked for in the wrong directory, and a no-op exits 0 so CI
  stayed green.
  **This is the part to carry forward:** when a builder script tolerates a
  missing input, check whether its *caller* also gates on that input - the two
  gates can disagree, and fixing the inner one then looks like a complete fix
  while the outer one still never calls it. `iso-release` is the task
  `build-image.yml` runs on ISO weeks, specifically to wrap the gated stable
  image in these layers, so the release ISO shipped without a snap layer too.

- **`build.sh flatpak -p plasma` could not build its layer at all: 13,847 MiB
  of data into a 13,824 MiB budget - FIXED (2026-10-06).** The size pre-flight
  in `build-flatpak-image.sh` aborted plasma's Flatpak image with
  `Flatpak data (13847 MiB) exceeds 90% of the 15 GiB image budget
  (13824 MiB)` — over by **23 MiB**. gnome (41 apps) fitted; plasma's 45 did
  not, so the layer was buildable for one profile and not the other, with
  nothing in the pipeline reporting that asymmetry. Raised 15 -> 20 GiB rather
  than trimming a curated app list for 23 MiB: the image is a sparse Btrfs
  subvolume, so headroom costs nothing on disk and does not inflate the
  artifact (gnome's `flatpakfs.zst` is 1.5 GB out of a 15 GiB image).
  Overridable via `FLATPAK_IMG_SIZE_GIB`.
  **The size was also spelled twice and could drift** — the byte computation at
  the pre-flight and a literal `"15G"` passed to `setup_btrfs_image` 30 lines
  later — so both now derive from one `FLATPAK_IMG_SIZE_GIB` constant. That
  second half is what would have made the fix silently not apply to the image
  actually created.
  Diagnosed rather than assumed: first confirmed there were **no leaked apps**
  from another profile (40 installed vs plasma's 45; the 5 differences are
  runtimes/extensions, which `flatpak list --app` does not show) and that
  `flatpak uninstall` had in fact succeeded for apps **despite** the
  `dbus-launch --autolaunch ... exited with code 1` errors in the log — so the
  overrun was genuine data, not residue. `build.sh iso` logs
  `No flatpakfs.zst for profile '<p>' - skipping.` as INFO, which is what made
  both this and the snap no-op below invisible at the point of use.

- **`build.sh snap` was a silent no-op for EVERY profile — FIXED
  (2026-10-06).** `build-snap-image.sh` looked for
  `image_profiles/<profile>/snap-packages.txt`. **No profile has one** — the
  list lives at `image_profiles/shared/snap-packages.txt`, and nothing in the
  repo referenced that path. So the script printed `No Snap package list at
  ... Exiting...` and `exit 0`. Because a no-op is a success: CI stayed green,
  `build.sh full` and `iso-release` reported a completed pipeline, and **every
  ISO shipped with no snap layer, on every profile**. The snap layer only
  looked optional because `build-iso.sh` genuinely treats it as optional
  (`No snapfs.zst for profile '<p>' — skipping`), which is what made the
  absence invisible at the point of use. Now falls back to the shared list
  (a per-profile list still wins, so a profile can diverge), and the genuinely
  empty case warns instead of logging an informational "Exiting..." that read
  like a finished build. Verified live: before, `snap -p gnome` printed
  "No Snap package list ... Exiting..." and produced no file; after, it uses
  the shared list and reports **"Contains: 7 snaps with assertions"**,
  producing a 536 MB `snapfs.zst` with sha256 `OK` and a Good GPG signature.
  **The transferable lesson, and the reason this was findable at all:** a
  layer that consumers treat as optional must never be *produced* by a path
  that no-ops successfully. Check that every "optional" input is actually
  present before trusting an ISO/artifact that a log calls complete.

- **The base-image cache guard hashed only the package lists - FIXED
  (2026-10-06).** `build-base-image.sh` decided "the base is unchanged, skip the
  rebuild" by hashing the three `Packages-*` text files and nothing else, so it
  was structurally blind to every other input that determines the base. Two real
  consequences, both hit in one session:
  **(a) a rebuilt builder image was invisible to it.** `:latest` is re-pulled on
  every run, so the base is assembled by whatever the tag resolved to while the
  guard still reported "unchanged" and skipped - leaving a base built by an
  older builder in place and reporting success. Verified live: gnome skipped
  with "Package list unchanged" immediately after a brand-new builder image was
  published. **(b) a package that vanished from a repo was invisible to it** -
  the lists still name it and the cached base "matches", but a fresh build could
  not have succeeded. That is exactly how `shani-core` went missing from the
  pacman db while every profile's `Packages-Base` still listed it (`target not
  found: shani-core` killed both image builds): the guard matched, and skipped a
  build that would have failed. The key now also covers the profile's
  `pacman.conf` and the builder image's **resolved image ID** (not the tag -
  the tag is mutable and re-pulled every run, so hashing it would defeat the
  cache on a no-op pull); `run_in_container.sh` resolves that ID and passes it
  as `-e BUILDER_IMAGE_ID`. The skip log now states what the guard still
  cannot detect (upstream versions moving, a package disappearing) rather than
  implying coverage it lacks. Verified by before/after on the real repo, with a
  negative control (identical inputs still hash equal; the old formula provably
  returns one value for two different builder image IDs - the bug reproduced).

- **A silently corrupted package in the shared pacman cache killed a 40-minute
  image build - FIXED (2026-10-06).** `plasma6-applets-window-title-0.9.0-2-any`
  and `plasma-setup-git-0.1.0-2-x86_64` were truncated inside their zstd frame,
  and plasma's `pacstrap` aborted at the very end with `failed to commit
  transaction (invalid or corrupted package)` after downloading and unpacking
  1475 packages. **The important part is what did not catch them:** `zstd -t`
  **PASSES** (the frame is well-formed) and `tar -tf` **PASSES** (the stream
  lists cleanly). The truncation was inside a valid frame whose payload is
  short, so every decompress-based check - the one you reach for first - calls
  those files fine; only comparing bytes against the repo's `%SHA256SUM%` sees
  it. `scripts/check-pacman-cache.sh` does that comparison for the exact
  versions `pacstrap` would install, and `build-base-image.sh` runs it *before*
  the install so this costs seconds instead of 40 minutes. It is advisory, not
  fatal: the cache is shared with `shani-pkgbuilds`, so deleting from it is not
  this script's call. Two things it learned the hard way, both load-bearing:
  expected hashes must come from the sync databases' `%SHA256SUM%` fields and
  **not** `pacman -Si`, because **pacman 7 prints no checksum field at all**
  (`Validated By : SHA-256 Sum  Signature` and no hash) - a checker built on it
  compares nothing and reports success forever, the same shape as a check that
  cannot fail, which is what the first version did. And it must `pacman -Sy`
  first: verified live, against the builder image's stale db it reported "1
  requested package is in NO configured repo" for `shani-core`, which is
  published and installed - a stale db yields false alarms, and in the mirrored
  case a false all-clear. Indexing extracts each sync db once rather than
  running one `bsdtar` per package (~1500 spawns, >15 min, slow enough to have
  been killed mid-check); it now takes ~2s.

- **Package-shipped `/var` directories did not exist at runtime - FIXED in the
  build, pending the next image (2026-10-01).** `/var` is an empty tmpfs on
  every boot (`systemd.volatile=state`) and the persistent `/data/varlib/<svc>`
  bind sources and `@libvirt`/`@snapd`/... subvolumes start empty, so a
  directory a package ships under `/var` only exists if a tmpfiles.d line
  creates it - and most Arch packages ship none. On a fresh install (real
  UEFI boot of the published 20260925 image): `smb`, `nmb`, `winbind`
  (no `/var/lib/samba/private`), `rpc-statd` (no `/var/lib/nfs/statd`),
  `libvirtd` (via `virt-secret-init-encryption`) and **`apparmor.service`**
  (the snap-confine profile includes `/var/lib/snapd/apparmor/snap-confine`,
  so *no* profile loaded) all failed. `scripts/gen-var-tmpfiles.sh`, run by
  `build-base-image.sh` after overlays + customizations, writes
  `/usr/lib/tmpfiles.d/shanios-package-var.conf` from pacman's own per-package
  mtree (the package's mode and owner; `:` prefixes so existing persistent
  state is never re-chmodded; paths any other tmpfiles.d file declares are
  skipped). Verified: in an Arch container against samba/nfs-utils/libvirt
  (modes match the packages, `:` leaves an existing dir alone, no duplicate
  warnings), and on a real UEFI boot of 20260925 with the generated file
  applied (132 entries) - all six services active. Found by shani-testbed's
  `config-validators`/`service-start` slot-tests; real-boot fidelity needs
  `slot-test --volatile` or `iso-install --boot-only --console-exec`. Until an
  image built with this ships, installed machines still have the failures.

**For the full narrative, verification methodology, and before/after
evidence behind every line below, see `AUDIT-HISTORY.md`.** This section
is deliberately just the current-state summary.

- **Install hooks that shell out to `grep`/`awk`/`vercmp` fail during the
  single-transaction `pacstrap`, and it is harmless — confirmed present,
  benign (2026-09-27).** `build-base-image.sh:202` installs
  `Packages-Base` + `Packages-Desktop` + `Packages-Extras` in ONE
  `pacstrap` call, and alpm runs each package's `.INSTALL` immediately
  after unpacking that package. A hook that calls a tool from a package not
  yet unpacked finds nothing on the target's disk. Reproduced against a real
  `pacstrap -p gnome` with the full package list: 10 failures, and
  `pacstrap` still exits 0. Mapped to the owning hook, all ten:

  | package | hook | missing |
  |---|---|---|
  | systemd | `.INSTALL:22` | `grep` |
  | fontconfig | `.INSTALL:2` | `vercmp` (ships with pacman) |
  | fish | `.INSTALL:2,3` | `grep` |
  | zsh | `.INSTALL:4,5` | `grep` |
  | shani-settings | `plymouth-set-default-theme:299` | `grep` |
  | shani-settings | `.INSTALL:10,12` | `grep` |
  | shani-settings | `.INSTALL:16` | `awk` |

  **They are non-fatal and silently degrading, not aborting.** For
  `shani-settings` all three lines still ran — `.INSTALL` does not run under
  `errexit` — so the log shows three separate errors rather than one abort,
  and the script continues to its next statement. Reading the actual lines:

  - `systemd:22` is `grep -qe '^/usr/bin/systemd-home-fallback-shell$' etc/shells`
    guarding an append, so the consequence is that `/etc/shells` ends up
    without `systemd-home-fallback-shell`. That entry only matters to
    `systemd-homed`, which Shanios does not use.
  - `fontconfig:2` is a `vercmp` version comparison for the font cache;
    nothing is lost, because that is not what populates the cache.
  - `shani-settings.install:10,12,16` read `UID_MIN`/`UID_MAX` out of
    `/etc/login.defs` with `grep` and filter `/etc/passwd` with `awk`, to
    feed the `usermod -a -G sambashare` loop. With both empty the user list
    is never computed, so **no account is added to `sambashare` during the
    initial install**. Harmless *at first install specifically*, because a
    fresh image has no regular accounts yet — users are created later by
    `os-installer-config/configure.sh` — and on any real upgrade `grep` and
    `awk` are long since on disk, so the hook does its job. The case that
    would genuinely matter is re-running that hook on a populated system
    from a root that really lacks `grep`/`awk`, which is not how this image
    is built.

  **Do not "fix" this by patching the individual hooks.** The real shape of
  the problem is that one transaction cannot guarantee hook ordering. If it
  ever does matter, the fix is to split the install so the packages
  providing hook tools land first — not to edit five `.install` files.
  Fixing `shani-settings.install` alone would also be wrong: it would mask
  the same class for the next package that needs a tool later in the list.

  **Verification note for anyone repeating this.** The target directory
  must be on an **exec-capable** mount. A first attempt into `/tmp`
  produced 97 `call to execv failed (Permission denied)` errors — a
  completely different signature, caused by the container's own root being
  `noexec`, not by anything in Shanios. On the exec-capable bind mount the
  same install shows 0 execv failures and only the 10 real ones above. Note
  also that `cmd_pacstrap` now honours extra package names (fixed in
  `shani-testbed`; this file's note on that was stale until 2026-10-06), so
  `pacstrap -p <profile> <packages...>` CAN drive that reproduction directly
  instead of concatenating the profile list by hand.

- **Server profile could never build: `Packages-Extras` listed two packages
  no configured repo has — FIXED (2026-09-23).** `amazon-ssm-agent` is
  AUR-only (stale 3.1.x) and `amazon-ec2-utils` isn't in the AUR at all;
  neither is in `[shani]`/`[core]`/`[extra]`, the only repos
  `image_profiles/server/pacman.conf` configures. `build-base-image.sh`
  installs Base+Desktop+Extras in ONE `pacstrap` call, so "target not
  found" killed every server build (added in `a4a4170`, 2026-09-18; CI only
  builds gnome/plasma, and there is no server image in `cache/output/`).
  Verified with a real resolve against the live repos using the server
  `pacman.conf` in the builder container, over the list filtered exactly as
  `build-base-image.sh` filters it: before, `error: target not found` for both;
  after, rc=0 with 563 packages resolved. **Correction to how that check was
  run, re-verified 2026-10-06: the invocation recorded here as
  `pacman --dbpath <tmp> -Sp` cannot work and always reports EVERY package as
  `target not found` — including `base`.** `SyncDbs` defaults to
  `$DBPath/sync`, so overriding `--dbpath` leaves it pointing at an empty
  directory (measured: 0 sync dbs under the override vs 3 in the image), and
  pacman then has no metadata for anything. Run it **without** `--dbpath`; the
  resolve is read-only anyway:

  ```bash
  # inside run_in_container.sh, after `pacman -Sy`
  pkgs=$(cat image_profiles/<p>/Packages-{Base,Desktop,Extras} \
         | grep -v '^[[:space:]]*#' | tr -d '\r' | grep -v '^[[:space:]]*$')
  pacman --config image_profiles/<p>/pacman.conf -Sp $pkgs
  ```

  `pacman -Sy` first is equally load-bearing: the builder image's sync dbs
  predate anything published since it was built, so a resolve without it
  reports `target not found: shani-core` on every desktop profile even when
  the package is published (measured 2026-10-06, before syncing; 0 after).
  Both were removed with a comment; `server-customization.sh` and
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
  boots use `shani-testbed/lib/vmspawn.sh` (path corrected 2026-10-06 — it
  lived at `test-env/vmspawn.sh` until the harness split; `test-env/test.sh`
  itself is only a shim that execs `../shani-testbed/testbed`, and
  `test-env/README.md` is the shim-era copy), which keeps its
  overlay/NVRAM/TPM inside a throwaway container. Also: an agent this session listed/read
  under `test-env/disk/` and `cache/` despite the rule below; no harm, but
  don't repeat it.
- **`cmd_pacstrap` ignores extra package names — FIXED in shani-testbed, and
  this note was STALE until 2026-10-06.** It was originally a real harness bug
  (2026-09-23): `cmd_pacstrap` hard-coded `pacstrap -cC "$conf" "$target"
  base` while this file and `test-env/README.md` both documented
  `pacstrap -p <profile> [extra-pkg ...]`, so the documented extra-package slice
  was silently never installed. **The fix landed with the testbed split
  (`shani-testbed` `0b6e2e1`) and this entry was never updated to match** — so
  for months this file has told readers the feature was broken, and the entry
  above still warns that the hook-failure reproduction "cannot" use it.
  Verified working live, not assumed: `build.sh test pacstrap -p gnome
  shani-core flatpak` logs `Extra packages: shani-core flatpak` and then
  `pacstrap OK — real packages installed and signature-verified`. Extra
  packages are now honoured, so that reproduction path is available again.
  **The real lesson is the cross-repo drift:** `shani-testbed` was split out of
  `shani-install-media/test-env/` and carries its own `AGENTS.md`, but fixes
  made in the new home were not reflected back in the old file's records.
  When checking a "known issue" here, confirm against the code in
  `shani-testbed/lib/` before trusting that it is still open.

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
