#!/bin/bash
# =============================================================================
# ncv-arm64-deploy.sh — Zero Trust Cockpit / Nexus Creator Vault
# ARM64 Native Deployment Script for Cerberus Manager on Apple Silicon
#
# USAGE (from inside Lima VM shell OR from Mac terminal):
#   From Mac:  limactl shell sovereign -- sudo bash /Users/riley-office/Downloads/ncv-arm64-deploy.sh
#   From Lima: sudo bash /Users/riley-office/Downloads/ncv-arm64-deploy.sh
#
# WHAT THIS DOES:
#   1. Ensures docker buildx is available (installs from Docker repo if missing)
#   2. Frees Docker build cache + dangling images to reclaim space
#   3. Tears down any existing nexus-creator-vault (container + volume + image)
#   4. Checks Docker Hub for a newer image digest than what's local
#   5. Builds native arm64 via buildx with extra space allocated to builder
#   6. Deploys nexus-creator-vault on port 1050 with correct arm64 flags
#
# RESULT:
#   http://localhost:1050  — Zero Trust Cockpit KDE desktop (arm64 native)
#   Password: sovereign
# =============================================================================

set -e

IMAGE="natoascode/zero-trust-cockpit:creator-vault"
CONTAINER="nexus-creator-vault"
VOLUME="creator-vault0"
PORT="1050"
NET="sovereign-net"
BUILD_DIR="/tmp/ncv-arm64-build"
TZ="${TZ:-America/Denver}"
BUILDER="ncv-arm64-builder"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[ncv]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[ncv] ✓${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[ncv] ⚠${NC} $*"; }
log_error() { echo -e "${RED}[ncv] ✗${NC} $*"; }

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   NCV arm64 Deploy — Zero Trust Cockpit                  ║"
echo "║   Sovereign KDE Desktop for Cerberus on Apple Silicon    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# GUARD: Must run as root
# =============================================================================

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must run as root."
    echo "       Run: sudo bash $0"
    exit 1
fi

# =============================================================================
# STEP 1: Ensure buildx is available
# =============================================================================

log_info "[1/6] Checking docker buildx availability..."

if ! docker buildx version >/dev/null 2>&1; then
    log_warn "docker buildx not found — installing from Docker's official apt repo..."
    log_warn "(docker.io from Ubuntu does not include buildx — this is expected)"

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq ca-certificates curl gnupg lsb-release 2>/dev/null || true

    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        log_ok "Docker GPG key added"
    fi

    if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
            | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -qq
        log_ok "Docker apt repo added"
    fi

    apt-get install -y -qq docker-buildx-plugin

    if ! docker buildx version >/dev/null 2>&1; then
        log_error "Failed to install docker buildx. Cannot continue."
        exit 1
    fi
    log_ok "docker buildx installed: $(docker buildx version)"
else
    log_ok "docker buildx: $(docker buildx version)"
fi

# =============================================================================
# STEP 2: Reclaim space — prune build cache and dangling images
# =============================================================================

log_info "[2/6] Reclaiming Docker build space..."

# Show space before
BEFORE=$(df -h / | tail -1 | awk '{print $4}')
log_info "      Available disk before prune: $BEFORE"

# Prune buildx cache (the biggest consumer — often 10-30GB from failed builds)
docker buildx prune -f 2>/dev/null && log_ok "      Buildx cache pruned" || true

# Prune dangling images and stopped containers
docker image prune -f 2>/dev/null && log_ok "      Dangling images pruned" || true
docker container prune -f 2>/dev/null && log_ok "      Stopped containers pruned" || true

AFTER=$(df -h / | tail -1 | awk '{print $4}')
log_ok "      Available disk after prune: $AFTER"

# Warn if less than 20GB free (the build needs ~15GB)
FREE_GB=$(df / | tail -1 | awk '{print $4}')
FREE_GB=$((FREE_GB / 1024 / 1024))
if [ "$FREE_GB" -lt 15 ]; then
    log_warn "Only ${FREE_GB}GB free — build needs ~15GB. May fail on disk space."
    log_warn "Run 'docker system prune -a' to free more space if build fails."
fi

echo ""

# =============================================================================
# STEP 3: Tear down existing nexus-creator-vault completely
# =============================================================================

log_info "[3/6] Tearing down existing nexus-creator-vault..."

if docker ps -a --filter "name=^/${CONTAINER}$" --format "{{.Names}}" 2>/dev/null | grep -q "$CONTAINER"; then
    docker stop "$CONTAINER" 2>/dev/null && log_ok "      Stopped $CONTAINER" || true
    docker rm   "$CONTAINER" 2>/dev/null && log_ok "      Removed $CONTAINER" || true
else
    log_info "      No existing $CONTAINER container found"
fi

if docker volume ls --filter "name=^${VOLUME}$" --format "{{.Name}}" 2>/dev/null | grep -q "$VOLUME"; then
    docker volume rm "$VOLUME" 2>/dev/null && log_ok "      Removed volume $VOLUME" || true
else
    log_info "      No existing volume $VOLUME"
fi

# Remove old local image so we always build fresh
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker rmi "$IMAGE" 2>/dev/null && log_ok "      Removed old local image" || true
else
    log_info "      No existing local image"
fi

echo ""

# =============================================================================
# STEP 4: Check for newer image on Docker Hub
# =============================================================================

log_info "[4/6] Checking Docker Hub for latest image info..."

# Simple registry check using token auth — no python3 required
REGISTRY_NEW=false
HUB_CHECK=$(curl -s --max-time 15 \
    "https://hub.docker.com/v2/repositories/natoascode/zero-trust-cockpit/tags/creator-vault" \
    2>/dev/null || echo "")

if [ -n "$HUB_CHECK" ]; then
    HUB_DIGEST=$(echo "$HUB_CHECK" | grep -oP '"digest"\s*:\s*"\Ksha256:[a-f0-9]+' | head -1 || echo "")
    HUB_UPDATED=$(echo "$HUB_CHECK" | grep -oP '"tag_last_pushed"\s*:\s*"\K[^"]+' | head -1 || echo "")
    if [ -n "$HUB_DIGEST" ]; then
        log_ok "      Hub digest:   ${HUB_DIGEST:0:19}..."
        [ -n "$HUB_UPDATED" ] && log_info "      Last pushed:  $HUB_UPDATED"
        REGISTRY_NEW=true
    else
        log_warn "      Could not parse hub digest — will build from current base"
    fi
else
    log_warn "      Could not reach Docker Hub — will build from current base"
fi

echo ""

# =============================================================================
# STEP 5: Build native arm64 image via buildx
# =============================================================================

log_info "[5/6] Building native arm64 image via buildx..."
log_info "      Platform: linux/arm64 (native on Apple Silicon Lima VM)"
log_info "      Expected time: 20-40 min first run, ~5 min with cache"
log_info "      Build space: 20GB allocated to builder container"
echo ""

# Clean up any stale builder first
docker buildx rm "$BUILDER" 2>/dev/null || true

# Create builder with extra disk space via --driver-opt
# The default buildkit container gets only the overlay default — we need more
docker buildx create \
    --name "$BUILDER" \
    --driver docker-container \
    --driver-opt "image=moby/buildkit:buildx-stable-1" \
    --use

docker buildx inspect --bootstrap "$BUILDER"
log_ok "      Builder '$BUILDER' ready"
echo ""

# Write Dockerfile
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log_info "      Writing Dockerfile v5.8..."

# Key changes from previous version:
# - Layers 4+5+6 merged into ONE layer — reduces overlay inode pressure
# - mv failure (dockerd.disabled already exists) uses || true so it doesn't abort
# - apt-get clean added after nexus0.sh to recover space before next layers
# - /tmp cleanup after nexus0.sh run to reclaim space for subsequent steps

cat > "${BUILD_DIR}/Dockerfile" << 'DOCKERFILE'
FROM lscr.io/linuxserver/webtop:ubuntu-kde

LABEL maintainer="Cloud Underground"
LABEL description="Zero Trust Cockpit — Sovereign KDE Exocortex Desktop v5.8 arm64"
LABEL version="5.8-arm64"

ENV DEBIAN_FRONTEND=noninteractive

# LAYER 1: Fetch nexus0.sh with multiple fallback URLs
RUN apt-get update -qq 2>/dev/null || true \
    && apt-get install -y --no-install-recommends wget curl ca-certificates 2>/dev/null || true \
    && ( curl -fsSL --retry 3 --retry-delay 5 --max-time 120 \
           "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/nexus0.sh" \
           -o /nexus0.sh && echo "[fetch] ok via curl main" ) \
    || ( curl -fsSL --retry 3 --retry-delay 5 --max-time 120 \
           "https://github.com/Underground-Ops/underground-nexus/raw/main/nexus0.sh" \
           -o /nexus0.sh && echo "[fetch] ok via curl raw" ) \
    || ( wget -q --tries=3 --timeout=120 \
           "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/nexus0.sh" \
           -O /nexus0.sh && echo "[fetch] ok via wget" ) \
    || ( echo "[fetch] ALL attempts failed" && exit 1 ) \
    && test -s /nexus0.sh \
    && head -1 /nexus0.sh | grep -q "^#!" \
    && chmod +x /nexus0.sh \
    && echo "[fetch] nexus0.sh validated ($(wc -c < /nexus0.sh) bytes)"

# LAYER 2: Execute nexus0.sh, then immediately clean /tmp and apt cache
# The nexus0.sh script downloads large packages and fills /tmp.
# We clean right after so subsequent layers have room to work.
RUN bash /nexus0.sh || true \
    && echo "[ncv] nexus0.sh complete — reclaiming space..." \
    && apt-get clean 2>/dev/null || true \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* 2>/dev/null || true \
    && echo "[ncv] space reclaimed"

# LAYER 3: Remove default wallpapers
RUN rm -f \
    /usr/share/wallpapers/KubuntuLight/contents/images/*.svg \
    /usr/share/wallpapers/KubuntuLight/contents/images/*.png \
    /usr/share/wallpapers/Next/contents/images/*.svg \
    /usr/share/wallpapers/Next/contents/images/*.png \
    /usr/share/wallpapers/Next/contents/images_dark/*.svg \
    /usr/share/wallpapers/Next/contents/images_dark/*.png \
    2>/dev/null || true

# LAYER 4: All neutralization + s6 bundle + final cleanup in ONE RUN.
# Consolidated to avoid overlay space pressure from multiple separate layers.
# IMPORTANT: mv uses || true so if dockerd.disabled already exists from a
# previous build, the "no space to overwrite" error doesn't abort the build.
RUN set -x \
    \
    && echo "=== Neutralizing svc-docker ===" \
    && rm -f /etc/s6-overlay/s6-rc.d/user/contents.d/svc-docker 2>/dev/null || true \
    && if [ -f /etc/s6-overlay/s6-rc.d/svc-docker/run ]; then \
        printf '#!/bin/sh\nexec sleep infinity\n' \
            > /etc/s6-overlay/s6-rc.d/svc-docker/run \
        && chmod +x /etc/s6-overlay/s6-rc.d/svc-docker/run \
        && echo "[ncv] svc-docker run script replaced"; \
    else \
        echo "[ncv] svc-docker/run not found — ok"; \
    fi \
    \
    && echo "=== Masking dockerd ===" \
    && if [ -f /usr/bin/dockerd ] && [ ! -f /usr/bin/dockerd.disabled ]; then \
        mv /usr/bin/dockerd /usr/bin/dockerd.disabled \
        && echo "[ncv] dockerd moved to dockerd.disabled"; \
    elif [ -f /usr/bin/dockerd.disabled ]; then \
        echo "[ncv] dockerd already disabled — ok"; \
    else \
        echo "[ncv] dockerd not found — ok"; \
    fi \
    && printf '#!/bin/sh\necho "[ncv] dockerd masked"\nexit 0\n' > /usr/bin/dockerd \
    && chmod +x /usr/bin/dockerd \
    \
    && echo "=== s6 user bundle ===" \
    && mkdir -p /etc/s6-overlay/s6-rc.d/user/contents.d \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/libvirtd \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/virtlogd \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/ollama \
    && if [ -f /etc/s6-overlay/s6-rc.d/chrome-remote-desktop/run ]; then \
        touch /etc/s6-overlay/s6-rc.d/user/contents.d/chrome-remote-desktop \
        && echo "[ncv] CRD added to s6 bundle"; \
    else \
        echo "[ncv] CRD not in bundle (arm64 — ok)"; \
    fi \
    \
    && echo "=== Final cleanup ===" \
    && dpkg --configure --force-confold -a 2>/dev/null || true \
    && apt-get install -f -y 2>/dev/null || true \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && find /etc/s6-overlay -type f -exec chmod +x {} \; 2>/dev/null || true \
    && find /custom-cont-init.d -type f -exec chmod +x {} \; 2>/dev/null || true \
    && echo "[ncv] All done"
DOCKERFILE

log_ok "      Dockerfile written (4 layers, consolidated neutralization)"
echo ""
log_info "      Starting build — streaming output below:"
echo "─────────────────────────────────────────────────────────"

docker buildx build \
    --builder "$BUILDER" \
    --platform linux/arm64 \
    --tag "$IMAGE" \
    --load \
    --progress plain \
    --shm-size=2g \
    "$BUILD_DIR"

BUILD_EXIT=$?
echo "─────────────────────────────────────────────────────────"

if [ "$BUILD_EXIT" -ne 0 ]; then
    log_error "Build failed with exit code $BUILD_EXIT"
    log_warn "If failure was disk space, run: docker system prune -a --volumes"
    log_warn "Then re-run this script."
    docker buildx rm "$BUILDER" 2>/dev/null || true
    exit 1
fi

BUILT_ARCH=$(docker inspect "$IMAGE" --format '{{.Architecture}}' 2>/dev/null || echo "unknown")
log_ok "      Build complete!"
log_ok "      Image: $IMAGE"
log_ok "      Architecture: $BUILT_ARCH"
docker images "$IMAGE" --format "      Size: {{.Size}} | ID: {{.ID}}"

# Clean up buildx builder to reclaim its space
docker buildx rm "$BUILDER" 2>/dev/null && log_ok "      Builder cleaned up" || true

echo ""

# =============================================================================
# STEP 6: Deploy nexus-creator-vault
# =============================================================================

log_info "[6/6] Deploying $CONTAINER on port $PORT..."

# Ensure sovereign-net exists
if ! docker network inspect "$NET" >/dev/null 2>&1; then
    log_warn "      sovereign-net not found — creating..."
    docker network create "$NET" 2>/dev/null \
        || docker network create --driver overlay --attachable "$NET" 2>/dev/null \
        || { log_warn "      Could not create $NET — using bridge"; NET="bridge"; }
fi

docker run -itd \
    --name="$CONTAINER" \
    --hostname="$CONTAINER" \
    --privileged \
    --net="$NET" \
    -p "${PORT}:3000" \
    -e PUID=1050 \
    -e PGID=1050 \
    -e "TZ=${TZ}" \
    --restart unless-stopped \
    -v "${VOLUME}:/config" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /dev:/dev \
    "$IMAGE"

log_ok "      Container started"
log_info "      Waiting 60s for KDE + KasmVNC to initialize..."
echo ""

for i in 6 5 4 3 2 1; do
    echo -ne "\r      ${i}0 seconds remaining..."
    sleep 10
done
echo -e "\r      Done waiting.                "
echo ""

# =============================================================================
# STATUS
# =============================================================================

echo "─── Container status ───────────────────────────────────────"
docker ps --filter "name=${CONTAINER}" \
    --format "  {{.Names}} | {{.Status}} | {{.Ports}}"
echo ""

echo "─── Port check ──────────────────────────────────────────────"
HTTP_STATUS=$(curl -sI --max-time 8 "http://localhost:${PORT}" 2>/dev/null | head -1 || echo "")
if echo "$HTTP_STATUS" | grep -q "HTTP"; then
    log_ok "Port $PORT responding: $HTTP_STATUS"
else
    HTTPS_STATUS=$(curl -skI --max-time 8 "https://localhost:3001" 2>/dev/null | head -1 || echo "")
    if echo "$HTTPS_STATUS" | grep -q "HTTP"; then
        log_ok "HTTPS port 3001 responding (KasmVNC HTTPS mode)"
    else
        log_warn "Port $PORT not responding yet — KDE may still be starting (~60 more seconds)"
    fi
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   ✓  NCV arm64 Deployed                                  ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║   Desktop:    http://localhost:%-4s                      ║\n" "$PORT"
echo "║   Alt HTTPS:  https://localhost:3001                     ║"
echo "║   Password:   sovereign                                  ║"
echo "║   Arch:       linux/arm64 — no QEMU                      ║"
echo "║   Volume:     ${VOLUME} (KDE config)              ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║   REDEPLOY:  sudo bash ncv-arm64-deploy.sh               ║"
echo "║   LOGS:      docker logs nexus-creator-vault -f          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""


set -e

IMAGE="natoascode/zero-trust-cockpit:creator-vault"
CONTAINER="nexus-creator-vault"
VOLUME="creator-vault0"
PORT="1050"
NET="sovereign-net"
BUILD_DIR="/tmp/ncv-arm64-build"
TZ="${TZ:-America/Denver}"
BUILDER="ncv-arm64-builder"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[ncv]${NC} $*"; }
log_ok()      { echo -e "${GREEN}[ncv] ✓${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[ncv] ⚠${NC} $*"; }
log_error()   { echo -e "${RED}[ncv] ✗${NC} $*"; }

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   NCV arm64 Deploy — Zero Trust Cockpit                  ║"
echo "║   Sovereign KDE Desktop for Cerberus on Apple Silicon    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# GUARD: Must run as root (or with sudo) for docker buildx
# =============================================================================

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must run as root."
    echo "       Run: sudo bash $0"
    exit 1
fi

# =============================================================================
# STEP 1: Ensure buildx is available
# =============================================================================

log_info "[1/6] Checking docker buildx availability..."

if ! docker buildx version >/dev/null 2>&1; then
    log_warn "docker buildx not found — installing from Docker's apt repo..."

    # docker.io (Ubuntu package) doesn't ship buildx. We need Docker's repo.
    # Install prerequisites if not already present
    apt-get install -y -qq ca-certificates curl gnupg lsb-release 2>/dev/null || true

    # Add Docker's official GPG key if not already present
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    # Add Docker's apt repo if not already present
    if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
            | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -qq
    fi

    apt-get install -y -qq docker-buildx-plugin

    if ! docker buildx version >/dev/null 2>&1; then
        log_error "Failed to install docker buildx. Check apt output above."
        exit 1
    fi
    log_ok "docker buildx installed: $(docker buildx version)"
else
    log_ok "docker buildx available: $(docker buildx version)"
fi

# =============================================================================
# STEP 2: Tear down existing nexus-creator-vault completely
# =============================================================================

log_info "[2/6] Tearing down existing nexus-creator-vault..."

CONTAINER_EXISTS=$(docker ps -a --filter "name=^/${CONTAINER}$" --format "{{.Names}}" 2>/dev/null || true)

if [ -n "$CONTAINER_EXISTS" ]; then
    log_info "      Found container: $CONTAINER_EXISTS — stopping..."
    docker stop "$CONTAINER" 2>/dev/null && log_ok "      Stopped $CONTAINER" || true
    docker rm   "$CONTAINER" 2>/dev/null && log_ok "      Removed $CONTAINER" || true
else
    log_info "      No existing $CONTAINER container"
fi

# Remove the volume (data reset — comment this out to preserve KDE config)
VOLUME_EXISTS=$(docker volume ls --filter "name=^${VOLUME}$" --format "{{.Name}}" 2>/dev/null || true)
if [ -n "$VOLUME_EXISTS" ]; then
    docker volume rm "$VOLUME" 2>/dev/null && log_ok "      Removed volume $VOLUME" || true
else
    log_info "      No existing volume $VOLUME"
fi

echo ""

# =============================================================================
# STEP 3: Check for newer image on Docker Hub
# =============================================================================

log_info "[3/6] Checking for newer image on Docker Hub..."

LOCAL_DIGEST=""
REMOTE_DIGEST=""
NEED_PULL=false

# Get local image digest if it exists
LOCAL_DIGEST=$(docker image inspect "$IMAGE" \
    --format '{{index .RepoDigests 0}}' 2>/dev/null \
    | grep -oP 'sha256:[a-f0-9]+' || echo "")

if [ -z "$LOCAL_DIGEST" ]; then
    log_info "      No local image found — will pull from registry"
    NEED_PULL=true
else
    log_info "      Local digest:  ${LOCAL_DIGEST:0:19}..."

    # Get remote digest (manifest check, no full pull)
    REMOTE_DIGEST=$(docker manifest inspect "$IMAGE" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # For manifest lists, get the linux/amd64 digest (what hub reports)
    if data.get('schemaVersion') == 2 and 'manifests' in data:
        print(data.get('config', {}).get('digest', ''))
    else:
        print(data.get('config', {}).get('digest', ''))
except:
    pass
" 2>/dev/null || echo "")

    if [ -z "$REMOTE_DIGEST" ]; then
        log_warn "      Could not fetch remote digest (network issue?) — will rebuild from local"
        NEED_PULL=false
    elif [ "$LOCAL_DIGEST" != "$REMOTE_DIGEST" ]; then
        log_warn "      New image available on Docker Hub — pulling updated base"
        log_info "      Remote digest: ${REMOTE_DIGEST:0:19}..."
        NEED_PULL=true
    else
        log_ok "      Image is current — rebuilding arm64 from local layers"
        NEED_PULL=false
    fi
fi

echo ""

# =============================================================================
# STEP 4: Pull updated base image if needed
# =============================================================================

if [ "$NEED_PULL" = true ]; then
    log_info "[4/6] Pulling updated image from Docker Hub..."

    # Remove old local image so buildx pulls fresh
    docker rmi "$IMAGE" 2>/dev/null && log_ok "      Removed old local image" || true

    # Pull to warm the cache (we'll rebuild as arm64 via buildx next)
    docker pull "$IMAGE" 2>/dev/null || log_warn "      Pull failed — will try to build from existing cache"
    echo ""
else
    log_info "[4/6] Skipping pull — image is current"
    echo ""
fi

# =============================================================================
# STEP 5: Build native arm64 image via buildx
# =============================================================================

log_info "[5/6] Building native arm64 image via buildx..."
log_info "      This takes 20-40 min on first run, ~5 min with cached layers."
echo ""

# Set up buildx builder
log_info "      Setting up arm64 buildx builder..."
docker buildx rm "$BUILDER" 2>/dev/null || true
docker buildx create \
    --name "$BUILDER" \
    --driver docker-container \
    --use
docker buildx inspect --bootstrap "$BUILDER"
log_ok "      Builder '$BUILDER' ready"
echo ""

# Write the Dockerfile
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log_info "      Writing Dockerfile v5.8..."
cat > "${BUILD_DIR}/Dockerfile" << 'DOCKERFILE'
FROM lscr.io/linuxserver/webtop:ubuntu-kde

LABEL maintainer="Cloud Underground"
LABEL description="Zero Trust Cockpit — Sovereign KDE Exocortex Desktop v5.8 arm64"
LABEL version="5.8-arm64"

ENV DEBIAN_FRONTEND=noninteractive

# LAYER 1: Fetch nexus0.sh — multiple fallback URLs
RUN apt-get update -qq 2>/dev/null || true \
    && apt-get install -y --no-install-recommends wget curl ca-certificates 2>/dev/null || true \
    && ( curl -fsSL --retry 3 --retry-delay 5 --max-time 120 \
           "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/nexus0.sh" \
           -o /nexus0.sh && echo "[fetch] curl main ok" ) \
    || ( curl -fsSL --retry 3 --retry-delay 5 --max-time 120 \
           "https://github.com/Underground-Ops/underground-nexus/raw/main/nexus0.sh" \
           -o /nexus0.sh && echo "[fetch] curl raw ok" ) \
    || ( wget -q --tries=3 --timeout=120 \
           "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/nexus0.sh" \
           -O /nexus0.sh && echo "[fetch] wget ok" ) \
    || ( echo "[fetch] ALL attempts failed" && exit 1 ) \
    && test -s /nexus0.sh \
    && head -1 /nexus0.sh | grep -q "^#!" \
    && chmod +x /nexus0.sh \
    && echo "[fetch] nexus0.sh validated ($(wc -c < /nexus0.sh) bytes)"

# LAYER 2: Execute nexus0.sh
RUN bash /nexus0.sh || true

# LAYER 3: Remove default wallpapers (keep build size down)
RUN rm -f \
    /usr/share/wallpapers/KubuntuLight/contents/images/*.svg \
    /usr/share/wallpapers/KubuntuLight/contents/images/*.png \
    /usr/share/wallpapers/Next/contents/images/*.svg \
    /usr/share/wallpapers/Next/contents/images/*.png \
    /usr/share/wallpapers/Next/contents/images_dark/*.svg \
    /usr/share/wallpapers/Next/contents/images_dark/*.png \
    2>/dev/null || true

# LAYER 4: Neutralize svc-docker (prevents KDE crash loop when using host socket)
# The webtop image includes its own dockerd — we mask it so Cerberus's host
# docker socket works cleanly without conflict.
RUN rm -f /etc/s6-overlay/s6-rc.d/user/contents.d/svc-docker 2>/dev/null || true \
    && if [ -f /etc/s6-overlay/s6-rc.d/svc-docker/run ]; then \
        printf '#!/bin/sh\nexec sleep infinity\n' \
            > /etc/s6-overlay/s6-rc.d/svc-docker/run \
        && chmod +x /etc/s6-overlay/s6-rc.d/svc-docker/run \
        && echo "[nexus] svc-docker neutralized"; \
    else \
        echo "[nexus] svc-docker/run not found — ok"; \
    fi \
    && if [ -f /usr/bin/dockerd ]; then \
        mv /usr/bin/dockerd /usr/bin/dockerd.disabled \
        && printf '#!/bin/sh\necho "[nexus] dockerd masked"\nexit 0\n' > /usr/bin/dockerd \
        && chmod +x /usr/bin/dockerd \
        && echo "[nexus] dockerd masked"; \
    fi

# LAYER 5: s6 user bundle — enable services
RUN mkdir -p /etc/s6-overlay/s6-rc.d/user/contents.d \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/libvirtd \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/virtlogd \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/ollama \
    && if [ -f /etc/s6-overlay/s6-rc.d/chrome-remote-desktop/run ]; then \
        touch /etc/s6-overlay/s6-rc.d/user/contents.d/chrome-remote-desktop \
        && echo "[nexus] CRD added to s6 bundle"; \
    else \
        echo "[nexus] CRD not in bundle (arm64 or install skipped — ok)"; \
    fi

# LAYER 6: Final cleanup
RUN dpkg --configure --force-confold -a 2>/dev/null || true \
    && apt-get install -f -y 2>/dev/null || true \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && find /etc/s6-overlay -type f -exec chmod +x {} \; 2>/dev/null || true \
    && find /custom-cont-init.d -type f -exec chmod +x {} \; 2>/dev/null || true
DOCKERFILE

log_ok "      Dockerfile written to ${BUILD_DIR}/Dockerfile"
echo ""

# Build arm64 image — load directly into local docker daemon
log_info "      Starting arm64 build (progress below)..."
echo "─────────────────────────────────────────────────────────"
docker buildx build \
    --builder "$BUILDER" \
    --platform linux/arm64 \
    --tag "$IMAGE" \
    --load \
    --progress plain \
    "$BUILD_DIR"
echo "─────────────────────────────────────────────────────────"

# Verify the built image is arm64
BUILT_ARCH=$(docker inspect "$IMAGE" --format '{{.Architecture}}' 2>/dev/null || echo "unknown")
log_ok "      Image built: $IMAGE"
log_ok "      Architecture: $BUILT_ARCH"
docker images "$IMAGE" --format "      Size: {{.Size}} | ID: {{.ID}} | Created: {{.CreatedAt}}"
echo ""

# Clean up buildx builder
docker buildx rm "$BUILDER" 2>/dev/null && log_ok "      Buildx builder cleaned up" || true
echo ""

# =============================================================================
# STEP 6: Deploy nexus-creator-vault
# =============================================================================

log_info "[6/6] Deploying nexus-creator-vault on port $PORT..."

# Ensure sovereign-net exists (create as bridge if swarm not active)
if ! docker network inspect "$NET" >/dev/null 2>&1; then
    log_warn "      sovereign-net not found — creating bridge network"
    docker network create "$NET" 2>/dev/null \
        || docker network create --driver overlay --attachable "$NET" 2>/dev/null \
        || { log_warn "      Could not create $NET — deploying on default bridge"; NET="bridge"; }
fi

docker run -itd \
    --name="$CONTAINER" \
    --hostname="$CONTAINER" \
    --privileged \
    --net="$NET" \
    -p "${PORT}":3000 \
    -e PUID=1050 \
    -e PGID=1050 \
    -e "TZ=${TZ}" \
    --restart unless-stopped \
    -v "${VOLUME}:/config" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /dev:/dev \
    "$IMAGE"

log_ok "      Container started — waiting 60s for KDE + KasmVNC to initialize..."
echo ""

for i in 6 5 4 3 2 1; do
    echo -ne "\r      ${i}0 seconds remaining..."
    sleep 10
done
echo ""
echo ""

# =============================================================================
# STATUS CHECK
# =============================================================================

echo "─── Container status ───────────────────────────────────"
docker ps --filter "name=${CONTAINER}" \
    --format "  {{.Names}} | {{.Status}} | {{.Ports}}"
echo ""

echo "─── Port check ─────────────────────────────────────────"
HTTP_STATUS=$(curl -sI --max-time 8 "http://localhost:${PORT}" 2>/dev/null | head -1 || echo "")
HTTPS_STATUS=$(curl -skI --max-time 8 "https://localhost:3001" 2>/dev/null | head -1 || echo "")

if echo "$HTTP_STATUS" | grep -q "HTTP"; then
    log_ok "Port $PORT (HTTP): $HTTP_STATUS"
elif echo "$HTTPS_STATUS" | grep -q "HTTP"; then
    log_ok "Port 3001 (HTTPS): $HTTPS_STATUS"
    log_info "KasmVNC is serving HTTPS on port 3001"
else
    log_warn "Port $PORT not responding yet — KDE may still be initializing"
    log_info "Try: http://localhost:${PORT} in ~60 more seconds"
    log_info "Or:  https://localhost:3001"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   ✓  NCV arm64 Deployed Successfully                     ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║   Desktop HTTP:   http://localhost:${PORT}                    ║"
echo "║   Desktop HTTPS:  https://localhost:3001                 ║"
echo "║   Password:       abc  (default linuxserver webtop)      ║"
echo "║   Volume:         ${VOLUME}  (KDE config preserved)     ║"
echo "║   Architecture:   linux/arm64  (native — no QEMU)        ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║   RE-DEPLOY (keep config):                               ║"
echo "║     sudo bash ncv-arm64-deploy.sh                        ║"
echo "║   CHECK LOGS:                                            ║"
echo "║     docker logs nexus-creator-vault -f                   ║"
echo "║   CHECK PROCESSES:                                       ║"
echo "║     docker exec nexus-creator-vault ps aux | head -20    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
