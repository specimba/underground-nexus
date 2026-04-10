#!/usr/bin/env bash
# =============================================================================
# HOME ASSISTANT UNINSTALLER
# Underground Nexus — Sovereign Smart Home
# File: Jelly-Apps/Home-Assistant/home-assistant-uninstall.jelly.bash
# =============================================================================
#
# MODES:
#   Full uninstall (container + config volume — ALL automations deleted):
#     bash home-assistant-uninstall.jelly.bash
#
#   Container only (config volume preserved — automations/integrations safe):
#     KEEP_DATA=true bash home-assistant-uninstall.jelly.bash
#
# =============================================================================

set -eo pipefail

HA_CONTAINER="${HA_CONTAINER:-home-assistant}"
KEEP_DATA="${KEEP_DATA:-false}"

echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  HOME ASSISTANT UNINSTALLER                         │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""

if [ "${KEEP_DATA}" = "true" ]; then
    echo "  Mode: CONTAINER ONLY"
    echo "  Will preserve: home-assistant-config volume"
    echo "  (All automations, integrations, and history are safe)"
    echo ""
    read -rp "  Type 'remove' to confirm: " CONFIRM
    [ "${CONFIRM}" = "remove" ] || { echo "  Cancelled."; exit 0; }
else
    echo "  ⚠  WARNING: This will delete ALL Home Assistant config:"
    echo "     - Automations, scripts, scenes"
    echo "     - Device integrations and credentials"
    echo "     - History database"
    echo "     - Dashboards and lovelace config"
    echo ""
    echo "  Back up first: bash sovereign-update.sh (creates config snapshot)"
    echo "  To keep data:  KEEP_DATA=true bash $0"
    echo ""
    read -rp "  Type 'uninstall' to confirm: " CONFIRM
    [ "${CONFIRM}" = "uninstall" ] || { echo "  Cancelled."; exit 0; }
fi

echo ""
echo "→ Stopping home-assistant..."
docker stop "${HA_CONTAINER}" 2>/dev/null && echo "  ✓ stopped" || echo "  (not running)"
echo "→ Removing home-assistant container..."
docker rm "${HA_CONTAINER}" 2>/dev/null && echo "  ✓ removed" || echo "  (not found)"

if [ "${KEEP_DATA}" = "false" ]; then
    echo "→ Removing home-assistant-config volume..."
    docker volume rm home-assistant-config 2>/dev/null \
        && echo "  ✓ removed" \
        || echo "  (not found)"
    echo ""
    echo "  ✓ Full uninstall complete."
else
    echo ""
    echo "  ✓ Container removed. Config volume preserved."
    echo "  Redeploy: bash home-assistant.jelly.bash"
fi
echo ""
