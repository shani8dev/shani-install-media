#!/bin/sh
echo "=== THE PROGRESS LOGFILE (what pkexec/shani-deploy actually wrote) ==="
cat /tmp/shani-update-progress.qcwZvz.log
echo "=== END OF LOGFILE (mode: $(stat -c %a /tmp/shani-update-progress.qcwZvz.log) size: $(stat -c %s /tmp/shani-update-progress.qcwZvz.log)) ==="
echo
echo "=== true container process view ==="
ps -ef
echo
echo "=== shani-deploy --rollback attempt (foreground, capturing rc) ==="
timeout 120 env DISPLAY=:1 XAUTHORITY=/root/.Xauthority pkexec /usr/local/bin/shani-deploy --rollback 2>&1 | head -40
echo "rollback_probe_pipe_rc=${PIPESTATUS[0]}"