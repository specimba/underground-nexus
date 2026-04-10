#!/usr/bin/env bash
# =============================================================================
# SOVEREIGN MASTER INSTALLER
# Underground Nexus — Install All Container Engine Add-Ons
# File: install-all.jelly.bash
# =============================================================================
#
# Installs every foundation Jelly App in the correct dependency order.
# Skips apps that are already running (fully idempotent).
# Also functions as a REPAIR command — re-runs any app that is stopped.
#
# USAGE:
#   Install everything:
#     bash install-all.jelly.bash
#
#   Install specific tier only:
#     TIER=core bash install-all.jelly.bash         # MinIO + Cerberus only
#     TIER=productivity bash install-all.jelly.bash  # BookStack + Vaultwarden
#     TIER=ops bash install-all.jelly.bash           # n8n + Portainer + Uptime
#     TIER=kanban bash install-all.jelly.bash        # Planka only
#     TIER=all bash install-all.jelly.bash           # everything (default)
#
#   Repair (restart stopped containers without reinstalling):
#     REPAIR=true bash install-all.jelly.bash
#
# INSTALL ORDER (dependency-aware):
#   1. MinIO         — object storage (required by BookStack S3)
#   2. BookStack     — knowledge base
#   3. Vaultwarden   — password vault
#   4. n8n           — automation/webhooks (required by Support ticketing)
#   5. Portainer     — container management UI
#   6. Uptime Kuma   — health monitoring
#   7. Planka        — stigmergic kanban board
#
# =============================================================================

set -eo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

TIER="${TIER:-all}"
REPAIR="${REPAIR:-false}"

# Jelly script search paths — checked in order
JELLY_SEARCH_PATHS=(
    "/underground-nexus/Jelly-Apps"
    "/nexus-bucket/underground-nexus/Jelly-Apps"
    "$(dirname "${BASH_SOURCE[0]}")/Jelly-Apps"
    "$(dirname "${BASH_SOURCE[0]}")"
    "$(pwd)/Jelly-Apps"
    "$(pwd)"
)

RESULTS=()
FAILED=()
SKIPPED=()

# =============================================================================
# HELPERS
# =============================================================================

log()     { echo "[install-all] $*"; }
ok()      { echo "[install-all] ✓ $*"; }
warn()    { echo "[install-all] ⚠ $*"; }
err()     { echo "[install-all] ✗ $*" >&2; }
section() {
    echo ""
    printf '─%.0s' {1..60}; echo ""
    echo "  $*"
    printf '─%.0s' {1..60}; echo ""
    echo ""
}

find_jelly() {
    local APP_DIR="$1"
    local SCRIPT="$2"
    for BASE in "${JELLY_SEARCH_PATHS[@]}"; do
        if [ -f "${BASE}/${APP_DIR}/${SCRIPT}" ]; then
            echo "${BASE}/${APP_DIR}/${SCRIPT}"
            return 0
        fi
        # Also try flat (script directly in search path)
        if [ -f "${BASE}/${SCRIPT}" ]; then
            echo "${BASE}/${SCRIPT}"
            return 0
        fi
    done
    echo ""
    return 1
}

is_running() {
    docker ps --format '{{.Names}}' | grep -qx "$1"
}

is_stopped() {
    docker ps -a --format '{{.Names}}' | grep -qx "$1" && \
        ! docker ps --format '{{.Names}}' | grep -qx "$1"
}

# Run a jelly app script — handles running/stopped/missing cases
run_app() {
    local DISPLAY_NAME="$1"
    local CONTAINER_NAME="$2"
    local APP_DIR="$3"
    local SCRIPT_NAME="$4"

    section "${DISPLAY_NAME}"

    # Already running
    if is_running "${CONTAINER_NAME}"; then
        ok "${DISPLAY_NAME} already running — skipping"
        SKIPPED+=("${DISPLAY_NAME}")
        return 0
    fi

    # Stopped container — start it (repair mode or normal)
    if is_stopped "${CONTAINER_NAME}"; then
        warn "${DISPLAY_NAME} container exists but is stopped"
        if [ "${REPAIR}" = "true" ]; then
            log "Repair mode: starting stopped container..."
            docker start "${CONTAINER_NAME}" 2>/dev/null \
                && ok "${DISPLAY_NAME} restarted" \
                || err "${DISPLAY_NAME} failed to start"
            RESULTS+=("${DISPLAY_NAME} (repaired)")
            return 0
        fi
    fi

    # Find the jelly script
    local JELLY
    JELLY=$(find_jelly "${APP_DIR}" "${SCRIPT_NAME}") || true

    if [ -z "${JELLY}" ]; then
        err "${DISPLAY_NAME}: script not found: ${SCRIPT_NAME}"
        err "  Searched:"
        for BASE in "${JELLY_SEARCH_PATHS[@]}"; do
            err "    ${BASE}/${APP_DIR}/${SCRIPT_NAME}"
        done
        FAILED+=("${DISPLAY_NAME} (script not found)")
        return 1
    fi

    log "Running: ${JELLY}"
    if bash "${JELLY}"; then
        ok "${DISPLAY_NAME} installed successfully"
        RESULTS+=("${DISPLAY_NAME}")
    else
        err "${DISPLAY_NAME} installation failed"
        FAILED+=("${DISPLAY_NAME}")
        return 1
    fi
}

# =============================================================================
# BANNER
# =============================================================================

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║   SOVEREIGN MASTER INSTALLER                             ║"
echo "  ║   Container Engine Add-Ons — Foundation Stack           ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""
log "Tier: ${TIER} | Repair mode: ${REPAIR}"
echo ""

# =============================================================================
# TIER: CORE (MinIO — required first, others depend on it)
# =============================================================================

if [[ "${TIER}" == "all" || "${TIER}" == "core" ]]; then
    section "CHECKING CORE SERVICES"

    # MinIO — deployed by sovereign installer, verify it's running
    if is_running "minio"; then
        ok "MinIO already running — core storage confirmed"
        SKIPPED+=("MinIO")
    else
        err "MinIO is NOT running. Run the sovereign installer first."
        err "  sudo ./sovereign-installer  (Linux)"
        err "  sovereign-installer.exe     (Windows)"
        err "  ./sovereign-installer-mac   (macOS)"
        err "Core dependency missing — some apps may fail without MinIO."
        echo ""
    fi

    if is_running "cerberus-manager"; then
        ok "Cerberus Manager running — C2 confirmed"
        SKIPPED+=("Cerberus Manager")
    else
        warn "Cerberus Manager not running — some apps may not have full C2 access"
    fi
fi

# =============================================================================
# TIER: PRODUCTIVITY (BookStack + Vaultwarden)
# =============================================================================

if [[ "${TIER}" == "all" || "${TIER}" == "productivity" ]]; then
    run_app "BookStack" "bookstack" "Bookstack" "bookstack.jelly.bash" || true
    run_app "Vaultwarden" "vaultwarden" "Vaultwarden" "vaultwarden.jelly.bash" || true
fi

# =============================================================================
# TIER: OPS (n8n + Portainer + Uptime Kuma)
# =============================================================================

if [[ "${TIER}" == "all" || "${TIER}" == "ops" ]]; then
    run_app "n8n Automation" "n8n" "n8n" "n8n.jelly.bash" || true
    run_app "Portainer" "portainer" "Portainer" "portainer.jelly.bash" || true
    run_app "Uptime Kuma" "uptime-kuma" "Uptime-Kuma" "uptime-kuma.jelly.bash" || true
fi

# =============================================================================
# TIER: KANBAN (Planka)
# =============================================================================

if [[ "${TIER}" == "all" || "${TIER}" == "kanban" ]]; then
    run_app "Planka Kanban" "planka" "Planka" "planka.jelly.bash" || true
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║   INSTALLATION SUMMARY                                   ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""

if [ "${#RESULTS[@]}" -gt 0 ]; then
    echo "  ✓ Installed:"
    for R in "${RESULTS[@]}"; do
        echo "    • ${R}"
    done
    echo ""
fi

if [ "${#SKIPPED[@]}" -gt 0 ]; then
    echo "  → Already running (skipped):"
    for S in "${SKIPPED[@]}"; do
        echo "    • ${S}"
    done
    echo ""
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "  ✗ Failed:"
    for F in "${FAILED[@]}"; do
        echo "    • ${F}"
    done
    echo ""
    echo "  Check logs above for each failed app."
    echo "  Retry individual apps with:"
    echo "    bash <AppName>/<app>.jelly.bash"
    echo ""
fi

echo "  Current container status:"
docker ps --format "    {{.Names}}\t{{.Status}}" 2>/dev/null || true
echo ""

echo "  ┌────────────────────────────────────────────────────────┐"
echo "  │  ENDPOINTS (when all apps running)                     │"
echo "  │  http://localhost         Cerberus Web UI              │"
echo "  │  http://localhost:4050    BookStack                    │"
echo "  │  http://localhost:8080    Vaultwarden                  │"
echo "  │  http://localhost:5678    n8n Automation               │"
echo "  │  https://localhost:9443   Portainer                    │"
echo "  │  http://localhost:3001    Uptime Kuma                  │"
echo "  │  http://localhost:3000    Planka Kanban                │"
echo "  │  http://localhost:9000    MinIO API                    │"
echo "  │  http://localhost:9001    MinIO Console                │"
echo "  ├────────────────────────────────────────────────────────┤"
echo "  │  UPDATE:  bash sovereign-update.sh                     │"
echo "  │  REPAIR:  REPAIR=true bash install-all.jelly.bash      │"
echo "  └────────────────────────────────────────────────────────┘"
echo ""

[ "${#FAILED[@]}" -eq 0 ]
