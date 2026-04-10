#!/usr/bin/env bash
# =============================================================================
# BOOKSTACK UNINSTALLER v3
# Underground Nexus — Sovereign Knowledge Base
# File: Jelly-Apps/Bookstack/bookstack-uninstall.jelly.bash
# =============================================================================
#
# MODES:
#   Full clean (containers + volumes — guaranteed fresh install next run):
#     bash bookstack-uninstall.jelly.bash
#
#   Keep DB, wipe app config only (fixes stale .env issues):
#     WIPE_APP_ONLY=true bash bookstack-uninstall.jelly.bash
#
#   Keep all volumes (containers only):
#     KEEP_DATA=true bash bookstack-uninstall.jelly.bash
#
# =============================================================================

set -euo pipefail

BOOKSTACK_CONTAINER="${BOOKSTACK_CONTAINER:-bookstack}"
BOOKSTACK_DB_CONTAINER="${BOOKSTACK_DB_CONTAINER:-bookstack-db}"
KEEP_DATA="${KEEP_DATA:-false}"
WIPE_APP_ONLY="${WIPE_APP_ONLY:-false}"

echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  BOOKSTACK UNINSTALLER                              │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""

if [ "${WIPE_APP_ONLY}" = "true" ]; then
    echo "  Mode: WIPE APP CONFIG (keeps database)"
    read -rp "  Type 'wipe' to confirm: " CONFIRM
    [ "${CONFIRM}" = "wipe" ] || { echo "  Cancelled."; exit 0; }
elif [ "${KEEP_DATA}" = "true" ]; then
    echo "  Mode: CONTAINERS ONLY (volumes preserved)"
    read -rp "  Type 'remove' to confirm: " CONFIRM
    [ "${CONFIRM}" = "remove" ] || { echo "  Cancelled."; exit 0; }
else
    echo "  Mode: FULL UNINSTALL (containers + volumes)"
    echo "  MinIO uploaded files are NOT deleted."
    echo ""
    read -rp "  Type 'uninstall' to confirm: " CONFIRM
    [ "${CONFIRM}" = "uninstall" ] || { echo "  Cancelled."; exit 0; }
fi

echo ""

# --- Stop and remove BookStack (always) ---
echo "→ Stopping bookstack..."
docker stop "${BOOKSTACK_CONTAINER}" 2>/dev/null && echo "  ✓" || echo "  (not running)"
docker rm "${BOOKSTACK_CONTAINER}" 2>/dev/null && echo "  ✓ removed" || echo "  (already removed)"

# --- DB container (skip in WIPE_APP_ONLY) ---
if [ "${WIPE_APP_ONLY}" != "true" ]; then
    echo "→ Stopping bookstack-db..."
    docker stop "${BOOKSTACK_DB_CONTAINER}" 2>/dev/null && echo "  ✓" || echo "  (not running)"
    docker rm "${BOOKSTACK_DB_CONTAINER}" 2>/dev/null && echo "  ✓ removed" || echo "  (already removed)"
fi

# --- Volumes ---
if [ "${KEEP_DATA}" != "true" ]; then
    # App volume — always remove (contains stale .env)
    echo "→ Removing bookstack-app-data volume..."
    docker volume rm bookstack-app-data 2>/dev/null && echo "  ✓ removed" || echo "  (not found)"

    if [ "${WIPE_APP_ONLY}" != "true" ]; then
        echo "→ Removing bookstack-db-data volume..."
        docker volume rm bookstack-db-data 2>/dev/null && echo "  ✓ removed" || echo "  (not found)"

        echo "→ Removing bookstack-internal network..."
        docker network rm bookstack-internal 2>/dev/null && echo "  ✓ removed" || echo "  (not found)"
    fi
fi

echo ""

if [ "${WIPE_APP_ONLY}" = "true" ]; then
    echo "  ✓ App config wiped. DB intact."
elif [ "${KEEP_DATA}" = "true" ]; then
    echo "  ✓ Containers removed. Volumes intact."
else
    echo "  ✓ Full uninstall complete."
fi

echo "  Redeploy: bash bookstack.jelly.bash"
echo ""
