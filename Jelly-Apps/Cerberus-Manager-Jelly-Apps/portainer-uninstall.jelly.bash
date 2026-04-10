#!/usr/bin/env bash
# =============================================================================
# PORTAINER UNINSTALLER
# File: Jelly-Apps/Portainer/portainer-uninstall.jelly.bash
# =============================================================================

set -euo pipefail

PT_CONTAINER="${PT_CONTAINER:-portainer}"
KEEP_DATA="${KEEP_DATA:-false}"

echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  PORTAINER UNINSTALLER                              │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""

if [ "${KEEP_DATA}" = "true" ]; then
    read -rp "  Type 'remove' to remove container (data preserved): " CONFIRM
    [ "${CONFIRM}" = "remove" ] || { echo "  Cancelled."; exit 0; }
else
    echo "  Will remove: portainer container + portainer-data volume"
    read -rp "  Type 'uninstall' to confirm: " CONFIRM
    [ "${CONFIRM}" = "uninstall" ] || { echo "  Cancelled."; exit 0; }
fi

echo ""
docker stop "${PT_CONTAINER}" 2>/dev/null && echo "  ✓ stopped" || echo "  (not running)"
docker rm "${PT_CONTAINER}" 2>/dev/null && echo "  ✓ removed" || echo "  (not found)"

if [ "${KEEP_DATA}" = "false" ]; then
    docker volume rm portainer-data 2>/dev/null && echo "  ✓ portainer-data removed" || echo "  (not found)"
fi

echo ""
echo "  ✓ Portainer uninstalled. Redeploy: bash portainer.jelly.bash"
echo ""
