#!/usr/bin/env bash
# =============================================================================
# BOOKSTACK JELLY APP v8 (HOST-FRIENDLY DUAL-ENTRYPOINT + PORT 80 + CERBERUS)
# Underground Nexus — Sovereign Knowledge Base
# File: Jelly-Apps/BookStack/bookstack.jelly.bash
# =============================================================================
#
# v8 lineage:
#   v4: force-write .env to defeat linuxserver image's stale-env-cache trap
#   v5: APP_URL=http://bookstack (broke host browser — backed out in v6)
#   v6: APP_URL=http://localhost:4050 (host browser works; container DNS path
#       still works via Bearer-token API; documented APP_PROXIES=*)
#   v7 (GPT proposal): port 80 binding when free + Cerberus net detection,
#       BUT regressed by hardcoding DB passwords (would brick existing volumes)
#       and dropping APP_KEY pre-generation + .env force-write
#
# v8 brings v6's safe defaults forward AND adds v7's good ideas:
#   - APP_KEY pre-generated via artisan inside the LSIO image
#   - host-hash-derived deterministic credentials (NOT hardcoded — preserves
#     existing DB volumes across re-runs)
#   - .env force-write so subsequent runs can't fall back to placeholder vals
#   - APP_URL resolved at deploy time: http://localhost when port 80 is free,
#     else http://localhost:4050. Host browser always gets a resolvable URL.
#   - port 80 binding is OPPORTUNISTIC: only when port is free, so it doesn't
#     fight Traefik or Cerberus Ultra's edge router
#   - container joins three networks: bookstack-internal (DB private),
#     sovereign-net (Twin), and Cerberus's network when present
#   - container labels (bookstack, bookstack-db) PRESERVED (downstream scripts)
#   - Traefik labels emitted only when a Traefik network is detected
#
# Defaults:
#   BookStack login: admin@admin.com / password (CHANGE IMMEDIATELY)
#   DB credentials: deterministic per-host hash so volumes persist cleanly
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

BOOKSTACK_DB_CONTAINER="${BOOKSTACK_DB_CONTAINER:-bookstack-db}"
BOOKSTACK_CONTAINER="${BOOKSTACK_CONTAINER:-bookstack}"
BOOKSTACK_HOST_PORT="${BOOKSTACK_HOST_PORT:-4050}"
BOOKSTACK_PUBLIC_PORT="${BOOKSTACK_PUBLIC_PORT:-80}"
BOOKSTACK_PUBLIC_BIND="${BOOKSTACK_PUBLIC_BIND:-0.0.0.0}"

BOOKSTACK_APP_URL="${BOOKSTACK_APP_URL:-}"
BOOKSTACK_APP_PROXIES="${BOOKSTACK_APP_PROXIES:-*}"

INTERNAL_NET="bookstack-internal"
SOVEREIGN_NET="${SOVEREIGN_NET:-sovereign-net}"
CERBERUS_NETWORK="${CERBERUS_NETWORK:-cerberus_cerberus-net}"
CERBERUS_ALT_NETWORK="${CERBERUS_ALT_NETWORK:-cerberus-net}"

DB_VOLUME="bookstack-db-data"
APP_VOLUME="bookstack-app-data"

# v6 retained — host-hash-derived deterministic credentials. Existing DB
# volumes have these baked in; HARDCODING them (v7 regression) would break
# existing deployments. Override via env if you need specific values.
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

network_exists() { docker network inspect "$1" >/dev/null 2>&1; }
container_exists() { docker inspect "$1" >/dev/null 2>&1; }
container_running() {
    [ "$(docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo missing)" = "running" ]
}

ensure_network() {
    local net="$1"
    if network_exists "$net"; then
        ok "Network '$net' present"
    else
        docker network create "$net" >/dev/null
        ok "Created network '$net'"
    fi
}

connect_net() {
    local c="$1" n="$2"
    container_exists "$c" || return 0
    network_exists "$n" || return 0
    if docker inspect "$c" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null \
        | grep -q "\"$n\""; then
        return 0
    fi
    docker network connect "$n" "$c" 2>/dev/null \
        && ok "  Connected $c → $n" \
        || warn "  Could not connect $c → $n"
}

port_available() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ! ss -ltn "( sport = :$port )" 2>/dev/null | grep -q ":$port"
    elif command -v lsof >/dev/null 2>&1; then
        ! lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    else
        return 1
    fi
}

resolve_app_url() {
    if [ -n "$BOOKSTACK_APP_URL" ]; then
        echo "$BOOKSTACK_APP_URL"
    elif port_available "$BOOKSTACK_PUBLIC_PORT"; then
        echo "http://localhost"
    else
        echo "http://localhost:${BOOKSTACK_HOST_PORT}"
    fi
}

traefik_network() {
    if network_exists "$CERBERUS_NETWORK"; then
        echo "$CERBERUS_NETWORK"
    elif network_exists "$CERBERUS_ALT_NETWORK"; then
        echo "$CERBERUS_ALT_NETWORK"
    else
        echo ""
    fi
}

reconcile_networks() {
    ensure_network "$INTERNAL_NET"
    ensure_network "$SOVEREIGN_NET"
    for n in "$SOVEREIGN_NET" "$CERBERUS_NETWORK" "$CERBERUS_ALT_NETWORK"; do
        network_exists "$n" || continue
        connect_net "$BOOKSTACK_CONTAINER" "$n"
    done
}

# =============================================================================
# IDEMPOTENCY CHECK
# =============================================================================

log "Checking deployment state..."

if container_running "$BOOKSTACK_CONTAINER"; then
    ok "BookStack already running"
    app_url="$(resolve_app_url)"
    log "  Host browser : http://127.0.0.1:${BOOKSTACK_HOST_PORT}"
    if docker port "$BOOKSTACK_CONTAINER" 80/tcp 2>/dev/null | grep -q ":${BOOKSTACK_PUBLIC_PORT}$"; then
        log "  Host browser : http://localhost (port ${BOOKSTACK_PUBLIC_PORT} mapped)"
    fi
    log "  Docker DNS   : http://bookstack (Twin / sovereign-net containers)"

    log "Reconciling network membership..."
    reconcile_networks

    log "Reconciling APP_URL in app volume to: $app_url"
    docker run --rm \
        -v "${APP_VOLUME}:/config" \
        alpine:latest \
        sh -c "
            if [ -f /config/www/.env ]; then
                sed -i 's|^APP_URL=.*|APP_URL=${app_url}|' /config/www/.env || true
                grep '^APP_URL=' /config/www/.env || true
            fi
        " 2>&1 | sed 's/^/  /'

    log "Restarting bookstack container so APP_URL takes effect"
    docker restart "${BOOKSTACK_CONTAINER}" >/dev/null 2>&1 \
        && ok "Container restarted" \
        || warn "Restart failed (try manually)"

    exit 0
fi

if container_exists "$BOOKSTACK_CONTAINER"; then
    warn "Stopped container found — starting..."
    docker start "${BOOKSTACK_DB_CONTAINER}" 2>/dev/null || true
    sleep 5
    docker start "${BOOKSTACK_CONTAINER}" >/dev/null || die "Failed to start bookstack"
    reconcile_networks
    ok "Started"
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
# STEP 2: BRIDGE NETWORKS
# =============================================================================

ensure_network "$INTERNAL_NET"
ensure_network "$SOVEREIGN_NET"

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

log "Writing .env to app volume (defends stale-env-cache trap)..."

app_url="$(resolve_app_url)"

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
APP_URL=${app_url}
APP_PROXIES=${BOOKSTACK_APP_PROXIES}
DB_HOST=${BOOKSTACK_DB_CONTAINER}:3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
${STORAGE_ENV_BLOCK}
MAIL_DRIVER=log
ENVEOF
        echo 'env written'
        cat /config/www/.env
    "

ok ".env written."

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

sleep 3

# =============================================================================
# STEP 6: VERIFY MARIADB CREDENTIALS
# =============================================================================

log "Verifying bookstack user credentials..."
DB_AUTH_OK=0
for i in $(seq 1 6); do
    if docker exec "${BOOKSTACK_DB_CONTAINER}" \
        mariadb -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" \
        -e "SELECT 1;" >/dev/null 2>&1; then
        DB_AUTH_OK=1
        ok "MariaDB credentials verified."
        break
    fi
    log "  Auth attempt ${i}/6..."
    sleep 3
done

[ "${DB_AUTH_OK}" -eq 1 ] || warn "Could not verify credentials — proceeding anyway."

# =============================================================================
# STEP 7: DEPLOY BOOKSTACK (port 80 opportunistic, Cerberus aware)
# =============================================================================

log "Deploying BookStack..."
log "  APP_URL          : $app_url"
log "  Host port (4050) : http://127.0.0.1:${BOOKSTACK_HOST_PORT}    [primary]"

port_args=(-p "127.0.0.1:${BOOKSTACK_HOST_PORT}:80")
if port_available "$BOOKSTACK_PUBLIC_PORT"; then
    port_args+=(-p "${BOOKSTACK_PUBLIC_BIND}:${BOOKSTACK_PUBLIC_PORT}:80")
    log "  Host port (${BOOKSTACK_PUBLIC_PORT})     : http://localhost   [opportunistic]"
else
    log "  Host port (${BOOKSTACK_PUBLIC_PORT})     : SKIPPED — already in use"
fi
log "  Container DNS    : http://bookstack:80   [Twin path]"

labels=()
tn="$(traefik_network)"
if [ -n "$tn" ]; then
    log "  Traefik network  : $tn — emitting labels"
    labels+=(--label traefik.enable=true)
    labels+=(--label "traefik.docker.network=$tn")
    labels+=(--label "traefik.http.routers.bookstack.rule=Host(\`bookstack.localhost\`) || PathPrefix(\`/bookstack\`)")
    labels+=(--label "traefik.http.routers.bookstack.entrypoints=web")
    labels+=(--label "traefik.http.services.bookstack.loadbalancer.server.port=80")
fi

log "First-run DB migration takes 2-4 minutes."

docker run -d \
    --name "${BOOKSTACK_CONTAINER}" \
    --restart unless-stopped \
    --network "${INTERNAL_NET}" \
    "${port_args[@]}" \
    ${labels[@]+"${labels[@]}"} \
    -e "APP_KEY=${APP_KEY}" \
    -e "APP_URL=${app_url}" \
    -e "APP_PROXIES=${BOOKSTACK_APP_PROXIES}" \
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
    -e MAIL_DRIVER=log \
    -e "TZ=${TZ:-America/Denver}" \
    -v "${APP_VOLUME}:/config" \
    lscr.io/linuxserver/bookstack:latest

reconcile_networks

# =============================================================================
# STEP 8: POLL FOR HTTP READINESS
# =============================================================================

log "Polling http://127.0.0.1:${BOOKSTACK_HOST_PORT}..."
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
        log "--- log tail ---"
        docker logs --tail 5 "${BOOKSTACK_CONTAINER}" 2>&1 | sed 's/^/  /'
    fi
    sleep 10
done

DOCKER_DNS_OK=0
DOCKER_DNS_HTTP="000"
if [ "${BS_READY}" -eq 1 ] && network_exists "$SOVEREIGN_NET"; then
    log "Polling http://bookstack via '${SOVEREIGN_NET}' (Twin path)..."
    DOCKER_DNS_HTTP=$(docker run --rm --network "${SOVEREIGN_NET}" \
        curlimages/curl:latest \
        -s -o /dev/null -w "%{http_code}" --max-time 10 \
        "http://bookstack/login" 2>/dev/null || echo "000")
    if [ "${DOCKER_DNS_HTTP}" != "000" ]; then
        DOCKER_DNS_OK=1
        ok "Docker DNS path http://bookstack responded HTTP ${DOCKER_DNS_HTTP}"
    else
        warn "http://bookstack NOT reachable from '${SOVEREIGN_NET}'"
    fi
fi

# =============================================================================
# STEP 9: VERIFY DB CONNECTIVITY
# =============================================================================

if [ "${BS_READY}" -eq 1 ]; then
    DB_ERRORS=$(docker logs "${BOOKSTACK_CONTAINER}" 2>&1 | grep -c "Access denied\|database_username\|SQLSTATE" || true)
    if [ "${DB_ERRORS}" -gt 0 ]; then
        warn "DB error detected:"
        docker logs "${BOOKSTACK_CONTAINER}" 2>&1 \
            | grep "Access denied\|database_username\|SQLSTATE\|DB_" \
            | head -10 | sed 's/^/  /'
    else
        ok "No DB errors detected in logs."
    fi
fi

# =============================================================================
# RESULT
# =============================================================================

echo ""

if [ "${BS_READY}" -eq 1 ] && [ "${DB_ERRORS:-0}" -eq 0 ]; then
    echo "  ┌────────────────────────────────────────────────────────────┐"
    echo "  │  ✓ BookStack is live (v8 dual-entrypoint + Cerberus aware) │"
    echo "  ├────────────────────────────────────────────────────────────┤"
    echo "  │  Host browser : http://127.0.0.1:${BOOKSTACK_HOST_PORT}            [primary]   │"
    if docker port "$BOOKSTACK_CONTAINER" 80/tcp 2>/dev/null | grep -q ":${BOOKSTACK_PUBLIC_PORT}$"; then
        echo "  │  Host browser : http://localhost                [port ${BOOKSTACK_PUBLIC_PORT}]    │"
    fi
    if [ "${DOCKER_DNS_OK}" -eq 1 ]; then
        echo "  │  Docker DNS   : http://bookstack          [✓ reachable]    │"
    else
        echo "  │  Docker DNS   : http://bookstack          [⚠ not verified] │"
    fi
    echo "  │  APP_URL      : ${app_url}              │"
    echo "  ├────────────────────────────────────────────────────────────┤"
    echo "  │  Email        : admin@admin.com                            │"
    echo "  │  Password     : password    ⚠  CHANGE IMMEDIATELY          │"
    echo "  ├────────────────────────────────────────────────────────────┤"
    echo "  │  Networks     : ${INTERNAL_NET} + ${SOVEREIGN_NET}        │"
    [ -n "$tn" ] && echo "  │                 + ${tn}                       │"
    echo "  │  Container    : ${BOOKSTACK_CONTAINER}, ${BOOKSTACK_DB_CONTAINER}                     │"
    echo "  └────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  Twin compatibility (Underground Index v3.6.4+):"
    echo "    /config/bookstack-config.json should set:"
    echo "      \"url\": \"http://bookstack\"           (Twin → BookStack)"
    echo "      \"external_url\": \"$app_url\"          (host browser)"
elif [ "${BS_READY}" -eq 1 ]; then
    echo "  BookStack responding but has DB errors. Investigation:"
    echo "    docker exec bookstack cat /config/www/.env | grep DB_"
    echo "    docker exec bookstack-db mariadb -u ${DB_USER} -p${DB_PASSWORD} ${DB_NAME} -e 'SHOW TABLES;'"
else
    err "BookStack did not respond within 6 minutes."
    docker logs --tail 20 "${BOOKSTACK_CONTAINER}" 2>&1 | sed 's/^/  /'
    exit 1
fi