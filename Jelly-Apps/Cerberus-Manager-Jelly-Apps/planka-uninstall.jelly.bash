#!/usr/bin/env bash
# =============================================================================
# PLANKA UNINSTALLER
# Underground Nexus — Stigmergic Kanban Board
# File: Jelly-Apps/Planka/planka-uninstall.jelly.bash
# =============================================================================
#
# MODES:
#   Full uninstall (containers + volumes — all boards/cards deleted):
#     bash planka-uninstall.jelly.bash
#
#   Keep DB, wipe app config only:
#     WIPE_APP_ONLY=true bash planka-uninstall.jelly.bash
#
#   Container only (volumes preserved — data safe):
#     KEEP_DATA=true bash planka-uninstall.jelly.bash
#
# =============================================================================

set -euo pipefail

PLANKA_CONTAINER="${PLANKA_CONTAINER:-planka}"
PLANKA_DB_CONTAINER="${PLANKA_DB_CONTAINER:-planka-db}"
KEEP_DATA="${KEEP_DATA:-false}"
WIPE_APP_ONLY="${WIPE_APP_ONLY:-false}"

echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  PLANKA UNINSTALLER                                 │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""

if [ "${WIPE_APP_ONLY}" = "true" ]; then
    echo "  Mode: WIPE APP DATA ONLY (database preserved)"
    read -rp "  Type 'wipe' to confirm: " CONFIRM
    [ "${CONFIRM}" = "wipe" ] || { echo "  Cancelled."; exit 0; }
elif [ "${KEEP_DATA}" = "true" ]; then
    echo "  Mode: CONTAINERS ONLY (all volumes preserved)"
    read -rp "  Type 'remove' to confirm: " CONFIRM
    [ "${CONFIRM}" = "remove" ] || { echo "  Cancelled."; exit 0; }
else
    echo "  ⚠  WARNING: ALL KANBAN BOARDS AND CARDS WILL BE DELETED."
    echo "     Back up first: bash sovereign-update.sh (creates pg_dump)"
    echo ""
    echo "  Will remove: planka + planka-db containers"
    echo "  Will remove: planka-app-data + planka-db-data volumes"
    echo "  Will remove: planka-internal bridge network"
    echo ""
    echo "  To keep data: KEEP_DATA=true bash $0"
    echo ""
    read -rp "  Type 'uninstall' to confirm: " CONFIRM
    [ "${CONFIRM}" = "uninstall" ] || { echo "  Cancelled."; exit 0; }
fi

echo ""

# Disconnect from sovereign-net before removing
docker network disconnect sovereign-net "${PLANKA_CONTAINER}" 2>/dev/null || true

echo "→ Stopping planka..."
docker stop "${PLANKA_CONTAINER}" 2>/dev/null && echo "  ✓ stopped" || echo "  (not running)"
docker rm "${PLANKA_CONTAINER}" 2>/dev/null && echo "  ✓ removed" || echo "  (not found)"

if [ "${WIPE_APP_ONLY}" != "true" ]; then
    echo "→ Stopping planka-db..."
    docker stop "${PLANKA_DB_CONTAINER}" 2>/dev/null && echo "  ✓ stopped" || echo "  (not running)"
    docker rm "${PLANKA_DB_CONTAINER}" 2>/dev/null && echo "  ✓ removed" || echo "  (not found)"
fi

if [ "${KEEP_DATA}" != "true" ]; then
    echo "→ Removing planka-app-data volume..."
    docker volume rm planka-app-data 2>/dev/null && echo "  ✓ removed" || echo "  (not found)"

    if [ "${WIPE_APP_ONLY}" != "true" ]; then
        echo "→ Removing planka-db-data volume..."
        docker volume rm planka-db-data 2>/dev/null && echo "  ✓ removed" || echo "  (not found)"
        echo "→ Removing planka-internal network..."
        docker network rm planka-internal 2>/dev/null && echo "  ✓ removed" || echo "  (not found)"
    fi
fi

echo ""
if [ "${WIPE_APP_ONLY}" = "true" ]; then
    echo "  ✓ App data wiped. Database intact."
elif [ "${KEEP_DATA}" = "true" ]; then
    echo "  ✓ Containers removed. Volumes preserved."
else
    echo "  ✓ Full uninstall complete."
fi
echo "  Redeploy: bash planka.jelly.bash"
echo ""
