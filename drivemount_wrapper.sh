#!/usr/bin/env bash
set -euo pipefail

script="${HOME}/.local/bin/drivemount.sh"
interval=10

cleanup() {
    "$script" -d || true
}

trap cleanup EXIT INT TERM

#start
"$script" && systemd-notify --ready --status="healthy: network drive mounted" || exit 1

while true; do
    sleep "$interval"
    if "$script" --health-check; then
        systemd-notify --status="healthy: last health check passed"
    else
        systemd-notify --status="unhealthy: health-check failed"
        exit 1
    fi
done
