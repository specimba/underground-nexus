#!/usr/bin/env bash
# =============================================================================
# N8N UNINSTALLER
# File: Jelly-Apps/n8n/n8n-uninstall.jelly.bash
# =============================================================================

set -euo pipefail

N8N_CONTAINER="${N8N_CONTAINER:-n8n}"
KEEP_DATA="${KEEP_DATA:-false}"

echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  N8N UNINSTALLER                                    │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""

if [ "${KEEP_DATA}" = "true" ]; then
    echo "  Mode: CONTAINER ONLY (workflows and credentials preserved)"
    read -rp "  Type 'remove' to confirm: " CONFIRM
    [ "${CONFIRM}" = "remove" ] || { echo "  Cancelled."; exit 0; }
else
    echo "  Will remove: n8n container + n8n-data volume (workflows, credentials)"
    echo "  To keep data: KEEP_DATA=true bash $0"
    echo ""
    read -rp "  Type 'uninstall' to confirm: " CONFIRM
    [ "${CONFIRM}" = "uninstall" ] || { echo "  Cancelled."; exit 0; }
fi

echo ""
docker stop "${N8N_CONTAINER}" 2>/dev/null && echo "  ✓ stopped" || echo "  (not running)"
docker rm "${N8N_CONTAINER}" 2>/dev/null && echo "  ✓ removed" || echo "  (not found)"

if [ "${KEEP_DATA}" = "false" ]; then
    docker volume rm n8n-data 2>/dev/null && echo "  ✓ n8n-data removed" || echo "  (not found)"
fi

echo ""
echo "  ✓ n8n uninstalled. Redeploy: bash n8n.jelly.bash"
echo ""
