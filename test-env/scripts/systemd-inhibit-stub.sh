#!/bin/bash
# Minimal stand-in for systemd-inhibit inside the test container.
#
# shani-deploy.sh calls it like:
#   systemd-inhibit --what=... --who=... --why=... [env NAME=VAL ...] <script> <args...>
#
# There's no logind/session in the container so real inhibitor locks make no
# sense here. Strip the systemd-inhibit-specific tokens and exec the rest.
set -euo pipefail

cmd=()
for a in "$@"; do
    case "$a" in
        --what=*|--who=*|--why=*|--mode=*) continue ;;
        env) continue ;;
        *=*)
            # Only swallow NAME=VAL tokens that appear before we've started
            # collecting the real command (i.e. the `env NAME=VAL` prefix).
            if [[ ${#cmd[@]} -eq 0 ]]; then
                export "${a?}"
                continue
            fi
            ;;
    esac
    cmd+=("$a")
done

exec "${cmd[@]}"
