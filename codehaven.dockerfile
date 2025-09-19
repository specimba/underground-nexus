# Underground Nexus — Golden Host
# - Pure docker:27-dind (no entrypoint changes)
# - Deploy scripts written via printf (bulletproof against brittle CI)
# - Optional AUTO_DEPLOY=light|full runs ~30s after dockerd is ready (via HEALTHCHECK hook)

FROM docker:27-dind

# Useful tools (compose v2 included in docker cli)
RUN apk add --no-cache bash curl wget jq nano tzdata iproute2 bind-tools \
    ca-certificates zip unzip docker-compose docker-cli-compose \
 && update-ca-certificates

ENV TZ=America/Denver \
    NEXUS_BUCKET=/nexus-bucket \
    PIHOLE_IP=10.20.0.20 \
    INNER_ATHENA_NET=10.20.0.0/24 \
    INNER_ATHENA_GW=10.20.0.1 \
    AUTO_DEPLOY=""

VOLUME ["/nexus-bucket"]

# --------------------------------------------------------------------
# Helper: wait-for-inner-docker
# --------------------------------------------------------------------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/wait-for-inner-docker && \
    printf '%s\n' 'for i in $(seq 1 180); do'                                >> /usr/local/bin/wait-for-inner-docker && \
    printf '%s\n' '  docker info >/dev/null 2>&1 && exit 0'                  >> /usr/local/bin/wait-for-inner-docker && \
    printf '%s\n' '  sleep 1'                                                >> /usr/local/bin/wait-for-inner-docker && \
    printf '%s\n' 'done'                                                     >> /usr/local/bin/wait-for-inner-docker && \
    printf '%s\n' 'echo "ERROR: inner dockerd not ready after 180s" >&2'     >> /usr/local/bin/wait-for-inner-docker && \
    printf '%s\n' 'exit 1'                                                   >> /usr/local/bin/wait-for-inner-docker && \
    chmod +x /usr/local/bin/wait-for-inner-docker

# --------------------------------------------------------------------
# Helper: nexus-swarm-prepare  (swarm + overlays)
# --------------------------------------------------------------------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/nexus-swarm-prepare && \
    printf '%s\n' 'set -eu'                                                  >> /usr/local/bin/nexus-swarm-prepare && \
    printf '%s\n' 'if ! docker info --format "{{.Swarm.LocalNodeState}}" 2>/dev/null | grep -q "^active$"; then' >> /usr/local/bin/nexus-swarm-prepare && \
    printf '%s\n' '  ADDR=$(ip -4 -o addr show dev eth0 | awk "{print \$4}" | cut -d/ -f1 | head -n1 || true)' >> /usr/local/bin/nexus-swarm-prepare && \
    printf '%s\n' '  docker swarm init ${ADDR:+--advertise-addr "$ADDR"} >/dev/null 2>&1 || docker swarm init >/dev/null 2>&1 || true' >> /usr/local/bin/nexus-swarm-prepare && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/nexus-swarm-prepare && \
    printf '%s\n' 'docker network inspect traefik-public >/dev/null 2>&1 || docker network create --attachable -d overlay --subnet=10.15.0.0/16 --gateway=10.15.0.1 traefik-public' >> /usr/local/bin/nexus-swarm-prepare && \
    printf '%s\n' 'docker network inspect underground-wordpress_internal >/dev/null 2>&1 || docker network create -d overlay --attachable --subnet=172.16.32.0/24 underground-wordpress_internal' >> /usr/local/bin/nexus-swarm-prepare && \
    chmod +x /usr/local/bin/nexus-swarm-prepare

# --------------------------------------------------------------------
# Helper: nexus-pihole (bridge + Pi-hole + DNS seed)
# --------------------------------------------------------------------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'set -eu'                                                  >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' ': "${NEXUS_BUCKET:=/nexus-bucket}"'                       >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' ': "${PIHOLE_IP:=10.20.0.20}"'                             >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' ': "${INNER_ATHENA_NET:=10.20.0.0/24}"'                    >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' ': "${INNER_ATHENA_GW:=10.20.0.1}"'                        >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'docker network inspect Inner-Athena >/dev/null 2>&1 || docker network create -d bridge --subnet="${INNER_ATHENA_NET}" --gateway="${INNER_ATHENA_GW}" Inner-Athena' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'if ! docker ps -a --format "{{.Names}}" | grep -q "^Inner-DNS-Control$"; then' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' '  docker run -d --name=Inner-DNS-Control -h Inner-DNS-Control --net=Inner-Athena --ip="${PIHOLE_IP}" -p 53:53/tcp -p 53:53/udp -p 800:80 -e WEBPASSWORD="${PIHOLE_WEBPASSWORD:-nexusadmin}" -e FTLCONF_LOCAL_IPV4="${PIHOLE_IP}" -v pihole_DNS_data:/etc/dnsmasq.d/ -v pihole_config:/etc/pihole/ --restart=always pihole/pihole:latest' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'DNSVOL_HOST="/var/lib/docker/volumes/pihole_DNS_data/_data"; CFGVOL_HOST="/var/lib/docker/volumes/pihole_config/_data"; mkdir -p "$DNSVOL_HOST" "$CFGVOL_HOST" || true' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'SRC_BASE="${NEXUS_BUCKET}/underground-nexus/Production Artifacts"' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' '[ -f "${SRC_BASE}/Inner-DNS-Control_teleporter.zip" ] && cp -f "${SRC_BASE}/Inner-DNS-Control_teleporter.zip" "$DNSVOL_HOST/Inner-DNS-Control_teleporter.zip" || true' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'docker exec Inner-DNS-Control sh -lc '\''cp /etc/dnsmasq.d/Inner-DNS-Control_teleporter.zip /Inner-DNS-Control_teleporter.zip || true'\''' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' '[ -f "${SRC_BASE}/pihole.toml" ] && cp -f "${SRC_BASE}/pihole.toml" "$DNSVOL_HOST/pihole.toml" || true' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'docker exec Inner-DNS-Control sh -lc '\''cp /etc/dnsmasq.d/pihole.toml /etc/pihole/pihole.toml || true'\''' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'grep -q "underground-ops.me" "$CFGVOL_HOST/custom.list" 2>/dev/null || echo "10.20.0.1 underground-ops.me" >> "$CFGVOL_HOST/custom.list"' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'C="$DNSVOL_HOST/05-pihole-custom-cname.conf"; touch "$C"' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add(){ grep -q "^cname=$1,$2$" "$C" 2>/dev/null || echo "cname=$1,$2" >> "$C"; }' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add api.underground-ops.me underground-ops.me'           >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add gitlab.underground-ops.me underground-ops.me'        >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add workbench.underground-ops.me underground-ops.me'     >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add grafana.underground-ops.me underground-ops.me'       >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add alertmanager.underground-ops.me underground-ops.me'  >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add indexer.underground-ops.me underground-ops.me'       >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add prometheus.underground-ops.me underground-ops.me'    >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add wazuh.underground-ops.me underground-ops.me'         >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add knowledge.underground-ops.me underground-ops.me'     >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add cloud.underground-ops.me underground-ops.me'         >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add portainer.underground-ops.me underground-ops.me'     >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add code.underground-ops.me underground-ops.me'          >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add vault.underground-ops.me underground-ops.me'         >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add minio.underground-ops.me underground-ops.me'         >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add security-operation-center.underground-ops.me underground-ops.me' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'sort -u "$C" -o "$C" || true'                             >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'docker exec Inner-DNS-Control sh -lc '\''pihole restartdns || s6-svc -h /var/run/s6/services/pihole-FTL || true'\''' >> /usr/local/bin/nexus-pihole && \
    chmod +x /usr/local/bin/nexus-pihole

# --------------------------------------------------------------------
# deploy-light.sh  (Pi-hole + core singletons + loopback & SOC)
# --------------------------------------------------------------------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'set -eu'                                                  >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'wait-for-inner-docker'                                    >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'nexus-pihole'                                             >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'nexus-swarm-prepare'                                      >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'docker volume create portainer_data >/dev/null 2>&1 || true' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if ! docker ps -a --format "{{.Names}}" | grep -q "^Olympiad0$"; then' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' '  docker run -d -p 8000:8000 -p 9050:9443 --name=Olympiad0 --dns=10.20.0.20 --net=Inner-Athena --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if ! docker ps -a --format "{{.Names}}" | grep -q "^workbench$"; then' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' '  docker run -itd --privileged --name=workbench -h workbench -e PUID=1000 -e PGID=1000 -e TZ="${TZ:-America/Denver}" -p 1000:3000 --dns=10.20.0.20 --net=Inner-Athena --restart=always -v /dev:/dev -v workbench0:/config -v "${NEXUS_BUCKET}:/config/Desktop/nexus-bucket" -v /var/run/docker.sock:/var/run/docker.sock natoascode/workbench0:latest' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' '# Workbench loopback proxy (inside same netns) so localhost:1000 -> 127.0.0.1:3000' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if ! docker ps -a --format "{{.Names}}" | grep -q "^workbench-loopback$"; then' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' '  docker run -d --name=workbench-loopback --network=container:workbench --restart=always alpine:3 sh -lc "apk add --no-cache socat && socat TCP-LISTEN:1000,bind=127.0.0.1,fork,reuseaddr TCP:127.0.0.1:3000"' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if ! docker ps -a --format "{{.Names}}" | grep -q "^Athena0$"; then' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' '  docker run -itd --init --name=Athena0 -h Athena0 --dns=10.20.0.20 --net=Inner-Athena --restart=always -v athena0:/home/ -v "${NEXUS_BUCKET}:${NEXUS_BUCKET}" -v /etc/docker:/etc/docker -v /usr/local/bin/docker:/usr/local/bin/docker -v /var/run/docker.sock:/var/run/docker.sock -v /var/lib/docker/volumes/:/var/lib/docker/volumes/ natoascode/athena0:latest' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if ! docker ps -a --format "{{.Names}}" | grep -q "^torpedo$"; then' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' '  docker run -itd --privileged -p 9000:9000 -p 9010:9001 --name=torpedo -h torpedo --dns=10.20.0.20 --net=Inner-Athena --restart=always -v "${NEXUS_BUCKET}:${NEXUS_BUCKET}" -v "${NEXUS_BUCKET}/s3-torpedo:/data" quay.io/minio/minio server /data --console-address :9001' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if [ "${ENABLE_OPENVSCODE:-true}" = "true" ] && ! docker ps -a --format "{{.Names}}" | grep -q "^code-server$"; then' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' '  docker run -d --name=code-server -e PUID=1050 -e PGID=1050 -p 18443:3000 --dns=10.20.0.20 --net=Inner-Athena -v "${NEXUS_BUCKET}:${NEXUS_BUCKET}" -v "${NEXUS_BUCKET}/visual-studio-code:/config" -v /etc/docker:/etc/docker -v /usr/local/bin/docker:/usr/local/bin/docker -v /var/run/docker.sock:/var/run/docker.sock --restart unless-stopped lscr.io/linuxserver/openvscode-server' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if [ "${ENABLE_VAULT_DEV:-true}" = "true" ] && ! docker ps -a --format "{{.Names}}" | grep -q "^Nexus-Secret-Vault$"; then' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' '  docker run -itd -p 8200:1234 --name=Nexus-Secret-Vault -h Nexus-Secret-Vault --dns=10.20.0.20 --net=Inner-Athena --restart=always --cap-add=IPC_LOCK -e VAULT_DEV_ROOT_TOKEN_ID=myroot -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:1234 vault:1.13.3' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' '# --- Security Operation Center (SOC) on 2000:3000 ---'  >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'docker volume create underground-soc >/dev/null 2>&1 || true' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if ! docker ps -a --format "{{.Names}}" | grep -q "^security-operation-center$"; then' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' '  docker run -itd --privileged --name=security-operation-center -h security-operation-center -e PUID=2000 -e PGID=2000 -e TZ="${TZ:-America/Denver}" -p 2000:3000 --dns=10.20.0.20 --net=Inner-Athena --restart=always -v /dev:/dev -v underground-soc:/config -v "${NEXUS_BUCKET}:/config/Desktop/nexus-bucket" natoascode/workbench0:ubuntu' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' '# SOC loopback proxy for localhost:2000 -> 127.0.0.1:3000' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if ! docker ps -a --format "{{.Names}}" | grep -q "^soc-loopback$"; then' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' '  docker run -d --name=soc-loopback --network=container:security-operation-center --restart=always alpine:3 sh -lc "apk add --no-cache socat && socat TCP-LISTEN:2000,bind=127.0.0.1,fork,reuseaddr TCP:127.0.0.1:3000"' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' '# Run SOC bootstrap after 30s (best-effort)'             >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' '( sleep 30 && docker exec security-operation-center bash /workbench.sh ) || true &' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'echo "[light] done."'                                     >> /usr/local/bin/deploy-light.sh && \
    chmod +x /usr/local/bin/deploy-light.sh

# --------------------------------------------------------------------
# deploy-full.sh  (Light + Traefik/GitLab/WP/Knowledge/Cloud/Observability/Wazuh)
# --------------------------------------------------------------------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'set -eu'                                                  >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'deploy-light.sh'                                          >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'nexus-swarm-prepare'                                      >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'connect(){ CN="$1"; IP="${2:-}"; if docker ps -a --format "{{.Names}}" | grep -q "^${CN}$"; then docker network inspect traefik-public 2>/dev/null | grep -q "\"Name\": \"${CN}\"" || { [ -n "$IP" ] && docker network connect --ip "$IP" traefik-public "$CN" || docker network connect traefik-public "$CN"; }; fi; }' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'connect workbench'                                        >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'connect Athena0'                                          >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'connect Inner-DNS-Control 10.15.0.200'                    >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'connect torpedo'                                          >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'connect code-server'                                      >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'connect Nexus-Secret-Vault'                               >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'connect security-operation-center'                        >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'NODE="$(docker info -f "{{.Name}}" 2>/dev/null || true)"; [ -n "$NODE" ] && docker node update --label-add traefik-public.traefik-public-certificates=true "$NODE" >/dev/null 2>&1 || true' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'docker node update --label-add traefik-public.traefik-public-certificates=true Underground-Nexus >/dev/null 2>&1 || true' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'docker node update --label-add traefik-public.traefik-public-certificates=true underground-nexus >/dev/null 2>&1 || true' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' ': "${NEXUS_BUCKET:=/nexus-bucket}"; REPO="${NEXUS_BUCKET}/underground-nexus"' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' '[ -f "${REPO}/traefik-api-proxy.yml" ]      && docker stack deploy -c "${REPO}/traefik-api-proxy.yml" traefik || true' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' '[ -f "${REPO}/gitlab-proxy-deploy.yml" ]    && docker stack deploy -c "${REPO}/gitlab-proxy-deploy.yml" gitlab || true' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' '[ -f "${REPO}/workbench-proxy-deploy.yml" ] && docker stack deploy -c "${REPO}/workbench-proxy-deploy.yml" collaborator-workbench || true' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'if [ -f "${REPO}/Production Artifacts/Wordpress/_data.zip" ]; then docker network create -d overlay --attachable --subnet=172.16.32.0/24 underground-wordpress_internal >/dev/null 2>&1 || true; mkdir -p /var/lib/docker/volumes/underground-wordpress_db_data || true; cp -f "${REPO}/Production Artifacts/Wordpress/_data.zip" /var/lib/docker/volumes/underground-wordpress_db_data/_data.zip || true; ( cd /var/lib/docker/volumes/underground-wordpress_db_data/ && unzip -o _data.zip && rm -f _data.zip ) || true; [ -f "${REPO}/wordpress-proxy-deploy.yml" ] && docker stack deploy -c "${REPO}/wordpress-proxy-deploy.yml" underground-wordpress || true; fi' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'if [ -d "${REPO}/Cloud Knowledge Base Stack" ]; then cd "${REPO}/Cloud Knowledge Base Stack"; [ -f knowledge-base-proxy-deploy.yml ] && docker stack deploy -c knowledge-base-proxy-deploy.yml underground-knowledge || true; [ -f nextcloud-proxy-deploy.yml ] && docker stack deploy -c nextcloud-proxy-deploy.yml underground-cloud || true; fi' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'if [ -d "${REPO}/Observability Stack" ]; then cd "${REPO}/Observability Stack"; if   [ -f docker-stack.yml ]; then docker stack deploy -c docker-stack.yml underground-observability; elif [ -f stack.yml ]; then docker stack deploy -c stack.yml underground-observability; elif [ -f docker-compose.yml ]; then docker stack deploy -c docker-compose.yml underground-observability; fi; fi' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'if [ -d "${REPO}/Observability Stack/wazuh-docker/single-node" ]; then rm -rf /wazuh-docker || true; cp -r "${REPO}/Observability Stack/wazuh-docker" /wazuh-docker; cd /wazuh-docker/single-node/; chmod 644 ./config/wazuh_indexer_ssl_certs/*.pem ./config/wazuh_indexer_ssl_certs/*.key 2>/dev/null || true; if docker compose version >/dev/null 2>&1; then docker compose -f generate-indexer-certs.yml run --rm generator || true; docker compose up -d || true; elif command -v docker-compose >/dev/null 2>&1; then docker-compose -f generate-indexer-certs.yml run --rm generator || true; docker-compose up -d || true; fi; fi' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'nexus-pihole'                                            >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'echo "[full] complete."'                                 >> /usr/local/bin/deploy-full.sh && \
    chmod +x /usr/local/bin/deploy-full.sh

# --------------------------------------------------------------------
# Optional auto-deploy (no entrypoint change): HEALTHCHECK hook
# --------------------------------------------------------------------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' 'set -eu'                                                  >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' '[ -f /var/run/nexus-autodeployed ] && exit 0'             >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' '[ -z "${AUTO_DEPLOY}" ] && exit 0'                        >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' 'wait-for-inner-docker || true'                             >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' 'sleep 30 || true'                                         >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' 'case "${AUTO_DEPLOY}" in'                                 >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' '  light) deploy-light.sh || true ;;'                      >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' '  full)  deploy-full.sh  || true ;;'                      >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' '  *) : ;;'                                                >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' 'esac'                                                     >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' 'touch /var/run/nexus-autodeployed || true'                >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' 'exit 0'                                                   >> /usr/local/bin/nexus-autodeploy && \
    chmod +x /usr/local/bin/nexus-autodeploy

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD /usr/local/bin/nexus-autodeploy || exit 0

# Optional helper to list contents quickly
RUN printf '%s\n' '#!/usr/bin/env sh' > /usr/local/bin/nexus-contents && \
    printf '%s\n' 'set -eu'            >> /usr/local/bin/nexus-contents && \
    printf '%s\n' 'echo "== Deploy scripts =="; ls -l /usr/local/bin/deploy-*.sh || true' >> /usr/local/bin/nexus-contents && \
    printf '%s\n' 'echo "== Helpers =="; ls -l /usr/local/bin/nexus-* || true'            >> /usr/local/bin/nexus-contents && \
    chmod +x /usr/local/bin/nexus-contents

# Expose the ports you map from the host
EXPOSE 53 80 443 1000 2000 9010 18443 9050
