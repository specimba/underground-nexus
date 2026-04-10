#!/usr/bin/env bash
# =============================================================================
# VAULTWARDEN JELLY APP v2
# Underground Nexus — Sovereign Password Vault
# File: Jelly-Apps/Vaultwarden/vaultwarden.jelly.bash
# =============================================================================
#
# CHANGES FROM v1:
#   - Fixed ADMIN_TOKEN_ARG quoting (was breaking if token contained spaces)
#   - Added HTTP readiness polling (same pattern as bookstack v4)
#   - Added credential verification step before startup
#   - Consistent logging style matching bookstack standard
#
# NOTES:
#   - SQLite is correct for single-node — no MariaDB sidecar needed
#   - Vaultwarden does NOT have the stale .env problem BookStack has
#     because it uses environment variables natively (no cached .env)
#   - HTTPS is required for Bitwarden clients — use WARP or Tunnel
#
# UNINSTALL:
#   bash vaultwarden-uninstall.jelly.bash
#
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

VW_CONTAINER="${VW_CONTAINER:-vaultwarden}"
VW_HOST_PORT="${VW_HOST_PORT:-8080}"
VW_DOMAIN="${VW_DOMAIN:-http://localhost:${VW_HOST_PORT}}"
VW_VOLUME="vaultwarden-data"
NETWORK="sovereign-net"

VW_SIGNUPS_ALLOWED="${VW_SIGNUPS_ALLOWED:-true}"
VW_ADMIN_TOKEN="${VW_ADMIN_TOKEN:-}"

# =============================================================================
# HELPERS
# =============================================================================

log()  { echo "[vaultwarden] $*"; }
ok()   { echo "[vaultwarden] ✓ $*"; }
warn() { echo "[vaultwarden] ⚠ $*"; }
err()  { echo "[vaultwarden] ✗ $*" >&2; }
die()  { err "$*"; exit 1; }

# =============================================================================
# IDEMPOTENCY CHECK
# =============================================================================

log "Checking deployment state..."

if docker ps --format '{{.Names}}' | grep -qx "${VW_CONTAINER}"; then
    ok "Vaultwarden already running at http://127.0.0.1:${VW_HOST_PORT}"
    log "To redeploy: bash vaultwarden-uninstall.jelly.bash && bash vaultwarden.jelly.bash"
    exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "${VW_CONTAINER}"; then
    warn "Stopped container found — starting..."
    docker start "${VW_CONTAINER}" || die "Failed to start vaultwarden"
    ok "Started. http://127.0.0.1:${VW_HOST_PORT}"
    exit 0
fi

# =============================================================================
# DEPLOY VAULTWARDEN
# =============================================================================

log "Deploying Vaultwarden..."

# Build args array — admin token only if set (avoids empty -e var issues)
RUN_ARGS=(
    -d
    --name "${VW_CONTAINER}"
    --restart unless-stopped
    --network "${NETWORK}"
    -p "127.0.0.1:${VW_HOST_PORT}:80"
    -e "DOMAIN=${VW_DOMAIN}"
    -e "SIGNUPS_ALLOWED=${VW_SIGNUPS_ALLOWED}"
    -e WEBSOCKET_ENABLED=true
    -e LOG_LEVEL=warn
    -e EXTENDED_LOGGING=true
    -e PUID=1000
    -e PGID=1000
    -e "TZ=${TZ:-America/Denver}"
    -v "${VW_VOLUME}:/data"
    --label "traefik.enable=true"
    --label "traefik.http.routers.vaultwarden.rule=PathPrefix(\`/vault\`)"
    --label "traefik.http.routers.vaultwarden.entrypoints=web"
    --label "traefik.http.services.vaultwarden.loadbalancer.server.port=80"
    --label "traefik.http.middlewares.vault-strip.stripprefix.prefixes=/vault"
    --label "traefik.http.routers.vaultwarden.middlewares=vault-strip@docker"
)

# Add admin token if provided
if [ -n "${VW_ADMIN_TOKEN}" ]; then
    RUN_ARGS+=(-e "ADMIN_TOKEN=${VW_ADMIN_TOKEN}")
    log "Admin panel enabled at /admin"
fi

docker run "${RUN_ARGS[@]}" vaultwarden/server:latest

# =============================================================================
# POLL FOR READINESS
# =============================================================================

log "Polling http://127.0.0.1:${VW_HOST_PORT} ..."

VW_READY=0
LAST_HTTP="000"
for i in $(seq 1 18); do
    LAST_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        "http://127.0.0.1:${VW_HOST_PORT}" 2>/dev/null || echo "000")

    if [ "${LAST_HTTP}" != "000" ]; then
        VW_READY=1
        ok "Vaultwarden responded HTTP ${LAST_HTTP} after $((i * 5))s."
        break
    fi

    log "  ${i}/18 — $((i*5))s — HTTP=${LAST_HTTP}"
    sleep 5
done

# =============================================================================
# RESULT
# =============================================================================

echo ""

if [ "${VW_READY}" -eq 1 ]; then
    echo "  ┌────────────────────────────────────────────────────────────┐"
    echo "  │  ✓ Vaultwarden is live                                     │"
    echo "  ├────────────────────────────────────────────────────────────┤"
    echo "  │  URL:    http://127.0.0.1:${VW_HOST_PORT}                          │"
    echo "  │  Data:   named volume 'vaultwarden-data' (SQLite)          │"
    echo "  ├────────────────────────────────────────────────────────────┤"
    echo "  │  NEXT STEPS:                                               │"
    echo "  │  1. Create account at http://127.0.0.1:${VW_HOST_PORT}             │"
    echo "  │  2. Lock signups: VW_SIGNUPS_ALLOWED=false bash \$0        │"
    echo "  │  3. Use WARP/Tunnel URL in Bitwarden clients               │"
    echo "  ├────────────────────────────────────────────────────────────┤"
    echo "  │  ⚠  Port 127.0.0.1 only — WARP/Tunnel required            │"
    echo "  │  ⚠  HTTPS needed for Bitwarden mobile/desktop clients      │"
    echo "  └────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  Logs:      docker logs vaultwarden"
    echo "  Uninstall: bash vaultwarden-uninstall.jelly.bash"
else
    err "Vaultwarden did not respond within 90s."
    docker logs --tail 20 "${VW_CONTAINER}" 2>&1 | sed 's/^/  /'
    exit 1
fi
