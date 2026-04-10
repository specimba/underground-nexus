#!/usr/bin/env bash
# =============================================================================
# HOME ASSISTANT JELLY APP
# Underground Nexus — Sovereign Smart Home & IoT Automation
# File: Jelly-Apps/Home-Assistant/home-assistant.jelly.bash
# =============================================================================
#
# WHAT THIS DEPLOYS:
#   home-assistant — Home Assistant Core (ghcr.io/home-assistant/home-assistant)
#
# ROLE IN THE SOVEREIGN STACK:
#   Home Assistant is the IoT and smart home layer of the Sovereign Grid.
#   It bridges physical devices (lights, sensors, cameras, locks, HVAC)
#   with the sovereign software stack via:
#
#   → n8n integration: HA webhooks trigger n8n workflows
#     (motion detected → Planka card created → Fractional CFO notified)
#
#   → Vaultwarden: Store HA long-lived tokens and device credentials
#     Access via WARP when not on local network
#
#   → BookStack: Document your device configs, automations, blueprints
#
#   → Uptime Kuma: Monitor HA availability (critical for home automation)
#
# ARCHITECTURE NOTES:
#   - Uses host network mode: HA requires direct access to the host network
#     for mDNS/zeroconf device discovery (Zigbee, Z-Wave, Matter, etc.)
#   - This is intentional and correct — HA cannot discover IoT devices
#     through Docker bridge/overlay networking
#   - The config volume is mounted at /config inside the container
#   - Privileged mode only enabled if USB device passthrough is needed
#     (Zigbee/Z-Wave USB dongle — set ENABLE_USB=true)
#
# PORT:
#   8123 — Home Assistant Web UI (host network, accessible on LAN)
#   127.0.0.1:8123 — loopback binding when NOT in host network mode
#
# STORAGE:
#   home-assistant-config — named volume for HA configuration, database,
#                           automations, blueprints, integrations
#
# AUTHENTICATION:
#   Home Assistant has its own built-in auth system.
#   Store the long-lived access token in Vaultwarden.
#   For enterprise SSO: add Cloudflare Access in front via Traefik.
#
# VAULTWARDEN INTEGRATION (manual step after install):
#   1. Log into HA → Profile → Long-Lived Access Tokens → Create Token
#   2. Store token in Vaultwarden under "Home Assistant"
#   3. Use token in n8n HTTP Request nodes for HA API calls
#
# N8N INTEGRATION:
#   HA REST API: http://home-assistant:8123/api/
#   HA Webhooks: http://home-assistant:8123/api/webhook/<webhook_id>
#   From n8n HTTP node, use the long-lived token in Authorization header:
#   Authorization: Bearer <token-from-vaultwarden>
#
# UPTIME KUMA:
#   Add monitor: HTTP(S) → http://localhost:8123
#   Expect HTTP 200/302 for healthy status
#
# =============================================================================

set -eo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

HA_CONTAINER="${HA_CONTAINER:-home-assistant}"
HA_HOST_PORT="${HA_HOST_PORT:-8123}"
HA_CONFIG_VOLUME="home-assistant-config"

# Network mode — host is required for device discovery (mDNS, Zigbee, Matter)
# Set to 'bridge' only if you don't need IoT device discovery
HA_NETWORK_MODE="${HA_NETWORK_MODE:-host}"

# USB device passthrough (Zigbee/Z-Wave/USB dongles)
# Set ENABLE_USB=true and USB_DEVICE=/dev/ttyUSB0 or /dev/ttyACM0
ENABLE_USB="${ENABLE_USB:-false}"
USB_DEVICE="${USB_DEVICE:-/dev/ttyUSB0}"

# Timezone — critical for automations and scheduling
HA_TZ="${TZ:-America/Denver}"

# =============================================================================
# HELPERS
# =============================================================================

log()  { echo "[home-assistant] $*"; }
ok()   { echo "[home-assistant] ✓ $*"; }
warn() { echo "[home-assistant] ⚠ $*"; }
err()  { echo "[home-assistant] ✗ $*" >&2; }
die()  { err "$*"; exit 1; }

# =============================================================================
# IDEMPOTENCY CHECK
# =============================================================================

log "Checking deployment state..."

if docker ps --format '{{.Names}}' | grep -qx "${HA_CONTAINER}"; then
    ok "Home Assistant already running at http://localhost:${HA_HOST_PORT}"
    log "To redeploy: bash home-assistant-uninstall.jelly.bash && bash home-assistant.jelly.bash"
    exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "${HA_CONTAINER}"; then
    warn "Stopped container found — starting..."
    docker start "${HA_CONTAINER}" || die "Failed to start home-assistant"
    ok "Home Assistant started. http://localhost:${HA_HOST_PORT}"
    exit 0
fi

# =============================================================================
# STEP 1: CLEAN UP STALE CONTAINERS
# =============================================================================

if docker ps -a --format '{{.Names}}' | grep -qx "${HA_CONTAINER}"; then
    warn "Removing stale container..."
    docker stop "${HA_CONTAINER}" 2>/dev/null || true
    docker rm "${HA_CONTAINER}" 2>/dev/null || true
fi

# =============================================================================
# STEP 2: BUILD DOCKER RUN ARGS
# =============================================================================

log "Configuring Home Assistant..."
log "  Network mode:  ${HA_NETWORK_MODE}"
log "  USB passthrough: ${ENABLE_USB}"
log "  Timezone:      ${HA_TZ}"

RUN_ARGS=(
    -d
    --name "${HA_CONTAINER}"
    --restart unless-stopped
    -e "TZ=${HA_TZ}"
    -v "${HA_CONFIG_VOLUME}:/config"
)

# Network configuration
if [ "${HA_NETWORK_MODE}" = "host" ]; then
    RUN_ARGS+=(--network host)
    log "  Host network mode: mDNS/Zigbee/Matter discovery enabled"
    log "  HA will be accessible at http://[host-ip]:${HA_HOST_PORT}"
else
    # Bridge mode — no IoT discovery but simpler networking
    RUN_ARGS+=(
        --network sovereign-net
        -p "127.0.0.1:${HA_HOST_PORT}:8123"
    )
    log "  Bridge network mode: no IoT device discovery"
    log "  HA accessible at http://127.0.0.1:${HA_HOST_PORT}"
fi

# USB passthrough for Zigbee/Z-Wave/Matter dongles
if [ "${ENABLE_USB}" = "true" ]; then
    if [ -e "${USB_DEVICE}" ]; then
        RUN_ARGS+=(
            --privileged
            --device "${USB_DEVICE}:${USB_DEVICE}"
        )
        ok "USB device ${USB_DEVICE} passthrough enabled"
    else
        warn "USB device ${USB_DEVICE} not found — continuing without USB passthrough"
        warn "Connect your Zigbee/Z-Wave dongle and redeploy with ENABLE_USB=true"
    fi
fi

# Traefik labels (ignored if Traefik not running — safe for open-source)
RUN_ARGS+=(
    --label "traefik.enable=true"
    --label "traefik.http.routers.homeassistant.rule=PathPrefix(\`/ha\`)"
    --label "traefik.http.routers.homeassistant.entrypoints=web"
    --label "traefik.http.services.homeassistant.loadbalancer.server.port=8123"
    --label "traefik.http.middlewares.ha-strip.stripprefix.prefixes=/ha"
    --label "traefik.http.routers.homeassistant.middlewares=ha-strip@docker"
)

# =============================================================================
# STEP 3: DEPLOY HOME ASSISTANT
# =============================================================================

log "Pulling Home Assistant image..."
docker pull ghcr.io/home-assistant/home-assistant:stable 2>/dev/null \
    && ok "Image pulled." \
    || warn "Pull failed — using cached image if available"

log "Deploying Home Assistant..."

docker run "${RUN_ARGS[@]}" \
    ghcr.io/home-assistant/home-assistant:stable

# =============================================================================
# STEP 4: POLL FOR READINESS
# =============================================================================

log "Polling http://localhost:${HA_HOST_PORT} ..."
log "First-run onboarding setup takes 30-90 seconds."

HA_READY=0
LAST_HTTP="000"
for i in $(seq 1 18); do
    LAST_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        "http://localhost:${HA_HOST_PORT}" 2>/dev/null || echo "000")

    if [ "${LAST_HTTP}" != "000" ]; then
        HA_READY=1
        ok "Home Assistant responded HTTP ${LAST_HTTP} after $((i*10))s."
        break
    fi

    log "  ${i}/18 — $((i*10))s — HTTP=${LAST_HTTP}"
    sleep 10
done

# =============================================================================
# RESULT
# =============================================================================

echo ""

if [ "${HA_READY}" -eq 1 ]; then
    echo "  ┌──────────────────────────────────────────────────────────────┐"
    echo "  │  ✓ Home Assistant is live                                    │"
    echo "  ├──────────────────────────────────────────────────────────────┤"
    echo "  │  URL:     http://localhost:${HA_HOST_PORT}                           │"
    echo "  │  Config:  home-assistant-config volume                       │"
    echo "  │  Network: ${HA_NETWORK_MODE}                                         │"
    echo "  ├──────────────────────────────────────────────────────────────┤"
    echo "  │  FIRST RUN ONBOARDING:                                       │"
    echo "  │  1. Open http://localhost:${HA_HOST_PORT} in browser                 │"
    echo "  │  2. Create your admin account                                │"
    echo "  │  3. Add your smart home integrations                         │"
    echo "  ├──────────────────────────────────────────────────────────────┤"
    echo "  │  VAULTWARDEN INTEGRATION (after setup):                      │"
    echo "  │  Profile → Security → Long-Lived Access Tokens → Create      │"
    echo "  │  Store token in Vaultwarden under 'Home Assistant'           │"
    echo "  │  Use token in n8n: Authorization: Bearer <token>             │"
    echo "  ├──────────────────────────────────────────────────────────────┤"
    echo "  │  N8N API ACCESS:                                             │"
    echo "  │  REST: http://home-assistant:8123/api/                       │"
    echo "  │  Webhooks: http://home-assistant:8123/api/webhook/<id>       │"
    if [ "${ENABLE_USB}" = "true" ]; then
        echo "  ├──────────────────────────────────────────────────────────────┤"
        echo "  │  USB: ${USB_DEVICE} passthrough active (Zigbee/Z-Wave)     │"
    fi
    echo "  ├──────────────────────────────────────────────────────────────┤"
    echo "  │  ⚠  Add to Uptime Kuma: http://localhost:${HA_HOST_PORT}             │"
    echo "  └──────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  Logs:      docker logs home-assistant -f"
    echo "  Uninstall: bash home-assistant-uninstall.jelly.bash"
    echo ""
    if [ "${ENABLE_USB}" = "false" ]; then
        echo "  Zigbee/Z-Wave dongle support:"
        echo "    ENABLE_USB=true USB_DEVICE=/dev/ttyUSB0 bash home-assistant.jelly.bash"
        echo ""
    fi
else
    warn "Home Assistant did not respond within 3 minutes."
    warn "It may still be initializing. Try: curl http://localhost:${HA_HOST_PORT} in 2 minutes."
    echo ""
    docker logs --tail 20 "${HA_CONTAINER}" 2>&1 | sed 's/^/  /' || true
fi
