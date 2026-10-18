#!/bin/sh
# shanios-boot-failure-hook.sh — dracut pre-mount hook: write boot_hard_failure
# marker before root mount is attempted.
#
# Install: /usr/lib/dracut/modules.d/99shanios/
#   hook-name: pre-mount (runs after device discovery and LUKS unlock,
#              before / is mounted)
#
# Logic:
#   This hook writes /data/boot_hard_failure unconditionally before the root
#   Btrfs subvolume mount is attempted. A companion pre-pivot hook
#   (shanios-boot-success-clear.sh) deletes the marker if mount succeeds and
#   the system reaches pivot_root. If mount fails, pre-pivot is never reached,
#   the marker persists across reboot, and shani-auto-rollback.sh detects a
#   hard failure.
#
#   This write-then-clear-on-success pattern is necessary because dracut has
#   no "on mount failure" hook — pre-mount runs unconditionally.
#
# The file persists across reboots intentionally: mark-boot-in-progress does
# NOT clear it. The marker is the only evidence a hard failure happened, so
# it is what shani-auto-rollback.sh acts on (it runs unattended, with no
# session/display, and calls shani-deploy --rollback for the two confirmed
# failure shapes). A marker whose content is not a valid slot name is
# deliberately left for manual recovery rather than acted on.

type getarg > /dev/null 2>&1 || return 0   # not in dracut environment

DATA_MNT="/run/shanios-data-tmp"
ROOT_LABEL="shani_root"

# Locate the @data subvolume device by filesystem label.
# At pre-mount 90 the crypt module has already run, so blkid -L finds the
# plaintext Btrfs device (or dm-crypt mapped device if LUKS is in use).
DATA_DEV=$(blkid -L "$ROOT_LABEL" 2>/dev/null) || {
    warn "shanios-hook: cannot locate $ROOT_LABEL device — skipping hard failure write"
    return 0
}

# Mount just the @data subvolume read-write so we can write the marker.
mkdir -p "$DATA_MNT"
if ! mount -t btrfs -o subvol=@data,rw "$DATA_DEV" "$DATA_MNT" 2>/dev/null; then
    warn "shanios-hook: cannot mount @data — hard failure marker not written"
    rmdir "$DATA_MNT" 2>/dev/null || true
    return 0
fi

# Record which slot was being attempted, then unmount immediately.
# Always overwrite — if a stale marker from a previous failed slot exists,
# it must reflect the current boot attempt. The clear hook removes it on
# success, so persistence only means the current attempt failed.
ATTEMPTED_SLOT=$(getarg rootflags | sed 's/.*subvol=@//;s/,.*//')
# Validate — if rootflags has no subvol=@ or sed returns garbage, use "unknown"
# as a sentinel. shani-auto-rollback.sh refuses to guess on an unknown slot
# and leaves it for manual recovery (shani-health / shani-deploy --rollback).
case "$ATTEMPTED_SLOT" in
    blue|green) ;;
    *) ATTEMPTED_SLOT="unknown" ;;
esac
# ── If the PREVIOUS boot also failed, stop defaulting to the broken slot ────
#
# The gap this closes: boot_hard_failure is written by a boot that FAILS, but
# shani-auto-rollback acts on it from a boot that SUCCEEDS. That works, but only
# if the operator knows to pick the other slot — because the default still
# points at the candidate that cannot mount, and on systemd 261 systemd-boot
# does not decrement the +3-0 tries counter, so every automatic boot lands back
# in dracut. Observed on a machine that lost power mid-update: three
# "Failed to mount /sysroot", four minutes apart, then an emergency shell.
#
# So flip the default here, at pre-mount, where we still can — the boot entry
# for THIS boot was chosen before the kernel started and cannot be changed now,
# but the next one can.
#
# Deliberately narrow, and fails open (any doubt changes nothing):
#   * only when a pre-existing boot_hard_failure proves an earlier boot failed
#   * only when the current default is a tries-counted entry, which is exactly
#     how a deploy marks an unproven candidate
#   * only by rewriting the `default` line — no entry is ever deleted
#   * self-limiting: after the switch the default is a plain entry, which does
#     not match, so this cannot ping-pong between two broken slots
# ── Diagnostic ────────────────────────────────────────────────────────────
# Three boots ran the failover block's guard to false while the host could see
# the marker on the same subvolume and this same hook WROTE it successfully
# every time. Both cannot be true unless this read is not looking at what the
# rest of the system sees. So state it, plainly, on every boot - the next
# answer is one console line.
warn "shanios-hook: DIAG root_label=${ROOT_LABEL}"
warn "shanios-hook: DIAG blkid-L-root=$(blkid -L "$ROOT_LABEL" 2>&1)"
warn "shanios-hook: DIAG by-label=$(readlink -f /dev/disk/by-label/$ROOT_LABEL 2>&1)"
warn "shanios-hook: DIAG data_dev=${DATA_DEV:-<unset>}"
warn "shanios-hook: DIAG mount-cmd=mount -t btrfs -o subvol=@data,rw ${DATA_DEV:-<none>} $DATA_MNT"
warn "shanios-hook: DIAG mountpoint-before=$(ls -A "$DATA_MNT" 2>&1 | tr '\n' ' ')"
warn "shanios-hook: DIAG marker-at-mountpoint=$(ls -la "$DATA_MNT/boot_hard_failure" 2>&1 | tr '\n' ' ')"
if [ -s "$DATA_MNT/boot_hard_failure" ]; then
    PRIOR_FAILURE=$(cat "$DATA_MNT/boot_hard_failure" 2>/dev/null)

    # Arm the emergency-mode recovery unit BEFORE anything else, and do it on
    # the strength of the marker alone. The block below rewrites loader.conf for
    # the *next* boot, which leaves this boot committed to the same broken UKI -
    # so without this, a power-cut candidate costs two black screens and the
    # third boot. Armed here, dracut's emergency shell runs the recovery while
    # we are still in this boot and the machine reboots once into the good slot.
    #
    # The unit's own script re-checks every condition before it acts (prior
    # marker, tries-counted default, a fallback entry exists, and the rewrite
    # verified) so arming it is cheap and safe even when this boot will in fact
    # succeed - on a successful boot emergency.target is never reached and the
    # script never runs.
    if command -v systemctl >/dev/null 2>&1; then
        # systemctl's OWN error, for the same reason the ESP mount's is kept.
        # A real boot logged only "could not arm ... - recovery is still
        # next-boot only", which is a summary of our intent, not a reason: the
        # unit may be missing from the initramfs, the unit path unwritable, or
        # the manager refusing to talk at dracut-pre-mount. None is guessable
        # from "it failed", and the arming has now failed on a real boot with
        # nothing on record about why.
        # Before arming: is the unit even IN this initramfs? dracut's
        # inst_simple is what puts it there, and "dracut did not install it" and
        # "systemd cannot see a file on its own unit path" are different bugs
        # with different fixes, and systemctl's one line ("does not exist")
        # reads identically for both.
        #
        # This is here because the harness was copying only *.sh for an entire
        # session, so no initramfs contained the unit at all and every
        # observation of "does not exist" was that, misread as a systemd fault.
        if [ -f /etc/systemd/system/shanios-recover-default.service ]; then
            warn "shanios-hook: DIAG unit-present=yes bytes=$(wc -c < /etc/systemd/system/shanios-recover-default.service 2>&1 | tr -d " ")"
        else
            warn "shanios-hook: DIAG unit-present=NO - dracut did not install it; /etc/systemd/system holds: $(ls /etc/systemd/system 2>&1 | tr '\n' ' ')"
        fi
        _arm_err=$(systemctl enable shanios-recover-default.service 2>&1) && \
            warn "shanios-hook: armed emergency-mode default recovery (this boot, not the next)" || \
            warn "shanios-hook: could not arm shanios-recover-default.service - recovery is still next-boot only - ${_arm_err:-no error output}"
    else
        warn "shanios-hook: systemctl absent in the initramfs - recovery is still next-boot only"
    fi

    ESP_DEV=$(blkid -L shani_boot 2>/dev/null)
    ESP_MNT=/run/shanios-boot-esp-tmp
    # Every exit below is announced. The first firmware boot of this ran through
    # this whole block, changed nothing, and logged nothing — so a branch that
    # does not run and a branch that runs and succeeds are indistinguishable
    # from the console, and the only way to tell them apart is a boot. Silence
    # was the wrong trade for a safety mechanism.
    if [ -z "$ESP_DEV" ]; then
        warn "shanios-hook: prior failure (@${PRIOR_FAILURE}) but blkid -L shani_boot found no ESP device"
    elif ! mkdir -p "$ESP_MNT" 2>/dev/null; then
        warn "shanios-hook: cannot create ${ESP_MNT} for the ESP mountpoint"
    elif ! _esp_err=$(mount -t vfat -o rw "$ESP_DEV" "$ESP_MNT" 2>&1); then
        # The mount's OWN error, not just ours. `2>/dev/null` here meant a boot
        # where the ESP could not be mounted printed only "could not mount the
        # ESP (/dev/vda1)" - which is exactly the level of detail that left the
        # original question ("is the ESP reachable at pre-mount at all?") open
        # through a whole investigation. The device is found by blkid and the
        # mount is a separate step that can fail for reasons worth naming: no
        # vfat driver in the initramfs, a busy device, a bad superblock, a
        # read-only mount. Each has a different fix and none is guessable from
        # "it failed".
        warn "shanios-hook: prior failure (@${PRIOR_FAILURE}) but could not mount the ESP (${ESP_DEV}) - ${_esp_err:-no error output}"
    else
        LOADER="$ESP_MNT/loader/loader.conf"
        ENTRIES="$ESP_MNT/loader/entries"
        if [ ! -f "$LOADER" ]; then
            warn "shanios-hook: prior failure (@${PRIOR_FAILURE}) but ${ESP_MNT}/loader/loader.conf is absent"
        else
            CUR=$(sed -n 's/^default[[:space:]]\+\([^[:space:]]*\).*/\1/p' "$LOADER" 2>/dev/null | head -1)
            # Resolve the default against the entries on disk before deciding
            # whether this slot is a marked candidate. loader.conf may spell the
            # default either as the bare ID or as the marked filename, and this
            # guard only ever saw one of them.
            #
            # Measured, on a real ESP written by os-installer-config's
            # configure.sh: entries were shanios-blue.conf + shanios-green.conf
            # with `default shanios-blue.conf`, and this hook reported
            #
            #   prior failure (@unknown) but default 'shanios-blue.conf' carries
            #   no tries counter - not an unproven candidate, leaving it
            #
            # - correctly declining to act on a slot that genuinely had no
            # marker. But it declined for the WRONG REASON: it never looked at
            # the filesystem, only at the string, so an ESP where the marked
            # entry exists and the default names it by bare ID looks identical
            # to an ESP with no marker at all. Those two cases need opposite
            # behaviour and this guard could not tell them apart.
            #
            # So: if the named entry exists plainly, honour the name. If it does
            # not exist but a `+N-M` variant of the same name does, the default
            # resolves to the marked entry - which is the candidate.
            case "$CUR" in
                *+*-*) : ;;
                "") : ;;
                *)
                    # The counter sits BEFORE the `.conf`, so the glob has to be
                    # built from the stem. My first version appended `+*-*.conf`
                    # to the whole name INCLUDING `.conf`, which asks for
                    # `shanios-blue.conf+3-0.conf` - a filename that cannot exist.
                    # It matched nothing, left CUR unchanged, and fell through to
                    # the "carries no tries counter" branch, which is exactly what
                    # a real boot then reported. The branch was not dead; the
                    # lookup feeding it was.
                    if [ ! -f "$ENTRIES/$CUR" ]; then
                        _stem="${CUR%.conf}"
                        for _m in "$ENTRIES/${_stem}"+*-*.conf; do
                            [ -f "$_m" ] || continue
                            CUR="${_m##*/}"
                            warn "shanios-hook: default resolved to marked entry '${CUR}' on disk"
                            break
                        done
                    fi
                    ;;
            esac
            case "$CUR" in
                *+*-*)
                    FALLBACK=""
                    for E in "$ENTRIES"/*.conf; do
                        [ -f "$E" ] || continue
                        N=$(basename "$E" .conf)
                        case "$N" in *+*-*) continue ;; esac
                        # The rewrite names the BASE ID (`name.conf`), which is what
                        # loader.conf's default has to name.
                        #
                        # This comment used to assert the opposite - that the id is
                        # the full filename and that naming the stem "matches
                        # NOTHING". That was true before systemd commit 4301ad0
                        # ("boot: Strip boot counter from entry id", fixes #38813,
                        # 2025-09-11), which made boot_entry_parse_tries() SET
                        # entry->id with the counter removed:
                        #
                        #     entry->id = xasprintf("%.*ls%ls", (int) prefix_len - 1,
                        #                                file, suffix);
                        #
                        # On the systemd this image ships (v262) the entry
                        # `shanios-green+3-0.conf` therefore has id
                        # `shanios-green.conf`, so the base ID is what matches.
                        #
                        # That correction cuts both ways, and the other half is why
                        # the resolution block above exists: because the id no
                        # longer carries the counter, a correctly-written
                        # loader.conf names the plain base ID even when the entry on
                        # disk is marked. So `case "$CUR" in *+*-*)` - the guard
                        # that decides whether this slot is an unproven candidate -
                        # could not match a correctly-configured machine at all. It
                        # only ever fired when loader.conf happened to spell the
                        # default with the marked filename, which is the one spelling
                        # systemd-boot does NOT match.
                        FALLBACK="${N}.conf"; break
                    done
                    if [ -z "$FALLBACK" ]; then
                        warn "shanios-hook: prior failure (@${PRIOR_FAILURE}) but no non-tries entry exists to fall back to (default=${CUR})"
                    elif [ "$FALLBACK" = "$CUR" ]; then
                        warn "shanios-hook: prior failure (@${PRIOR_FAILURE}) but the only plain entry is the current default (${CUR})"
                    else
                        cp "$LOADER" "$LOADER.shanios-bak" 2>/dev/null
                        if sed -i "s|^default[[:space:]]\+[^[:space:]]*|default $FALLBACK|" "$LOADER" 2>/dev/null; then
                            warn "shanios-hook: previous boot also failed (@${PRIOR_FAILURE}); boot default switched ${CUR} -> ${FALLBACK}"
                            # sed -i renames a new file over the old one, so the
                            # directory entry AND the file data are dirty. Flush
                            # explicitly: the initramfs is about to be discarded,
                            # and a write that never leaves its page cache is
                            # indistinguishable from one that never happened.
                            # That is exactly what was seen - the hook reporting
                            # the switch on every boot while loader.conf on disk
                            # never changed.
                            sync
                            # Rewriting loader.conf is NOT enough, and this is the
                            # single most important thing in this hook.
                            #
                            # systemd-boot reads loader.conf's `default` LAST.
                            # config_select_default_entry() (v262 src/boot/boot.c)
                            # tries LoaderEntrySysFail, LoaderEntryOneShot,
                            # LoaderEntryPreferred, then the saved entry, then
                            # LoaderEntryDefault - and RETURNS ON THE FIRST MATCH.
                            # loader.conf is only consulted after all of those.
                            #
                            # And finalize_boot_entries() runs `bootctl
                            # set-default "${loader_default}"` after every deploy,
                            # which persists LoaderEntryDefault naming the
                            # CANDIDATE. So on a real machine that variable is set,
                            # it outranks this rewrite, and the machine boots the
                            # candidate that just failed - forever.
                            #
                            # A field test of this hook passed end to end while
                            # missing exactly this, because the testbed's EFI
                            # variables were unset (no real deploy had run). The
                            # precondition that made it pass is the one a deploy
                            # actively violates.
                            #
                            # MEASURED, on real efivarfs in a real firmware
                            # boot (edk2-ovmf via iso-install --boot-only,
                            # tests/efivar-proof.sh):
                            #
                            #   printf '' > $node   rc=0  node still there
                            #                                size UNCHANGED
                            #   truncate -s 0 $node  rc=0  node still there
                            #   rm -f $node          rc=0  node GONE
                            #
                            # Both zero-byte forms are SILENT NO-OPS. They exit 0
                            # with no error and change nothing, so the version of
                            # this hook that used them reported "cleared" on every
                            # boot while clearing nothing, on every machine, with
                            # its unit test green - because that test drives this
                            # code against a scratch directory, where the same
                            # write truncates an ordinary file to zero bytes.
                            # tmpfs cannot reproduce efivarfs, which is the whole
                            # reason this was invisible for so long.
                            #
                            # So: unlink, and then VERIFY. Trusting the exit
                            # status is precisely what hid the last version -
                            # rc=0 meant nothing happened. A write to a file
                            # system that does not implement the operation
                            # succeeds, so the only evidence is the node's
                            # absence afterwards.
                            _cleared=""
                            # Overridable so a test can point this at a scratch
                            # directory. It MUST NOT point at the real efivarfs in
                            # a test: this code deletes four persistent variables,
                            # and a test host running systemd-boot would lose
                            # them. Only the four systemd-boot names below are
                            # touched; a GRUB host has none of them, which is why
                            # an accidental run against a live efivarfs can go
                            # unnoticed.
                            _efivarfs="${SHANIOS_EFIVARS_DIR:-/sys/firmware/efi/efivars}"
                            for _v in LoaderEntrySysFail LoaderEntryOneShot \
                                     LoaderEntryPreferred LoaderEntryDefault; do
                                for _f in "$_efivarfs"/${_v}-*; do
                                    [ -e "$_f" ] || continue
                                    # `chattr -i` FIRST. Since the kernel's
                                    # "efi: Make efivarfs entries immutable by
                                    # default" (ed8b0de, 2016), every efivarfs
                                    # node that is not on a small allowlist of
                                    # standardised variables is created
                                    # IMMUTABLE — see fs/efivarfs/inode.c:
                                    #
                                    #   inode->i_flags = is_removable ? 0 : S_IMMUTABLE;
                                    #
                                    # and `is_removable` comes from
                                    # efivar_variable_is_removable(), an allowlist.
                                    # systemd-boot's `LoaderEntry*` variables are
                                    # vendor-specific, NOT standardised, so they are
                                    # immutable — and unlinking an immutable inode is
                                    # EPERM.
                                    #
                                    # This was measured, not inferred: one
                                    # iso-install --boot-only boot, same invocation,
                                    # same uid/capabilities —
                                    #
                                    #   victim=ConOut-8BE4DF61-...      rm -f -> rc 0, GONE
                                    #   loader-victim=LoaderEntrySelected-
                                    #     4a67b082-...                rm -f -> EPERM, survives
                                    #
                                    # So `rm -f` alone cannot have ever cleared these,
                                    # and the kernel docs are explicit that the flag is
                                    # exactly the intended way through: "This doesn't
                                    # prevent removal - `chattr -i` will work".
                                    #
                                    # `|| true`: if chattr is missing or the fs
                                    # refuses, fall through to `rm -f` anyway and let
                                    # the existence check below report the truth.
                                    chattr -i "$_f" 2>/dev/null || true
                                    rm -f "$_f" 2>/dev/null
                                    if [ ! -e "$_f" ]; then
                                        _cleared="${_cleared} ${_v}"
                                    else
                                        warn "shanios-hook: could not clear EFI variable ${_v} (${_f}) - systemd-boot may still boot ${CUR}"
                                    fi
                                done
                            done
                            if [ -n "$_cleared" ]; then
                                warn "shanios-hook: cleared EFI variables that outrank loader.conf:${_cleared}"
                            fi
                            sync
                        else
                            warn "shanios-hook: sed failed rewriting the default in ${LOADER} (leaving ${CUR})"
                        fi
                    fi
                    ;;
                "")
                    warn "shanios-hook: prior failure (@${PRIOR_FAILURE}) but loader.conf has no default line" ;;
                *)
                    warn "shanios-hook: prior failure (@${PRIOR_FAILURE}) but default '${CUR}' carries no tries counter - not an unproven candidate, leaving it" ;;
            esac
        fi
        # Do not discard a failed unmount. If the ESP is still mounted when the
        # initramfs goes, its dirty pages go with it and the switch is lost -
        # silently, which is how a hook that reports success every boot can
        # leave the boot target exactly where it was.
        sync
        if ! umount "$ESP_MNT" 2>/dev/null; then
            warn "shanios-hook: umount of ${ESP_MNT} failed - the default change may not persist"
            umount -l "$ESP_MNT" 2>/dev/null || true
        fi
    fi
    rmdir "$ESP_MNT" 2>/dev/null || true
fi

printf '%s\n' "$ATTEMPTED_SLOT" > "$DATA_MNT/boot_hard_failure" 2>/dev/null && \
    warn "shanios-hook: boot_hard_failure written for slot '@${ATTEMPTED_SLOT}' (will be cleared on successful pivot)"

umount "$DATA_MNT" 2>/dev/null || true
rmdir  "$DATA_MNT" 2>/dev/null || true
