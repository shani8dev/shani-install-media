#!/bin/bash
# Wait up to 30 seconds for /swap/swapfile to appear in /proc/swaps.
TIMEOUT=30
while [ $TIMEOUT -gt 0 ]; do
    if grep -q '/swap/swapfile' /proc/swaps; then
        exit 0
    fi
    sleep 1
    TIMEOUT=$((TIMEOUT - 1))
done
echo "Warning: /swap/swapfile not active after waiting; proceeding with zram setup." >&2
exit 0
