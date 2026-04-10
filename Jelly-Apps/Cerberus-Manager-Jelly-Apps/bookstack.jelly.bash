#!/usr/bin/env bash
# =============================================================================
# BOOKSTACK JELLY APP v4
# Underground Nexus — Sovereign Knowledge Base
# File: Jelly-Apps/Bookstack/bookstack.jelly.bash
# =============================================================================
#
# ROOT CAUSE RESOLVED (v4):
#   The linuxserver/bookstack image writes a default .env to the config volume
#   on first run. If a PREVIOUS run wrote a .env with placeholder values
#   (DB_USER=database_username, DB_PASSWORD=secret etc.), the image REUSES
#   that stale .env on subsequent runs — it does NOT overwrite with docker -e vars.
#
#   Fix: Force-write the correct .env into the volume BEFORE starting BookStack,
#   using a one-shot alpine container. This guarantees our credentials are used
#   regardless of what was previously in the volume.
#
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

BOOKSTACK_DB_CONTAINER="${BOOKSTACK_DB_CONTAINER:-bookstack-db}"
BOOKSTACK_CONTAINER="${BOOKSTACK_CONTAINER:-bookstack}"
BOOKSTACK_HOST_PORT="${BOOKSTACK_HOST_PORT:-4050}"
BOOKSTACK_APP_URL="${BOOKSTACK_APP_URL:-http://localhost:${BOOKSTACK_HOST_PORT}}"

INTERNAL_NET="bookstack-internal"
DB_VOLUME="bookstack-db-data"
APP_VOLUME="bookstack-app-data"

# Credentials — deterministic per host
_HOST_HASH=$(hostname | md5sum | cut -c1-12)
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-CerbRoot_${_HOST_HASH}}"
DB_PASSWORD="${DB_PASSWORD:-CerbBS_${_HOST_HASH}}"
DB_USER="${DB_USER:-bookstack}"
DB_NAME="${DB_NAME:-bookstack}"

# MinIO S3 (sovereign-net, deployed by installer)
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio:9000}"
MINIO_BUCKET="${MINIO_BUCKET:-bookstack}"
MINIO_KEY="${MINIO_ROOT_USER:-sovereign}"
MINIO_SECRET="${MINIO_ROOT_PASSWORD:-sovereign2024}"
MINIO_REGION="${MINIO_REGION:-us-east-1}"
STORAGE_TYPE="${STORAGE_TYPE:-s3}"

# =============================================================================
# HELPERS
# =============================================================================

log()  { echo "[bookstack] $*"; }
ok()   { echo "[bookstack] ✓ $*"; }
warn() { echo "[bookstack] ⚠ $*"; }
err()  { echo "[bookstack] ✗ $*" >&2; }
die()  { err "$*"; exit 1; }

# =============================================================================
# IDEMPOTENCY CHECK
# =============================================================================

log "Checking deployment state..."

if docker ps --format '{{.Names}}' | grep -qx "${BOOKSTACK_CONTAINER}"; then
    ok "BookStack already running at http://127.0.0.1:${BOOKSTACK_HOST_PORT}"
    log "To redeploy: bash bookstack-uninstall.jelly.bash && bash bookstack.jelly.bash"
    exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "${BOOKSTACK_CONTAINER}"; then
    warn "Stopped container found — starting..."
    docker start "${BOOKSTACK_DB_CONTAINER}" 2>/dev/null || true
    sleep 5
    docker start "${BOOKSTACK_CONTAINER}" || die "Failed to start bookstack"
    ok "Started. http://127.0.0.1:${BOOKSTACK_HOST_PORT}"
    exit 0
fi

# =============================================================================
# STEP 1: GENERATE APP_KEY
# =============================================================================

log "Generating APP_KEY..."

APP_KEY=$(docker run --rm \
    --entrypoint /bin/bash \
    lscr.io/linuxserver/bookstack:latest \
    -c "php /app/www/artisan key:generate --show 2>/dev/null | tr -d '\r\n'" \
    2>/dev/null) || true

if [ -z "${APP_KEY}" ] || [[ "${APP_KEY}" != base64:* ]]; then
    warn "artisan key:generate failed — using openssl fallback"
    APP_KEY="base64:$(openssl rand -base64 32)"
fi

ok "APP_KEY generated."

# =============================================================================
# STEP 2: BRIDGE NETWORK
# =============================================================================

if ! docker network inspect "${INTERNAL_NET}" >/dev/null 2>&1; then
    docker network create "${INTERNAL_NET}"
    ok "Created bridge network '${INTERNAL_NET}'."
else
    ok "Network '${INTERNAL_NET}' exists."
fi

# =============================================================================
# STEP 3: CLEAN UP STALE CONTAINERS
# =============================================================================

for STALE in "${BOOKSTACK_CONTAINER}" "${BOOKSTACK_DB_CONTAINER}"; do
    if docker ps -a --format '{{.Names}}' | grep -qx "${STALE}"; then
        warn "Removing stale container '${STALE}'..."
        docker stop "${STALE}" 2>/dev/null || true
        docker rm "${STALE}" 2>/dev/null || true
    fi
done

# =============================================================================
# STEP 4: FORCE-WRITE CORRECT .env INTO APP VOLUME
# =============================================================================
# THE KEY FIX:
# The linuxserver image caches .env in the volume and reuses it on restart.
# If a previous run wrote placeholder values (database_username, secret, etc.)
# those wrong values persist. We write the correct .env BEFORE starting
# BookStack so it always finds the right credentials regardless of history.
#
# The linuxserver image stores .env at /config/www/.env inside the volume.
# We create the directory structure and write the file directly.

log "Writing .env to app volume (prevents stale credential reuse)..."

# Build storage config block
if [ "${STORAGE_TYPE}" = "s3" ]; then
    STORAGE_ENV_BLOCK="STORAGE_TYPE=s3
STORAGE_S3_KEY=${MINIO_KEY}
STORAGE_S3_SECRET=${MINIO_SECRET}
STORAGE_S3_BUCKET=${MINIO_BUCKET}
STORAGE_S3_REGION=${MINIO_REGION}
STORAGE_S3_ENDPOINT=${MINIO_ENDPOINT}
STORAGE_URL=${MINIO_ENDPOINT}/${MINIO_BUCKET}"
else
    STORAGE_ENV_BLOCK="STORAGE_TYPE=local"
fi

docker run --rm \
    -v "${APP_VOLUME}:/config" \
    alpine:latest \
    sh -c "
        mkdir -p /config/www
        cat > /config/www/.env << 'ENVEOF'
APP_KEY=${APP_KEY}
APP_URL=${BOOKSTACK_APP_URL}
DB_HOST=${BOOKSTACK_DB_CONTAINER}:3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
${STORAGE_ENV_BLOCK}
ENVEOF
        echo 'env written'
        cat /config/www/.env
    "

ok ".env written to volume with correct credentials."

# =============================================================================
# STEP 5: DEPLOY MARIADB
# =============================================================================

log "Deploying MariaDB 10.11..."

docker run -d \
    --name "${BOOKSTACK_DB_CONTAINER}" \
    --restart unless-stopped \
    --network "${INTERNAL_NET}" \
    -e MYSQL_ROOT_PASSWORD="${DB_ROOT_PASSWORD}" \
    -e MYSQL_DATABASE="${DB_NAME}" \
    -e MYSQL_USER="${DB_USER}" \
    -e MYSQL_PASSWORD="${DB_PASSWORD}" \
    -v "${DB_VOLUME}:/var/lib/mysql" \
    mariadb:10.11

ok "MariaDB started. Polling readiness..."

DB_READY=0
for i in $(seq 1 18); do
    if docker exec "${BOOKSTACK_DB_CONTAINER}" \
        mariadb-admin ping -u root -p"${DB_ROOT_PASSWORD}" --silent 2>/dev/null; then
        DB_READY=1
        ok "MariaDB ready after $((i * 5))s."
        break
    fi
    log "  Waiting $((i * 5))s..."
    sleep 5
done

[ "${DB_READY}" -eq 1 ] || {
    docker logs --tail 20 "${BOOKSTACK_DB_CONTAINER}" 2>&1 | sed 's/^/  /'
    die "MariaDB not ready after 90s. Check: docker logs ${BOOKSTACK_DB_CONTAINER}"
}

# Extra buffer for InnoDB to finish init
sleep 3

# =============================================================================
# STEP 6: VERIFY MARIADB ACCEPTS OUR CREDENTIALS
# =============================================================================
# Catch wrong-password errors before BookStack ever tries to connect.

log "Verifying MariaDB accepts bookstack user credentials..."

DB_AUTH_OK=0
for i in $(seq 1 6); do
    if docker exec "${BOOKSTACK_DB_CONTAINER}" \
        mariadb -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" \
        -e "SELECT 1;" >/dev/null 2>&1; then
        DB_AUTH_OK=1
        ok "MariaDB credentials verified (user=${DB_USER}, db=${DB_NAME})."
        break
    fi
    log "  Auth attempt ${i}/6..."
    sleep 3
done

if [ "${DB_AUTH_OK}" -eq 0 ]; then
    warn "Could not verify credentials — MariaDB may still be initializing users."
    warn "Proceeding anyway — BookStack will report DB errors if this fails."
fi

# =============================================================================
# STEP 7: DEPLOY BOOKSTACK
# =============================================================================

log "Deploying BookStack..."
log "First-run DB migration takes 2-4 minutes."

docker run -d \
    --name "${BOOKSTACK_CONTAINER}" \
    --restart unless-stopped \
    --network "${INTERNAL_NET}" \
    -p "127.0.0.1:${BOOKSTACK_HOST_PORT}:80" \
    -e "APP_KEY=${APP_KEY}" \
    -e "APP_URL=${BOOKSTACK_APP_URL}" \
    -e "DB_HOST=${BOOKSTACK_DB_CONTAINER}:3306" \
    -e "DB_DATABASE=${DB_NAME}" \
    -e "DB_USERNAME=${DB_USER}" \
    -e "DB_PASSWORD=${DB_PASSWORD}" \
    -e "STORAGE_TYPE=${STORAGE_TYPE}" \
    -e "STORAGE_S3_KEY=${MINIO_KEY}" \
    -e "STORAGE_S3_SECRET=${MINIO_SECRET}" \
    -e "STORAGE_S3_BUCKET=${MINIO_BUCKET}" \
    -e "STORAGE_S3_REGION=${MINIO_REGION}" \
    -e "STORAGE_S3_ENDPOINT=${MINIO_ENDPOINT}" \
    -e "STORAGE_URL=${MINIO_ENDPOINT}/${MINIO_BUCKET}" \
    -e PUID=1000 \
    -e PGID=1000 \
    -e "TZ=${TZ:-America/Denver}" \
    -v "${APP_VOLUME}:/config" \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.bookstack.rule=PathPrefix(\`/bookstack\`)" \
    --label "traefik.http.routers.bookstack.entrypoints=web" \
    --label "traefik.http.services.bookstack.loadbalancer.server.port=80" \
    --label "traefik.http.middlewares.bookstack-strip.stripprefix.prefixes=/bookstack" \
    --label "traefik.http.routers.bookstack.middlewares=bookstack-strip@docker" \
    lscr.io/linuxserver/bookstack:latest

# Connect to sovereign-net (best-effort — open-source mode doesn't need it)
docker network connect sovereign-net "${BOOKSTACK_CONTAINER}" 2>/dev/null \
    && log "Connected to sovereign-net." \
    || warn "sovereign-net skipped (normal in open-source mode)."

# =============================================================================
# STEP 8: POLL FOR HTTP READINESS
# =============================================================================

log "Polling http://127.0.0.1:${BOOKSTACK_HOST_PORT} ..."

BS_READY=0
LAST_HTTP="000"
for i in $(seq 1 36); do
    LAST_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        "http://127.0.0.1:${BOOKSTACK_HOST_PORT}" 2>/dev/null || echo "000")

    if [ "${LAST_HTTP}" != "000" ]; then
        BS_READY=1
        ok "BookStack responded HTTP ${LAST_HTTP} after $((i * 10))s."
        break
    fi

    log "  ${i}/36 — $((i*10))s — HTTP=${LAST_HTTP}"

    if [ $((i % 6)) -eq 0 ]; then
        log "--- BookStack log tail ---"
        docker logs --tail 5 "${BOOKSTACK_CONTAINER}" 2>&1 | sed 's/^/  /'
        log "--------------------------"
    fi

    sleep 10
done

# =============================================================================
# STEP 9: VERIFY DB CONNECTIVITY FROM BOOKSTACK
# =============================================================================
# After BookStack starts, check logs for DB errors to catch remaining issues.

if [ "${BS_READY}" -eq 1 ]; then
    log "Checking BookStack logs for DB errors..."
    DB_ERRORS=$(docker logs "${BOOKSTACK_CONTAINER}" 2>&1 | grep -c "Access denied\|database_username\|SQLSTATE" || true)
    if [ "${DB_ERRORS}" -gt 0 ]; then
        warn "DB error detected in BookStack logs. Showing relevant lines:"
        docker logs "${BOOKSTACK_CONTAINER}" 2>&1 \
            | grep "Access denied\|database_username\|SQLSTATE\|DB_" \
            | head -10 \
            | sed 's/^/  /'
        warn "The page may show a 500 error. See troubleshooting section."
    else
        ok "No DB errors detected in logs."
    fi
fi

# =============================================================================
# RESULT
# =============================================================================

echo ""

if [ "${BS_READY}" -eq 1 ] && [ "${DB_ERRORS:-0}" -eq 0 ]; then
    echo "  ┌────────────────────────────────────────────────────────┐"
    echo "  │  ✓ BookStack is live                                   │"
    echo "  ├────────────────────────────────────────────────────────┤"
    echo "  │  URL:       http://127.0.0.1:${BOOKSTACK_HOST_PORT}                │"
    echo "  │  Email:     admin@admin.com                            │"
    echo "  │  Password:  password                                   │"
    echo "  ├────────────────────────────────────────────────────────┤"
    echo "  │  DB:        ${BOOKSTACK_DB_CONTAINER} (MariaDB 10.11, user=${DB_USER})    │"
    echo "  │  Storage:   ${STORAGE_TYPE}                                       │"
    echo "  ├────────────────────────────────────────────────────────┤"
    echo "  │  ⚠  Change password immediately after first login      │"
    echo "  └────────────────────────────────────────────────────────┘"
elif [ "${BS_READY}" -eq 1 ]; then
    echo "  BookStack is responding but has DB errors."
    echo "  Most likely the .env still has wrong credentials."
    echo ""
    echo "  Run this to inspect and fix:"
    echo "  docker exec bookstack cat /config/www/.env | grep DB_"
    echo "  docker exec bookstack-db mariadb -u ${DB_USER} -p${DB_PASSWORD} ${DB_NAME} -e 'SHOW TABLES;'"
    echo ""
    echo "  If DB_USERNAME still says 'database_username', run:"
    echo "  bash bookstack-uninstall.jelly.bash  (type: uninstall)"
    echo "  bash bookstack.jelly.bash"
else
    err "BookStack did not respond within 6 minutes."
    echo ""
    docker logs --tail 20 "${BOOKSTACK_CONTAINER}" 2>&1 | sed 's/^/  /'
    exit 1
fi
