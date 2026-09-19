#!/bin/sh
# Diagnostic for the wedged shani-update probe (cancel3)
echo "--- fds of shani-update 1773 ---"
ls -la /proc/1773/fd 2>&1 | sed -n '1,15p'
echo
echo "--- fds of yad 1848 ---"
ls -la /proc/1848/fd 2>&1 | sed -n '1,15p'
echo
echo "--- full find for progress logfile ---"
find / -name 'shani-update-progress*' 2>/dev/null
echo
echo "--- ps for any pkexec/defunct/rollback/snapper ---"
ps -ef | grep -E 'pkexec|shani-deploy|defunct|snapper|btrfs' | grep -v grep
echo
echo "--- pkexec sanity test (echo) ---"
timeout 20 pkexec /bin/echo pkexec-echo-ok 2>&1; echo "pkexec_echo_rc=$?"
echo
echo "--- shani-deploy version via pkexec with exact env ---"
timeout 20 env DISPLAY=:1 XAUTHORITY=/root/.Xauthority pkexec /usr/local/bin/shani-deploy --version 2>&1; echo "pkexec_ver_rc=$?"
echo
echo "--- journal around pkexec (last 30 journalctl lines) ---"
journalctl -b --no-pager 2>/dev/null | grep -iE 'pkexec|polkit|not authorized|shani' | tail -20