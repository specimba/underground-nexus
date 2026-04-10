#!/usr/bin/env bash
# =============================================================================
# UPTIME KUMA JELLY APP
# Underground Nexus — Sovereign Service Health Monitor
# File: Jelly-Apps/Uptime-Kuma/uptime-kuma.jelly.bash
# =============================================================================
#
# WHAT THIS DEPLOYS:
#   Uptime Kuma — self-hosted monitoring dashboard (UptimeRobot alternative)
#
# ROLE IN THE SOVEREIGN STACK:
#   Monitors all sovereign services and alerts on downtime:
#     - BookStack (http://127.0.0.1:4050)
#     - Vaultwarden (http://127.0.0.1:8080)
#     - n8n (http://127.0.0.1:5678)
#     - MinIO (http://minio:9000 — internal)
#     - Cerberus Manager (http://cerberus-manager)
#     - Custom TCP/HTTP checks for any service
#
#   Sends alerts via:
#     - n8n webhook (routes to Zoho CRM, email, Slack, etc.)
#     - Direct email (SMTP configurable in UI)
#     - Apprise (multi-notification aggregator)
#
# PORT SECURITY:
#   127.0.0.1:3001 — localhost only (WARP/Tunnel for external access)
#
# =============================================================================

set -euo pipefail

UK_CONTAINER="${UK_CONTAINER:-uptime-kuma}"
UK_HOST_PORT="${UK_HOST_PORT:-3001}"
UK_VOLUME="uptime-kuma-data"
NETWORK="sovereign-net"

log()  { echo "[uptime-kuma] $*"; }
ok()   { echo "[uptime-kuma] ✓ $*"; }
warn() { echo "[uptime-kuma] ⚠ $*"; }
err()  { echo "[uptime-kuma] ✗ $*" >&2; }
die()  { err "$*"; exit 1; }

log "Checking deployment state..."

if docker ps --format '{{.Names}}' | grep -qx "${UK_CONTAINER}"; then
    ok "Uptime Kuma already running at http://127.0.0.1:${UK_HOST_PORT}"
    exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "${UK_CONTAINER}"; then
    warn "Stopped container found — starting..."
    docker start "${UK_CONTAINER}" || die "Failed to start uptime-kuma"
    ok "Started. http://127.0.0.1:${UK_HOST_PORT}"
    exit 0
fi

log "Deploying Uptime Kuma..."

docker run -d \
    --name "${UK_CONTAINER}" \
    --restart unless-stopped \
    --network "${NETWORK}" \
    -p "127.0.0.1:${UK_HOST_PORT}:3001" \
    -v "${UK_VOLUME}:/app/data" \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -e "TZ=${TZ:-America/Denver}" \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.uptime.rule=PathPrefix(\`/uptime\`)" \
    --label "traefik.http.routers.uptime.entrypoints=web" \
    --label "traefik.http.services.uptime.loadbalancer.server.port=3001" \
    --label "traefik.http.middlewares.uptime-strip.stripprefix.prefixes=/uptime" \
    --label "traefik.http.routers.uptime.middlewares=uptime-strip@docker" \
    louislam/uptime-kuma:latest

log "Polling http://127.0.0.1:${UK_HOST_PORT} ..."
UK_READY=0
for i in $(seq 1 12); do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "http://127.0.0.1:${UK_HOST_PORT}" 2>/dev/null || echo "000")
    if [ "${HTTP}" != "000" ]; then
        UK_READY=1
        ok "Uptime Kuma responded HTTP ${HTTP} after $((i*5))s."
        break
    fi
    log "  ${i}/12 — $((i*5))s"
    sleep 5
done

echo ""
if [ "${UK_READY}" -eq 1 ]; then
    echo "  ┌────────────────────────────────────────────────────────┐"
    echo "  │  ✓ Uptime Kuma is live                                 │"
    echo "  ├────────────────────────────────────────────────────────┤"
    echo "  │  URL: http://127.0.0.1:${UK_HOST_PORT}                      │"
    echo "  ├────────────────────────────────────────────────────────┤"
    echo "  │  RECOMMENDED MONITORS TO ADD:                          │"
    echo "  │  BookStack    http://127.0.0.1:4050                    │"
    echo "  │  Vaultwarden  http://127.0.0.1:8080                    │"
    echo "  │  n8n          http://127.0.0.1:5678                    │"
    echo "  │  MinIO API    http://minio:9000 (internal)             │"
    echo "  │  Cerberus     http://cerberus-manager (internal)       │"
    echo "  ├────────────────────────────────────────────────────────┤"
    echo "  │  Connect alerts to n8n webhook for CRM routing         │"
    echo "  └────────────────────────────────────────────────────────┘"
    echo ""
    echo "  Logs:      docker logs uptime-kuma"
    echo "  Uninstall: bash uptime-kuma-uninstall.jelly.bash"
else
    err "Uptime Kuma did not respond within 60s."
    docker logs --tail 20 "${UK_CONTAINER}" 2>&1 | sed 's/^/  /'
    exit 1
fi
