#!/usr/bin/env bash
# =============================================================================
# SOVEREIGN UPDATE PIPELINE v2
# Underground Nexus — Immutable Patching with Backup-Before-Swap
# File: sovereign-update.sh
# =============================================================================
#
# CRITICAL FIXES FROM v1:
#
#   FIX 1 — STOP-BEFORE-CHECK WAS CATASTROPHIC:
#     v1 stopped and removed containers BEFORE checking if the jelly script
#     existed. If the script path was wrong, the app was destroyed with no
#     way to recover without a manual redeploy. This killed every app on the
#     first run because the jelly scripts weren't in the GitHub repo yet.
#     Fix: jelly script is located and verified FIRST. If not found, the
#     container is LEFT RUNNING and the update is skipped with a clear error.
#
#   FIX 2 — NEXUS_REPO PATH MISMATCH:
#     Scripts live at /underground-nexus/Jelly-Apps/ inside the Cerberus
#     container, but NEXUS_REPO defaulted to /nexus-bucket/underground-nexus.
#     Fix: find_jelly() searches multiple paths in priority order and returns
#     the first match. Operators can also set JELLY_BASE explicitly.
#
#   FIX 3 — INTEGER COMPARISON BUG IN PRUNE LOOP:
#     wc -l returns "      7\n" with whitespace and newline, causing
#     [: integer expected. Fix: use grep -c instead of wc -l | tr -d " ".
#
# USAGE:
#   From Cerberus shell:
#     bash /underground-nexus/sovereign-update.sh
#     bash /nexus-bucket/underground-nexus/sovereign-update.sh
#
#   Symlinked as UPDATE command:
#     ln -sf /underground-nexus/sovereign-update.sh /usr/local/bin/UPDATE
#     UPDATE
#
#   Via docker exec from host:
#     docker exec cerberus-manager bash /underground-nexus/sovereign-update.sh
#
#   Selective updates:
#     UPDATE_ALL=false UPDATE_BOOKSTACK=true bash sovereign-update.sh
#     UPDATE_ALL=false UPDATE_VAULTWARDEN=true bash sovereign-update.sh
#     UPDATE_ALL=false UPDATE_PLANKA=true bash sovereign-update.sh
#
# =============================================================================

set -eo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# Jelly script search paths — checked in order, first match wins
# Add your custom path here if scripts live elsewhere
JELLY_SEARCH_PATHS=(
    "/underground-nexus/Jelly-Apps"
    "/nexus-bucket/underground-nexus/Jelly-Apps"
    "/nexus-bucket/Jelly-Apps"
    "$(dirname "${BASH_SOURCE[0]}")/Jelly-Apps"
)

# Git repo for pulling updates (scripts, artifacts)
NEXUS_REPO="${NEXUS_REPO:-/nexus-bucket/underground-nexus}"
NEXUS_REPO_ALT="${NEXUS_REPO_ALT:-/underground-nexus}"

BACKUP_DIR="${BACKUP_DIR:-/backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${BACKUP_DIR}/update-${TIMESTAMP}.log"

# Which apps to update
UPDATE_ALL="${UPDATE_ALL:-true}"
UPDATE_BOOKSTACK="${UPDATE_BOOKSTACK:-${UPDATE_ALL}}"
UPDATE_VAULTWARDEN="${UPDATE_VAULTWARDEN:-${UPDATE_ALL}}"
UPDATE_MINIO="${UPDATE_MINIO:-${UPDATE_ALL}}"
UPDATE_N8N="${UPDATE_N8N:-${UPDATE_ALL}}"
UPDATE_PORTAINER="${UPDATE_PORTAINER:-${UPDATE_ALL}}"
UPDATE_UPTIME_KUMA="${UPDATE_UPTIME_KUMA:-${UPDATE_ALL}}"
UPDATE_PLANKA="${UPDATE_PLANKA:-${UPDATE_ALL}}"
UPDATE_CERBERUS="${UPDATE_CERBERUS:-false}"  # manual only
UPDATE_HOME_ASSISTANT="${UPDATE_HOME_ASSISTANT:-${UPDATE_ALL}}" 

# =============================================================================
# LOGGING
# =============================================================================

mkdir -p "${BACKUP_DIR}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }

log_section() {
    echo "" | tee -a "${LOG_FILE}"
    printf '=%.0s' {1..60} | tee -a "${LOG_FILE}"; echo "" | tee -a "${LOG_FILE}"
    echo "  $*" | tee -a "${LOG_FILE}"
    printf '=%.0s' {1..60} | tee -a "${LOG_FILE}"; echo "" | tee -a "${LOG_FILE}"
    echo "" | tee -a "${LOG_FILE}"
}

log_section "SOVEREIGN UPDATE PIPELINE v2 — ${TIMESTAMP}"
log "Log file:  ${LOG_FILE}"
log "Backups:   ${BACKUP_DIR}"

# =============================================================================
# JELLY SCRIPT LOCATOR
# =============================================================================
# Searches all known paths for a jelly script.
# Returns the full path if found, empty string if not found.
# Never fatals — caller decides what to do.

find_jelly() {
    local APP_DIR="$1"     # e.g. "Bookstack"
    local SCRIPT="$2"      # e.g. "bookstack.jelly.bash"

    for BASE in "${JELLY_SEARCH_PATHS[@]}"; do
        local CANDIDATE="${BASE}/${APP_DIR}/${SCRIPT}"
        if [ -f "${CANDIDATE}" ]; then
            echo "${CANDIDATE}"
            return 0
        fi
    done

    # Also check same directory as this script
    local SELF_DIR
    SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local CANDIDATE="${SELF_DIR}/${APP_DIR}/${SCRIPT}"
    if [ -f "${CANDIDATE}" ]; then
        echo "${CANDIDATE}"
        return 0
    fi

    echo ""
    return 1
}

# =============================================================================
# STEP 1: GIT PULL — UPDATE NEXUS REPO
# =============================================================================

log_section "STEP 1: Updating Underground Nexus Repository"

for REPO_PATH in "${NEXUS_REPO}" "${NEXUS_REPO_ALT}"; do
    if [ -d "${REPO_PATH}/.git" ]; then
        log "Pulling ${REPO_PATH}..."
        git -C "${REPO_PATH}" config --global --add safe.directory "${REPO_PATH}" 2>/dev/null || true
        git -C "${REPO_PATH}" pull origin main 2>&1 | tee -a "${LOG_FILE}" || \
            log "WARNING: git pull failed for ${REPO_PATH} — using local version"
        log "✓ Repo updated: ${REPO_PATH}"
    else
        log "No git repo at ${REPO_PATH} — skipping pull"
    fi
done

# =============================================================================
# BACKUP FUNCTION — Quiesce → Tar → Unpause
# =============================================================================

backup_volume() {
    local CONTAINER_NAME="$1"
    local VOLUME_NAME="$2"
    local BACKUP_LABEL="$3"

    if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
        log "  [backup] ${CONTAINER_NAME} not running — skipping volume backup"
        return 0
    fi

    local BACKUP_FILE="${BACKUP_DIR}/${BACKUP_LABEL}-${TIMESTAMP}.tar.gz"

    log "  [backup] Pausing ${CONTAINER_NAME}..."
    docker pause "${CONTAINER_NAME}" 2>/dev/null || true

    log "  [backup] Archiving '${VOLUME_NAME}' → ${BACKUP_FILE}"
    docker run --rm \
        -v "${VOLUME_NAME}:/data:ro" \
        -v "${BACKUP_DIR}:/backup" \
        alpine:latest \
        tar -czf "/backup/${BACKUP_LABEL}-${TIMESTAMP}.tar.gz" -C /data . \
        2>&1 | tee -a "${LOG_FILE}" \
        && log "  [backup] ✓ ${BACKUP_FILE}" \
        || log "  [backup] WARNING: backup failed — proceeding"

    log "  [backup] Unpausing ${CONTAINER_NAME}..."
    docker unpause "${CONTAINER_NAME}" 2>/dev/null || true
}

# =============================================================================
# SAFE UPDATE FUNCTION
# =============================================================================
# ORDER OF OPERATIONS (safe — no container is removed if script not found):
#   1. Locate jelly script — ABORT UPDATE if not found (container stays running)
#   2. Backup all volumes
#   3. Pull new image
#   4. Stop and remove old container
#   5. Redeploy from jelly script

safe_update() {
    local CONTAINER_NAME="$1"
    local IMAGE="$2"
    local APP_DIR="$3"        # directory name in Jelly-Apps/
    local SCRIPT_NAME="$4"    # .jelly.bash filename
    shift 4
    local VOLUMES=("$@")      # volume names to backup

    log_section "Updating: ${CONTAINER_NAME}"

    # --- STEP 1: LOCATE JELLY SCRIPT FIRST (safe gate) ---
    local JELLY_PATH
    JELLY_PATH=$(find_jelly "${APP_DIR}" "${SCRIPT_NAME}") || true

    if [ -z "${JELLY_PATH}" ]; then
        log "  ⚠ SKIPPING UPDATE: jelly script not found for ${CONTAINER_NAME}"
        log "    Searched paths:"
        for BASE in "${JELLY_SEARCH_PATHS[@]}"; do
            log "      ${BASE}/${APP_DIR}/${SCRIPT_NAME}"
        done
        log "    Container is LEFT RUNNING — no changes made."
        log "    To fix: place ${SCRIPT_NAME} in one of the above paths."
        return 0
    fi

    log "  ✓ Jelly script found: ${JELLY_PATH}"

    # --- STEP 2: BACKUP VOLUMES ---
    for VOL in "${VOLUMES[@]}"; do
        backup_volume "${CONTAINER_NAME}" "${VOL}" "${CONTAINER_NAME}-${VOL}"
    done

    # --- STEP 3: PULL NEW IMAGE ---
    log "  Pulling: ${IMAGE}"
    docker pull "${IMAGE}" 2>&1 | tee -a "${LOG_FILE}" \
        && log "  ✓ Image pulled" \
        || log "  WARNING: pull failed (air-gap or unchanged)"

    # --- STEP 4: STOP AND REMOVE OLD CONTAINER ---
    if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
        log "  Stopping ${CONTAINER_NAME}..."
        docker stop "${CONTAINER_NAME}" 2>/dev/null || true
        docker rm "${CONTAINER_NAME}" 2>/dev/null || true
        log "  ✓ Old container removed"
    fi

    # --- STEP 5: REDEPLOY ---
    log "  Redeploying via: ${JELLY_PATH}"
    bash "${JELLY_PATH}" 2>&1 | tee -a "${LOG_FILE}" \
        && log "  ✓ ${CONTAINER_NAME} redeployed" \
        || log "  ERROR: redeployment failed — check logs above"
}

# =============================================================================
# STEP 2: BOOKSTACK
# =============================================================================

if [ "${UPDATE_BOOKSTACK}" = "true" ]; then

    log_section "STEP 2a: BookStack MariaDB Dump"

    if docker ps --format '{{.Names}}' | grep -qx "bookstack-db"; then
        MYSQL_BACKUP="${BACKUP_DIR}/bookstack-mysql-${TIMESTAMP}.sql.gz"
        DB_ROOT_PW=$(docker inspect bookstack-db \
            --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
            | grep MYSQL_ROOT_PASSWORD | cut -d= -f2 || echo "")
        log "Dumping MariaDB..."
        docker exec bookstack-db \
            mariadb-dump -u root -p"${DB_ROOT_PW}" --all-databases 2>/dev/null \
            | gzip > "${MYSQL_BACKUP}" \
            && log "✓ MariaDB dump: ${MYSQL_BACKUP}" \
            || log "WARNING: dump failed — volume tar will be used"
    fi

    safe_update \
        "bookstack" \
        "lscr.io/linuxserver/bookstack:latest" \
        "Bookstack" \
        "bookstack.jelly.bash" \
        "bookstack-app-data"

    log_section "STEP 2b: BookStack DB Image Update"
    if docker ps -a --format '{{.Names}}' | grep -qx "bookstack-db"; then
        backup_volume "bookstack-db" "bookstack-db-data" "bookstack-db"
        docker pull mariadb:10.11 2>&1 | tee -a "${LOG_FILE}" || true
        log "✓ MariaDB image updated (sidecar restarted by bookstack.jelly.bash)"
    fi
fi

# =============================================================================
# STEP 3: VAULTWARDEN
# =============================================================================

if [ "${UPDATE_VAULTWARDEN}" = "true" ]; then
    safe_update \
        "vaultwarden" \
        "vaultwarden/server:latest" \
        "Vaultwarden" \
        "vaultwarden.jelly.bash" \
        "vaultwarden-data"
fi

# =============================================================================
# STEP 4: MINIO
# =============================================================================

if [ "${UPDATE_MINIO}" = "true" ]; then
    log_section "STEP 4: Updating MinIO"

    if docker ps -a --format '{{.Names}}' | grep -qx "minio"; then
        backup_volume "minio" "minio-data" "minio"

        docker pull minio/minio:latest 2>&1 | tee -a "${LOG_FILE}" || true

        MINIO_ENV=$(docker inspect minio \
            --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || echo "")
        MINIO_USER=$(echo "${MINIO_ENV}" | grep "^MINIO_ROOT_USER=" | cut -d= -f2 || echo "sovereign")
        MINIO_PASS=$(echo "${MINIO_ENV}" | grep "^MINIO_ROOT_PASSWORD=" | cut -d= -f2 || echo "sovereign2024")

        docker stop minio 2>/dev/null || true
        docker rm minio 2>/dev/null || true

        docker run -d \
            --restart unless-stopped \
            --name minio \
            --network sovereign-net \
            -p 9000:9000 \
            -p 9001:9001 \
            -e "MINIO_ROOT_USER=${MINIO_USER}" \
            -e "MINIO_ROOT_PASSWORD=${MINIO_PASS}" \
            -v minio-data:/data \
            minio/minio:latest server /data --console-address ":9001" \
            && log "✓ MinIO updated and restarted" \
            || log "ERROR: MinIO restart failed"
    else
        log "MinIO not found — skipping"
    fi
fi

# =============================================================================
# STEP 5: N8N
# =============================================================================

if [ "${UPDATE_N8N}" = "true" ]; then
    safe_update \
        "n8n" \
        "n8nio/n8n:latest" \
        "n8n" \
        "n8n.jelly.bash" \
        "n8n-data"
fi

# =============================================================================
# STEP 6: PORTAINER
# =============================================================================

if [ "${UPDATE_PORTAINER}" = "true" ]; then
    safe_update \
        "portainer" \
        "portainer/portainer-ce:latest" \
        "Portainer" \
        "portainer.jelly.bash" \
        "portainer-data"
fi

# =============================================================================
# STEP 7: UPTIME KUMA
# =============================================================================

if [ "${UPDATE_UPTIME_KUMA}" = "true" ]; then
    safe_update \
        "uptime-kuma" \
        "louislam/uptime-kuma:latest" \
        "Uptime-Kuma" \
        "uptime-kuma.jelly.bash" \
        "uptime-kuma-data"
fi

# =============================================================================
# STEP 8: PLANKA
# =============================================================================

if [ "${UPDATE_PLANKA}" = "true" ]; then
    log_section "STEP 8: Updating Planka (with pg_dump)"

    if docker ps -a --format '{{.Names}}' | grep -qx "planka"; then
        # PostgreSQL dump BEFORE anything else
        PG_DUMP_FILE="${BACKUP_DIR}/planka-postgres-${TIMESTAMP}.sql.gz"
        PG_PASS=$(docker inspect planka-db \
            --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
            | grep "^POSTGRES_PASSWORD=" | cut -d= -f2 || echo "")

        if [ -n "${PG_PASS}" ]; then
            docker exec planka-db \
                pg_dump -U planka planka 2>/dev/null \
                | gzip > "${PG_DUMP_FILE}" \
                && log "✓ Planka pg_dump: ${PG_DUMP_FILE}" \
                || log "WARNING: pg_dump failed — volume tar backup will be used"
        fi

        # Locate script BEFORE touching anything
        JELLY_PATH=$(find_jelly "Planka" "planka.jelly.bash") || true
        if [ -z "${JELLY_PATH}" ]; then
            log "⚠ SKIPPING Planka update: jelly script not found — container left running"
        else
            backup_volume "planka" "planka-app-data" "planka-app"
            backup_volume "planka-db" "planka-db-data" "planka-db"

            docker pull ghcr.io/plankanban/planka:latest 2>&1 | tee -a "${LOG_FILE}" || true

            docker network disconnect sovereign-net planka 2>/dev/null || true
            docker stop planka 2>/dev/null || true
            docker rm planka 2>/dev/null || true
            docker stop planka-db 2>/dev/null || true
            docker rm planka-db 2>/dev/null || true

            bash "${JELLY_PATH}" 2>&1 | tee -a "${LOG_FILE}" \
                && log "✓ Planka redeployed" \
                || log "ERROR: Planka redeployment failed"
        fi
    else
        log "Planka not deployed — skipping"
    fi
fi

# =============================================================================
# STEP 8b: HOME ASSISTANT
# =============================================================================
# Home Assistant uses host networking — backup config volume before swap.
# HA history.db can be large — backup is volume tar only (no SQL dump needed).

if [ "${UPDATE_HOME_ASSISTANT}" = "true" ]; then
    if docker ps -a --format "{{.Names}}" | grep -qx "home-assistant"; then
        log_section "STEP 8b: Updating Home Assistant"

        JELLY_PATH=$(find_jelly "Home-Assistant" "home-assistant.jelly.bash") || true
        if [ -z "${JELLY_PATH}" ]; then
            log "⚠ SKIPPING: home-assistant jelly script not found — container left running"
        else
            backup_volume "home-assistant" "home-assistant-config" "home-assistant-config"

            log "  Pulling latest Home Assistant image..."
            docker pull ghcr.io/home-assistant/home-assistant:stable 2>&1 | tee -a "${LOG_FILE}" || true

            docker stop home-assistant 2>/dev/null || true
            docker rm home-assistant 2>/dev/null || true

            bash "${JELLY_PATH}" 2>&1 | tee -a "${LOG_FILE}" \
                && log "  ✓ Home Assistant redeployed" \
                || log "  ERROR: Home Assistant redeployment failed"
        fi
    else
        log "Home Assistant not deployed — skipping"
    fi
fi

# =============================================================================
# STEP 9: PRUNE OLD BACKUPS (keep 7 per app)
# =============================================================================

log_section "STEP 9: Pruning Old Backups (keep 7)"

for PREFIX in bookstack vaultwarden minio n8n portainer uptime-kuma planka home-assistant; do
    # Use grep -c for reliable integer count (no whitespace issues)
    FILE_LIST=$(ls "${BACKUP_DIR}/${PREFIX}"*.tar.gz 2>/dev/null || true)
    if [ -z "${FILE_LIST}" ]; then
        continue
    fi
    COUNT=$(echo "${FILE_LIST}" | grep -c "." 2>/dev/null || echo "0")
    if [ "${COUNT}" -gt 7 ] 2>/dev/null; then
        echo "${FILE_LIST}" | sort -t_ -k2 | head -n $((COUNT - 7)) | while read -r OLD; do
            log "  Removing old backup: ${OLD}"
            rm -f "${OLD}"
        done
    fi
done

log "✓ Backup rotation complete"

# =============================================================================
# STEP 10: PRUNE DANGLING IMAGES
# =============================================================================

log_section "STEP 10: Pruning Dangling Images"
docker image prune -f 2>&1 | tee -a "${LOG_FILE}" || true
log "✓ Dangling images removed"

# =============================================================================
# SUMMARY
# =============================================================================

log_section "UPDATE COMPLETE — ${TIMESTAMP}"
log "Log: ${LOG_FILE}"
log "Backups: ${BACKUP_DIR}"
echo ""
log "Current containers:"
docker ps --format "  {{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null | tee -a "${LOG_FILE}" || true
echo ""
log "Rollback any app:"
log "  docker stop <container>"
log "  docker run --rm -v <vol>:/data -v ${BACKUP_DIR}:/backup alpine tar -xzf /backup/<backup>.tar.gz -C /data"
log "  bash <app>.jelly.bash"
