# Underground Nexus — Golden Host (vNext)

This is the **golden** Docker-in-Docker base used to validate, harden, and deploy the Underground Nexus.  
It keeps the reliable pattern that worked in your tests: the image starts **pure `docker:27-dind`** and
writes resilient deploy scripts with `printf` (no heredocs to break in brittle pipelines).

> **Key properties**
> - Pi-hole seeded with apex + CNAMEs (idempotent)
> - Swarm + overlays (`traefik-public`, `underground-wordpress_internal`)
> - Core singletons: Portainer (9050), Workbench (`natoascode/workbench0:latest`), Athena0, MinIO, OpenVSCode, Vault (dev)
> - Full stacks: Traefik, GitLab, WordPress Control Panel, Knowledge (BookStack), Cloud (Nextcloud), Observability (Grafana/Loki/Prom/Alertmanager), Wazuh
> - New: **Security Operation Center** (SOC) companion @ 2000:3000 using `natoascode/workbench0:ubuntu`
> - New: **Workbench loopback proxy**: inside Workbench, `http(s)://localhost:1000` (and `127.0.0.1:1000`) works and forwards to Selkies (3000)
> - Optional **Auto-deploy** via HEALTHCHECK: set `AUTO_DEPLOY=light|full` to start deploy **~30s after dockerd is ready** (no entrypoint changes)

---

## Build

```bash
docker build -t underground-nexus-golden:latest .
```

## Run

```bash
docker run -d --name underground-nexus --privileged --init \
  -p 53:53/udp -p 53:53 \
  -p 9050:9050 \            # Portainer (host 9050 -> container 9443)
  -p 1000:1000 \            # Workbench (loopback proxy) -> Selkies 3000
  -p 1000:3000 \            # Workbench (direct Selkies)
  -p 2000:2000 \            # SOC loopback proxy -> SOC 3000
  -p 2000:3000 \            # SOC (direct)
  -p 9010:9010 -p 18443:18443 \
  -e PIHOLE_WEBPASSWORD='change-me' \
  -e AUTO_DEPLOY='' \       # set to light|full to auto-deploy after ~30s (optional)
  -v nexus-bucket:/nexus-bucket \
  underground-nexus-golden:latest
```

> If you set `AUTO_DEPLOY=light` or `AUTO_DEPLOY=full`, the container will deploy automatically
> ~30 seconds after `dockerd` becomes ready, using a one-shot HEALTHCHECK hook.  
> No entrypoint changes; re-runnable; idempotent.

## Manual Deploy (recommended for first boot)

```bash
docker exec -it underground-nexus sh -lc "nexus-contents && head -n 30 /usr/local/bin/deploy-full.sh"
docker exec -it underground-nexus sh -lc "deploy-light.sh"
docker exec -it underground-nexus sh -lc "deploy-full.sh"
```

---

## URLs & DNS (Pi-hole + Traefik)

- Traefik: `https://api.underground-ops.me`
- Portainer: `https://portainer.underground-ops.me` **and** `https://localhost:9050`
- Workbench (Selkies desktop):  
  - `https://workbench.underground-ops.me`  
  - `http(s)://10.20.0.1:1000` (gateway)  
  - `http(s)://localhost:1000` and `http(s)://127.0.0.1:1000` (inside Workbench and from host)
- GitLab: `https://gitlab.underground-ops.me`
- MinIO Console: `https://minio.underground-ops.me`
- OpenVSCode: `https://code.underground-ops.me`
- Vault (dev): `https://vault.underground-ops.me`
- BookStack (Knowledge): `https://knowledge.underground-ops.me` (tracks LinuxServer **latest**; v25.07+)
- Nextcloud (Cloud): `https://cloud.underground-ops.me`
- Grafana: `https://grafana.underground-ops.me`
- Prometheus: `https://prometheus.underground-ops.me`
- Alertmanager: `https://alertmanager.underground-ops.me`
- Wazuh: `https://wazuh.underground-ops.me`
- **NEW** SOC (Security Operation Center):  
  - `https://security-operation-center.underground-ops.me`
  - `http(s)://10.20.0.1:2000`
  - `http(s)://localhost:2000` and `http(s)://127.0.0.1:2000` (inside SOC and from host)

**Pi-hole CNAMEs** are created idempotently for all above subdomains; apex `underground-ops.me` resolves to gateway `10.20.0.1`.

---

## BookStack 25.07+

The Full deploy uses your repo stack (`knowledge-base-proxy-deploy.yml`) routed at `knowledge.underground-ops.me`.  
Because the stack follows LinuxServer’s BookStack image (`linuxserver/bookstack:latest`), updates (incl. v25.07) are pulled automatically:
- Data & uploads persist via your compose volumes.
- No breaking env changes required compared to prior LSIO releases.

If you pin a version, set `image: linuxserver/bookstack:version-25.07` in your stack.

---

## SOC Companion

`natoascode/workbench0:ubuntu` is started as **security-operation-center** on port **2000:3000** with its own persistent volume `underground-soc`.  
30s after it starts, the deploy script runs:

```bash
docker exec security-operation-center bash /workbench.sh || true
```

This is best-effort and will not stop the overall deploy if the script is missing.

---

## Observability & Wazuh

The Observability stack is deployed from your repo. It preserves the Nexus wiring:
- Grafana with Loki, Prometheus, Alertmanager
- **Wazuh** single-node via compose v2
- Grafana datasource for **Wazuh Elastic** remains as configured in your repo (Grafana bootstraps it via provisioning files if present).

If you move provisioning paths, keep the same directory layout under your `Observability Stack/` so the deploy picks them up.

---

## Why this design is the Golden Host

- **Resilient script creation** using `printf` per line (passes brittle CI & Windows shells)
- **Idempotent** deploys (safe re-runs)
- **No entrypoint override** (dockerd starts as upstream intended)
- Optional **auto-deploy** with HEALTHCHECK (no PID1 shims)
- **Loopback proxy** inside Workbench & SOC, satisfying localhost UX for Selkies/web UIs
- Clean separation: singletons vs. swarm stacks

> **Note:** Keep this image as the canonical base for future Underground Nexus work.  
> All future Dockerfiles should **reference this file & rationale**.

---

## Troubleshooting

- `deploy-*.sh` empty? → Use `nexus-contents` to confirm; scripts are written via `printf` and should never be zero-length.
- Pi-hole DNS didn’t pick up records? → `docker exec -it underground-nexus sh -lc "nexus-pihole"` to re-seed and restart FTL.
- Auto-deploy didn’t trigger? → Ensure `-e AUTO_DEPLOY=light|full` and check `docker inspect --format '{{json .State.Health}}' underground-nexus` for health logs.
