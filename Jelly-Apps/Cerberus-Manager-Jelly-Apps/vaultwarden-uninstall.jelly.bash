#!/usr/bin/env bash
# =============================================================================
# VAULTWARDEN UNINSTALLER
# Underground Nexus — Sovereign Password Vault
# File: Jelly-Apps/Vaultwarden/vaultwarden-uninstall.jelly.bash
# =============================================================================
#
# MODES:
#   Full uninstall (container + volume — ALL PASSWORDS DELETED):
#     bash vaultwarden-uninstall.jelly.bash
#
#   Container only (keeps vault data):
#     KEEP_DATA=true bash vaultwarden-uninstall.jelly.bash
#
# =============================================================================

set -euo pipefail

VW_CONTAINER="${VW_CONTAINER:-vaultwarden}"
KEEP_DATA="${KEEP_DATA:-false}"

echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  VAULTWARDEN UNINSTALLER                            │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""

if [ "${KEEP_DATA}" = "true" ]; then
    echo "  Mode: CONTAINER ONLY (vault data preserved)"
    read -rp "  Type 'remove' to confirm: " CONFIRM
    [ "${CONFIRM}" = "remove" ] || { echo "  Cancelled."; exit 0; }
else
    echo "  ⚠  WARNING: This will permanently delete ALL stored passwords."
    echo "     Back up first: bash vaultwarden-backup.jelly.bash"
    echo ""
    echo "  Will remove:  vaultwarden container + vaultwarden-data volume"
    echo "  To keep data: KEEP_DATA=true bash $0"
    echo ""
    read -rp "  Type 'uninstall' to confirm: " CONFIRM
    [ "${CONFIRM}" = "uninstall" ] || { echo "  Cancelled."; exit 0; }
fi

echo ""
echo "→ Stopping vaultwarden..."
docker stop "${VW_CONTAINER}" 2>/dev/null && echo "  ✓ stopped" || echo "  (not running)"
echo "→ Removing vaultwarden container..."
docker rm "${VW_CONTAINER}" 2>/dev/null && echo "  ✓ removed" || echo "  (not found)"

if [ "${KEEP_DATA}" = "false" ]; then
    echo "→ Removing vaultwarden-data volume..."
    docker volume rm vaultwarden-data 2>/dev/null && echo "  ✓ removed" || echo "  (not found)"
    echo ""
    echo "  ✓ Full uninstall complete."
else
    echo ""
    echo "  ✓ Container removed. Volume 'vaultwarden-data' preserved."
fi

echo "  Redeploy: bash vaultwarden.jelly.bash"
echo ""
