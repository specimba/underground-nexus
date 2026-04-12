# Sovereign Container Engine

**Cloud Underground · Underground Nexus · Cerberus C2 Bootstrap**

> Turn any machine into a sovereign container node in a single command. No Docker Desktop. No corporate licensing. No inbound ports.

<img src="https://github.com/Underground-Ops/underground-nexus/blob/main/Graphics/SVG/The-BLG-Triad-The-Output.svg" alt="BLG Triad and the Exoskeleton">

---

## What Is the Sovereign Container Engine

The Sovereign Container Engine is a self-contained infrastructure bootstrapper that provisions any machine — laptop, bare-metal server, or cloud instance — into a fully operational container node running Cerberus Manager, MinIO object storage, and a Docker Swarm cluster. It works completely offline after the initial image pull and is designed to be air-gappable for secure and disconnected environments.

The engine ships as a single compiled binary for each platform. No dependencies. No package manager. Double-click or run one command and the entire stack stands up automatically, including handling reboots on Windows.

---

## What Gets Deployed

Every platform installs the same core stack:

| Component | Role | Ports |
|---|---|---|
| Docker Engine | Raw container runtime (no Docker Desktop) | — |
| Docker Swarm | Single-node overlay orchestrator | — |
| `sovereign-net` | Attachable overlay network (shared by all apps) | — |
| **MinIO** | S3-compatible local object storage | 9000 (API), 9001 (Console) |
| **Cerberus Manager** | C2 node manager · s6-overlay PID 1 · DEV/SEC/OPS commands | 80, 443 |

Once the base engine is running, Jelly Apps (BookStack, Vaultwarden, Planka, n8n, Home Assistant, and others) deploy on top via individual install scripts.

---

## Platform Installers

```
Sovereign-Container-Engine/
└── Installers/
    ├── Linux/
    │   └── sovereign-installer          # ELF amd64 — Ubuntu, Debian, Fedora, Arch
    ├── Mac-OS/
    │   ├── sovereign-installer-mac-arm64   # Apple Silicon (M1/M2/M3/M4)
    │   └── sovereign-installer-mac-intel   # Intel Mac (x86_64)
    └── Windows/
        └── sovereign-installer.exe      # Windows 10/11 amd64
```

---

## Windows Installation

### Requirements

- Windows 10 version 2004 or later / Windows 11
- 64-bit Intel or AMD processor with virtualization enabled in BIOS
- 8 GB RAM minimum (16 GB recommended)
- 20 GB free disk space

### Install

1. Download `sovereign-installer.exe`
2. Double-click the file
3. Click **Yes** when Windows asks for Administrator permission
4. The installer will run, configure WSL2, and **reboot your machine automatically**
5. After reboot, log back in — the installer **resumes automatically** via a registry RunOnce key
6. Wait for the terminal window to complete (5–15 minutes total depending on internet speed)

### What Happens Automatically

| Phase | Action |
|---|---|
| 1 | Self-elevates to Administrator |
| 2 | Writes `.wslconfig` — caps WSL2 RAM at 50% of system RAM, disables swap |
| 3 | Enables WSL2 + VirtualMachinePlatform Windows features |
| 4 | Registers RunOnce key → initiates graceful reboot |
| 5 | Installs Ubuntu 22.04 inside WSL2 |
| 6 | Injects `systemd=true` into WSL2 (required for Docker daemon) |
| 7 | Installs Docker Engine (no Docker Desktop) |
| 8 | Enables and starts Docker daemon via systemd |
| 9 | Initializes Docker Swarm + creates `sovereign-net` overlay |
| 10 | Deploys MinIO + Cerberus Manager |

### Check Status

```powershell
# Confirm WSL2 and Ubuntu are running
wsl -l -v

# Confirm Docker is working
wsl docker --version

# Confirm containers are running
wsl docker ps

# Confirm Swarm is active
wsl docker info | grep Swarm
```

### Uninstall

```powershell
sovereign-installer.exe --uninstall
```

Type `uninstall` when prompted. Removes all containers, volumes, Ubuntu WSL distribution, `.wslconfig`, and registry entries. WSL2 Windows feature remains enabled (disable manually if needed).

---

## Linux Installation

### Requirements

- Ubuntu 22.04 LTS / 24.04 LTS (primary targets)
- Also supported: Debian, Fedora, RHEL, CentOS, Rocky, AlmaLinux, Arch Linux
- 64-bit x86_64 (amd64) processor
- 4 GB RAM minimum (8 GB recommended)
- 15 GB free disk space
- Root / sudo access

### Install

```bash
# Make executable
chmod +x sovereign-installer

# Run as root
sudo ./sovereign-installer
```

The installer auto-detects your Linux distribution and package manager. No configuration required.

### What Happens Automatically

| Phase | Action |
|---|---|
| 1 | Root check · KVM/virtualization check · distro detection |
| 2 | Installs Linux kernel headers (eBPF prerequisite) + Docker Engine |
| 3 | Initializes Docker Swarm with auto-detected primary IP |
| 4 | Creates `sovereign-net` overlay network (`--attachable`) |
| 5 | Deploys MinIO (ports 9000, 9001) |
| 6 | Deploys Cerberus Manager (ports 80, 443) |

### Supported Distributions

| Distribution | Package Manager |
|---|---|
| Ubuntu 22.04 / 24.04 | apt |
| Debian 11 / 12 | apt |
| Fedora 38 / 39+ | dnf |
| RHEL / CentOS Stream | dnf |
| Rocky Linux / AlmaLinux | dnf |
| Arch Linux | pacman |

### Check Status

```bash
# All containers
docker ps

# Swarm health
docker info | grep -i swarm

# Network
docker network ls | grep sovereign

# Status report
sudo ./sovereign-installer --status
```

### Uninstall

```bash
sudo ./sovereign-installer --uninstall
```

Type `uninstall` when prompted. Removes all containers, volumes, Docker Engine, and apt/dnf repository entries.

---

## macOS Installation

### Requirements

- macOS 12 Monterey or later
- Apple Silicon (M1/M2/M3/M4) **or** Intel processor
- 8 GB RAM minimum
- 20 GB free disk space
- Xcode Command Line Tools
- Homebrew

> **Important:** Do NOT run with `sudo`. The macOS installer operates as your standard user account.

### Prerequisites (one-time setup)

**Step 1 — Xcode Command Line Tools:**

```bash
xcode-select --install
```

**Step 2 — Homebrew:**

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**Step 3 — Add Homebrew to your PATH:**

```bash
# Apple Silicon (M-chip):
eval "$(/opt/homebrew/bin/brew shellenv)"

# Intel Mac:
eval "$(/usr/local/bin/brew shellenv)"
```

### Install

**Apple Silicon (M1/M2/M3/M4):**

```bash
chmod +x sovereign-installer-mac-arm64
./sovereign-installer-mac-arm64
```

**Intel Mac:**

```bash
chmod +x sovereign-installer-mac-intel
./sovereign-installer-mac-intel
```

### What Happens Automatically

| Phase | Action |
|---|---|
| 1 | Validates environment: Xcode CLT, Homebrew, user context |
| 2 | Installs Lima (Linux VM hypervisor) + Docker CLI via Homebrew |
| 3 | Generates Lima VM config — 50% RAM cap, VZ backend on Apple Silicon |
| 4 | Starts headless Ubuntu 22.04 VM inside Lima |
| 5 | Installs Docker Engine inside the Lima VM |
| 6 | Creates `sovereign` Docker context routing to Lima VM socket |
| 7 | Writes `DOCKER_HOST` to shell profile (`.zshrc`, `.bashrc`) |
| 8 | Initializes Docker Swarm + creates `sovereign-net` |
| 9 | Deploys MinIO + Cerberus Manager |

### Architecture Note: Why Lima?

Apple's Darwin kernel cannot run Linux containers natively. The installer uses **Lima** (Linux Machines) instead of Docker Desktop:

| Feature | Apple Silicon | Intel Mac |
|---|---|---|
| VM Backend | Apple VZ (native framework) | QEMU |
| File Sharing | VirtioFS (near bare-metal speed) | 9p |
| First-run time | 5–10 min (image download) | 10–15 min |

From your terminal, `docker` commands route transparently through the Lima VM socket. The VM is invisible to the user.

### After Install — Important

Open a **new terminal tab** before running any `docker` commands. The `DOCKER_HOST` environment variable needs to load from your shell profile.

```bash
# Confirm routing is active
docker context show
# Should output: sovereign

# Confirm containers are running
docker ps
```

### Check Status

```bash
./sovereign-installer-mac-arm64 --status
# or
./sovereign-installer-mac-intel --status
```

### Uninstall

```bash
./sovereign-installer-mac-arm64 --uninstall
# or
./sovereign-installer-mac-intel --uninstall
```

Type `uninstall` when prompted. Removes containers, volumes, Lima VM, and Docker context. Lima, Docker CLI, and Homebrew are kept installed.

---

## Endpoints After Install

| Service | URL | Notes |
|---|---|---|
| Cerberus Web UI | `http://localhost` | Primary C2 interface |
| Cerberus HTTPS | `https://localhost` | |
| MinIO API | `http://localhost:9000` | S3-compatible storage |
| MinIO Console | `http://localhost:9001` | Web management UI |

**Default MinIO credentials:** `sovereign` / `sovereign2024`
Change these immediately at `http://localhost:9001` after install.

---

## Verifying the C2 Socket

The ultimate validation that Cerberus Manager has full command and control over the container engine:

**Linux / macOS:**
```bash
docker exec -it cerberus-manager docker ps
```

**Windows:**
```powershell
wsl docker exec -it cerberus-manager docker ps
```

If this returns the host container list, the Docker socket mount succeeded and Cerberus has C2 over the hardware. This is the correct expected result.

---

## DEV / SEC / OPS Commands

Once Cerberus Manager is running, the following commands are available from inside the Cerberus shell or via `docker exec`:

```bash
# Enter the Cerberus shell
docker exec -it cerberus-manager bash

# Deploy development workspace
DEV

# Deploy Underground Nexus (chaos test → golden host validation)
SEC

# Deploy Underground Ops node
OPS

# Rebuild variants (tear down and redeploy with fresh volumes)
DEV-rebuild
SEC-rebuild
OPS-rebuild
```

---

## Installing Jelly Apps

After the base engine is running, sovereign applications (Jelly Apps) deploy via individual install scripts. Place the scripts inside the running Cerberus Manager and execute them:

```bash
# From inside the Cerberus shell:
bash /nexus-bucket/underground-nexus/Jelly-Apps/Bookstack/bookstack.jelly.bash
bash /nexus-bucket/underground-nexus/Jelly-Apps/Vaultwarden/vaultwarden.jelly.bash
bash /nexus-bucket/underground-nexus/Jelly-Apps/Planka/planka.jelly.bash
bash /nexus-bucket/underground-nexus/Jelly-Apps/n8n/n8n.jelly.bash
bash /nexus-bucket/underground-nexus/Jelly-Apps/Home-Assistant/home-assistant.jelly.bash

# Or install all foundation apps at once:
bash /nexus-bucket/underground-nexus/install-all.jelly.bash
```

### Available Jelly Apps

| App | Port | Role |
|---|---|---|
| BookStack | 4050 | Sovereign knowledge base and wiki |
| Vaultwarden | 8080 | Self-hosted Bitwarden password vault |
| Planka | 3000 | Stigmergic kanban board |
| n8n | 5678 | Automation and webhook engine |
| Portainer | 9443 | Container management UI |
| Uptime Kuma | 3001 | Service health monitoring |
| Home Assistant | 8123 | Smart home and IoT automation |

---

## Keeping Everything Updated

The sovereign update pipeline performs backup-before-swap on every app before pulling new images. Data loss during updates is not possible with this system — volumes are snapshotted before any container is replaced.

```bash
# From inside the Cerberus shell:
bash /nexus-bucket/underground-nexus/sovereign-update.sh

# Or if symlinked:
UPDATE
```

Selective updates:
```bash
UPDATE_ALL=false UPDATE_BOOKSTACK=true bash sovereign-update.sh
UPDATE_ALL=false UPDATE_VAULTWARDEN=true bash sovereign-update.sh
```

---

## Port Reference

| Port | Service | Binding | Notes |
|---|---|---|---|
| 80 | Cerberus Web UI | 0.0.0.0 | HTTP |
| 443 | Cerberus HTTPS | 0.0.0.0 | HTTPS |
| 9000 | MinIO API | 0.0.0.0 | S3-compatible |
| 9001 | MinIO Console | 0.0.0.0 | Web management |
| 4050 | BookStack | 127.0.0.1 | WARP/Tunnel only |
| 8080 | Vaultwarden | 127.0.0.1 | WARP/Tunnel only |
| 3000 | Planka | 127.0.0.1 | WARP/Tunnel only |
| 5678 | n8n | 127.0.0.1 | WARP/Tunnel only |
| 9005 | Portainer HTTP | 127.0.0.1 | Redirects to 9443 |
| 9443 | Portainer HTTPS | 127.0.0.1 | Primary UI |
| 3001 | Uptime Kuma | 127.0.0.1 | WARP/Tunnel only |
| 8123 | Home Assistant | host network | LAN device discovery |

Jelly Apps bind to `127.0.0.1` — they are not accessible from the public internet. Use Cloudflare WARP or a Cloudflare Tunnel for remote access without opening firewall ports.

---

## Troubleshooting

### Cerberus Manager exits immediately after starting

The container must be started with `-itd` (interactive + TTY + detached). Without `-t`, s6-overlay exits immediately. The installer handles this correctly — if you are starting manually, always use `-itd`.

```bash
docker logs cerberus-manager
```

### Windows: installer hangs after reboot

The RunOnce registry key may not have fired. Run the installer again — it detects the phase state file and resumes automatically:

```powershell
sovereign-installer.exe
```

### Windows: Docker commands not found after install

```powershell
wsl -l -v              # confirm Ubuntu-22.04 is running
wsl docker --version   # confirm Docker is in WSL
```

### macOS: docker command not working after install

```bash
# Load shell profile in current session
eval "$(/opt/homebrew/bin/brew shellenv)"
docker context use sovereign

# Confirm Lima VM is running
limactl list
```

### Linux: Swarm init fails (multiple network interfaces)

The installer auto-detects the primary IP. If it picks the wrong interface:

```bash
# Find your primary IP
ip route get 1.1.1.1

# Re-run swarm init manually
docker swarm leave --force
docker swarm init --advertise-addr <your-ip>
```

### BookStack shows 500 error after install

BookStack's first-run database migration takes 2–4 minutes. Wait, then reload. Check:

```bash
docker logs bookstack --tail 20
docker logs bookstack-db --tail 10
```

---

## State Files

Each installer tracks progress in a state file. If the installer is interrupted, re-running it resumes from the last completed phase automatically.

| Platform | State File |
|---|---|
| Windows | `%TEMP%\sovereign-installer-phase.txt` |
| Linux | `/tmp/sovereign-installer-phase.txt` |
| macOS | `/tmp/sovereign-installer-mac-phase.txt` |

---

## Security Notes

- Jelly App ports are bound to `127.0.0.1` only — safe on public Wi-Fi
- MinIO default credentials must be changed immediately after install
- Cerberus Manager mounts `/var/run/docker.sock` — treat access to this container as root access to the host
- Port 80 and 443 are public — these are the Cerberus Web UI entry points intended for Cloudflare Tunnel or WARP routing
- For enterprise Zero Trust access (SSO, custom domains, team access), see the Enterprise upgrade documentation

---

## Building the Installers from Source

All installers are written in Go. Build them from the source repository:

```bash
# Linux (amd64)
GOOS=linux GOARCH=amd64 go build -o sovereign-installer main.go

# Linux (arm64 — Raspberry Pi, AWS Graviton)
GOOS=linux GOARCH=arm64 go build -o sovereign-installer-arm64 main.go

# macOS Apple Silicon
GOOS=darwin GOARCH=arm64 go build -o sovereign-installer-mac-arm64 main.go

# macOS Intel
GOOS=darwin GOARCH=amd64 go build -o sovereign-installer-mac-intel main.go

# Windows
GOOS=windows GOARCH=amd64 go build -o sovereign-installer.exe main.go
```

No `go mod tidy` required for Linux and macOS (zero external dependencies). Windows requires `golang.org/x/sys/windows/registry`.

---

## Learn More

- **Cloud Underground:** [cloudunderground.dev](https://cloudunderground.dev)
- **Cloud Jam Gauntlet** (structured learning path): [cloudunderground.dev/products/cloud-jam](https://cloudunderground.dev/products/cloud-jam)
- **Underground Nexus repository:** [github.com/Underground-Ops/underground-nexus](https://github.com/Underground-Ops/underground-nexus)
- **Cerberus Manager:** [github.com/Underground-Ops/underground-nexus/tree/cerberus0](https://github.com/Underground-Ops/underground-nexus/tree/cerberus0)

---

*Cloud Underground · Sovereign Container Engine · Built with the Civilization Architect Pro dRAG stack*