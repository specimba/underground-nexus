# Underground Nexus — Golden Host ++ (k3d + full Swarm deploy + Pi-hole DNS/CNAME + WordPress DB import)
# - Base: docker:27-dind
# - Pi-hole + Workbench: standalone containers on bridge "Inner-Athena"
# - Traefik / GitLab / Collaborator Workbench / WordPress / Knowledge Base / Nextcloud / Observability: Swarm stacks on traefik-public
# - Wazuh single-node: docker-compose (per original)
# - k3d/kubectl/helm preinstalled; KuberNexus maps 18888:8080@loadbalancer (was 18080)
# - All generated scripts use safe single-quoted printf lines (no accidental shell interpolation)

FROM docker:27-dind

# Core tools with a retry; plus git, unzip, iproute2 for IP detection, bind-tools for DNS testing
RUN (apk add --no-cache bash curl wget jq nano tzdata iproute2 bind-tools \
              ca-certificates zip unzip git docker-compose docker-cli-compose \
      && update-ca-certificates) \
 || (sleep 3 && apk add --no-cache bash curl wget jq nano tzdata iproute2 bind-tools \
              ca-certificates zip unzip git docker-compose docker-cli-compose \
              && update-ca-certificates)

ENV TZ=America/Denver \
    NEXUS_BUCKET=/nexus-bucket \
    PIHOLE_IP=10.20.0.20 \
    INNER_ATHENA_NET=10.20.0.0/24 \
    INNER_ATHENA_GW=10.20.0.1 \
    K3D_CLUSTER=KuberNexus \
    AUTO_DEPLOY=""

VOLUME ["/nexus-bucket"]

# Helpful ports (host will map/route as needed)
EXPOSE 22 53 80 443 1000 18443 9010 9050 9443 18888

# ---------- wait-for-inner-docker ----------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/wait-for-inner-docker && \
    printf '%s\n' 'for i in $(seq 1 180); do docker info >/dev/null 2>&1 && exit 0; sleep 1; done; echo "dockerd not ready" >&2; exit 1' >> /usr/local/bin/wait-for-inner-docker && \
    chmod +x /usr/local/bin/wait-for-inner-docker

# ---------- Install k3d, kubectl, helm (quiet, resilient) ----------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/nexus-k8s-tools && \
    printf '%s\n' 'set -eu'                                                  >> /usr/local/bin/nexus-k8s-tools && \
    printf '%s\n' 'tmpdir=$(mktemp -d); cd "$tmpdir"'                        >> /usr/local/bin/nexus-k8s-tools && \
    printf '%s\n' 'echo "[k8s] installing k3d"'                              >> /usr/local/bin/nexus-k8s-tools && \
    printf '%s\n' 'curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash || true' >> /usr/local/bin/nexus-k8s-tools && \
    printf '%s\n' 'echo "[k8s] installing kubectl (amd64 preferred)"'        >> /usr/local/bin/nexus-k8s-tools && \
    printf '%s\n' 'KVER=$(curl -fsSL https://dl.k8s.io/release/stable.txt || echo "v1.29.0")' >> /usr/local/bin/nexus-k8s-tools && \
    printf '%s\n' 'curl -fsSLo kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl" || curl -fsSLo kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/arm64/kubectl" || true' >> /usr/local/bin/nexus-k8s-tools && \
    printf '%s\n' 'chmod +x kubectl && mv kubectl /usr/local/bin/kubectl || true' >> /usr/local/bin/nexus-k8s-tools && \
    printf '%s\n' 'echo "[k8s] installing helm"'                              >> /usr/local/bin/nexus-k8s-tools && \
    printf '%s\n' 'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || true' >> /usr/local/bin/nexus-k8s-tools && \
    printf '%s\n' 'helm repo add stable https://charts.helm.sh/stable >/dev/null 2>&1 || true' >> /usr/local/bin/nexus-k8s-tools && \
    printf '%s\n' 'helm repo add gitlab https://charts.gitlab.io/ >/dev/null 2>&1 || true' >> /usr/local/bin/nexus-k8s-tools && \
    printf '%s\n' 'cd /; rm -rf "$tmpdir"; echo "[k8s] tools ready"'         >> /usr/local/bin/nexus-k8s-tools && \
    chmod +x /usr/local/bin/nexus-k8s-tools

# ---------- Swarm prepare (overlay for stacks) ----------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/nexus-swarm-prepare && \
    printf '%s\n' 'set -eu'                                                  >> /usr/local/bin/nexus-swarm-prepare && \
    printf '%s\n' 'if ! docker info --format "{{.Swarm.LocalNodeState}}" 2>/dev/null | grep -q "^active$"; then' >> /usr/local/bin/nexus-swarm-prepare && \
    printf '%s\n' '  ADDR=$(ip -4 -o addr show dev eth0 | awk "{print \$4}" | cut -d/ -f1 | head -n1 || true)' >> /usr/local/bin/nexus-swarm-prepare && \
    printf '%s\n' '  docker swarm init ${ADDR:+--advertise-addr "$ADDR"} >/dev/null 2>&1 || docker swarm init >/dev/null 2>&1 || true' >> /usr/local/bin/nexus-swarm-prepare && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/nexus-swarm-prepare && \
    printf '%s\n' 'docker network inspect traefik-public >/dev/null 2>&1 || docker network create --attachable -d overlay --subnet=10.15.0.0/16 --gateway=10.15.0.1 traefik-public' >> /usr/local/bin/nexus-swarm-prepare && \
    printf '%s\n' 'docker network inspect underground-wordpress_internal >/dev/null 2>&1 || docker network create -d overlay --attachable --subnet=172.16.32.0/24 underground-wordpress_internal' >> /usr/local/bin/nexus-swarm-prepare && \
    chmod +x /usr/local/bin/nexus-swarm-prepare

# ---------- Clone or update the Underground Nexus repo into the bucket ----------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/nexus-repo-clone && \
    printf '%s\n' 'set -eu'                                                  >> /usr/local/bin/nexus-repo-clone && \
    printf '%s\n' ': "${NEXUS_BUCKET:=/nexus-bucket}"'                       >> /usr/local/bin/nexus-repo-clone && \
    printf '%s\n' 'mkdir -p "$NEXUS_BUCKET"'                                 >> /usr/local/bin/nexus-repo-clone && \
    printf '%s\n' 'if [ -d "$NEXUS_BUCKET/underground-nexus/.git" ]; then'   >> /usr/local/bin/nexus-repo-clone && \
    printf '%s\n' '  echo "[repo] pulling updates..."'                       >> /usr/local/bin/nexus-repo-clone && \
    printf '%s\n' '  git -C "$NEXUS_BUCKET/underground-nexus" pull --ff-only || true' >> /usr/local/bin/nexus-repo-clone && \
    printf '%s\n' 'else'                                                     >> /usr/local/bin/nexus-repo-clone && \
    printf '%s\n' '  echo "[repo] cloning fresh..."'                         >> /usr/local/bin/nexus-repo-clone && \
    printf '%s\n' '  git clone --depth=1 https://github.com/Underground-Ops/underground-nexus "$NEXUS_BUCKET/underground-nexus" || true' >> /usr/local/bin/nexus-repo-clone && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/nexus-repo-clone && \
    printf '%s\n' 'echo "[repo] ready at $NEXUS_BUCKET/underground-nexus"'   >> /usr/local/bin/nexus-repo-clone && \
    chmod +x /usr/local/bin/nexus-repo-clone

# ---------- Pi-hole + DNS/CNAME seeds exactly like the reference scripts ----------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'set -eu'                                                  >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' ': "${NEXUS_BUCKET:=/nexus-bucket}"'                       >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' ': "${PIHOLE_IP:=10.20.0.20}"'                             >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' ': "${INNER_ATHENA_NET:=10.20.0.0/24}"'                    >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' ': "${INNER_ATHENA_GW:=10.20.0.1}"'                        >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'docker network inspect Inner-Athena >/dev/null 2>&1 || docker network create -d bridge --subnet="${INNER_ATHENA_NET}" --gateway="${INNER_ATHENA_GW}" Inner-Athena' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'if ! docker ps -a --format "{{.Names}}" | grep -q "^Inner-DNS-Control$"; then' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' '  docker run -d --name=Inner-DNS-Control -h Inner-DNS-Control --net=Inner-Athena --ip="${PIHOLE_IP}" -p 53:53/tcp -p 53:53/udp -p 800:80 -e WEBPASSWORD="${PIHOLE_WEBPASSWORD:-nexusadmin}" -e FTLCONF_LOCAL_IPV4="${PIHOLE_IP}" -v pihole_DNS_data:/etc/dnsmasq.d/ -v pihole_config:/etc/pihole/ --restart=always pihole/pihole:latest && docker run -itd --privileged -p 9000:9000 -p 9010:9001 --name=torpedo -h torpedo --dns=10.20.0.20 --net=Inner-Athena --restart=always -v /nexus-bucket:/nexus-bucket -v /nexus-bucket/s3-torpedo:/data quay.io/minio/minio server /data --console-address ":9001"' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'for i in $(seq 1 60); do docker exec Inner-DNS-Control pihole -v >/dev/null 2>&1 && break || sleep 1; done' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'DNSVOL="/var/lib/docker/volumes/pihole_DNS_data/_data"; CFGVOL="/var/lib/docker/volumes/pihole_config/_data"; mkdir -p "$DNSVOL" "$CFGVOL" || true' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'SRC="$NEXUS_BUCKET/underground-nexus/Production Artifacts"' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' '[ -f "$SRC/Inner-DNS-Control_teleporter.zip" ] && cp -f "$SRC/Inner-DNS-Control_teleporter.zip" "$DNSVOL/Inner-DNS-Control_teleporter.zip" || true' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' '[ -f "$SRC/pihole.toml" ] && cp -f "$SRC/pihole.toml" "$DNSVOL/pihole.toml" || true' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'docker exec Inner-DNS-Control sh -lc '\''cp /etc/dnsmasq.d/pihole.toml /etc/pihole/pihole.toml 2>/dev/null || true'\''' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'grep -q "underground-ops.me" "$CFGVOL/custom.list" 2>/dev/null || echo "10.20.0.1 underground-ops.me" >> "$CFGVOL/custom.list"' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'C="$DNSVOL/05-pihole-custom-cname.conf"; touch "$C"'      >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'add(){ grep -q "^cname=$1,$2$" "$C" 2>/dev/null || echo "cname=$1,$2" >> "$C"; }' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'for h in api gitlab workbench grafana alertmanager indexer prometheus wazuh knowledge cloud portainer code vault minio security-operation-center; do add "$h.underground-ops.me" underground-ops.me; done' >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'sort -u "$C" -o "$C" || true'                             >> /usr/local/bin/nexus-pihole && \
    printf '%s\n' 'docker exec Inner-DNS-Control sh -lc '\''pihole restartdns || s6-svc -h /var/run/s6/services/pihole-FTL || true'\''' >> /usr/local/bin/nexus-pihole && \
    chmod +x /usr/local/bin/nexus-pihole

# ---------- k3d cluster create (maps 18888:8080@LB, network Inner-Athena) ----------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/nexus-k3d && \
    printf '%s\n' 'set -eu'                                                  >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' ': "${K3D_CLUSTER:=KuberNexus}"'                           >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' ': "${NEXUS_BUCKET:=/nexus-bucket}"'                       >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' 'if command -v k3d >/dev/null 2>&1; then'                  >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' '  if ! k3d cluster list | awk "NR>1{print \$1}" | grep -qx "$K3D_CLUSTER"; then' >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' '    echo "[k3d] creating cluster $K3D_CLUSTER (18888:8080@LB)";' >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' '    k3d cluster create "$K3D_CLUSTER" --network Inner-Athena --api-port 10.20.0.1:6443 \' >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' '      -p 18888:8080@loadbalancer -p 8443:8443@loadbalancer -p 2222:22@loadbalancer \' >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' '      -p 179:179@loadbalancer -p 2375:2376@loadbalancer -p 2378:2379@loadbalancer -p 2381:2380@loadbalancer \' >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' '      -p 8472:8472@loadbalancer -p 8843:443@loadbalancer -p 4789:4789@loadbalancer \' >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' '      -p 9099:9099@loadbalancer -p 7443:9443@loadbalancer \' >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' '      -p 9796:9796@loadbalancer -p 6783:6783@loadbalancer -p 10250:10250@loadbalancer -p 10254:10254@loadbalancer \' >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' '      -p 31896:31896@loadbalancer -v "$NEXUS_BUCKET:$NEXUS_BUCKET" -v /dev:/dev --servers 1 --registry-create "${K3D_CLUSTER}-registry" --kubeconfig-update-default || true' >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' '    command -v kubectl >/dev/null 2>&1 && k3d kubeconfig merge "$K3D_CLUSTER" --kubeconfig-merge-default || true' >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' '  fi'                                                     >> /usr/local/bin/nexus-k3d && \
    printf '%s\n' 'fi'                                                       >> /usr/local/bin/nexus-k3d && \
    chmod +x /usr/local/bin/nexus-k3d

# ---------- Seed a couple of compact stack files (we will mostly deploy from repo files) ----------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/seed-stacks && \
    printf '%s\n' 'set -eu; mkdir -p /stacks'                                >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'start(){ OUT="$1"; : >"$OUT"; }; l(){ printf "%s\n" "$1" >>"$OUT"; }' >> /usr/local/bin/seed-stacks && \
    \
    printf '%s\n' 'start /stacks/traefik.yml'                                >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''version: "3.8"'\'''                                 >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''services:'\'''                                      >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''  traefik:'\'''                                     >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    image: traefik:2.11'\'''                        >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    command:'\'''                                   >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      - --providers.docker.swarmMode=true'\'''      >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      - --providers.docker.exposedByDefault=false'\''' >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      - --entrypoints.web.address=:80'\'''          >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      - --api.dashboard=true'\'''                   >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    ports:'\'''                                     >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      - target: 80'\'''                             >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''        published: 80'\'''                          >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''        mode: host'\'''                             >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    networks: [traefik-public]'\'''                 >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    volumes: ["/var/run/docker.sock:/var/run/docker.sock:ro"]'\''' >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    deploy:'\'''                                    >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      placement: { constraints: ["node.role == manager"] }'\''' >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      labels:'\'''                                  >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''        - traefik.enable=true'\'''                  >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''        - traefik.http.routers.api.rule=Host(`api.underground-ops.me`)'\''' >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''        - traefik.http.routers.api.entrypoints=web'\''' >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''        - traefik.http.routers.api.service=api@internal'\''' >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''        - traefik.docker.network=traefik-public'\''' >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''networks:'\'''                                      >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''  traefik-public: { external: true }'\'''           >> /usr/local/bin/seed-stacks && \
    \
    printf '%s\n' 'start /stacks/wordpress.yml'                              >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''version: "3.8"'\'''                                 >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''services:'\'''                                      >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''  db:'\'''                                          >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    image: mariadb:10.11'\'''                       >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    environment:'\'''                               >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      MYSQL_ROOT_PASSWORD: wp_root'\'''             >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      MYSQL_DATABASE: wordpress'\'''                >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      MYSQL_USER: wordpress'\'''                    >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      MYSQL_PASSWORD: wordpresspass'\'''            >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    volumes: ["wp_db:/var/lib/mysql"]'\'''          >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    networks: [underground-wordpress_internal]'\''' >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''  wordpress:'\'''                                   >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    image: wordpress:6-apache'\'''                  >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    environment:'\'''                               >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      WORDPRESS_DB_HOST: db'\'''                    >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      WORDPRESS_DB_USER: wordpress'\'''             >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      WORDPRESS_DB_PASSWORD: wordpresspass'\'''     >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      WORDPRESS_DB_NAME: wordpress'\'''             >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    networks: [traefik-public, underground-wordpress_internal]'\''' >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    depends_on: [db]'\'''                           >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    volumes: ["wp_app:/var/www/html"]'\'''          >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''    deploy:'\'''                                    >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''      labels:'\'''                                  >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''        - traefik.enable=true'\'''                  >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''        - traefik.http.routers.wp.rule=Host(`underground-ops.me`)'\''' >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''        - traefik.http.routers.wp.entrypoints=web'\''' >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''        - traefik.http.services.wp.loadbalancer.server.port=80'\''' >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''        - traefik.docker.network=traefik-public'\''' >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''networks:'\'''                                      >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''  traefik-public: { external: true }'\'''           >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''  underground-wordpress_internal: { external: true }'\''' >> /usr/local/bin/seed-stacks && \
    printf '%s\n' 'l '\''volumes: { wp_app: {}, wp_db: {} }'\'''             >> /usr/local/bin/seed-stacks && \
    \
    printf '%s\n' 'for f in /stacks/*.yml; do echo "[seed] $(basename "$f") size=$(wc -c <"$f")"; head -n 4 "$f" || true; done' >> /usr/local/bin/seed-stacks && \
    chmod +x /usr/local/bin/seed-stacks

# ---------- LIGHT DEPLOY: Pi-hole, Portainer (Olympiad0), Workbench, Athena0, Code-server, Vault ----------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'set -eu'                                                  >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'wait-for-inner-docker'                                    >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'nexus-k8s-tools || true'                                  >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'nexus-pihole'                                             >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'nexus-swarm-prepare'                                      >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'docker volume create portainer_data >/dev/null 2>&1 || true' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if ! docker ps -a --format "{{.Names}}" | grep -q "^Olympiad0$"; then docker run -d -p 8000:8000 -p 9050:9443 --name=Olympiad0 --dns=10.20.0.20 --net=Inner-Athena --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest; fi' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if ! docker ps -a --format "{{.Names}}" | grep -q "^workbench$"; then docker run -itd --privileged --name=workbench -h workbench -e PUID=1000 -e PGID=1000 -e TZ="${TZ:-America/Denver}" -p 1000:3000 --dns=10.20.0.20 --net=Inner-Athena --restart=always -v /dev:/dev -v workbench0:/config -v "${NEXUS_BUCKET}:/config/Desktop/nexus-bucket" -v /var/run/docker.sock:/var/run/docker.sock natoascode/workbench0:latest; fi' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if ! docker ps -a --format "{{.Names}}" | grep -q "^workbench-loopback$"; then docker run -d --name=workbench-loopback --network=container:workbench --restart=always alpine:3 sh -lc "apk add --no-cache socat && socat TCP-LISTEN:1000,bind=127.0.0.1,fork,reuseaddr TCP:127.0.0.1:3000"; fi' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if ! docker ps -a --format "{{.Names}}" | grep -q "^Athena0$"; then docker run -itd --init --name=Athena0 -h Athena0 --dns=10.20.0.20 --net=Inner-Athena --restart=always -v athena0:/home/ -v "${NEXUS_BUCKET}:${NEXUS_BUCKET}" -v /etc/docker:/etc/docker -v /usr/local/bin/docker:/usr/local/bin/docker -v /var/run/docker.sock:/var/run/docker.sock natoascode/athena0:latest; fi' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if [ "${ENABLE_OPENVSCODE:-true}" = "true" ] && ! docker ps -a --format "{{.Names}}" | grep -q "^code-server$"; then docker run -d --name=code-server -e PUID=1050 -e PGID=1050 -p 18443:3000 --dns=10.20.0.20 --net=Inner-Athena -v "${NEXUS_BUCKET}:${NEXUS_BUCKET}" -v "${NEXUS_BUCKET}/visual-studio-code:/config" -v /etc/docker:/etc/docker -v /usr/local/bin/docker:/usr/local/bin/docker -v /var/run/docker.sock:/var/run/docker.sock --restart unless-stopped lscr.io/linuxserver/openvscode-server; fi' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'if [ "${ENABLE_VAULT_DEV:-true}" = "true" ] && ! docker ps -a --format "{{.Names}}" | grep -q "^Nexus-Secret-Vault$"; then docker run -itd -p 8200:1234 --name=Nexus-Secret-Vault -h Nexus-Secret-Vault --dns=10.20.0.20 --net=Inner-Athena --restart=always --cap-add=IPC_LOCK -e VAULT_DEV_ROOT_TOKEN_ID=myroot -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:1234 vault:1.13.3; fi' >> /usr/local/bin/deploy-light.sh && \
    printf '%s\n' 'echo "[light] done."'                                     >> /usr/local/bin/deploy-light.sh && \
    chmod +x /usr/local/bin/deploy-light.sh

# ---------- FULL DEPLOY: repo stacks + DNS + WordPress DB import + k3d + Observability ----------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'set -eu'                                                  >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'deploy-light.sh'                                          >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'nexus-repo-clone'                                         >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'nexus-swarm-prepare'                                      >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'NEX="$NEXUS_BUCKET/underground-nexus"'                    >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'NODE="$(docker info -f "{{.Name}}" 2>/dev/null || true)"; [ -n "$NODE" ] && docker node update --label-add traefik-public.traefik-public-certificates=true "$NODE" >/dev/null 2>&1 || true' >> /usr/local/bin/deploy-full.sh && \
    \
    printf '%s\n' 'echo "[swarm] attach management containers to traefik-public (like reference)"' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'docker network connect traefik-public workbench  >/dev/null 2>&1 || true' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'docker network connect traefik-public Athena0    >/dev/null 2>&1 || true' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'docker network connect --ip 10.15.0.200 traefik-public Inner-DNS-Control >/dev/null 2>&1 || true' >> /usr/local/bin/deploy-full.sh && \
    \
    printf '%s\n' 'deploy_stack(){ name="$1"; file="$2"; echo "[stack] $name -> $file"; rm -f /tmp/stack.err; if docker stack config -c "$file" >/tmp/stack.out 2>/tmp/stack.err; then docker stack deploy -c "$file" "$name"; else echo "[stack] YAML invalid: $file" >&2; cat /tmp/stack.err >&2 || true; exit 1; fi; }' >> /usr/local/bin/deploy-full.sh && \
    \
    printf '%s\n' 'echo "[stacks] Traefik + GitLab + Collaborator Workbench (from repo)"' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'deploy_stack traefik               "$NEX/traefik-api-proxy.yml"' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'deploy_stack gitlab                "$NEX/gitlab-proxy-deploy.yml"' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'deploy_stack collaborator-workbench "$NEX/workbench-proxy-deploy.yml"' >> /usr/local/bin/deploy-full.sh && \
    \
    printf '%s\n' 'echo "[wordpress] prep DB volume from Production Artifacts"' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'mkdir -p /var/lib/docker/volumes/underground-wordpress_db_data' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'if [ -f "$NEX/Production Artifacts/Wordpress/_data.zip" ]; then cp "$NEX/Production Artifacts/Wordpress/_data.zip" /var/lib/docker/volumes/underground-wordpress_db_data/; fi' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'if [ -f /var/lib/docker/volumes/underground-wordpress_db_data/_data.zip ]; then cd /var/lib/docker/volumes/underground-wordpress_db_data/ && unzip -o _data.zip && rm -f _data.zip; fi' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'deploy_stack underground-wordpress "$NEX/wordpress-proxy-deploy.yml"' >> /usr/local/bin/deploy-full.sh && \
    \
    printf '%s\n' 'echo "[knowledge] Knowledge Base + Nextcloud stacks (from repo)"' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'deploy_stack underground-knowledge "$NEX/Cloud Knowledge Base Stack/knowledge-base-proxy-deploy.yml"' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'deploy_stack underground-cloud     "$NEX/Cloud Knowledge Base Stack/nextcloud-proxy-deploy.yml"' >> /usr/local/bin/deploy-full.sh && \
    \
    printf '%s\n' 'echo "[observability] Deploy main stack (Grafana/Loki etc.) from repo"' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'deploy_stack underground-observability "$NEX/Observability Stack/docker-stack.yml"' >> /usr/local/bin/deploy-full.sh && \
    \
    printf '%s\n' 'echo "[wazuh] single-node via docker-compose (per original scripts)"' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'rm -rf /wazuh-docker && cp -r "$NEX/Observability Stack/wazuh-docker" / && cd "/wazuh-docker/single-node/"' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'chmod 644 ./config/wazuh_indexer_ssl_certs/*.pem || true; chmod 644 ./config/wazuh_indexer_ssl_certs/*.key || true' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'echo "docker-compose -f generate-indexer-certs.yml run --rm generator && docker-compose up -d" > build-wazuh.sh' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'sh build-wazuh.sh || true'                                >> /usr/local/bin/deploy-full.sh && \
    \
    printf '%s\n' 'echo "[dns] ensure Pi-hole has teleporter + pihole.toml + CNAMEs (and restart dns)"' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'nexus-pihole'                                             >> /usr/local/bin/deploy-full.sh && \
    \
    printf '%s\n' 'echo "[k3d] ensure cluster exists (18888 forward) and kubeconfig merged)"' >> /usr/local/bin/deploy-full.sh && \
    printf '%s\n' 'nexus-k3d || true'                                        >> /usr/local/bin/deploy-full.sh && \
    \
    printf '%s\n' 'echo "[full] complete."'                                  >> /usr/local/bin/deploy-full.sh && \
    chmod +x /usr/local/bin/deploy-full.sh

# ---------- Auto-deploy hook (optional) ----------
RUN printf '%s\n' '#!/usr/bin/env sh'                                         >  /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' 'set -eu'                                                  >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' '[ -f /var/run/nexus-autodeployed ] && exit 0'             >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' '[ -z "${AUTO_DEPLOY}" ] && exit 0'                        >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' 'wait-for-inner-docker || true'                             >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' 'sleep 30 || true'                                         >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' 'case "${AUTO_DEPLOY}" in'                                 >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' '  light) deploy-light.sh || true ;;'                      >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' '  full)  deploy-full.sh  || true ;;'                      >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' 'esac'                                                     >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' 'touch /var/run/nexus-autodeployed || true'                >> /usr/local/bin/nexus-autodeploy && \
    printf '%s\n' 'exit 0'                                                   >> /usr/local/bin/nexus-autodeploy && \
    chmod +x /usr/local/bin/nexus-autodeploy

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD /usr/local/bin/nexus-autodeploy || exit 0

# ---------- Quick introspection helper ----------
RUN printf '%s\n' '#!/usr/bin/env sh' > /usr/local/bin/nexus-contents && \
    printf '%s\n' 'set -eu'            >> /usr/local/bin/nexus-contents && \
    printf '%s\n' 'echo "== Deploy scripts =="; ls -l /usr/local/bin/deploy-*.sh || true' >> /usr/local/bin/nexus-contents && \
    printf '%s\n' 'echo "== Helpers =="; ls -l /usr/local/bin/nexus-* || true'            >> /usr/local/bin/nexus-contents && \
    chmod +x /usr/local/bin/nexus-contents
