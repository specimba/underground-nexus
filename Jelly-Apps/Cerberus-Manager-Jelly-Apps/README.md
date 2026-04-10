# Sovereign Node — Complete Operations Guide

**Cloud Underground · Underground Nexus · Cerberus C2 Bootstrap**

This document covers the complete Sovereign Node stack built across the Cerberus installer trilogy (Windows, Linux, macOS), the Cerberus Manager containers (open-source and enterprise), the Jelly App deployment system, and the update pipeline. It is written to be self-contained — readable offline, air-gappable, and usable as the single source of truth for any operator on any platform.

---

## Table of Contents

1. [What Is a Sovereign Node](#1-what-is-a-sovereign-node)
2. [Repository Structure](#2-repository-structure)
3. [Platform Installers](#3-platform-installers)
4. [Core Architecture](#4-core-architecture)
5. [Cerberus Manager (Open Source)](#5-cerberus-manager-open-source)
6. [Cerberus Manager Ultra (Enterprise)](#6-cerberus-manager-ultra-enterprise)
7. [Jelly Apps](#7-jelly-apps)
8. [The Update Pipeline](#8-the-update-pipeline)
9. [Networking: WARP vs Tunnel](#9-networking-warp-vs-tunnel)
10. [Backup and Recovery](#10-backup-and-recovery)
11. [Port Reference](#11-port-reference)
12. [Troubleshooting](#12-troubleshooting)
13. [Upgrade Paths](#13-upgrade-paths)

---

## 1. What Is a Sovereign Node

A Sovereign Node is any machine — laptop, server, cloud instance, or Raspberry Pi — running the Cerberus C2 bootstrap stack. It operates without Docker Desktop, without corporate licensing, and without vendor lock-in. One double-click (Windows) or one command (Linux/macOS) provisions the full stack from scratch.

The node is built from three layers:

```
┌─────────────────────────────────────────────────────┐
│  JELLY APPS                                         │
│  BookStack · Vaultwarden · (custom apps)            │
│  Deployed and managed from the Cerberus shell       │
├─────────────────────────────────────────────────────┤
│  CERBERUS MANAGER                                   │
│  C2 node · Docker socket · DEV/SEC/OPS commands     │
│  MinIO object storage · sovereign-net overlay       │
├─────────────────────────────────────────────────────┤
│  PLATFORM EXOSKELETON                               │
│  Windows (WSL2) · Linux (native) · macOS (Lima VZ)  │
│  Docker Engine · Docker Swarm · sovereign-net       │
└─────────────────────────────────────────────────────┘
```

---

## 2. Repository Structure

```
underground-nexus/
├── Jelly-Apps/
│   ├── Bookstack/
│   │   └── bookstack.jelly.bash        ← Deploy BookStack + MariaDB
│   ├── Vaultwarden/
│   │   └── vaultwarden.jelly.bash      ← Deploy Vaultwarden
│   ├── Nexus-Creator-Vault/
│   │   └── nexus-creator-vault.jelly.bash
│   └── Zero-Trust-Cockpit/
│       └── zero-trust-cockpit.jelly.bash
├── Dagger CI/Scripts/
│   └── nexus-devsecops-appinator.sh    ← Installs DEV/SEC/OPS commands
├── Cloud Knowledge Base Stack/
│   └── knowledge-base-proxy-deploy.yml ← Legacy Swarm compose for BookStack
├── Production Artifacts/
│   └── deploy-olympiad.sh              ← Full Underground Nexus activation
├── sovereign-update.sh                 ← UPDATE command / immutable patching
├── update-git-packages.sh              ← Git pull + ownership fix
├── underground-nexus-update.sh         ← Full stack update (legacy)
└── README.md                           ← This file
```

**Cerberus Manager repos (separate branches):**

```
cerberus0/          ← Open-source Cerberus (Ubuntu base, s6-overlay)
  └── Dockerfile

cerberus-manager-ultra/   ← Enterprise Cerberus (Python/FastAPI base, tini)
  ├── manager/
  │   ├── Dockerfile
  │   ├── command_api.py
  │   └── shell-tools/    ← DEV, SEC, OPS, cerbpkg, terminator
  ├── cloudflare/
  │   ├── Dockerfile
  │   └── start.sh
  └── docker-compose.yml  ← Traefik + Cloudflare + MinIO + Manager
```

---

## 3. Platform Installers

Three Go binaries, one per OS. Each is a self-contained state machine — if interrupted, re-run and it resumes from where it stopped.

### 3.1 Windows

```
sovereign-installer.exe
```

**Build:**
```powershell
GOOS=windows GOARCH=amd64 go build -o sovereign-installer.exe main.go
```

**Run:** Double-click. Auto-elevates to Administrator. Handles reboot automatically via RunOnce registry key.

**What it does (10 phases):**

| Phase | Action |
|---|---|
| 1 | Self-elevate to Administrator |
| 2 | Write `.wslconfig` (50% RAM cap, swap=0, CPU/2) |
| 3 | Enable WSL2 + VirtualMachinePlatform features |
| 4 | Write RunOnce registry key → reboot → auto-resume |
| 5 | Install Ubuntu-22.04 via `wsl --install` |
| 6 | Inject `systemd=true` into `/etc/wsl.conf` → `wsl --shutdown` |
| 7 | Install Docker Engine inside WSL2 (no Docker Desktop) |
| 8 | `systemctl enable docker` + `systemctl start docker` |
| 9 | `docker swarm init` + `docker network create sovereign-net --attachable` |
| 10 | Deploy MinIO + Cerberus Manager |

**Uninstall:**
```
sovereign-installer.exe --uninstall
```
Type `uninstall` to confirm. Removes Cerberus, MinIO, Swarm, Docker, WSL Ubuntu VHDX, .wslconfig, and registry entries.

**State file:** `%TEMP%\sovereign-installer-phase.txt`

---

### 3.2 Linux

```
sovereign-installer
```

**Build:**
```bash
GOOS=linux GOARCH=amd64 go build -o sovereign-installer main.go
# ARM64:
GOOS=linux GOARCH=arm64 go build -o sovereign-installer-arm64 main.go
```

**Run:**
```bash
sudo ./sovereign-installer
```

Do NOT run without sudo — Docker installation requires root.

**What it does (5 phases):**

| Phase | Action |
|---|---|
| 1 | Root check, KVM check, kernel version detection, distro detection |
| 2 | Install kernel headers + Docker Engine (apt/dnf/pacman, auto-detected) |
| 3 | `docker swarm init` (eth0 → routing table → fallback IP detection) + `sovereign-net` |
| 4 | Deploy MinIO |
| 5 | Deploy Cerberus Manager |

**Supported distros:** Ubuntu, Debian, Fedora, RHEL, CentOS, Rocky, AlmaLinux, Arch

**Check status:**
```bash
sudo ./sovereign-installer --status
```

**Uninstall:**
```bash
sudo ./sovereign-installer --uninstall
```

**State file:** `/tmp/sovereign-installer-phase.txt`

---

### 3.3 macOS

```
sovereign-installer-mac        # Apple Silicon (M1/M2/M3/M4)
sovereign-installer-mac-intel  # Intel
```

**Build:**
```bash
GOOS=darwin GOARCH=arm64 go build -o sovereign-installer-mac main.go
GOOS=darwin GOARCH=amd64 go build -o sovereign-installer-mac-intel main.go
```

**Prerequisites (must be done manually once):**
```bash
# 1. Xcode Command Line Tools
xcode-select --install

# 2. Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 3. Add brew to PATH (Apple Silicon)
eval "$(/opt/homebrew/bin/brew shellenv)"
```

**Run:**
```bash
./sovereign-installer-mac
```

Do NOT use sudo — Lima and Homebrew operate as the current user.

**What it does (4 phases):**

| Phase | Action |
|---|---|
| 1 | Validate user, Xcode CLT, Homebrew |
| 2 | Install Lima + Docker CLI via Homebrew, generate Lima YAML (50% RAM, VZ on arm64) |
| 3 | Start Lima VM, wait for Docker socket, create `sovereign` Docker context, update shell profiles |
| 4 | Swarm init + sovereign-net + MinIO + Cerberus Manager |

**Architecture differences:**

| Feature | Apple Silicon | Intel |
|---|---|---|
| VM backend | Apple VZ (native) | QEMU |
| File sharing | VirtioFS | 9p |
| First-run time | 5-10 min (image download) | 10-15 min |

**Check status:**
```bash
./sovereign-installer-mac --status
```

**Note:** After install, open a new terminal tab before running docker commands — `DOCKER_HOST` needs to load from your shell profile.

**State file:** `/tmp/sovereign-installer-mac-phase.txt`

---

## 4. Core Architecture

### 4.1 Sovereign Network

All sovereign containers share a single Docker overlay network:

```
sovereign-net  (overlay, --attachable, Docker Swarm)
```

This network is created by the installer on every platform. Containers on this network communicate by name (`http://minio:9000`, `http://cerberus-manager`, etc.) without host port exposure.

### 4.2 Container Map

```
sovereign-net
├── cerberus-manager    ports: 80, 443 (host)
├── minio               ports: 9000, 9001 (host)
├── bookstack-db        (internal only — no host port)
├── bookstack           port: 127.0.0.1:4050 (host, localhost only)
└── vaultwarden         port: 127.0.0.1:8080 (host, localhost only)
```

### 4.3 Port Security Model

**Open ports (all platforms):**

| Port | Service | Accessible from |
|---|---|---|
| 80 | Cerberus Web UI | Network (via Traefik/Tunnel) |
| 443 | Cerberus HTTPS | Network (via Traefik/Tunnel) |
| 9000 | MinIO API | Network |
| 9001 | MinIO Console | Network |

**Localhost-only ports (Jelly Apps):**

| Port | Service | Accessible from |
|---|---|---|
| 127.0.0.1:4050 | BookStack | Localhost / WARP tunnel only |
| 127.0.0.1:8080 | Vaultwarden | Localhost / WARP tunnel only |

Jelly Apps bind to `127.0.0.1` explicitly — they are never exposed to `0.0.0.0`. A Surface Pro on public Wi-Fi cannot be accessed by external parties on these ports.

### 4.4 Volume Architecture

All persistent data lives in named Docker volumes on native ext4 (inside WSL2 VHDX on Windows, native on Linux, inside Lima VHDX on macOS). This prevents NTFS-crossing I/O degradation.

```
cerberus-state      Cerberus Manager persistent state
minio-data          MinIO object storage (buckets, data)
bookstack-db-data   BookStack MariaDB database files
bookstack-app-data  BookStack config and cache
vaultwarden-data    Vaultwarden SQLite database
```

---

## 5. Cerberus Manager (Open Source)

**Image:** `natoascode/cerberus0:latest`
**Base:** Ubuntu 20.04
**PID 1:** s6-overlay v3.1.6.2

### 5.1 What s6-overlay Provides

s6-overlay replaces bash as PID 1. Without it, bash as PID 1 cannot reap zombie processes. When DEV/SEC/OPS commands spawn child processes that crash or finish, those zombies accumulate RAM until the host crashes. s6 acts as the grim reaper — automatically cleaning any orphan process the moment it exits.

s6 is completely invisible to DEV/SEC/OPS. Those commands run via `docker exec` exactly as before. s6 manages three supervised services:

| Service | Type | Purpose |
|---|---|---|
| sshd | longrun | SSH daemon (respawns if it exits) |
| crond | longrun | Cron daemon |
| cerberus-init | oneshot | Git sync + appinator + update-git-packages at start |

### 5.2 Deploy Command (from installer)

```bash
docker run -itd \
  --restart unless-stopped \
  --name cerberus-manager \
  --network sovereign-net \
  -p 80:80 -p 443:443 \
  -e SOVEREIGN_TIER=open-source \
  -e MINIO_ENDPOINT=http://minio:9000 \
  -e MINIO_ROOT_USER=sovereign \
  -e MINIO_ROOT_PASSWORD=sovereign2024 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v cerberus-state:/cerberus/state \
  natoascode/cerberus0:latest
```

**Why `-itd` and not `-d`:** s6-overlay needs a TTY (`-t`) to initialize its supervision tree. Without `-t`, s6 exits immediately and the container appears to start but dies within seconds. `-i` keeps stdin open. `-d` detaches after start. All three flags are required.

### 5.3 C2 Commands

From inside the Cerberus shell or via `docker exec`:

```bash
DEV          # Deploy nexus-creator-vault workbench
SEC          # Deploy Underground-Nexus (chaos test → golden host)
OPS          # Deploy Underground-Ops node
DEV-rebuild  # Tear down and redeploy DEV
SEC-rebuild  # Tear down and redeploy SEC
OPS-rebuild  # Tear down and redeploy OPS
```

### 5.4 Build (Multi-Arch)

```bash
docker buildx create --use --name sovereign-builder
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t natoascode/cerberus0:latest \
  --push .
```

---

## 6. Cerberus Manager Ultra (Enterprise)

**Base:** `python:3.11-slim`
**PID 1:** tini
**API:** FastAPI on port 8001

### 6.1 Why tini Instead of s6-overlay

The enterprise manager runs one primary process: `uvicorn` (FastAPI). tini is the correct init for a single-process container. It reaps zombies from subprocess calls in `command_api.py` (every DEV/SEC/OPS invocation via the API spawns child processes) and forwards SIGTERM to uvicorn cleanly. s6-overlay would add unused multi-service supervision machinery.

### 6.2 Stack (docker-compose.yml)

```
edge-router         Traefik v3.1 (HTTP routing, Docker provider)
zero-trust-tunnel   Cloudflare Tunnel sidecar (named or quick tunnel)
nexus-bucket        MinIO (ports 9000/9001)
cerberus-manager    FastAPI command API (port 8001, routed via /cm)
```

### 6.3 Start the Stack

```bash
cp .env.example .env
# Edit .env — set CLOUDFLARE_TUNNEL_TOKEN if using named tunnel
docker compose up -d
```

### 6.4 API Endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/api/healthz` | Liveness check |
| GET | `/api/docker/ps` | List running containers |
| POST | `/api/appination/DEV` | Trigger DEV command |
| POST | `/api/appination/SEC` | Trigger SEC command |
| POST | `/api/appination/OPS` | Trigger OPS command |

Via Traefik: `http://localhost:8088/cm/api/healthz`

### 6.5 Shell Tools

Available inside the container and from `docker exec`:

```
DEV          Deploy nexus-creator-vault (with Traefik labels)
SEC          Deploy Underground-Nexus (with Traefik labels)
OPS          Deploy Underground-Ops (with Traefik labels)
terminator   Launch 2x2 tmux grid
cerbpkg      Package inspector (list, install zarf/dagger)
```

### 6.6 Cloudflare Tunnel

**Quick tunnel (no token needed — temporary URL):**
Leave `CLOUDFLARE_TUNNEL_TOKEN` empty in `.env`. Cloudflared prints a public URL on startup.

**Named tunnel (permanent URL):**
Set `CLOUDFLARE_TUNNEL_TOKEN=<your-token>` in `.env`. The tunnel connects to your Cloudflare Zero Trust dashboard and uses your configured hostname.

---

## 7. Jelly Apps

Jelly Apps are sovereign applications deployed from the Cerberus shell. They are bash scripts that deploy Docker containers onto `sovereign-net`, bind localhost-only ports for security, and integrate with MinIO for file storage where applicable.

**Convention:**
- Live in `Jelly-Apps/<AppName>/<appname>.jelly.bash`
- Idempotent: re-running detects existing containers and skips or starts them
- Environment-variable configurable: all defaults work out of the box
- Self-documenting: run without arguments for usage

### 7.1 Running Jelly Apps

**From the Cerberus Manager shell:**
```bash
bash /nexus-bucket/underground-nexus/Jelly-Apps/Bookstack/bookstack.jelly.bash
bash /nexus-bucket/underground-nexus/Jelly-Apps/Vaultwarden/vaultwarden.jelly.bash
```

**Via docker exec from the host:**
```bash
docker exec cerberus-manager \
  bash /nexus-bucket/underground-nexus/Jelly-Apps/Bookstack/bookstack.jelly.bash
```

**Windows (WSL):**
```powershell
wsl docker exec cerberus-manager \
  bash /nexus-bucket/underground-nexus/Jelly-Apps/Bookstack/bookstack.jelly.bash
```

---

### 7.2 BookStack — Sovereign Knowledge Base

**Script:** `Jelly-Apps/Bookstack/bookstack.jelly.bash`

**Deploys:**
- `bookstack-db` — MariaDB 10.11 sidecar (internal, no host port)
- `bookstack` — linuxserver/bookstack (port `127.0.0.1:4050`)

**MinIO integration:**
All file and image uploads go directly to MinIO at `http://minio:9000`. BookStack itself is stateless — destroying and redeploying the container loses nothing because files are in MinIO and the database is in `bookstack-db-data`.

**First login:**
```
URL:      http://127.0.0.1:4050
Email:    admin@admin.com
Password: password
```
Change the password immediately.

**Default volumes:**
```
bookstack-db-data   MariaDB data
bookstack-app-data  BookStack config, cache, logs
MinIO bucket:       bookstack (file uploads)
```

**Custom configuration:**
```bash
# Change host port
BOOKSTACK_HOST_PORT=5050 bash bookstack.jelly.bash

# Set APP_URL for Tunnel/WARP access
BOOKSTACK_APP_URL=https://your-tunnel-url.trycloudflare.com \
  bash bookstack.jelly.bash
```

**Stop:**
```bash
docker stop bookstack bookstack-db
```

**Destroy (removes containers, keeps data in volumes):**
```bash
docker stop bookstack bookstack-db
docker rm bookstack bookstack-db
```

**Full wipe (removes containers AND data — use with caution):**
```bash
docker stop bookstack bookstack-db
docker rm bookstack bookstack-db
docker volume rm bookstack-app-data bookstack-db-data
```

---

### 7.3 Vaultwarden — Sovereign Password Vault

**Script:** `Jelly-Apps/Vaultwarden/vaultwarden.jelly.bash`

**Deploys:**
- `vaultwarden` — vaultwarden/server:latest (port `127.0.0.1:8080`, SQLite)

**Why SQLite:** Vaultwarden is designed and optimized for SQLite on single-node deployments. There is no performance benefit to Postgres/MySQL at this scale and a significant complexity cost. SQLite is also trivially backed up as a single file.

**Important — HTTPS requirement:**
Bitwarden clients (browser extension, mobile app, desktop) require HTTPS to connect. Direct HTTP at `localhost:8080` works for the web UI during initial setup only. To use Bitwarden clients, you need either:
- Cloudflare WARP (open-source tier): access via your WARP-connected device
- Cloudflare Tunnel (enterprise tier): access via your tunnel hostname

**First login:**
```
URL: http://127.0.0.1:8080
```
Create your account from the web UI. After creating accounts, disable signups:

```bash
docker stop vaultwarden
docker rm vaultwarden
VW_SIGNUPS_ALLOWED=false bash vaultwarden.jelly.bash
```

**Pointing Bitwarden clients to your server:**
In the Bitwarden app, go to Settings → Server URL → set your Cloudflare Tunnel URL or WARP-accessible address.

**Default volumes:**
```
vaultwarden-data    SQLite database + attachments
```

**Stop:**
```bash
docker stop vaultwarden
```

---

## 8. The Update Pipeline

**Script:** `sovereign-update.sh`

**Install as `UPDATE` command:**
```bash
ln -sf /nexus-bucket/underground-nexus/sovereign-update.sh /usr/local/bin/UPDATE
chmod +x /usr/local/bin/UPDATE
```

Then from anywhere in the Cerberus shell: `UPDATE`

### 8.1 What It Does

```
1. git pull         Update nexus repo (scripts, Jelly Apps, artifacts)
2. For each app:
   a. docker pause                       Freeze writes (consistent snapshot)
   b. tar -czf volume → /backups/        Backup named volume
   c. docker unpause                     Resume writes
   d. mariadb-dump (BookStack only)      SQL-level backup
   e. docker pull                        Fetch new image
   f. docker stop + docker rm            Remove old container
   g. bash <app>.jelly.bash              Redeploy with same volumes
3. Prune old backups (keep 7 per app)
4. docker image prune                   Remove dangling images
5. Summary report
```

### 8.2 Selective Updates

```bash
# Update only BookStack
UPDATE_ALL=false UPDATE_BOOKSTACK=true bash sovereign-update.sh

# Update only Vaultwarden
UPDATE_ALL=false UPDATE_VAULTWARDEN=true bash sovereign-update.sh

# Update only MinIO
UPDATE_ALL=false UPDATE_MINIO=true bash sovereign-update.sh

# Update everything (default)
bash sovereign-update.sh
```

### 8.3 Backup Location

```
/backups/
├── bookstack-bookstack-app-data-20241215_143022.tar.gz
├── bookstack-mysql-20241215_143022.sql.gz
├── bookstack-db-bookstack-db-data-20241215_143022.tar.gz
├── vaultwarden-vaultwarden-data-20241215_143022.tar.gz
└── minio-minio-data-20241215_143022.tar.gz
```

Backups rotate — the 8 oldest are removed automatically, keeping 7 per app.

---

## 9. Networking: WARP vs Tunnel

### Open-Source Tier — Cloudflare WARP

WARP is a Zero-Trust VPN mesh. Install it on every device that needs to access the node. Once connected, `localhost:4050`, `localhost:8080`, etc. route through the WARP mesh to your sovereign node — without opening any inbound router ports.

```
Your laptop (WARP) → Cloudflare mesh → Node (WARP) → localhost:4050 → BookStack
```

No open ports. No DDNS. No port forwarding. The Surface Pro on public Wi-Fi is completely dark to the internet.

**Install WARP:** https://one.one.one.one/

### Enterprise Tier — Cloudflare Tunnel

Traefik acts as the edge router. Cloudflare Tunnel (`cloudflared`) creates an outbound-only encrypted connection from your node to Cloudflare's edge. Your domain (`vault.yourdomain.com`, `knowledge.yourdomain.com`) routes through Cloudflare → tunnel → Traefik → containers. No inbound ports required.

```
Browser → Cloudflare Edge → Named Tunnel → Traefik → /bookstack → BookStack
                                                     → /vault    → Vaultwarden
                                                     → /cm       → Cerberus API
```

Set `CLOUDFLARE_TUNNEL_TOKEN` in `.env` and restart the stack.

---

## 10. Backup and Recovery

### Backing Up a Volume Manually

```bash
docker run --rm \
  -v <volume-name>:/data:ro \
  -v /backups:/backup \
  alpine:latest \
  tar -czf /backup/<label>-$(date +%Y%m%d).tar.gz -C /data .
```

### Restoring a Volume

```bash
# Stop the affected container first
docker stop <container>

# Restore the volume
docker run --rm \
  -v <volume-name>:/data \
  -v /backups:/backup \
  alpine:latest \
  tar -xzf /backup/<backup-file>.tar.gz -C /data

# Redeploy
bash /nexus-bucket/underground-nexus/Jelly-Apps/<App>/<app>.jelly.bash
```

### Restoring BookStack MariaDB from SQL Dump

```bash
docker start bookstack-db
docker exec -i bookstack-db \
  mariadb -u root -p<root_password> < /backups/bookstack-mysql-<timestamp>.sql
```

### Full Node Recovery (60 seconds)

If the entire node is lost and you have volume backups:

1. Run the sovereign installer on a fresh machine
2. Restore each volume from backup (commands above)
3. Re-run each Jelly App script
4. Containers start with full data intact

---

## 11. Port Reference

| Port | Service | Binding | Notes |
|---|---|---|---|
| 80 | Cerberus Web UI | 0.0.0.0 | HTTP |
| 443 | Cerberus HTTPS | 0.0.0.0 | HTTPS |
| 9000 | MinIO API | 0.0.0.0 | S3-compatible |
| 9001 | MinIO Console | 0.0.0.0 | Web UI |
| 4050 | BookStack | 127.0.0.1 | WARP/Tunnel only |
| 8080 | Vaultwarden | 127.0.0.1 | WARP/Tunnel only |
| 8088 | Traefik HTTP | 0.0.0.0 | Enterprise only |
| 8001 | Cerberus API | internal | Via Traefik /cm |
| 22 | SSH (cerberus0) | varies | Open-source only |

---

## 12. Troubleshooting

### Cerberus won't start / exits immediately

```bash
docker logs cerberus-manager
```

Most common cause: the container was run with `-d` instead of `-itd`. s6-overlay requires a TTY. Always use `-itd`.

### Docker socket not accessible

```bash
# Check socket exists
ls -la /var/run/docker.sock

# WSL2 specific
wsl -- ls -la /var/run/docker.sock
```

### BookStack can't connect to MariaDB

```bash
docker logs bookstack
docker logs bookstack-db
```

Wait 30 seconds after deploying bookstack-db before deploying bookstack. The MariaDB init script needs time.

### Vaultwarden clients can't connect

Bitwarden clients require HTTPS. `localhost:8080` only works for the web UI. Use your Cloudflare Tunnel URL or WARP address in Bitwarden client → Settings → Server URL.

### MinIO bucket not found (BookStack uploads fail)

```bash
# Check MinIO is running
docker ps | grep minio

# Check the bucket exists
docker run --rm --network sovereign-net --entrypoint sh minio/mc:latest \
  -c "mc alias set local http://minio:9000 sovereign sovereign2024 && mc ls local"
```

### WSL2 unregister fails during uninstall (Windows)

The installer retries 5 times with 3-second delays. If all fail, run manually:
```powershell
wsl --terminate Ubuntu-22.04
wsl --unregister Ubuntu-22.04
```

### Lima VM not starting (macOS)

```bash
limactl list
limactl start sovereign          # if stopped
limactl delete sovereign         # if broken — re-run installer to recreate
```

### Docker commands fail after macOS install

Open a new terminal tab (DOCKER_HOST needs to load from shell profile), or:
```bash
eval "$(/opt/homebrew/bin/brew shellenv)"
docker context use sovereign
```

---

## 13. Upgrade Paths

### Open-Source → Enterprise

The open-source Cerberus (`cerberus0`) and enterprise Cerberus Ultra use different architectures. To upgrade:

1. Export Jelly App data (volumes are portable — they stay)
2. `docker stop cerberus-manager && docker rm cerberus-manager`
3. Clone the enterprise repo, configure `.env`
4. `docker compose up -d`
5. Re-run Jelly App scripts (volumes intact, containers reconnect)

### Adding New Jelly Apps

Follow the convention:

```
Jelly-Apps/<AppName>/<appname>.jelly.bash
```

Requirements for any Jelly App:

1. `set -euo pipefail` at the top
2. Idempotency check — detect existing container before deploying
3. `--network sovereign-net` on all containers
4. `-p 127.0.0.1:<port>:<internal>` for user-facing ports
5. Named Docker volumes only — no bind mounts
6. `--restart unless-stopped` on all containers
7. Traefik labels for enterprise routing (ignored if Traefik absent)

### Updating a Single Jelly App Without the Full Pipeline

```bash
# Stop and remove
docker stop bookstack && docker rm bookstack

# Pull new image
docker pull lscr.io/linuxserver/bookstack:latest

# Redeploy (volumes are preserved automatically)
bash /nexus-bucket/underground-nexus/Jelly-Apps/Bookstack/bookstack.jelly.bash
```

Data is safe — named volumes survive container removal.

---

*Cloud Underground · Underground Nexus · Sovereign Node Operations Guide*
*Built with the Civilization Architect Pro dRAG stack*
