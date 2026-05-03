#!/usr/bin/env bash
# =============================================================================
# BOOKSTACK JELLY APP v9 — EDGE-ROUTER AUTO-DETECTION
# Underground Nexus — Sovereign Knowledge Base
# File: Jelly-Apps/BookStack/bookstack.jelly.bash
# =============================================================================
#
# v9 NEW: detect Cerberus Manager Ultra's Traefik edge-router container and,
# when present, configure BookStack to be reached through the edge router at
# http://edge-router/bookstack/. This solves the user's "BookStack works on
# the big system but breaks on the small system" inconsistency:
#
#   - Big system has edge-router → /bookstack/ path works for BOTH the
#     host browser AND the Twin agent. One canonical URL.
#   - Small system has no edge-router → falls back to localhost:4050.
#
# v9 detection runs on EVERY install (including warm restarts), so a host
# that gains edge-router later automatically gets the better routing on
# the next install. Data persists — only the network labels and APP_URL
# change.
#
# Lineage:
#   v4: force-write .env to defeat linuxserver image's stale-env-cache trap
#   v6: APP_URL=http://localhost:4050 + APP_PROXIES=*; host-hash deterministic
#       creds; .env force-write
#   v8: opportunistic port 80 binding + Cerberus-net detection + Traefik labels
#   v9: edge-router AUTO-DETECTION + canonical routing through it when present
#
# Defaults:
#   BookStack login: admin@admin.com / password (CHANGE IMMEDIATELY)
#   DB credentials:  deterministic per-host hash (volumes persist across re-runs)
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

BOOKSTACK_APP_URL="${BOOKSTACK_APP_URL:-}"          # auto-resolved if empty
BOOKSTACK_APP_PROXIES="${BOOKSTACK_APP_PROXIES:-*}"

# v9 — edge-router (Cerberus Manager Ultra Traefik gateway)
EDGE_ROUTER_CONTAINER="${EDGE_ROUTER_CONTAINER:-edge-router}"
# Networks the edge-router lives on — checked in order. The first that
# exists wins; BookStack is connected to that network so Traefik can
# resolve it.
EDGE_ROUTER_NETWORKS="${EDGE_ROUTER_NETWORKS:-cerberus_cerberus-net cerberus-net edge-net traefik}"
# Path prefix BookStack should be served at when behind edge-router.
# Twin's bookstack-config.json url should be set to:
#   http://edge-router${BOOKSTACK_PATH_PREFIX}
# The trailing slash matters — Traefik PathPrefix matching needs it.
BOOKSTACK_PATH_PREFIX="${BOOKSTACK_PATH_PREFIX:-/bookstack}"

INTERNAL_NET="bookstack-internal"
SOVEREIGN_NET="${SOVEREIGN_NET:-sovereign-net}"

DB_VOLUME="bookstack-db-data"
APP_VOLUME="bookstack-app-data"

# Host-hash deterministic credentials — preserves existing volumes
_HOST_HASH=$(hostname | md5sum | cut -c1-12)
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-CerbRoot_${_HOST_HASH}}"
DB_PASSWORD="${DB_PASSWORD:-CerbBS_${_HOST_HASH}}"
DB_USER="${DB_USER:-bookstack}"
DB_NAME="${DB_NAME:-bookstack}"

# MinIO S3 (sovereign-net)
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

# v9 — edge-router detection. Returns the network name that has both
# edge-router AND BookStack reachable (or empty string if no Traefik
# is present on this host).
detect_edge_router() {
    if ! container_running "$EDGE_ROUTER_CONTAINER" 2>/dev/null; then
        return 1
    fi
    # Find the first network edge-router is on that we can also use
    for net in $EDGE_ROUTER_NETWORKS; do
        if network_exists "$net"; then
            # Confirm edge-router is actually attached to this network
            if docker inspect "$EDGE_ROUTER_CONTAINER" \
                --format '{{json .NetworkSettings.Networks}}' 2>/dev/null \
                | grep -q "\"$net\""; then
                echo "$net"
                return 0
            fi
        fi
    done
    return 1
}

resolve_app_url() {
    if [ -n "$BOOKSTACK_APP_URL" ]; then
        echo "$BOOKSTACK_APP_URL"
        return
    fi
    # v9 — if edge-router is present, that's the canonical URL
    local edge_net
    edge_net=$(detect_edge_router 2>/dev/null) || edge_net=""
    if [ -n "$edge_net" ]; then
        echo "http://edge-router${BOOKSTACK_PATH_PREFIX}"
    elif port_available "$BOOKSTACK_PUBLIC_PORT"; then
        echo "http://localhost"
    else
        echo "http://localhost:${BOOKSTACK_HOST_PORT}"
    fi
}

reconcile_networks() {
    ensure_network "$INTERNAL_NET"
    ensure_network "$SOVEREIGN_NET"
    # Always attach to sovereign-net for Twin reachability
    connect_net "$BOOKSTACK_CONTAINER" "$SOVEREIGN_NET"
    # If edge-router is present, attach to its network too
    local edge_net
    edge_net=$(detect_edge_router 2>/dev/null) || edge_net=""
    if [ -n "$edge_net" ]; then
        connect_net "$BOOKSTACK_CONTAINER" "$edge_net"
    fi
}

# v9 — emit Traefik labels appropriate for the path-prefix routing
build_traefik_labels() {
    local edge_net="$1"
    local labels=()
    if [ -n "$edge_net" ]; then
        labels+=(--label "traefik.enable=true")
        labels+=(--label "traefik.docker.network=$edge_net")
        # Strip /bookstack from incoming requests before forwarding to
        # the container (BookStack listens at /). The middleware is
        # named after the container so it doesn't clash.
        labels+=(--label "traefik.http.middlewares.bookstack-strip.stripprefix.prefixes=${BOOKSTACK_PATH_PREFIX}")
        labels+=(--label "traefik.http.routers.bookstack.rule=PathPrefix(\`${BOOKSTACK_PATH_PREFIX}\`)")
        labels+=(--label "traefik.http.routers.bookstack.entrypoints=web")
        labels+=(--label "traefik.http.routers.bookstack.middlewares=bookstack-strip@docker")
        labels+=(--label "traefik.http.services.bookstack.loadbalancer.server.port=80")
        # Optional: also expose at host-based route bookstack.localhost
        labels+=(--label "traefik.http.routers.bookstack-host.rule=Host(\`bookstack.localhost\`)")
        labels+=(--label "traefik.http.routers.bookstack-host.entrypoints=web")
        labels+=(--label "traefik.http.routers.bookstack-host.service=bookstack")
    fi
    printf '%s\n' "${labels[@]}"
}

# =============================================================================
# IDEMPOTENCY CHECK
# =============================================================================

log "Checking deployment state..."

EDGE_NET=$(detect_edge_router 2>/dev/null) || EDGE_NET=""
if [ -n "$EDGE_NET" ]; then
    ok "Edge-router detected on network '$EDGE_NET' — BookStack will route through it"
else
    log "Edge-router not detected — using direct port routing"
fi

if container_running "$BOOKSTACK_CONTAINER"; then
    ok "BookStack already running"
    app_url="$(resolve_app_url)"

    # v9 — IDEMPOTENT REPAIR: re-apply current routing without destroying data.
    # If edge-router was added/removed since last install, we want THIS run
    # to converge BookStack to the correct topology. Approach:
    #   - If routing topology changed (edge-router presence delta), recreate
    #     container with new labels but PRESERVE volumes
    #   - Otherwise just nudge .env's APP_URL
    current_labels=$(docker inspect "$BOOKSTACK_CONTAINER" \
        --format '{{json .Config.Labels}}' 2>/dev/null || echo '{}')
    has_traefik_label=$(echo "$current_labels" | grep -c '"traefik.enable":"true"' || true)

    if [ -n "$EDGE_NET" ] && [ "$has_traefik_label" = "0" ]; then
        warn "Edge-router is now present but container has no Traefik labels — recreating"
        warn "(This is a relabel, not a rebuild — data volumes preserve.)"
        docker stop "$BOOKSTACK_CONTAINER" "$BOOKSTACK_DB_CONTAINER" 2>/dev/null || true
        docker rm "$BOOKSTACK_CONTAINER" 2>/dev/null || true
        # Fall through to the deploy section below
    elif [ -z "$EDGE_NET" ] && [ "$has_traefik_label" != "0" ]; then
        warn "Edge-router was removed since last install — recreating without Traefik labels"
        docker stop "$BOOKSTACK_CONTAINER" "$BOOKSTACK_DB_CONTAINER" 2>/dev/null || true
        docker rm "$BOOKSTACK_CONTAINER" 2>/dev/null || true
        # Fall through
    else
        # Topology unchanged — soft reconciliation
        log "  Host browser : http://127.0.0.1:${BOOKSTACK_HOST_PORT}"
        if [ -n "$EDGE_NET" ]; then
            log "  Edge-router  : http://edge-router${BOOKSTACK_PATH_PREFIX} (PRIMARY)"
        fi
        log "  Docker DNS   : http://bookstack (Twin / sovereign-net)"

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

        # Twin config hint
        if [ -n "$EDGE_NET" ]; then
            log "  Twin config: set bookstack-config.json url to http://edge-router${BOOKSTACK_PATH_PREFIX}"
        else
            log "  Twin config: set bookstack-config.json url to http://bookstack"
        fi
        exit 0
    fi
fi

if container_exists "$BOOKSTACK_CONTAINER"; then
    warn "Stopped container found — starting..."
    docker start "${BOOKSTACK_DB_CONTAINER}" 2>/dev/null || true
    sleep 5
    docker start "${BOOKSTACK_CONTAINER}" >/dev/null || die "Failed to start"
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
# STEP 4: FORCE-WRITE .env (defends stale-env-cache trap)
# =============================================================================

log "Writing .env to app volume..."
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
    die "MariaDB not ready after 90s."
}

sleep 3

# =============================================================================
# STEP 6: VERIFY DB CREDENTIALS
# =============================================================================

log "Verifying credentials..."
DB_AUTH_OK=0
for i in $(seq 1 6); do
    if docker exec "${BOOKSTACK_DB_CONTAINER}" \
        mariadb -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" \
        -e "SELECT 1;" >/dev/null 2>&1; then
        DB_AUTH_OK=1
        ok "Credentials verified."
        break
    fi
    sleep 3
done

# =============================================================================
# STEP 7: DEPLOY BOOKSTACK (edge-router aware)
# =============================================================================

log "Deploying BookStack..."
log "  APP_URL          : $app_url"

port_args=(-p "127.0.0.1:${BOOKSTACK_HOST_PORT}:80")

# v9 — port 80 binding strategy
if [ -n "$EDGE_NET" ]; then
    # When edge-router is present, the user goes through Traefik for
    # external access; binding host port 80 would fight Traefik.
    log "  Host port 80     : SKIPPED (edge-router handles external routing)"
elif port_available "$BOOKSTACK_PUBLIC_PORT"; then
    port_args+=(-p "${BOOKSTACK_PUBLIC_BIND}:${BOOKSTACK_PUBLIC_PORT}:80")
    log "  Host port 80     : http://localhost   [opportunistic]"
else
    log "  Host port 80     : SKIPPED — already in use"
fi
log "  Host port 4050   : http://127.0.0.1:${BOOKSTACK_HOST_PORT}    [primary fallback]"
log "  Container DNS    : http://bookstack:80   [Twin path]"

if [ -n "$EDGE_NET" ]; then
    log "  Edge-router      : http://edge-router${BOOKSTACK_PATH_PREFIX}  [PRIMARY]"
fi

# Build labels conditionally
mapfile -t labels < <(build_traefik_labels "$EDGE_NET")

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
# STEP 8: POLL READINESS
# =============================================================================

log "Polling readiness on http://127.0.0.1:${BOOKSTACK_HOST_PORT}..."
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

# Twin-path probe via sovereign-net
DOCKER_DNS_OK=0
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

# v9 — Edge-router-path probe
EDGE_OK=0
if [ "${BS_READY}" -eq 1 ] && [ -n "$EDGE_NET" ]; then
    log "Polling http://edge-router${BOOKSTACK_PATH_PREFIX}/login via '${EDGE_NET}'..."
    EDGE_HTTP=$(docker run --rm --network "${EDGE_NET}" \
        curlimages/curl:latest \
        -s -o /dev/null -w "%{http_code}" --max-time 10 \
        "http://edge-router${BOOKSTACK_PATH_PREFIX}/login" 2>/dev/null || echo "000")
    if [ "${EDGE_HTTP}" != "000" ]; then
        EDGE_OK=1
        ok "Edge-router path responded HTTP ${EDGE_HTTP}"
    else
        warn "Edge-router path NOT reachable from '${EDGE_NET}'"
    fi
fi

# =============================================================================
# RESULT
# =============================================================================

echo ""

if [ "${BS_READY}" -eq 1 ]; then
    echo "  ┌────────────────────────────────────────────────────────────┐"
    echo "  │  ✓ BookStack is live (v9 edge-router aware)                │"
    echo "  ├────────────────────────────────────────────────────────────┤"
    echo "  │  Host browser : http://127.0.0.1:${BOOKSTACK_HOST_PORT}            [fallback] │"
    if docker port "$BOOKSTACK_CONTAINER" 80/tcp 2>/dev/null | grep -q ":${BOOKSTACK_PUBLIC_PORT}$"; then
        echo "  │  Host browser : http://localhost                [port ${BOOKSTACK_PUBLIC_PORT}]    │"
    fi
    if [ "${DOCKER_DNS_OK}" -eq 1 ]; then
        echo "  │  Docker DNS   : http://bookstack          [✓ reachable]    │"
    else
        echo "  │  Docker DNS   : http://bookstack          [⚠ not verified] │"
    fi
    if [ -n "$EDGE_NET" ]; then
        if [ "${EDGE_OK}" -eq 1 ]; then
            echo "  │  Edge-router  : http://edge-router${BOOKSTACK_PATH_PREFIX}    [✓ PRIMARY]   │"
        else
            echo "  │  Edge-router  : http://edge-router${BOOKSTACK_PATH_PREFIX}    [⚠ retry]    │"
        fi
    fi
    echo "  │  APP_URL      : ${app_url}              │"
    echo "  ├────────────────────────────────────────────────────────────┤"
    echo "  │  Email        : admin@admin.com                            │"
    echo "  │  Password     : password    ⚠  CHANGE IMMEDIATELY          │"
    echo "  ├────────────────────────────────────────────────────────────┤"
    echo "  │  Container    : ${BOOKSTACK_CONTAINER}, ${BOOKSTACK_DB_CONTAINER}                     │"
    if [ -n "$EDGE_NET" ]; then
        echo "  │  Networks     : ${INTERNAL_NET} + ${SOVEREIGN_NET} + ${EDGE_NET}"
    else
        echo "  │  Networks     : ${INTERNAL_NET} + ${SOVEREIGN_NET}"
    fi
    echo "  └────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  Twin compatibility (Underground Index v3.6.5+):"
    echo "    /config/bookstack-config.json should set:"
    if [ -n "$EDGE_NET" ]; then
        echo "      \"url\": \"http://edge-router${BOOKSTACK_PATH_PREFIX}\"   [PRIMARY — Traefik]"
        echo "      \"external_url\": \"$app_url\""
        echo ""
        echo "  Note: With edge-router routing, the SAME URL works from both"
        echo "  the host browser AND the Twin agent. No more URL mismatch."
    else
        echo "      \"url\": \"http://bookstack\"           (Twin → BookStack)"
        echo "      \"external_url\": \"$app_url\"          (host browser)"
        echo ""
        echo "  Note: install Cerberus Manager Ultra (with edge-router) to"
        echo "  unify host + Twin URLs through Traefik. Re-running this script"
        echo "  will detect edge-router and reconfigure WITHOUT data loss."
    fi
else
    err "BookStack did not respond within 6 minutes."
    docker logs --tail 20 "${BOOKSTACK_CONTAINER}" 2>&1 | sed 's/^/  /'
    exit 1
fi