#!/usr/bin/env bash
# =============================================================================
# N8N JELLY APP
# Underground Nexus — Sovereign Automation & Webhook Engine
# File: Jelly-Apps/n8n/n8n.jelly.bash
# =============================================================================
#
# WHAT THIS DEPLOYS:
#   n8n — self-hosted workflow automation (Zapier/Make alternative)
#
# ROLE IN THE SOVEREIGN STACK:
#   n8n is the automation backbone. It receives webhooks from:
#     - Vaultwarden Support channel → routes to Zoho CRM
#     - BookStack updates → notifies Dojo channel in chat
#     - sovereign-update.sh completion → sends status notification
#     - Cerberus API events → triggers downstream workflows
#
#   SUPPORT_WEBHOOK_URL in sovereign-chat points to:
#     http://n8n:5678/webhook/<your-workflow-id>
#
# PORT SECURITY:
#   127.0.0.1:5678 — localhost only (WARP/Tunnel for external access)
#
# STORAGE:
#   n8n-data — named volume for workflows, credentials, execution history
#
# =============================================================================

set -euo pipefail

N8N_CONTAINER="${N8N_CONTAINER:-n8n}"
N8N_HOST_PORT="${N8N_HOST_PORT:-5678}"
N8N_VOLUME="n8n-data"
NETWORK="sovereign-net"

N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-$(openssl rand -hex 32)}"
N8N_HOST="${N8N_HOST:-localhost}"
N8N_PROTOCOL="${N8N_PROTOCOL:-http}"
WEBHOOK_URL="${WEBHOOK_URL:-http://localhost:${N8N_HOST_PORT}/}"

log()  { echo "[n8n] $*"; }
ok()   { echo "[n8n] ✓ $*"; }
warn() { echo "[n8n] ⚠ $*"; }
err()  { echo "[n8n] ✗ $*" >&2; }
die()  { err "$*"; exit 1; }

log "Checking deployment state..."

if docker ps --format '{{.Names}}' | grep -qx "${N8N_CONTAINER}"; then
    ok "n8n already running at http://127.0.0.1:${N8N_HOST_PORT}"
    exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "${N8N_CONTAINER}"; then
    warn "Stopped container found — starting..."
    docker start "${N8N_CONTAINER}" || die "Failed to start n8n"
    ok "Started. http://127.0.0.1:${N8N_HOST_PORT}"
    exit 0
fi

# Persist encryption key so workflows survive container recreation
# Write to volume before first start
docker run --rm \
    -v "${N8N_VOLUME}:/home/node/.n8n" \
    alpine:latest \
    sh -c "mkdir -p /home/node/.n8n && \
           echo 'N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}' > /home/node/.n8n/.env && \
           chown -R 1000:1000 /home/node/.n8n" 2>/dev/null || true

log "Deploying n8n..."

docker run -d \
    --name "${N8N_CONTAINER}" \
    --restart unless-stopped \
    --network "${NETWORK}" \
    -p "127.0.0.1:${N8N_HOST_PORT}:5678" \
    -e "N8N_HOST=${N8N_HOST}" \
    -e "N8N_PORT=5678" \
    -e "N8N_PROTOCOL=${N8N_PROTOCOL}" \
    -e "NODE_ENV=production" \
    -e "WEBHOOK_URL=${WEBHOOK_URL}" \
    -e "N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}" \
    -e "N8N_METRICS=false" \
    -e "N8N_LOG_LEVEL=warn" \
    -e "EXECUTIONS_DATA_PRUNE=true" \
    -e "EXECUTIONS_DATA_MAX_AGE=168" \
    -e PUID=1000 \
    -e PGID=1000 \
    -e "TZ=${TZ:-America/Denver}" \
    -v "${N8N_VOLUME}:/home/node/.n8n" \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.n8n.rule=PathPrefix(\`/n8n\`)" \
    --label "traefik.http.routers.n8n.entrypoints=web" \
    --label "traefik.http.services.n8n.loadbalancer.server.port=5678" \
    --label "traefik.http.middlewares.n8n-strip.stripprefix.prefixes=/n8n" \
    --label "traefik.http.routers.n8n.middlewares=n8n-strip@docker" \
    n8nio/n8n:latest

log "Polling http://127.0.0.1:${N8N_HOST_PORT} ..."
N8N_READY=0
for i in $(seq 1 18); do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "http://127.0.0.1:${N8N_HOST_PORT}" 2>/dev/null || echo "000")
    if [ "${HTTP}" != "000" ]; then
        N8N_READY=1
        ok "n8n responded HTTP ${HTTP} after $((i*5))s."
        break
    fi
    log "  ${i}/18 — $((i*5))s"
    sleep 5
done

echo ""
if [ "${N8N_READY}" -eq 1 ]; then
    echo "  ┌────────────────────────────────────────────────────────┐"
    echo "  │  ✓ n8n Automation Engine is live                       │"
    echo "  ├────────────────────────────────────────────────────────┤"
    echo "  │  URL:      http://127.0.0.1:${N8N_HOST_PORT}               │"
    echo "  │  Webhooks: http://n8n:5678/webhook/<id>                │"
    echo "  │  Data:     n8n-data volume                             │"
    echo "  ├────────────────────────────────────────────────────────┤"
    echo "  │  USE CASES IN THIS STACK:                              │"
    echo "  │  - Support ticket → Zoho CRM routing                  │"
    echo "  │  - sovereign-update.sh completion notifications        │"
    echo "  │  - BookStack → Chat Dojo announcements                 │"
    echo "  ├────────────────────────────────────────────────────────┤"
    echo "  │  Set SUPPORT_WEBHOOK_URL in sovereign-chat to:         │"
    echo "  │  http://n8n:5678/webhook/<your-workflow-id>            │"
    echo "  └────────────────────────────────────────────────────────┘"
    echo ""
    echo "  Logs:      docker logs n8n"
    echo "  Uninstall: bash n8n-uninstall.jelly.bash"
else
    err "n8n did not respond within 90s."
    docker logs --tail 20 "${N8N_CONTAINER}" 2>&1 | sed 's/^/  /'
    exit 1
fi
