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
| `disk` | `test.sh`'s `cmd_disk` | Creates two sparse loop-backed images standing in for the real GPT disk (`esp.img` FAT32, `root.img` Btrfs — see `os-installer-config/bits/part.sfdisk`). Auto-installs `dosfstools` first if `mkfs.fat` is missing from the builder image — see "Requirements" below |
| `ca` | `test.sh`'s `cmd_ca` | Generates a throwaway CA + `downloads.shani.dev` server cert, used only inside this rig (see "The local mirror" below) |
| `bootstrap -p <profile> [-d latest\|stable\|<date>]` | `test.sh`'s `cmd_bootstrap` | Resolves and `btrfs receive`s a real `.zst` **directly from `OUTPUT_DIR`** (config.sh's `./cache/output`), snapshots it to `@blue`/`@green`, creates the full production subvolume set, trust-anchors the test CA into each slot, and runs `gen-efi configure <slot>` for each — the ESP comes out of `bootstrap` genuinely bootable, same as a real install |
| `serve [port]` | `test.sh`'s `cmd_serve` | Serves `OUTPUT_DIR` as-is over real HTTPS as a stand-in for `downloads.shani.dev` |
| `enter <blue\|green> [--boot]` | `test.sh`'s `cmd_enter` | Enters a slot via `systemd-nspawn`, looking exactly like a booted ShaniOS system to `shani-deploy`/`shani-update` |
| `upgrade` / `reboot` / `rollback` | `test.sh`'s `cmd_upgrade`/`cmd_reboot`/`cmd_rollback` | Drive the real update → reboot → rollback cycle (each just resolves the current slot and calls `cmd_enter`) |
| `cycle -p <profile>` | `test.sh`'s inline `cycle` case | `disk` → `ca` → `bootstrap` → `serve` (background) → `upgrade` → `reboot` in one go |
| `qemu` | `test.sh`'s `cmd_qemu` | A genuine UEFI boot (via OVMF) of the real bootloader/kernel/UKI `shani-deploy` produced — **host-only**, run `test-env/test.sh qemu` directly, not through `build.sh test` |
| `clean` | `test.sh`'s `cmd_clean` | Unmounts everything (nspawn overlays, the ESP, the top-level Btrfs mount) and detaches root.img/esp.img's loop devices. Leaves the images themselves in place |

**Run `clean` when you're done testing.** Loop-device attachment doesn't
survive across separate `run_in_container.sh` invocations (each is a fresh
`--rm`'d container), so every `disk`/`bootstrap`/`enter`/`cycle` call
re-attaches or reuses root.img/esp.img's loop devices on the *host* —
nothing ever detaches them again on its own. Across a long testing session
this accumulates loop devices indefinitely; only `clean`, a manual
`losetup -d`, or a reboot releases them.

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
- `cmd_enter` bind-mounts the host's `/etc/hosts` into the slot so DNS
  resolution matches, and swaps in the `systemd-inhibit` stub script (there's
  no logind session in a one-shot `nspawn` invocation)

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
`/etc/hosts` and `systemd-inhibit` are bind-mounted in transiently, per
`nspawn` invocation, never written to `@blue`/`@green`.

## Quick start

```bash
# from the shani-install-media repo root:
./build.sh image -p plasma            # or whatever profile you're testing
./build.sh release -p plasma latest   # writes cache/output/plasma/latest.txt

./run_in_container.sh build.sh test disk
./run_in_container.sh build.sh test ca
./run_in_container.sh build.sh test bootstrap -p plasma

# in a separate terminal (blocks in the foreground):
./run_in_container.sh build.sh test serve

# after building + releasing a NEWER image to cache/output:
./run_in_container.sh build.sh test upgrade
./run_in_container.sh build.sh test reboot
./run_in_container.sh build.sh test rollback   # if you want to test the recovery path

# or all of the above in one go:
./run_in_container.sh build.sh test cycle -p plasma

# on the HOST, not through run_in_container.sh:
test-env/test.sh qemu

# when you're done — releases loop devices, leaves root.img/esp.img in place:
./run_in_container.sh build.sh test clean
```

## What this does NOT simulate

- `/etc` and `/var` as overlayfs mounts (real ShaniOS overlays them from
  `@data`; this harness leaves them as plain parts of the slot subvolume —
  fine for deploy/rollback/slot logic, not a full persistence test)
- GPG signature verification is only as good as whatever `.asc` file sits
  next to your build output — `./build.sh` should already produce one
- The real install flow (`os-installer-config/scripts/install.sh`) itself —
  `cmd_bootstrap` creates the same full subvolume set and calls the same
  `gen-efi configure <slot>` each slot's own install would have, but skips
  install.sh's disk-partitioning and configure.sh's locale/hostname/user
  setup

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

Host, for `test-env/test.sh qemu` only: `qemu-system-x86` + OVMF
(`apt install qemu-system-x86 ovmf` / `pacman -S qemu-full edk2-ovmf`).
