# test-env — install / boot / update / rollback a built image

This is a *piece* of the build pipeline, not a separate tool bolted on next
to it: it installs, boots, updates, and rolls back a real Shani OS image or
ISO **built by this repo** (`./build.sh`), on loop-mounted disks — without
needing a spare machine or a real UEFI install. It's invoked the exact same
way as every other operation in this repo:

```bash
./run_in_container.sh build.sh test <command> [options]
```

There is no separate `test-env/run_in_container.sh` or `test-env/Dockerfile`.
This reuses the **same** `../run_in_container.sh` wrapper and the **same**
published builder image (`docker.io/shrinivasvkumbhar/shani-builder`) as
`./build.sh image`, `./build.sh iso`, etc. — the same Arch base the actual
built OS uses, already carrying `btrfs-progs`, `systemd` (which is where
`systemd-nspawn` comes from), `util-linux`, `mtools`. That wrapper already
bind-mounts the whole repo and sets every privilege flag (`--privileged`,
`--cap-add SYS_ADMIN`, `-v /sys/fs/cgroup:ro`, `-v /lib/modules:ro`, ...) this
needs — nothing extra to build or maintain.

Every script here also `source`s the repo's own `config/config.sh` — the
same file `build-base-image.sh`/`build-iso.sh`/`upload.sh` use — and reuses
its `log`/`warn`/`die`, `OUTPUT_DIR`, `OS_NAME`, and even `setup_btrfs_image()`
(the exact helper `build-base-image.sh` uses for `base.img`, reused here
verbatim for `root.img`). `config.sh` gained one new function for this,
`check_dependencies_test()`, alongside its three existing
`check_dependencies*` variants — same pattern, not a parallel one.

This lives in `shani-install-media` (not `shani-deploy`) because it's a test
ground for **this repo's build output** — the `.zst` image and, eventually,
the ISO — not a home for the deploy/update scripts themselves. `shani-deploy`
ships as a real pacman package baked into every profile image (see
`image_profiles/*/package-list.txt`); this harness exercises exactly that
packaged binary, unmodified, from inside a real received image. Nothing here
vendors or patches `shani-deploy`/`shani-update`/`gen-efi`.

## What it does

`build.sh test <command>` (its dispatch table just execs `test-env/test.sh`,
same as every other `build.sh` subcommand execs a script under `scripts/`).
The entire rig is this one file — every command is a function called
directly by the dispatcher at the bottom:

| `build.sh test` command | Implemented by | What it does |
|---|---|---|
| `disk` | `test.sh`'s `cmd_disk` | Creates two sparse loop-backed images standing in for the real GPT disk (`esp.img` FAT32, `root.img` Btrfs — see `os-installer-config/bits/part.sfdisk`). A faster, fabricate-only pair — **`bootstrap` no longer uses this** (it creates its own `install.img` via the real `install.sh` instead); only relevant if you specifically want a pre-partitioned pair for something else. Both images are created **empty** and nothing in the supported install+configure/bootstrap flow ever populates them — `qemu`/`gui` fall back to this pair (with a warning) only when `install.img` is absent, and `iso` attaches it as a blank install target. Auto-installs `dosfstools` first if `mkfs.fat` is missing from the builder image — see "Requirements" below. Self-heals stale/duplicate loop-device attachments left over from a previous `run_in_container.sh` session before recreating both images — see "Loop-device robustness" below |
| `ca [extra-host ...]` | `test.sh`'s `cmd_ca` | Generates a throwaway CA + a leaf cert for `downloads.shani.dev`, plus one more per extra hostname given — see "The local mirror" below |
| `bootstrap -p <profile> [-d latest\|stable\|<date>] [--encrypted]` | `test.sh`'s `cmd_bootstrap` | Runs the REAL `install.sh`+`configure.sh` (calls `cmd_install`/`cmd_configure` directly — real partitioning, optional LUKS, Btrfs subvolumes, image extraction, UKI generation/signing, boot-entry write), then one genuinely test-only step: trust-anchoring this session's throwaway CA into both `@blue`/`@green` slots. Requires `ca` to have been run first. As a side effect of its real install+configure pass it produces `disk/install.img` — the bootable whole-disk image `qemu`/`gui` prefer |
| `serve [port] [docroot] [cert-host]` | `test.sh`'s `cmd_serve` | Serves a docroot (default `OUTPUT_DIR`) as-is over real HTTPS as a stand-in for a CA'd hostname (default `downloads.shani.dev`) — see "The local mirror" below for standing up a second instance for a second hostname |
| `enter <blue\|green> [--boot] [--local-src=<dir>]` | `test.sh`'s `cmd_enter` | Enters a slot via `systemd-nspawn`, looking exactly like a booted ShaniOS system to `shani-deploy`/`shani-update`. `--local-src=/opt/shani-deploy/scripts` overlays the sibling `shani-deploy` checkout's CURRENT scripts (and its `systemd/{system,user}/` units) over the package-installed ones — see "Testing edited scripts" below |
| `verify-boot [blue\|green] [seconds] [--local-src=<dir>]` | `test.sh`'s `cmd_verifyboot` | Headless boot smoke test: full `systemd --boot`, console captured to `disk/boot-<slot>-console.log`, then reports whether the target/failed units look healthy. No display or TTY needed — CI-friendly. `--local-src` works exactly as it does for `enter` — **use it whenever verifying a unit-file change**, since a bootstrapped image's baked-in units can be stale relative to the repo's current working tree otherwise |
| `install -p <profile> [-d latest\|stable\|<date>] [--encrypted]` | `test.sh`'s `cmd_install` | Runs the REAL, unmodified `os-installer-config/scripts/install.sh` against a fresh whole-disk loop image (partitioning, optional LUKS, Btrfs subvolumes, image extraction) — see "install / configure" below. Writes `disk/install.img` (default 24G, override with `INSTALL_DISK_SIZE`): the only layout `install.sh` can produce (it partitions a whole disk itself) and the only one that's actually bootable via OVMF, since `qemu`/`gui` prefer it |
| `configure -p <profile> [--encrypted]` | `test.sh`'s `cmd_configure` | Runs the REAL, unmodified `os-installer-config/scripts/configure.sh` (locale/hostname/user/Secure Boot/UKI) against `install`'s result — see "install / configure" below. Populates `disk/install.img`'s ESP with the signed UKI and boot entries (`gen-efi.sh`/`finalize_boot_entries`) — what makes `install.img` bootable for `qemu`/`gui` |
| `upgrade [--local-src=<dir>] [extra shani-deploy args]` | `test.sh`'s `cmd_upgrade` | Calls `shani-deploy` **directly** (`--force --channel latest --skip-self-update`) — a real, complete deploy: download, SHA256+GPG verify, extract, `gen-efi` UKI generation/signing, boot-entry write. Does NOT go through `shani-update` (which needs a real display to open its progress terminal) |
| `update-check [--local-src=<dir>] [extra shani-update args]` | `test.sh`'s `cmd_updatecheck` | Exercises `shani-update.sh` **itself**: its GUI-dialog fallback chain (fails over — no display here) then a genuine console-approval prompt, fed `y` via an allocated pty (`script`). Proves shani-update's own dialog/prompt/decision logic; its `shani-deploy` hand-off (and its `--rollback` path) still needs a real display, so this does **not** complete an actual deploy — use `upgrade` for that |
| `reboot` | `test.sh`'s `cmd_reboot` | Re-enters whichever slot `/data/current-slot` now points at |
| `rollback [--local-src=<dir>]` | `test.sh`'s `cmd_rollback` | Calls `shani-deploy --rollback` directly, same direct-call reasoning as `upgrade` — `shani-update`'s `--rollback` also routes through the display-needing terminal wrapper |
| `cycle -p <profile>` | `test.sh`'s inline `cycle` case | `ca` (if missing) → `bootstrap` → `serve` (background) → `upgrade` → `reboot` in one go |
| `qemu [--vnc[=port]]` | `test.sh`'s `cmd_qemu` | A genuine UEFI boot (via OVMF) of the real bootloader/kernel/UKI `shani-deploy` produced — **host-only**, run `test-env/test.sh qemu` directly, not through `build.sh test`. Which image it boots is resolved by `_resolve_qemu_boot_drives` (env `SHANIOS_TEST_QEMU_DISK`, default `auto`): prefers `disk/install.img` (produced by `install`+`configure`/`bootstrap` — the only bootable layout), falling back to the empty `disk/root.img`+`disk/esp.img` pair with a warning. Also wires up a virtio-serial channel for `qemu-guest-agent` (every profile ships it via `shani-video-guest`), matching what a real libvirt-managed VM provides. `--vnc[=port]` (default 5700) serves the real framebuffer over VNC-over-websocket instead of opening a local GTK window — confirmed live: QEMU's own `websocket=` vnc suboption opens both raw VNC (5900) and the websocket bridge, no separate `websockify` needed — open it via `watch`'s Desktop panel, or any VNC client at `localhost:5900` |
| `watch [--port=N]` | `test.sh`'s `cmd_watch` | **Host-only** local dashboard (default `http://127.0.0.1:8090/`) to actually *see* a boot instead of grepping log files afterward: live-tails whichever `*-console.log` is newest (from `desktop` or `verify-boot`), plus a noVNC panel for a `qemu --vnc` session. Pure stdlib `python3 http.server`, nothing leaves `127.0.0.1` |
| `iso -p <profile> [-d latest\|stable\|<date>]` | `test.sh`'s `cmd_iso` | A genuine UEFI boot (via OVMF) of a real, unmodified installer ISO from `OUTPUT_DIR` — **host-only**, run `test-env/test.sh iso -p <profile>` directly. Boots to the real live-installer `systemd-boot` menu; the GUI installer itself is interactive and not automated. `cmd_iso` is the one caller that still uses `disk/root.img`+`disk/esp.img` as blank install targets only — it never resolves them via `_resolve_qemu_boot_drives`, and the empty pair is fine here since the live installer writes its own target |
| `clean` | `test.sh`'s `cmd_clean` | Unmounts everything (nspawn overlays, the ESP, the top-level Btrfs mount) and detaches root.img/esp.img's loop devices. Leaves the images themselves in place |
| `verify` | `test.sh`'s `cmd_verify` | Runs integrity checks against the built image — verifies checksums, signatures, and package consistency |
| `pacstrap -p <profile> [pkg ...]` | `test.sh`'s `cmd_pacstrap` | Real `pacstrap` smoke test against a throwaway root using that profile's actual `image_profiles/<profile>/pacman.conf` — proves the builder's keyring genuinely satisfies that profile's `SigLevel` (e.g. `Required DatabaseOptional`) against real packages and real signatures, not just that the config file parses. Defaults to `base`; pass extra package names to pull in more of a profile's real dependency set (`shani-core`, `flatpak`, `podman`, etc.) for a deeper check. This is the standard way to verify any `pacman.conf`/signing change before trusting it — see "What this does NOT simulate" below for why it's the right layer for that, instead of driving each shipped runtime directly |

**Run `clean` when you're done testing.** Loop-device attachment doesn't
survive across separate `run_in_container.sh` invocations (each is a fresh
`--rm`'d container), so every `disk`/`bootstrap`/`enter`/`cycle` call
re-attaches or reuses root.img/esp.img's loop devices on the *host* —
nothing ever detaches them again on its own. Across a long testing session
this accumulates loop devices indefinitely; only `clean`, a manual
`losetup -d`, or a reboot releases them.

### Disk layouts: `install.img` vs. `root.img`+`esp.img`

Two different disk artifacts live under `test-env/disk/`, and only one of
them is ever actually bootable. `cmd_qemu`/`cmd_gui` resolve which one to
boot through the shared `_resolve_qemu_boot_drives()` helper (env
`SHANIOS_TEST_QEMU_DISK`, default `auto`):

| Image | Created by | Populated by | Bootable via OVMF? | Used by |
|---|---|---|---|---|
| `disk/install.img` (whole disk, default 24G) | `install` | `install` (partitioning, LUKS, subvolumes, extraction) + `configure` (Secure Boot, UKI, boot entries) — i.e. `bootstrap` runs both | **Yes** — the only bootable layout | `qemu`, `gui` (preferred), `bootstrap`/`install`/`configure` themselves |
| `disk/root.img` (Btrfs) + `disk/esp.img` (FAT32) | `disk` — both created **empty** | **Nothing** in the supported flow. `bootstrap` writes straight to the `@blue`/`@green` subvolumes on `root.img` for nspawn testing and never touches the ESP; `install.sh` partitions a whole disk itself so it can only ever produce `install.img` | **No** — booting it lands on firmware PXE, not on shanios | `qemu`/`gui` (fallback only, with a warning, when `install.img` is absent), `iso` (as a blank install target — the live installer writes its own) |

`SHANIOS_TEST_QEMU_DISK=install|root|auto` (default `auto`) pins the choice:
`auto` prefers `install.img` when present and falls back to the empty pair
with a warning; `install`/`root` require the named image(s) and die with a
pointer to the right command if they're missing. `cmd_iso` is the one caller
that bypasses this helper entirely — it always uses `root.img`+`esp.img`,
and only as blank install targets for the live installer.

### Loop-device robustness

The flip side of loop devices persisting across containers: it's possible to
end up with **more than one** loop device attached to the same backing file
at once — e.g. an interrupted `disk`/`enter`/`bootstrap` from an earlier
session, or a second `losetup --find --show` racing the first before
`.root_loop`/`.esp_loop` got written. This used to require noticing
`losetup -a` showing two devices for one image and manually
`losetup -d`-ing the stale one before `disk`/`bootstrap` would work reliably
again. `test.sh` now self-heals this instead:

- `_loops_for_image` / `_detach_all_loops` / `_ensure_single_loop` (shared
  helpers near the top of `test.sh`) detect however many loop devices are
  currently bound to a given image and either detach all of them (`disk`,
  which is about to wipe and reformat the image anyway) or collapse
  duplicates down to exactly one clean attachment and reuse it
  (`_ensure_disk_attached`, used by `bootstrap`/`enter`/`cycle` re-attaching
  to an *existing* image across a fresh container).
- `cmd_disk` calls `_detach_all_loops` on both `root.img` and `esp.img`
  before doing anything else, so a stale or duplicate attachment from a
  previous session is torn down automatically rather than surfacing as a
  confusing "why does `losetup` show two devices for the same file" the next
  time someone runs `disk`.
- `cmd_install`'s whole-disk image (`install.img`, see "install / configure"
  below) gets the same treatment.

Nothing about `/dev/disk/by-label/*` needs separate handling here — it's
always re-`ln -sf`'d to whatever loop device this run just resolved, so a
dangling symlink from a dead loop device is simply overwritten, never left
stale.

### Testing edited scripts

Testing an unreleased fix to `shani-deploy`/`gen-efi`/`shani-update`/
`check-boot-failure` no longer means manually `cp`-ing edited files into a
running `nspawn` session and remembering that it only "sticks" because the
overlay's upper layer persists across `enter` calls. `enter <slot>
--local-src=<dir>` does it as part of entering:

```bash
./run_in_container.sh build.sh test enter blue --local-src=/opt/shani-deploy/scripts
```

`run_in_container.sh` bind-mounts the sibling `shani-deploy` checkout
read-only at `/opt/shani-deploy` (same optional, sibling-dir convention as
`os-installer-config` at `/opt/os-installer-config` — a no-op if that
checkout isn't present; override with `SHANIOS_TEST_DEPLOY_HOST_DIR`), so
`--local-src` always overlays whatever is currently on disk in that
checkout — no separate copy to keep in sync by hand. Don't stage a manual
copy of these scripts anywhere under this repo instead; it will silently
drift from the real checkout the moment either one changes.

Naming convention: `<dir>/<name>.sh`, where `<name>` matches exactly what
`shani-pkgbuilds/shani-deploy/PKGBUILD`'s `package()` installs at
`/usr/local/bin/<name>` (it strips the `.sh` extension at package time) —
so `shani-deploy.sh` overlays `/usr/local/bin/shani-deploy`, `gen-efi.sh`
overlays `/usr/local/bin/gen-efi`, and so on for `shani-update.sh`/
`check-boot-failure.sh`. Any other `*.sh` file is applied the same way if a
same-named file already exists at `/usr/local/bin` in the slot; anything
that doesn't match is skipped with a warning rather than silently ignored.

This lands in the `nspawn` overlay's upper layer — exactly like any other
write made from inside a session — never in `@blue`/`@green` itself and
never in `<dir>` on the host. It's a plain `cp -f`, so running `enter
--local-src=...` again (or against a different slot, or after editing the
source file further) just re-copies: no doubling, no error, nothing to
reset in between.

**Systemd unit files are overlaid too, automatically.** If `<dir>`'s
parent directory has a sibling `systemd/system/` and/or `systemd/user/`
(shani-deploy's actual real layout: `scripts/` and `systemd/` side by
side under the repo root), any `*.service`/`*.timer`/`*.path` file there
whose name already exists under `/usr/lib/systemd/{system,user}` in the
slot gets overlaid the same way — no separate flag needed, passing
`--local-src=.../shani-deploy/scripts` picks up edited units from
`.../shani-deploy/systemd/` for free. This matters because `verify-boot`
and `enter --boot` read units from disk fresh at `--boot` time — a unit
file edit with **no** matching script edit (a new hardening directive, a
changed `Requires=`) previously had no way to be exercised by either
command at all; only a same-day rebuilt image would reflect it. Also
works with `verify-boot` (not just `enter`), added at the same time as
this note.

### One file, no sibling scripts

Everything that used to be a numbered script (`00`–`07`) or a separate
bind-mounted stub is now inside `test.sh` — one file to read top to bottom:

- `cmd_disk`, `cmd_ca`, `cmd_bootstrap`, `cmd_serve`, `cmd_enter`,
  `cmd_upgrade`, `cmd_reboot`, `cmd_rollback` are plain functions, called
  directly by the dispatcher `case` at the bottom.
- `cmd_qemu` (was `07-boot-qemu.sh`) is a function too. It runs on the
  **host**, outside `run_in_container.sh` entirely, so it guards itself with
  `_in_container()` and refuses to boot (with a pointer to the right
  invocation) if you accidentally run it through `build.sh test qemu` inside
  the builder container instead of `test-env/test.sh qemu` directly.
- The `systemd-inhibit` stub — needed because `shani-deploy.sh` calls
  `systemd-inhibit` and there's no logind session inside `nspawn` — used to
  be a standalone file only because it's bind-mounted **by path**
  (`--bind=".../stub:/usr/bin/systemd-inhibit"`). `cmd_enter` now calls
  `_ensure_inhibit_stub`, which writes that file out once to
  `disk/.systemd-inhibit-stub.sh` the first time it's needed, so there's
  still a real file to bind-mount without keeping it checked into the repo.

## The local mirror

`shani-deploy.sh` hardcodes `R2_BASE_URL="https://downloads.shani.dev"` with
no override hook, and this harness deliberately does not patch that (that
would mean testing a modified binary, not what actually ships). Instead:

- `../run_in_container.sh` passes `--add-host=downloads.shani.dev:127.0.0.1`
  on every invocation (a no-op for every command except this one), so the
  domain resolves to the container's own loopback
- `cmd_ca` mints a CA + leaf cert for that exact CN
- `cmd_bootstrap` trust-anchors the CA **inside `@blue`/`@green`**
  (Arch/p11-kit: `trust anchor` + `trust extract-compat`) at receive time
- `cmd_enter` bind-mounts a hosts file into the slot so DNS resolution
  matches, and swaps in the `systemd-inhibit` stub script (there's no
  logind session in a one-shot `nspawn` invocation)

Net effect: the real, unmodified `shani-update`/`shani-deploy` binaries
already inside the received image hit `https://downloads.shani.dev` exactly
as they would in production, and land on `cmd_serve` instead — real
HTTPS, real cert validation, zero code changes anywhere.

The on-disk layout of `OUTPUT_DIR` and the real R2/SourceForge remote are
**identical** (compare `scripts/upload.sh`'s `R2_SUBPATH="${PROFILE}/${RESOLVED_DATE}"`
against `shani-deploy.sh`'s `r2_image_path="${REMOTE_PROFILE}/${REMOTE_VERSION}/${IMAGE_NAME}"`),
so `cmd_serve` serves `OUTPUT_DIR` completely as-is — nothing is
staged, copied, or reshaped.

**Important:** none of this ever touches the original `.zst` or any repo
other than the received `@blue`/`@green` subvolumes on `test-env/disk/root.img`
(persisted on the host, like everything else `../run_in_container.sh` mounts
— re-running `bootstrap` deliberately wipes and re-receives them from
scratch, same as `disk` wipes and recreates both loop images). The CA anchor
is the one deliberate, documented on-disk change made to a received image;
the hosts file and `systemd-inhibit` are bind-mounted in transiently, per
`nspawn` invocation, never written to `@blue`/`@green`.

### Beyond `downloads.shani.dev`: any external host

Some fixes call out to a hardcoded URL that **isn't** `downloads.shani.dev`
— e.g. the self-update path's `raw.githubusercontent.com` — and testing them
used to mean hand-rolling this exact CA/hosts/serve pattern from scratch in a
one-off script (see `test-env/self-update-test.sh`'s own comments for what
that looked like). `cmd_ca` and `cmd_enter` generalize it:

- `cmd_ca [extra-host ...]` mints one more leaf cert per extra hostname,
  signed by the **same** test CA (`downloads.shani.dev` keeps its historical
  `server.crt`/`server.key`; every other host gets `<host>.crt`/`<host>.key`
  under `test-env/disk/ca/`). Since a slot only ever needs to trust the CA
  once (at `bootstrap` time), it automatically trusts every leaf cert minted
  under it afterward too — no additional `bootstrap` or per-host trust step:

  ```bash
  ./run_in_container.sh build.sh test ca raw.githubusercontent.com
  ```

- `cmd_enter` (and `verify-boot`) build the slot's `/etc/hosts` from the
  host's own hosts file plus one `127.0.0.1 <host>` line per extra hostname
  `cmd_ca` has a leaf cert for (`_ensure_test_hosts_file`, scanning
  `test-env/disk/ca/*.crt`) — regenerated on every `enter`, so a host `ca`'d
  after the slot was last entered is picked up on the next one, with no
  manual `/etc/hosts` editing anywhere.

- To serve genuinely different content for the second hostname (rather than
  reusing `OUTPUT_DIR`), run a second, independent `serve` in its own
  session on a different port with that hostname's own docroot/cert-host:

  ```bash
  ./run_in_container.sh build.sh test serve 8443 /some/other/docroot raw.githubusercontent.com &
  ```

  `cmd_serve`'s default arguments (port 443, `OUTPUT_DIR`,
  `downloads.shani.dev`) are unchanged, so every existing call site keeps
  working untouched — `docroot`/`cert-host` are purely additive.

Verified live: a second `serve` instance standing in for
`raw.githubusercontent.com` on port 8443 was reachable from inside `enter`
via plain `curl https://raw.githubusercontent.com:8443/...` — no `--cacert`
needed, since the slot already trusts the whole CA from `bootstrap`.

## install / configure

`cmd_install` and `cmd_configure` run the real, unmodified
`os-installer-config/scripts/install.sh`/`configure.sh`, driven purely by
the `OSI_*` environment variables the real `os-installer` GUI sets — no GUI
involved or needed, same principle as this harness exercising the real
`shani-deploy`/`shani-update` binaries unmodified. **`cmd_bootstrap` now
calls these two directly** (this used to be a separate, faster
fabricate-only path — `btrfs receive` + snapshot + a manual `gen-efi
configure` call, skipping install.sh/configure.sh entirely — since
replaced with real calls to `cmd_install`/`cmd_configure`, plus one
genuinely test-only step: trust-anchoring this session's throwaway CA into
both slots), so `./run_in_container.sh build.sh test bootstrap -p <profile>`
is real install+configure coverage on every run, not just when `install`/
`configure` are invoked directly.

```bash
./run_in_container.sh build.sh test install -p plasma              # or --encrypted
./run_in_container.sh build.sh test configure -p plasma            # match --encrypted if used
```

- **`install`** creates a fresh, blank, loop-backed **whole-disk** image
  (`test-env/disk/install.img`, default 24G, override with
  `INSTALL_DISK_SIZE`) — deliberately **not** `cmd_disk`'s pre-partitioned
  ESP+Btrfs pair, since `install.sh` does its own GPT partitioning via
  `bits/part.sfdisk` (`sfdisk`) against a whole device. `--encrypted` sets
  `OSI_USE_ENCRYPTION=1` and a test LUKS passphrase (default
  `shanios-test-passphrase`, override with `SHANIOS_TEST_LUKS_PIN`);
  omitted, the install is plain unencrypted Btrfs.
- **`configure`** re-attaches `install.img` (works across a separate
  `run_in_container.sh` invocation — same loop/LUKS-persistence principle as
  `root.img`/`esp.img`, see "Loop-device robustness" above) and runs
  `configure.sh` with a realistic `OSI_USER_*`/locale/keyboard/timezone
  environment (`testuser`/"Test User", `en_US.UTF-8`, `UTC`, `us` keyboard —
  every value overridable via `SHANIOS_TEST_OSI_*`, see `test.sh -h`).

Both scripts run **fully unmodified** — every `OSI_DEVICE_*`/`OSI_USER_*`/
`OSI_ENCRYPTION_PIN`/locale variable they read was found by reading
`install.sh`/`configure.sh` in full, not guessed. Getting there against a
loop device instead of real hardware needed a few harness-side
accommodations (documented at length in `test.sh` itself, right above
`cmd_install`/`cmd_configure`):

- `install.sh`'s `ROOTFSZST_SOURCE`/`FLATPAKFS_SOURCE`/`SNAPFS_SOURCE` are
  hardcoded to `/run/archiso/bootmnt/<os>/x86_64/*.zst` (the live ISO's own
  mount point) — `cmd_install` bind-mounts the real files from `OUTPUT_DIR`
  there (a symlink doesn't work: `install.sh`'s `zstd -d` refuses to follow
  one and silently extracts an empty stream instead — confirmed live).
- `install.sh`'s partition-prefix logic only special-cases `nvme*`/`mmcblk*`
  device names; a loop device's real kernel-assigned partitions
  (`/dev/loopNp1`/`p2`) don't match what it computes for anything else
  (`/dev/loopN1`/`N2`) — bridged with compatibility symlinks rather than
  patching the script (`_make_loop_partition_compat`).
- This container has no live `udevd`, so `/dev/disk/by-label/*` (which both
  scripts mount through exclusively) is created by hand
  (`_ensure_install_by_label_symlinks`) instead of relying on one — same
  principle `cmd_disk` already uses for `root.img`/`esp.img`'s labels.
- `configure.sh` calls `hostnamectl`/`localectl`/`timedatectl` from inside a
  plain `chroot` — on a real install this works because the live ISO's own
  already-booted systemd/D-Bus gets `rbind`-mounted into the target along
  with `/run`. `_ensure_systemd_target_services` fakes the same shape here
  (a `/run/systemd/system` marker plus the standalone `systemd-hostnamed`/
  `systemd-localed`/`systemd-timedated` binaries, not a full boot) so those
  calls succeed instead of aborting `configure.sh` outright.

Verified live end-to-end, both encrypted and unencrypted, with independent
inspection afterward (not just reading `configure.sh`'s own success log):
real GPT partitioning + `mkfs.btrfs`/`mkfs.fat`, real subvolume creation,
real `rootfs.zst`+`flatpakfs.zst` extraction, `testuser` present in
`/etc/passwd`/`/etc/shadow` with a password hash and `wheel` membership,
hostname/machine-id/locale/current-slot all set, real `dracut`+`sbsign` UKI
generation — and, for `--encrypted`, the resulting LUKS2 volume rejects the
wrong passphrase and unlocks cleanly with the configured one
(`cryptsetup open --test-passphrase`).

Needs the sibling `os-installer-config` checkout present on the host (next
to this repo, i.e. `../os-installer-config`) — `run_in_container.sh`
bind-mounts it read-only automatically if found (override the host-side path
with `SHANIOS_TEST_OSI_HOST_DIR`, or the in-container path with
`SHANIOS_TEST_OSI_ROOT`). `check_dependencies_install` (config.sh)
auto-installs whatever `install.sh`/`configure.sh` themselves need that the
builder image doesn't already carry (`sudo`, `parted`, `cryptsetup`,
`firewalld`, `dracut`, ...), same pattern as `cmd_disk` auto-installing
`dosfstools`.

## Quick start

```bash
# from the shani-install-media repo root:
./build.sh image -p plasma            # or whatever profile you're testing
./build.sh release -p plasma latest   # writes cache/output/plasma/latest.txt

./run_in_container.sh build.sh test ca
./run_in_container.sh build.sh test bootstrap -p plasma

# in a separate terminal (blocks in the foreground):
./run_in_container.sh build.sh test serve

# after building + releasing a NEWER image to cache/output — calls
# shani-deploy directly for a real, complete deploy (--channel latest by
# default; add --local-src=/opt/shani-deploy/scripts to test your current
# shani-deploy checkout instead of whatever's baked into the image):
./run_in_container.sh build.sh test upgrade
./run_in_container.sh build.sh test reboot
./run_in_container.sh build.sh test rollback   # if you want to test the recovery path

# to exercise shani-update.sh itself (the interactive dialog/prompt layer
# upgrade/rollback skip — see the command table above for what it does and
# does not prove):
./run_in_container.sh build.sh test update-check --local-src=/opt/shani-deploy/scripts

# or all of the above in one go:
./run_in_container.sh build.sh test cycle -p plasma

# the real, unmodified install.sh/configure.sh, driven by OSI_* env vars:
./run_in_container.sh build.sh test install -p plasma
./run_in_container.sh build.sh test configure -p plasma

# on the HOST, not through run_in_container.sh:
test-env/test.sh qemu

# when you're done — releases loop devices, leaves root.img/esp.img in place:
./run_in_container.sh build.sh test clean
```

## What this does NOT simulate

**Container/sandbox runtimes shipped by the OS** (podman, distrobox,
apptainer, lxc/lxd, flatpak, snapd, waydroid, nix) — this harness
deliberately does not drive any of them directly (e.g. actually creating a
distrobox container or launching a Flatpak app inside a test slot). Those
are real upstream projects with their own test suites; what's actually in
Shanios's scope to verify is that a profile's real `package-list.txt` pulls
each one in correctly and its packaged systemd units/hooks install cleanly —
that's exactly what `cmd_pacstrap` (real signature-verified `pacstrap` runs)
plus each package's own `.install` `post_install`/`post_upgrade` hooks
already cover, not a reason to add per-runtime driving code here. `docker`/
`podman` themselves are already load-bearing as the **outer** layer
(`run_in_container.sh`'s runtime detection, "prefer docker, fall back to
podman"); `systemd-nspawn` (`cmd_enter`) and `qemu`/OVMF (`cmd_qemu`,
`cmd_iso`) are the two *inner* execution layers this harness is actually
built around, and both already have real, live-tested coverage above.
AppImage isn't a systemd-managed package at all — nothing at the OS-assembly
layer to verify.

**Kiosk profile:** The `kiosk` profile (`image_profiles/kiosk/`) is configured for single-purpose deployments with a locked-down user session. See `image_profiles/kiosk/package-list.txt` for the package list.

**Profiles:** This repo ships 6 image profiles: `cosmic`, `gnome`, `kiosk`, `plasma`, `server`, and `shared`. Each profile has its own package list and configuration under `image_profiles/<profile>/`.

- `/etc` and `/var` as overlayfs mounts **on a `cmd_bootstrap`-produced
  slot** (real ShaniOS overlays them from `@data`; `cmd_bootstrap` leaves
  them as plain parts of the slot subvolume — fine for deploy/rollback/slot
  logic, not a full persistence test). `cmd_install`+`cmd_configure` set
  these overlays up for real, since that's `install.sh`/`configure.sh`'s own
  job — see "install / configure" above.
- GPG signature verification is only as good as whatever `.asc` file sits
  next to your build output — `./build.sh` should already produce one
- The GUI itself: `os-installer`'s GTK4 frontend is not driven by anything
  here — `cmd_install`/`cmd_configure` run its two backing scripts directly
  via the same `OSI_*` environment variables the GUI would set, which is a
  genuine, complete exercise of the install/configure logic, just without
  clicking through pages. `cmd_iso` gets you to the real, interactive
  installer GUI (see below) if you want to verify the GUI itself, or the
  full disk-selection/encryption-prompt/user-entry flow end to end by hand.

~~The real install flow (`os-installer-config/scripts/install.sh`,
`configure.sh`) itself~~ — **closed**: `cmd_install`/`cmd_configure` now run
both, unmodified, against a real loop-backed whole-disk image (partitioning,
optional LUKS, Btrfs subvolumes, locale/hostname/user/Secure Boot/UKI all
included) — see "install / configure" above for what's verified and how.

`cmd_qemu` (via OVMF) IS a genuine, complete UEFI boot of what
`cmd_bootstrap` sets up — firmware → shim → systemd-boot → the real UKI →
kernel → systemd → GDM, all unmodified. `cmd_bootstrap` used to leave the
ESP completely empty (no bootloader, no UKI — `cmd_qemu` would just fall
through firmware to a PXE attempt), and used a minimal
`@data`/`@swap`/`@etc`/`@var` subvolume set that was enough for the plain
`cmd_enter` overlay (which never reads `/etc/fstab`) but left a real boot
dropping into emergency mode the instant systemd tried to mount anything
`/etc/fstab` references that this set didn't have — `@cache` first, but
every other production subvolume was equally missing. Both are now handled
by `cmd_bootstrap` itself, using the exact subvolume list and per-slot
`gen-efi configure` call a real install performs, so `cmd_qemu` works
against any freshly bootstrapped disk with no manual setup.

`cmd_iso` (via OVMF) is a genuine boot of a real, unmodified installer
ISO — firmware → shim → systemd-boot, presenting the actual live-installer
boot menu ("Shani OS installer (x86_64, UEFI)", the nomodeset variant, EFI
Shell, Reboot Into Firmware Interface) — confirmed live. It's the one part
of the pipeline this harness previously had zero coverage of at all:
`build.sh iso`/`iso-only`/`repack` only build and upload the ISO, with no
boot-test step anywhere. `cmd_iso` doesn't drive the GUI installer itself
(it's interactive by design), but it does give an automated, repeatable
answer to "does the ISO you just built actually boot" — the most common
way an ISO silently breaks (a bad shim/MOK signature, a corrupt hybrid
GPT/El Torito image, a missing kernel module in the live squashfs) shows
up right here, before a human ever needs to sit through it.

Two more gaps found via an actual booted-to-GDM run and fixed to match
production/real-hypervisor behavior instead of leaving the harness to
paper over them:

- `cmd_bootstrap` also creates `@swap/swapfile` now (via
  `btrfs filesystem mkswapfile`, sized to available RAM, skipped if disk
  space is short) — the shipped image's `/etc/fstab` already has a
  `/swap/swapfile none swap defaults` entry, matching
  `install.sh`'s `create_swapfile()`; without the file present a real boot
  fails with "Failed to activate swap /swap/swapfile". Unlike
  `install.sh`, this never calls `swapon` — that would activate swap on the
  *builder host*, not the guest being assembled.
- `cmd_qemu` now passes a virtio-serial channel + `virtserialport` for
  `org.qemu.guest_agent.0`. Every profile (`gnome`/`plasma`/`cosmic`) ships
  `shani-video-guest` → `qemu-guest-agent`, enabled by default; a real
  libvirt-managed VM always provides this channel, and without it the boot
  blocked on "Timed out waiting for device
  /dev/virtio-ports/org.qemu.guest_agent.0".

## Running GUI apps from the test harness (X11/Wayland forwarding)

`cmd_enter`/`cmd_desktop` boot a slot headlessly; there is no desktop to see.
To actually *render* a GTK app (yad dialogs, gnome-terminal, the
`shani-update` progress window) against the host's real display, the harness
forwards the host's X11 or Wayland socket through both layers:

1. **Docker layer** (`run_in_container.sh`) — `X11_FORWARD_ARGS` /
   `WAYLAND_FORWARD_ARGS`, conditional on the host actually having a socket
   (`$DISPLAY` / `$WAYLAND_DISPLAY`). Binds `/tmp/.X11-unix` (X11) or just
   the one Wayland file (not the whole `$XDG_RUNTIME_DIR`) into the
   container.
2. **nspawn layer** (`test.sh` `_nspawn_binds()`) — builds `X11_BIND` /
   `WAYLAND_BIND` and wires them into `NSPAWN_ENTER_ARGS` and
   `NSPAWN_FULL_BOOT_ARGS`, so the socket reaches the booted slot too.

This is the standard, long-established way to run a container GUI on the
host's real display (see systemd/systemd#12671). It needs no GPU/EGL for a
plain 2D dialog, and required no changes to any real (non-test) code.

### Prerequisites (host-side, one-time)

- X11 only: run `xhost +local:` on the host **before** starting the
  harness. This is a host-wide access-control change — restore with
  `xhost -` when you're done.
- A real session on the host with MIT-MAGIC-COOKIE auth (e.g. Xorg on a
  vt, `$XAUTHORITY` set). The harness reads it from the env as usual.
- No Wayland here — `WAYLAND_DISPLAY` unset, so the Wayland path is a no-op.

### Running a GUI app inside a slot

```bash
# --local-src overlays the sibling shani-deploy checkout's current scripts
# onto the slot's /usr/local/bin, so you're testing the real edited code.
./run_in_container.sh build.sh test enter blue \
    --local-src=/opt/shani-deploy/scripts \
    -- bash -c 'shani-update --health --terminal'
```

To *see* the result, screenshot it from inside the slot — ImageMagick's
`import` is already in the image:

```bash
import -window root /data/screenshot.png
```

`/data` is bind-mounted out through the existing `SHANIOS_TEST_EXTRA_BINDS`
mechanism, so the PNG appears on the host. Bind your own scratch scripts the
same way:

```bash
SHANIOS_TEST_EXTRA_BINDS="/host/path/my-script.sh:/usr/local/bin/my-script.sh"
```

### What this harness proved (and the bugs it caught)

Rendering real dialogs end-to-end is the only way to find yad bugs — reading
`show_dialog()`'s source cannot. Confirmed live against the real yad 15.0
build in the slot:

- **`--image-on-top` was never a yad flag.** Every yad invocation failed to
  parse its command line ("Unknown option --image-on-top", exit 255) *before*
  ever opening a display, and the backend-detection logic treated rc=255 as a
  "bad backend, try next" — so every shani-update dialog had **never actually
  rendered via yad, on any real system, ever**, silently falling through to
  notify-send. Removed; `--image=`/`--on-top` already provide the functionality.
- **Three yad icon crashes** (broken SVG rasterizer via glycin-svg bwrap
  child exits 1 → `gtkiconhelper.c:495` assertion → SIGABRT):
  `show_dialog`'s `--window-icon`, `_run_gui_progress`'s
  `--window-icon="software-update-available"`, and `_run_tray`'s
  `--image="software-update-available"`. Removed all three; `--image=`
  survives where it's needed.
- **`_acquire_lock` failed in headless slots** — `mkdir "$LOCK_FILE"` died when
  `$XDG_RUNTIME_DIR` didn't exist. Added `mkdir -p "${LOCK_FILE%/*}"`.
- **`gnome-terminal --wait` needs a D-Bus session bus** — launches fine, then
  exits ~1s later once activation fails. `_launch_terminal_tail` now waits
  1.5s and checks the terminal PID is still alive; `_run_gui_progress`
  re-shows the graphical view on a failed launch.

### Reusable GUI-verification helper

`test-env/.verify-bin/` holds scratch scripts used for empirical verification
(`alert-fallback-unit.sh`, `termargs3.sh`, `yadaudit.sh`, …). They are bound
into slots via `SHANIOS_TEST_EXTRA_BINDS` exactly like any other script.
`alert-fallback-unit.sh` is a host-side, deterministic unit test of
`show_alert`/`show_dialog`'s fallback paths (stubbed yad + notify-send, clean
minimal PATH so the host's own `/usr/bin/zenity` can't leak in and give a
false rc=1) — the full nspawn harness is flaky in this environment, and the
*positive* paths (real yad dialog rendering) were already verified live.

## Requirements

Whatever `../run_in_container.sh` already needs for a normal build — nothing
extra to install on the host. Inside the container, `check_dependencies_test()`
(`config/config.sh`) verifies `btrfs`, `mkfs.btrfs`, `mkfs.fat`, `losetup`,
`mount`, `umount`, `blkid`, `zstd`, `systemd-nspawn`, `openssl`, `chroot` are
present before `bootstrap` runs, and fails fast with the exact `pacman -S`
package name for anything missing. The one plausible gap in the published
builder image (built for image/ISO assembly, not this harness) is
`dosfstools` for `mkfs.fat` — `disk` auto-installs it if missing, using the
same persistent pacman cache `../run_in_container.sh` already bind-mounts, so
it's only a real download on the very first run.

`install`/`configure` additionally need `check_dependencies_install()`
(`config/config.sh`, a superset of `check_dependencies_test()` plus
`sudo`/`parted`/`partprobe`/`cryptsetup`/`firewall-offline-cmd`/`dracut`/
`sbsign`/`sbverify`/`mokutil` — everything `install.sh`/`configure.sh`
themselves shell out to) and the sibling `os-installer-config` checkout
(`../os-installer-config` next to this repo) — see "install / configure"
above.

Host, for `test-env/test.sh qemu` only: `qemu-system-x86` + OVMF
(`apt install qemu-system-x86 ovmf` / `pacman -S qemu-full edk2-ovmf`).
