#!/usr/bin/env bash
# test-env/test.sh — shim. The test harness now lives in its own repo,
# shani-testbed (split out 2026-09-23); this keeps every documented
# `./run_in_container.sh build.sh test <command>` and `test-env/test.sh
# <command>` invocation working unchanged.
#
# Looks for the testbed in: $SHANI_TESTBED, /opt/shani-testbed (where
# run_in_container.sh mounts the sibling checkout inside the builder
# container), then ../shani-testbed next to this repo (host-only commands).
set -euo pipefail
here="$(dirname "$(realpath "$0")")"
for candidate in "${SHANI_TESTBED:-}" /opt/shani-testbed "${here}/../../shani-testbed"; do
  if [[ -n "$candidate" && -x "${candidate}/testbed" ]]; then
    exec "${candidate}/testbed" "$@"
  fi
done
echo "test-env/test.sh: shani-testbed not found." >&2
echo "  Check it out next to this repo (../shani-testbed), or set SHANI_TESTBED." >&2
echo "  Inside the builder container it is mounted at /opt/shani-testbed by run_in_container.sh." >&2
exit 2
