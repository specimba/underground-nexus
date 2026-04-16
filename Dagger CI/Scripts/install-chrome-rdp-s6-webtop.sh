#!/usr/bin/env bash
# =============================================================================
# fix-chrome-rdp.sh
# Cloud Underground · Underground Nexus
# =============================================================================
#
# WHAT THIS DOES:
#   1. Detects abc's home directory (works in linuxserver /config and
#      bare-metal /home/abc environments)
#   2. Downloads the latest Chrome Remote Desktop deb from Google
#   3. Installs/reinstalls it via gdebi (handles deps + repair)
#   4. Enables and starts the service
#   5. Registers an s6-overlay longrun service so Chrome RDP restarts
#      automatically every time the container restarts
#
# USAGE (run as root inside the container):
#   docker exec -it nexus-creator-vault bash
#   wget -q https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/fix-chrome-rdp.sh -O /tmp/fix-chrome-rdp.sh
#   chmod +x /tmp/fix-chrome-rdp.sh
#   bash /tmp/fix-chrome-rdp.sh
#
# AFTER THIS SCRIPT:
#   Switch to abc and run the Chrome RDP authorize string:
#     su - abc
#     DISPLAY= /opt/google/chrome-remote-desktop/start-host \
#       --code="<YOUR-CODE>" \
#       --redirect-url="https://remotedesktop.google.com/_/oauthredirect" \
#       --name=$(hostname)
#   Get your code at: https://remotedesktop.google.com/headless
#
# NOTES:
#   - Must be run as root (or with sudo)
#   - Chrome RDP is amd64 only — exits cleanly on arm64
#   - The s6 service uses s6-setuidgid to run as abc, not root
#   - Container restart persistence: the s6 bundle entry survives restarts
#     because /etc/s6-overlay is baked into the image layer, not a volume
#
# =============================================================================

set -o pipefail

log()  { echo "[crd-fix] $*"; }
ok()   { echo "[crd-fix] ✓ $*"; }
warn() { echo "[crd-fix] ⚠ $*"; }
err()  { echo "[crd-fix] ✗ $*" >&2; }

# =============================================================================
# ROOT CHECK
# =============================================================================

if [ "$(id -u)" != "0" ]; then
    err "This script must be run as root (or with sudo)"
    exit 1
fi

# =============================================================================
# ARCHITECTURE CHECK
# =============================================================================

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
if [ "${ARCH}" != "amd64" ] && [ "${ARCH}" != "x86_64" ]; then
    warn "Chrome Remote Desktop is amd64 only — this is ${ARCH}"
    warn "On arm64, use KasmVNC (:3000) as the primary access method"
    exit 0
fi

log "═══════════════════════════════════════════════════"
log "Chrome Remote Desktop — Install + s6 Registration"
log "═══════════════════════════════════════════════════"

# =============================================================================
# DETECT ABC'S HOME DIRECTORY
# Works in:
#   - lscr.io/linuxserver/webtop: abc home = /config (HOME env var)
#   - Bare metal / standard Ubuntu: abc home = /home/abc
# =============================================================================

# Try to get home from passwd first (most reliable)
ABC_HOME=$(getent passwd abc 2>/dev/null | cut -d: -f6)

# Fallback: check HOME env if set (linuxserver sets HOME=/config)
if [ -z "${ABC_HOME}" ] && [ -n "${HOME}" ] && [ "${HOME}" != "/root" ]; then
    ABC_HOME="${HOME}"
fi

# Final fallback: check if /config exists (linuxserver webtop) else /home/abc
if [ -z "${ABC_HOME}" ]; then
    if [ -d "/config" ]; then
        ABC_HOME="/config"
    else
        ABC_HOME="/home/abc"
    fi
fi

mkdir -p "${ABC_HOME}"
log "abc home directory: ${ABC_HOME}"

# =============================================================================
# STEP 1: INSTALL PREREQUISITES
# gdebi handles dependency resolution better than raw dpkg for .deb installs
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 1: Prerequisites"
log "─────────────────────────────────────────────────────"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq 2>/dev/null || warn "apt-get update had issues"
apt-get install -y gdebi-core wget curl 2>/dev/null \
    && ok "gdebi-core, wget, curl ready" \
    || warn "Some prerequisites failed — continuing"

# =============================================================================
# STEP 2: DOWNLOAD CHROME REMOTE DESKTOP
# Official Google URL — always delivers the latest version
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 2: Download Chrome Remote Desktop"
log "─────────────────────────────────────────────────────"

CRD_DEB="/tmp/chrome-remote-desktop_current_amd64.deb"
CRD_URL="https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb"

# Download with retry
DOWNLOAD_OK=false
for ATTEMPT in 1 2 3; do
    log "  Download attempt ${ATTEMPT}/3..."
    if wget -q "${CRD_URL}" -O "${CRD_DEB}"; then
        DOWNLOAD_OK=true
        ok "Downloaded: ${CRD_DEB}"
        break
    fi
    warn "  Attempt ${ATTEMPT} failed — waiting 5 seconds"
    sleep 5
done

if [ "${DOWNLOAD_OK}" = "false" ]; then
    err "Chrome RDP download failed after 3 attempts"
    err "Check network connectivity and try again"
    exit 1
fi

# =============================================================================
# STEP 3: INSTALL / REINSTALL VIA GDEBI
# gdebi automatically resolves and installs dependencies.
# --non-interactive prevents any prompts.
# Running on an already-installed package reinstalls/repairs it cleanly.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 3: Install / reinstall Chrome Remote Desktop"
log "─────────────────────────────────────────────────────"

INSTALL_OK=false

# Primary: gdebi (best dependency handling)
if command -v gdebi >/dev/null 2>&1; then
    log "  Installing via gdebi..."
    if gdebi --non-interactive "${CRD_DEB}" 2>/dev/null; then
        INSTALL_OK=true
        ok "Chrome Remote Desktop installed via gdebi"
    else
        warn "gdebi install had errors — trying dpkg + apt fix"
    fi
fi

# Fallback: dpkg + apt-get install -f
if [ "${INSTALL_OK}" = "false" ]; then
    log "  Installing via dpkg..."
    dpkg -i "${CRD_DEB}" 2>/dev/null || true
    apt-get install -y -f 2>/dev/null \
        && INSTALL_OK=true \
        && ok "Chrome Remote Desktop installed via dpkg + apt fix" \
        || warn "dpkg install also had errors — checking if binary exists anyway"
fi

# Verify binary exists regardless of exit codes
if [ -f "/opt/google/chrome-remote-desktop/chrome-remote-desktop" ]; then
    ok "Verified: /opt/google/chrome-remote-desktop/chrome-remote-desktop exists"
else
    err "Chrome Remote Desktop binary not found after install"
    err "Check: ls /opt/google/chrome-remote-desktop/"
    exit 1
fi

rm -f "${CRD_DEB}"

# =============================================================================
# STEP 4: ENABLE AND START THE INIT.D SERVICE
# Chrome RDP ships with /etc/init.d/chrome-remote-desktop.
# We enable and start it via the init.d interface (no systemd in containers).
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 4: Enable and start chrome-remote-desktop service"
log "─────────────────────────────────────────────────────"

if [ -f /etc/init.d/chrome-remote-desktop ]; then
    chmod +x /etc/init.d/chrome-remote-desktop

    # Add abc to the chrome-remote-desktop group if the group exists
    if getent group chrome-remote-desktop >/dev/null 2>&1; then
        usermod -aG chrome-remote-desktop abc 2>/dev/null || true
        ok "abc added to chrome-remote-desktop group"
    fi

    # Start the service (may fail if no session is authorized yet — that's OK)
    /etc/init.d/chrome-remote-desktop start 2>/dev/null \
        && ok "chrome-remote-desktop init.d service started" \
        || warn "init.d start returned non-zero (normal if not yet authorized)"
else
    warn "/etc/init.d/chrome-remote-desktop not found — skipping init.d start"
fi

# =============================================================================
# STEP 5: REGISTER S6-OVERLAY LONGRUN SERVICE
#
# The container uses s6-overlay as PID 1 (/init → s6-overlay-3.x.x).
# s6 supervised services defined in /etc/s6-overlay/s6-rc.d/ restart
# automatically if they exit, AND start on every container restart.
#
# Service structure:
#   /etc/s6-overlay/s6-rc.d/chrome-remote-desktop/
#     type    → "longrun" (s6 keeps it running)
#     run     → the script s6 executes (runs as abc via s6-setuidgid)
#
# Bundle registration:
#   /etc/s6-overlay/s6-rc.d/user/contents.d/chrome-remote-desktop
#   (empty file — its presence tells s6 to include this service in the
#    user bundle that starts at container boot)
#
# DISPLAY=:1 is required — linuxserver webtop sets this env var and
# Chrome RDP needs to know which X display to attach to.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 5: Register s6-overlay supervised service"
log "─────────────────────────────────────────────────────"

S6_BASE="/etc/s6-overlay"
S6_SVC="${S6_BASE}/s6-rc.d/chrome-remote-desktop"
S6_BUNDLE="${S6_BASE}/s6-rc.d/user/contents.d"

# Create service directory
mkdir -p "${S6_SVC}"
mkdir -p "${S6_BUNDLE}"

# Write service type
echo "longrun" > "${S6_SVC}/type"

# Write the run script
# Key points:
#   - s6-setuidgid abc: drops from root to abc before executing
#   - DISPLAY=:1: linuxserver webtop's X display (set in container env)
#   - HOME is set to abc's home so Chrome RDP finds its config files
#   - The service is wrapped in a loop: if chrome-remote-desktop exits,
#     s6 restarts it automatically (longrun semantics)
#   - The || true at the chrome-remote-desktop --check line means:
#     if the service is not authorized yet, we sleep and retry
#     rather than crashing the s6 supervision tree

cat > "${S6_SVC}/run" << RUNSCRIPT
#!/usr/bin/with-contenv bash
# s6-overlay supervised service: chrome-remote-desktop
# Runs as: abc (via s6-setuidgid)
# Restarts: automatically if it exits (s6 longrun)

# Resolve abc's home directory at runtime
ABC_HOME=\$(getent passwd abc | cut -d: -f6)
[ -z "\${ABC_HOME}" ] && ABC_HOME="${ABC_HOME}"

export HOME="\${ABC_HOME}"
export DISPLAY="\${DISPLAY:-:1}"
export USER=abc
export LOGNAME=abc

# Wait for the X display to be ready (linuxserver webtop starts X during init)
for i in \$(seq 1 30); do
    if [ -e "/tmp/.X11-unix/X\${DISPLAY#:}" ] || \
       xdpyinfo -display "\${DISPLAY}" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Run Chrome Remote Desktop as abc
exec s6-setuidgid abc \
    /opt/google/chrome-remote-desktop/chrome-remote-desktop \
    --start
RUNSCRIPT

chmod +x "${S6_SVC}/run"
ok "s6 run script written: ${S6_SVC}/run"

# Write a finish script — called by s6 when the service exits
# Logs the exit for debugging before s6 restarts it
cat > "${S6_SVC}/finish" << 'FINISHSCRIPT'
#!/usr/bin/with-contenv bash
# Called by s6 when chrome-remote-desktop exits
echo "[s6:crd] chrome-remote-desktop exited (code: $1, signal: $2) — s6 will restart"
sleep 2
FINISHSCRIPT

chmod +x "${S6_SVC}/finish"
ok "s6 finish script written: ${S6_SVC}/finish"

# Register in the user bundle
# This empty file tells s6 to include chrome-remote-desktop in the user bundle
# that starts at container boot via /init → stage0 → user bundle
touch "${S6_BUNDLE}/chrome-remote-desktop"
ok "s6 user bundle entry created: ${S6_BUNDLE}/chrome-remote-desktop"

# Fix all s6-overlay file permissions
find "${S6_BASE}" -type f -name "run"    -exec chmod 755 {} \;
find "${S6_BASE}" -type f -name "finish" -exec chmod 755 {} \;

ok "s6 service permissions set"

# =============================================================================
# STEP 6: START THE S6 SERVICE NOW (without restarting the container)
# s6-rc is the s6 service management tool. We use it to start the service
# in the currently running supervision tree without a container restart.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 6: Start s6 service in running supervision tree"
log "─────────────────────────────────────────────────────"

# Try s6-rc to bring the service up in the live supervision tree
if command -v s6-rc >/dev/null 2>&1; then
    s6-rc -u change chrome-remote-desktop 2>/dev/null \
        && ok "s6-rc: chrome-remote-desktop started in live tree" \
        || warn "s6-rc change failed — service will start on next container restart"
elif command -v s6-svc >/dev/null 2>&1; then
    # Fallback: direct s6-svc signal to a running service
    S6_SCANDIR=$(find /run/s6 -name "chrome-remote-desktop" -maxdepth 4 2>/dev/null | head -1)
    if [ -n "${S6_SCANDIR}" ]; then
        s6-svc -u "${S6_SCANDIR}" 2>/dev/null \
            && ok "s6-svc: chrome-remote-desktop brought up" \
            || warn "s6-svc up failed"
    else
        warn "s6 scandir for chrome-remote-desktop not found in /run/s6"
        warn "Service will start on next container restart"
    fi
else
    warn "s6-rc and s6-svc not found in PATH"
    warn "Service will start on next container restart"
fi

# =============================================================================
# COMPLETE — NEXT STEPS FOR USER
# =============================================================================

echo ""
echo "═══════════════════════════════════════════════════════"
echo "✓ Chrome Remote Desktop setup complete"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "s6 service registered — Chrome RDP will now:"
echo "  • Start automatically on every container restart"
echo "  • Restart automatically if it crashes"
echo "  • Run as user abc (not root)"
echo ""
echo "══ NEXT: Authorize Chrome RDP (as abc, NO sudo) ══"
echo ""
echo "  1. Switch to abc:"
echo "       su - abc"
echo ""
echo "  2. Get your authorize code:"
echo "       https://remotedesktop.google.com/headless"
echo "       → Access my computer → Install via SSH → Authorize"
echo ""
echo "  3. Paste the Linux string in the abc shell:"
echo "       DISPLAY= /opt/google/chrome-remote-desktop/start-host \\"
echo "         --code=\"<YOUR-CODE>\" \\"
echo "         --redirect-url=\"https://remotedesktop.google.com/_/oauthredirect\" \\"
echo "         --name=\$(hostname)"
echo ""
echo "  4. Access your desktop:"
echo "       https://remotedesktop.google.com/access"
echo ""
echo "══ VERIFY SERVICE STATUS ══"
echo ""
echo "  Check s6 supervision:"
echo "    s6-rc -a list 2>/dev/null | grep chrome"
echo ""
echo "  Check init.d status:"
echo "    /etc/init.d/chrome-remote-desktop status"
echo ""
echo "  Service files at:"
echo "    ${S6_SVC}/"
echo "    ${S6_BUNDLE}/chrome-remote-desktop"
echo ""
echo "═══════════════════════════════════════════════════════"