#!/usr/bin/env bash
# =============================================================================
# UPTIME KUMA UNINSTALLER
# File: Jelly-Apps/Uptime-Kuma/uptime-kuma-uninstall.jelly.bash
# =============================================================================

set -euo pipefail
UK_CONTAINER="${UK_CONTAINER:-uptime-kuma}"
KEEP_DATA="${KEEP_DATA:-false}"

echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  UPTIME KUMA UNINSTALLER                            │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""

if [ "${KEEP_DATA}" = "true" ]; then
    read -rp "  Type 'remove' to remove container (data preserved): " CONFIRM
    [ "${CONFIRM}" = "remove" ] || { echo "  Cancelled."; exit 0; }
else
    echo "  Will remove: uptime-kuma container + uptime-kuma-data volume"
    read -rp "  Type 'uninstall' to confirm: " CONFIRM
    [ "${CONFIRM}" = "uninstall" ] || { echo "  Cancelled."; exit 0; }
fi

echo ""
docker stop "${UK_CONTAINER}" 2>/dev/null && echo "  ✓ stopped" || echo "  (not running)"
docker rm "${UK_CONTAINER}" 2>/dev/null && echo "  ✓ removed" || echo "  (not found)"
if [ "${KEEP_DATA}" = "false" ]; then
    docker volume rm uptime-kuma-data 2>/dev/null && echo "  ✓ uptime-kuma-data removed" || echo "  (not found)"
fi
echo ""
echo "  ✓ Uninstalled. Redeploy: bash uptime-kuma.jelly.bash"
echo ""
