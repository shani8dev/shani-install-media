# test-env — moved to shani-testbed

The test harness (install / boot / update / rollback / GUI-test real ShaniOS
images, plus the MCP server for AI agents) now lives in its own repo,
**`shani-testbed`**, checked out next to this one:

```
../shani-testbed/README.md    full documentation
../shani-testbed/AGENTS.md    rules for agents working on the harness
```

Nothing changes in how you run it — from this repo's root:

```bash
./run_in_container.sh build.sh test <command> [options]   # e.g. suite -p gnome, verify-boot blue, app blue --run=...
test-env/test.sh <command>                                  # HOST-ONLY: qemu, gui, iso, watch, vmspawn
```

`test-env/test.sh` is a shim that execs `shani-testbed/testbed`;
`run_in_container.sh` mounts the sibling checkout read-only at
`/opt/shani-testbed`. Harness state stays here, in `test-env/disk/`
(gitignored).
