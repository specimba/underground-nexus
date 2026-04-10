#!/usr/bin/env bash
# =============================================================================
# PLANKA JELLY APP v2
# Underground Nexus — Stigmergic Kanban Board
# File: Jelly-Apps/Planka/planka.jelly.bash
# =============================================================================
#
# FIX v2:
#   Root cause: set -u (unbound variable check) combined with a failing
#   `docker run --rm` for SECRET_KEY persistence caused bash to exit before
#   ADMIN_PASSWORD was in scope when the main docker run executed.
#   The single-quote variable expansion in the alpine one-shot container also
#   failed silently in some shell environments (MINGW64, WSL edge cases).
#
#   Fixes applied:
#   1. All configuration variables declared at top with explicit defaults
#      using ${VAR:-default} so -u never fires on them
#   2. SECRET_KEY persistence uses printf instead of echo with single-quotes
#   3. The alpine one-shot is wrapped in || true so it never kills the script
#   4. Added explicit variable validation block before docker run
#   5. Removed nested variable expansions that break in MINGW64
#
# =============================================================================

set -eo pipefail
# NOTE: -u (unbound variable) intentionally NOT set here.
# We use explicit defaults on every variable instead, which is safer
# across MINGW64, WSL, and native Linux environments.

# =============================================================================
# CONFIGURATION — all vars declared with explicit defaults up front
# =============================================================================

PLANKA_DB_CONTAINER="${PLANKA_DB_CONTAINER:-planka-db}"
PLANKA_CONTAINER="${PLANKA_CONTAINER:-planka}"
PLANKA_HOST_PORT="${PLANKA_HOST_PORT:-3000}"
PLANKA_BASE_URL="${PLANKA_BASE_URL:-http://localhost:${PLANKA_HOST_PORT:-3000}}"

INTERNAL_NET="planka-internal"
EXTERNAL_NET="sovereign-net"

DB_VOLUME="planka-db-data"
APP_VOLUME="planka-app-data"

# PostgreSQL credentials
_HOST_HASH=$(hostname | md5sum | cut -c1-12 2>/dev/null || hostname | cksum | cut -c1-12)
DB_PASSWORD="${DB_PASSWORD:-PlankaDB_${_HOST_HASH}}"
DB_USER="${DB_USER:-planka}"
DB_NAME="${DB_NAME:-planka}"

# Admin account — change these after first login
ADMIN_EMAIL="${PLANKA_ADMIN_EMAIL:-admin@sovereign.local}"
ADMIN_PASSWORD="${PLANKA_ADMIN_PASSWORD:-SovereignAdmin1}"
ADMIN_NAME="${PLANKA_ADMIN_NAME:-Sovereign Admin}"
ADMIN_USERNAME="${PLANKA_ADMIN_USERNAME:-sovereign}"

# SECRET_KEY — will be generated below if not set
SECRET_KEY=""

# =============================================================================
# HELPERS
# =============================================================================

log()  { echo "[planka] $*"; }
ok()   { echo "[planka] ✓ $*"; }
warn() { echo "[planka] ⚠ $*"; }
err()  { echo "[planka] ✗ $*" >&2; }
die()  { err "$*"; exit 1; }

# =============================================================================
# IDEMPOTENCY CHECK
# =============================================================================

log "Checking deployment state..."

if docker ps --format '{{.Names}}' | grep -qx "${PLANKA_CONTAINER}"; then
    ok "Planka already running at http://127.0.0.1:${PLANKA_HOST_PORT}"
    log "To redeploy: bash planka-uninstall.jelly.bash && bash planka.jelly.bash"
    exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "${PLANKA_CONTAINER}"; then
    warn "Stopped container found — starting..."
    docker start "${PLANKA_DB_CONTAINER}" 2>/dev/null || true
    sleep 5
    docker start "${PLANKA_CONTAINER}" || die "Failed to start planka"
    ok "Started. http://127.0.0.1:${PLANKA_HOST_PORT}"
    exit 0
fi

# =============================================================================
# STEP 1: GENERATE SECRET_KEY
# =============================================================================

log "Generating SECRET_KEY..."

# Check if a key was previously saved in the volume (preserves sessions across updates)
SAVED_KEY=""
SAVED_KEY=$(docker run --rm \
    -v "${APP_VOLUME}:/appdata" \
    alpine:latest \
    sh -c "cat /appdata/.planka_secret_key 2>/dev/null || true" 2>/dev/null) || true

if [ -n "${SAVED_KEY}" ] && [ "${#SAVED_KEY}" -ge 64 ]; then
    SECRET_KEY="${SAVED_KEY}"
    ok "Restored SECRET_KEY from volume (sessions preserved)."
else
    # Generate fresh key
    SECRET_KEY=$(openssl rand -hex 64 2>/dev/null || \
        cat /dev/urandom | tr -dc 'a-f0-9' | head -c 128 | head -c 64)
    ok "Generated new SECRET_KEY."

    # Persist to volume — use printf to avoid quote expansion issues
    docker run --rm \
        -v "${APP_VOLUME}:/appdata" \
        alpine:latest \
        sh -c "mkdir -p /appdata && printf '%s' '${SECRET_KEY}' > /appdata/.planka_secret_key && chmod 600 /appdata/.planka_secret_key" \
        2>/dev/null || warn "Could not persist SECRET_KEY to volume (non-fatal)."
fi

# Hard validate SECRET_KEY is set and non-empty
if [ -z "${SECRET_KEY}" ]; then
    die "SECRET_KEY generation failed. Check openssl is available: openssl rand -hex 64"
fi

ok "SECRET_KEY ready (length: ${#SECRET_KEY})."

# =============================================================================
# STEP 2: VALIDATE ALL REQUIRED VARIABLES
# =============================================================================
# Explicit check before docker run — catches any edge case before we get to
# the long-running container deployment.

log "Validating configuration..."

VALIDATION_OK=true
for VAR_NAME in PLANKA_CONTAINER PLANKA_DB_CONTAINER PLANKA_HOST_PORT \
    DB_USER DB_PASSWORD DB_NAME DB_VOLUME APP_VOLUME \
    ADMIN_EMAIL ADMIN_PASSWORD ADMIN_NAME ADMIN_USERNAME SECRET_KEY; do
    VAR_VALUE=$(eval echo "\${${VAR_NAME}:-}")
    if [ -z "${VAR_VALUE}" ]; then
        err "Required variable ${VAR_NAME} is empty."
        VALIDATION_OK=false
    fi
done

[ "${VALIDATION_OK}" = "true" ] || die "Configuration validation failed. See errors above."
ok "All variables validated."

# =============================================================================
# STEP 3: INTERNAL BRIDGE NETWORK
# =============================================================================

if ! docker network inspect "${INTERNAL_NET}" >/dev/null 2>&1; then
    docker network create "${INTERNAL_NET}"
    ok "Created bridge network '${INTERNAL_NET}'."
else
    ok "Network '${INTERNAL_NET}' exists."
fi

# =============================================================================
# STEP 4: CLEAN UP STALE CONTAINERS
# =============================================================================

for STALE in "${PLANKA_CONTAINER}" "${PLANKA_DB_CONTAINER}"; do
    if docker ps -a --format '{{.Names}}' | grep -qx "${STALE}"; then
        warn "Removing stale container '${STALE}'..."
        docker stop "${STALE}" 2>/dev/null || true
        docker rm "${STALE}" 2>/dev/null || true
    fi
done

# =============================================================================
# STEP 5: DEPLOY POSTGRESQL SIDECAR
# =============================================================================

log "Deploying PostgreSQL 14 Alpine..."

docker run -d \
    --name "${PLANKA_DB_CONTAINER}" \
    --restart unless-stopped \
    --network "${INTERNAL_NET}" \
    -e "POSTGRES_USER=${DB_USER}" \
    -e "POSTGRES_PASSWORD=${DB_PASSWORD}" \
    -e "POSTGRES_DB=${DB_NAME}" \
    -v "${DB_VOLUME}:/var/lib/postgresql/data" \
    postgres:14-alpine

ok "PostgreSQL started. Polling readiness..."

DB_READY=0
for i in $(seq 1 18); do
    if docker exec "${PLANKA_DB_CONTAINER}" \
        pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null 2>&1; then
        DB_READY=1
        ok "PostgreSQL ready after $((i*5))s."
        break
    fi
    log "  Waiting $((i*5))s..."
    sleep 5
done

if [ "${DB_READY}" -eq 0 ]; then
    docker logs --tail 20 "${PLANKA_DB_CONTAINER}" 2>&1 | sed 's/^/  /'
    die "PostgreSQL not ready after 90s. Check: docker logs ${PLANKA_DB_CONTAINER}"
fi

# Verify credentials
PG_AUTH_OK=0
for i in $(seq 1 6); do
    if docker exec "${PLANKA_DB_CONTAINER}" \
        psql -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;" >/dev/null 2>&1; then
        PG_AUTH_OK=1
        ok "PostgreSQL credentials verified."
        break
    fi
    sleep 3
done

[ "${PG_AUTH_OK}" -eq 1 ] || warn "Could not verify credentials — proceeding (PG may still be initializing)."

sleep 3

# =============================================================================
# STEP 6: DEPLOY PLANKA
# =============================================================================

log "Deploying Planka kanban board..."
log "First-run DB migration takes 60-90 seconds."

# Build DATABASE_URL — no nested variable expansions
DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD}@${PLANKA_DB_CONTAINER}/${DB_NAME}"

log "  Container:    ${PLANKA_CONTAINER}"
log "  Port:         127.0.0.1:${PLANKA_HOST_PORT}"
log "  Admin email:  ${ADMIN_EMAIL}"
log "  DB URL:       postgresql://${DB_USER}:***@${PLANKA_DB_CONTAINER}/${DB_NAME}"

docker run -d \
    --name "${PLANKA_CONTAINER}" \
    --restart unless-stopped \
    --network "${INTERNAL_NET}" \
    -p "127.0.0.1:${PLANKA_HOST_PORT}:1337" \
    -e "BASE_URL=${PLANKA_BASE_URL}" \
    -e "DATABASE_URL=${DATABASE_URL}" \
    -e "SECRET_KEY=${SECRET_KEY}" \
    -e "DEFAULT_ADMIN_EMAIL=${ADMIN_EMAIL}" \
    -e "DEFAULT_ADMIN_PASSWORD=${ADMIN_PASSWORD}" \
    -e "DEFAULT_ADMIN_NAME=${ADMIN_NAME}" \
    -e "DEFAULT_ADMIN_USERNAME=${ADMIN_USERNAME}" \
    -e "TRUST_PROXY=0" \
    -e "TZ=${TZ:-America/Denver}" \
    -v "${APP_VOLUME}:/app/public/user-avatars" \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.planka.rule=PathPrefix(\`/planka\`)" \
    --label "traefik.http.routers.planka.entrypoints=web" \
    --label "traefik.http.services.planka.loadbalancer.server.port=1337" \
    --label "traefik.http.middlewares.planka-strip.stripprefix.prefixes=/planka" \
    --label "traefik.http.routers.planka.middlewares=planka-strip@docker" \
    ghcr.io/plankanban/planka:latest

# Connect to sovereign-net (best-effort — n8n and chat API access)
docker network connect "${EXTERNAL_NET}" "${PLANKA_CONTAINER}" 2>/dev/null \
    && log "Connected to sovereign-net." \
    || warn "sovereign-net connect skipped (normal in open-source mode)."

# =============================================================================
# STEP 7: POLL FOR HTTP READINESS
# =============================================================================

log "Polling http://127.0.0.1:${PLANKA_HOST_PORT} ..."

PK_READY=0
LAST_HTTP="000"
for i in $(seq 1 24); do
    LAST_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        "http://127.0.0.1:${PLANKA_HOST_PORT}" 2>/dev/null || echo "000")

    if [ "${LAST_HTTP}" != "000" ]; then
        PK_READY=1
        ok "Planka responded HTTP ${LAST_HTTP} after $((i*10))s."
        break
    fi

    log "  ${i}/24 — $((i*10))s — HTTP=${LAST_HTTP}"

    if [ $((i % 6)) -eq 0 ]; then
        log "--- Planka log tail ---"
        docker logs --tail 5 "${PLANKA_CONTAINER}" 2>&1 | sed 's/^/  /'
        log "-----------------------"
    fi

    sleep 10
done

# =============================================================================
# RESULT
# =============================================================================

echo ""

if [ "${PK_READY}" -eq 1 ]; then
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │  ✓ Planka Stigmergic Kanban is live                      │"
    echo "  ├──────────────────────────────────────────────────────────┤"
    echo "  │  URL:       http://127.0.0.1:${PLANKA_HOST_PORT}                  │"
    echo "  │  Email:     ${ADMIN_EMAIL}             │"
    echo "  │  Password:  ${ADMIN_PASSWORD}                        │"
    echo "  ├──────────────────────────────────────────────────────────┤"
    echo "  │  DB:        planka-db (PostgreSQL 14 Alpine)             │"
    echo "  │  Volumes:   planka-db-data + planka-app-data             │"
    echo "  ├──────────────────────────────────────────────────────────┤"
    echo "  │  N8N API (internal sovereign-net):                       │"
    echo "  │  Auth:  POST http://planka:1337/api/access-tokens        │"
    echo "  │  Card:  POST http://planka:1337/api/cards                │"
    echo "  ├──────────────────────────────────────────────────────────┤"
    echo "  │  ⚠  Change admin password immediately after first login  │"
    echo "  │  ⚠  Port 127.0.0.1:${PLANKA_HOST_PORT} — WARP/Tunnel only         │"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo ""
    echo "  Logs:      docker logs planka"
    echo "  Uninstall: bash planka-uninstall.jelly.bash"
else
    err "Planka did not respond within 4 minutes (last HTTP: ${LAST_HTTP})."
    echo ""
    echo "  DIAGNOSIS:"
    echo "  docker logs planka --tail 30"
    echo "  docker logs planka-db --tail 10"
    echo "  curl -v http://127.0.0.1:${PLANKA_HOST_PORT}"
    echo ""
    docker logs --tail 20 "${PLANKA_CONTAINER}" 2>&1 | sed 's/^/  /' || true
    exit 1
fi
