#!/usr/bin/env bash
# =============================================================================
# PORTAINER JELLY APP v2
# Underground Nexus — Sovereign Container Management UI
# File: Jelly-Apps/Portainer/portainer.jelly.bash
# =============================================================================
#
# PORT FIX v2:
#   MinIO owns port 9000 on the host.
#   Portainer HTTP is now mapped to 9005 (→ internal 9000).
#   Portainer HTTPS remains at 9443 (→ internal 9443).
#   Use HTTPS (9443) as primary — Portainer redirects HTTP to HTTPS internally.
#
# PORTS:
#   127.0.0.1:9005  → Portainer HTTP  (redirects to HTTPS)
#   127.0.0.1:9443  → Portainer HTTPS (primary UI)
#
# =============================================================================

set -euo pipefail

PT_CONTAINER="${PT_CONTAINER:-portainer}"
PT_HTTP_PORT="${PT_HTTP_PORT:-9005}"
PT_HTTPS_PORT="${PT_HTTPS_PORT:-9443}"
PT_VOLUME="portainer-data"
NETWORK="sovereign-net"

log()  { echo "[portainer] $*"; }
ok()   { echo "[portainer] ✓ $*"; }
warn() { echo "[portainer] ⚠ $*"; }
err()  { echo "[portainer] ✗ $*" >&2; }
die()  { err "$*"; exit 1; }

log "Checking deployment state..."

if docker ps --format '{{.Names}}' | grep -qx "${PT_CONTAINER}"; then
    ok "Portainer already running at https://127.0.0.1:${PT_HTTPS_PORT}"
    exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "${PT_CONTAINER}"; then
    warn "Stopped container found — starting..."
    docker start "${PT_CONTAINER}" || die "Failed to start portainer"
    ok "Started. https://127.0.0.1:${PT_HTTPS_PORT}"
    exit 0
fi

# Verify no port conflict on 9443 before deploying
if ss -tlnp 2>/dev/null | grep -q ":${PT_HTTPS_PORT}" || \
   netstat -tlnp 2>/dev/null | grep -q ":${PT_HTTPS_PORT}"; then
    warn "Port ${PT_HTTPS_PORT} already in use. Check: ss -tlnp | grep ${PT_HTTPS_PORT}"
    warn "Override: PT_HTTPS_PORT=9444 bash $0"
fi

log "Deploying Portainer CE..."
log "HTTP:  127.0.0.1:${PT_HTTP_PORT} (→ internal 9000)"
log "HTTPS: 127.0.0.1:${PT_HTTPS_PORT} (→ internal 9443)"

docker run -d \
    --name "${PT_CONTAINER}" \
    --restart unless-stopped \
    --network "${NETWORK}" \
    -p "127.0.0.1:${PT_HTTP_PORT}:9000" \
    -p "127.0.0.1:${PT_HTTPS_PORT}:9443" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${PT_VOLUME}:/data" \
    -e "TZ=${TZ:-America/Denver}" \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.portainer.rule=PathPrefix(\`/portainer\`)" \
    --label "traefik.http.routers.portainer.entrypoints=web" \
    --label "traefik.http.services.portainer.loadbalancer.server.port=9000" \
    --label "traefik.http.middlewares.portainer-strip.stripprefix.prefixes=/portainer" \
    --label "traefik.http.routers.portainer.middlewares=portainer-strip@docker" \
    portainer/portainer-ce:latest

log "Polling https://127.0.0.1:${PT_HTTPS_PORT} ..."
PT_READY=0
for i in $(seq 1 12); do
    HTTP=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 \
        "https://127.0.0.1:${PT_HTTPS_PORT}" 2>/dev/null || echo "000")
    if [ "${HTTP}" != "000" ]; then
        PT_READY=1
        ok "Portainer responded HTTP ${HTTP} after $((i*5))s."
        break
    fi
    log "  ${i}/12 — $((i*5))s"
    sleep 5
done

echo ""
if [ "${PT_READY}" -eq 1 ]; then
    echo "  ┌────────────────────────────────────────────────────────┐"
    echo "  │  ✓ Portainer CE is live                                │"
    echo "  ├────────────────────────────────────────────────────────┤"
    echo "  │  HTTPS (primary): https://127.0.0.1:${PT_HTTPS_PORT}       │"
    echo "  │  HTTP  (redirect): http://127.0.0.1:${PT_HTTP_PORT}        │"
    echo "  ├────────────────────────────────────────────────────────┤"
    echo "  │  ⚠  Create admin account WITHIN 5 MINUTES of start    │"
    echo "  │     After 5min timeout: restart container to reset     │"
    echo "  │     docker restart portainer                           │"
    echo "  │  ⚠  Accept self-signed cert warning in browser         │"
    echo "  │  ✓  MinIO port 9000 is NOT conflicted (using 9005)     │"
    echo "  └────────────────────────────────────────────────────────┘"
    echo ""
    echo "  Logs:      docker logs portainer"
    echo "  Uninstall: bash portainer-uninstall.jelly.bash"
else
    err "Portainer did not respond within 60s."
    docker logs --tail 20 "${PT_CONTAINER}" 2>&1 | sed 's/^/  /'
    exit 1
fi
