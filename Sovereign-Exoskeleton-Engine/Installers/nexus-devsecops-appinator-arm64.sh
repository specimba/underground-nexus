#!/bin/bash
# =============================================================================
# nexus-devsecops-appinator.sh — Cloud Underground · Underground Nexus
# Installs DEV / SEC / OPS / SEC-exoskeleton commands into /usr/local/bin
#
# KEY CHANGES (arm64 wave):
#   - DEV: builds arm64 image locally via buildx instead of docker pull
#   - SEC / SEC-exoskeleton / all rebuilds: uses underground-nexus:arm64
#   - SEC-exoskeleton: ONLY forwards ports 1000 and 2000 (no 9010/9050/18080)
#   - MinIO image: pgsty/minio:latest (minio/minio:latest archived Feb 2026)
# =============================================================================

# ---- DEV ----
# Builds natoascode/zero-trust-cockpit:creator-vault for arm64 locally via
# buildx then deploys it. Falls back to docker pull if buildx is unavailable.
cat > /usr/local/bin/DEV << 'DEVCMD'
#!/bin/bash
IMAGE="natoascode/zero-trust-cockpit:creator-vault"
CONTAINER="nexus-creator-vault"
BUILD_DIR="/tmp/ncv-arm64-build"

echo "[DEV] Building arm64 NCV image locally..."

if docker buildx version >/dev/null 2>&1; then
    # Remove existing builder and recreate clean
    docker buildx rm sovereign-builder 2>/dev/null || true
    docker buildx create --name sovereign-builder --driver docker-container --use 2>/dev/null
    docker buildx inspect --bootstrap sovereign-builder 2>/dev/null

    rm -rf "${BUILD_DIR}" && mkdir -p "${BUILD_DIR}"
    tee "${BUILD_DIR}/Dockerfile" > /dev/null << 'DOCKERFILE'
FROM lscr.io/linuxserver/webtop:ubuntu-kde
LABEL maintainer="Cloud Underground"
LABEL version="5.8-arm64"
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq 2>/dev/null || true \
    && apt-get install -y --no-install-recommends wget curl ca-certificates 2>/dev/null || true \
    && curl -fsSL --retry 3 --retry-delay 5 --max-time 120 \
       "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/nexus0.sh" \
       -o /nexus0.sh \
    || wget -q --tries=3 --timeout=120 \
       "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/nexus0.sh" \
       -O /nexus0.sh \
    && test -s /nexus0.sh && chmod +x /nexus0.sh
RUN bash /nexus0.sh || true
RUN rm -f /usr/share/wallpapers/KubuntuLight/contents/images/*.svg \
          /usr/share/wallpapers/KubuntuLight/contents/images/*.png \
          /usr/share/wallpapers/Next/contents/images/*.svg \
          /usr/share/wallpapers/Next/contents/images/*.png \
          /usr/share/wallpapers/Next/contents/images_dark/*.svg \
          /usr/share/wallpapers/Next/contents/images_dark/*.png 2>/dev/null || true
RUN rm -f /etc/s6-overlay/s6-rc.d/user/contents.d/svc-docker 2>/dev/null || true \
    && if [ -f /etc/s6-overlay/s6-rc.d/svc-docker/run ]; then \
        printf '#!/bin/sh\nexec sleep infinity\n' > /etc/s6-overlay/s6-rc.d/svc-docker/run \
        && chmod +x /etc/s6-overlay/s6-rc.d/svc-docker/run; fi \
    && if [ -f /usr/bin/dockerd ]; then \
        mv /usr/bin/dockerd /usr/bin/dockerd.disabled \
        && printf '#!/bin/sh\necho "dockerd masked"\nexit 0\n' > /usr/bin/dockerd \
        && chmod +x /usr/bin/dockerd; fi
RUN mkdir -p /etc/s6-overlay/s6-rc.d/user/contents.d \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/libvirtd \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/virtlogd \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/ollama
RUN apt-get clean && rm -rf /var/lib/apt/lists/* \
    && find /etc/s6-overlay -type f -exec chmod +x {} \; 2>/dev/null || true \
    && find /custom-cont-init.d -type f -exec chmod +x {} \; 2>/dev/null || true
DOCKERFILE

    echo "[DEV] Building arm64 image (20-40 min first run)..."
    docker buildx build \
        --builder sovereign-builder \
        --platform linux/arm64 \
        --tag "${IMAGE}" \
        --load \
        --progress plain \
        "${BUILD_DIR}"
    echo "[DEV] Build complete — deploying..."
else
    echo "[DEV] buildx not available — pulling from registry..."
    docker pull "${IMAGE}"
fi

# Stop/remove existing container
docker stop "${CONTAINER}" 2>/dev/null || true
docker rm   "${CONTAINER}" 2>/dev/null || true

docker run -itd \
    --name=nexus-creator-vault \
    -h nexus-creator-vault \
    --privileged \
    -p 1050:3000 \
    -e PUID=1050 \
    -e PGID=1050 \
    -e TZ=America/Denver \
    --restart unless-stopped \
    -v /dev:/dev \
    -v creator-vault0:/config \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "${IMAGE}"
echo "[DEV] nexus-creator-vault deployed on port 1050"
DEVCMD
chmod +x /usr/local/bin/DEV

# ---- SEC (full port set — bare Linux, no cerberus port conflicts) ----
echo 'docker run -itd --name=Underground-Nexus -h Underground-Nexus --privileged --init -p 22 -p 80:80 -p 8080:8080 -p 443:443 -p 1000:1000 -p 2000:2000 -p 2375:2375 -p 2376:2376 -p 2377:2377 -p 18080:18080 -p 18443:18443 -v /dev:/dev -v underground-nexus-docker-socket:/var/run -v underground-nexus-data:/var/lib/docker/volumes -v nexus-bucket:/nexus-bucket natoascode/underground-nexus:arm64 && docker exec Underground-Nexus bash deploy-olympiad.sh' > /usr/local/bin/SEC
chmod +x /usr/local/bin/SEC

# ---- SEC-exoskeleton (Cerberus context — ONLY ports 1000 and 2000) ----
# Skips 80/443/23xx because Cerberus already owns those on the host.
# Skips 9010/9050/18080 — those were cerberus's own ports, not nexus ports.
# arm64 native — no QEMU needed on arm64 hosts.
echo 'docker run -itd --name=Underground-Nexus -h Underground-Nexus --privileged --init -p 1000:1000 -p 2000:2000 -v /dev:/dev -v underground-nexus-docker-socket:/var/run -v underground-nexus-data:/var/lib/docker/volumes -v nexus-bucket:/nexus-bucket natoascode/underground-nexus:arm64 && docker exec Underground-Nexus bash deploy-olympiad.sh' > /usr/local/bin/SEC-exoskeleton
chmod +x /usr/local/bin/SEC-exoskeleton

echo "DEV, SEC, SEC-exoskeleton, OPS commands installed."

# ---- OPS ----
echo 'docker run -itd --name=Underground-Ops -h Underground-Ops --privileged --init -p 1060:1050 -v /dev:/dev -v underground-ops-docker-socket:/var/run natoascode/underground-nexus:arm64' > /usr/local/bin/OPS
chmod +x /usr/local/bin/OPS

# ============================================================
# REBUILD COMMANDS (full stop/rm/volume wipe then redeploy)
# ============================================================

# DEV-rebuild
cat > /usr/local/bin/DEV-rebuild << 'DEVREBUILD'
#!/bin/bash
docker container stop nexus-creator-vault 2>/dev/null || true
docker container rm nexus-creator-vault 2>/dev/null || true
docker volume rm creator-vault0 2>/dev/null || true
docker rmi natoascode/zero-trust-cockpit:creator-vault 2>/dev/null || true
exec /usr/local/bin/DEV
DEVREBUILD
chmod +x /usr/local/bin/DEV-rebuild

# SEC-rebuild
echo 'docker container stop Underground-Nexus && docker container rm Underground-Nexus && docker volume rm underground-nexus-docker-socket underground-nexus-data nexus-bucket && docker pull natoascode/underground-nexus:arm64 && docker run -itd --name=Underground-Nexus -h Underground-Nexus --privileged --init -p 22 -p 80:80 -p 8080:8080 -p 443:443 -p 1000:1000 -p 2000:2000 -p 2375:2375 -p 2376:2376 -p 2377:2377 -p 18080:18080 -p 18443:18443 -v /dev:/dev -v underground-nexus-docker-socket:/var/run -v underground-nexus-data:/var/lib/docker/volumes -v nexus-bucket:/nexus-bucket natoascode/underground-nexus:arm64 && docker exec Underground-Nexus bash deploy-olympiad.sh' > /usr/local/bin/SEC-rebuild
chmod +x /usr/local/bin/SEC-rebuild

# SEC-exoskeleton-rebuild
echo 'docker container stop Underground-Nexus && docker container rm Underground-Nexus && docker volume rm underground-nexus-docker-socket underground-nexus-data nexus-bucket && docker pull natoascode/underground-nexus:arm64 && docker run -itd --name=Underground-Nexus -h Underground-Nexus --privileged --init -p 1000:1000 -p 2000:2000 -v /dev:/dev -v underground-nexus-docker-socket:/var/run -v underground-nexus-data:/var/lib/docker/volumes -v nexus-bucket:/nexus-bucket natoascode/underground-nexus:arm64 && docker exec Underground-Nexus bash deploy-olympiad.sh' > /usr/local/bin/SEC-exoskeleton-rebuild
chmod +x /usr/local/bin/SEC-exoskeleton-rebuild

# OPS-rebuild
echo 'docker container stop Underground-Ops && docker container rm Underground-Ops && docker volume rm underground-ops-docker-socket nexus-bucket && docker pull natoascode/underground-nexus:arm64 && docker run -itd --name=Underground-Ops -h Underground-Ops --privileged --init -p 1060:1050 -v /dev:/dev -v underground-ops-docker-socket:/var/run natoascode/underground-nexus:arm64' > /usr/local/bin/OPS-rebuild
chmod +x /usr/local/bin/OPS-rebuild

# ============================================================
# RESTORE COMMANDS (stop/rm container only, volumes preserved)
# ============================================================

# DEV-restore
cat > /usr/local/bin/DEV-restore << 'DEVRESTORE'
#!/bin/bash
docker container stop nexus-creator-vault 2>/dev/null || true
docker container rm nexus-creator-vault 2>/dev/null || true
exec /usr/local/bin/DEV
DEVRESTORE
chmod +x /usr/local/bin/DEV-restore

# SEC-restore
echo 'docker container stop Underground-Nexus && docker container rm Underground-Nexus && docker volume rm underground-nexus-docker-socket && docker pull natoascode/underground-nexus:arm64 && docker run -itd --name=Underground-Nexus -h Underground-Nexus --privileged --init -p 22 -p 80:80 -p 8080:8080 -p 443:443 -p 1000:1000 -p 2000:2000 -p 2375:2375 -p 2376:2376 -p 2377:2377 -p 18080:18080 -p 18443:18443 -v /dev:/dev -v underground-nexus-docker-socket:/var/run -v underground-nexus-data:/var/lib/docker/volumes -v nexus-bucket:/nexus-bucket natoascode/underground-nexus:arm64 && docker exec Underground-Nexus bash deploy-olympiad.sh' > /usr/local/bin/SEC-restore
chmod +x /usr/local/bin/SEC-restore

# SEC-exoskeleton-restore
echo 'docker container stop Underground-Nexus && docker container rm Underground-Nexus && docker volume rm underground-nexus-docker-socket && docker pull natoascode/underground-nexus:arm64 && docker run -itd --name=Underground-Nexus -h Underground-Nexus --privileged --init -p 1000:1000 -p 2000:2000 -v /dev:/dev -v underground-nexus-docker-socket:/var/run -v underground-nexus-data:/var/lib/docker/volumes -v nexus-bucket:/nexus-bucket natoascode/underground-nexus:arm64 && docker exec Underground-Nexus bash deploy-olympiad.sh' > /usr/local/bin/SEC-exoskeleton-restore
chmod +x /usr/local/bin/SEC-exoskeleton-restore

# OPS-restore
echo 'docker container stop Underground-Ops && docker container rm Underground-Ops && docker volume rm underground-ops-docker-socket && docker pull natoascode/underground-nexus:arm64 && docker run -itd --name=Underground-Ops -h Underground-Ops --privileged --init -p 1060:1050 -v /dev:/dev -v underground-ops-docker-socket:/var/run natoascode/underground-nexus:arm64' > /usr/local/bin/OPS-restore
chmod +x /usr/local/bin/OPS-restore

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  All commands installed to /usr/local/bin               ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  DEV              — build arm64 NCV + deploy port 1050  ║"
echo "║  SEC              — deploy Underground-Nexus arm64      ║"
echo "║  SEC-exoskeleton  — deploy Nexus arm64, ports 1000+2000 ║"
echo "║  OPS              — deploy Underground-Ops arm64        ║"
echo "║                                                          ║"
echo "║  DEV-rebuild / DEV-restore                              ║"
echo "║  SEC-rebuild / SEC-restore                              ║"
echo "║  SEC-exoskeleton-rebuild / SEC-exoskeleton-restore      ║"
echo "║  OPS-rebuild / OPS-restore                              ║"
echo "╚══════════════════════════════════════════════════════════╝"
