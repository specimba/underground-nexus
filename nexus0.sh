#!/usr/bin/env bash
# =============================================================================
# NEXUS0.SH v5 — Polymorphic Payload
# Cloud Underground · Underground Nexus
# =============================================================================
#
# WHAT THIS IS:
#   Single-script bootstrap for the Underground Nexus ecosystem.
#   Works on every deployment surface:
#     • natoascode/nexus0 containers (the DEV command)
#     • lscr.io/linuxserver/webtop:ubuntu-kde containers
#     • Custom Ubuntu/Debian containers with KDE
#     • Bare-metal Ubuntu 22.04 / 24.04 / 25.04 (DEV-metal path)
#     • Kubernetes pods
#
# CORE PHILOSOPHY: THE BULLDOZER
#   Everything installs unconditionally. Failures are logged and the script
#   continues. Only the DISPLAY MECHANISM (KasmVNC s6 services vs SDDM)
#   is conditional on environment detection.
#
# USER MANAGEMENT (the right way):
#   Containers (linuxserver): Do NOT change UID here. Pass -e PUID=1000 -e PGID=1000
#     at docker run time. Linuxserver handles UID mapping natively through /init.
#     abc's home is /config (linuxserver standard for webtop volumes).
#   Bare metal / non-linuxserver: abc is created at UID 1000 if it does not exist.
#     abc's home is /home/abc.
#   The script detects which scenario it is in and acts accordingly.
#
# KVM INTELLIGENCE:
#   Always installs QEMU/KVM packages. At runtime, probes /dev/kvm:
#     • /dev/kvm present  → Tier 1: hardware acceleration (KVM native speed)
#     • /dev/kvm missing  → Tier 2: QEMU TCG software emulation (slower, still works)
#   KVM is a RUNTIME concern — the container must be started with
#   --privileged -v /dev:/dev to pass /dev/kvm through.
#   This script never fails if KVM is unavailable. It adapts.
#
# WALLPAPER SYSTEM (three-image, aspect-ratio responsive):
#   nexus0-sea-space-jelly-highres.jpg → all landscape/widescreen sizes
#   nexus0-sea-space-jelly.jpg         → standard/square sizes
#   nexus0-moon-jelly.jpg              → portrait/vertical sizes
#   KDE picks the closest filename match to the actual display resolution.
#   rm -rf *.png removes kubuntu defaults so our JPGs take priority.
#
# =============================================================================

# pipefail catches broken pipes but NOT every error — we handle errors manually
set -o pipefail

# =============================================================================
# LOGGING
# =============================================================================

NX_LOG="/tmp/nexus0-install.log"
mkdir -p /tmp

log()  { echo "[nexus0] $*" | tee -a "${NX_LOG}"; }
ok()   { echo "[nexus0] ✓ $*" | tee -a "${NX_LOG}"; }
warn() { echo "[nexus0] ⚠ $*" | tee -a "${NX_LOG}"; }
err()  { echo "[nexus0] ✗ $*" | tee -a "${NX_LOG}" >&2; }

log "═══════════════════════════════════════════════════"
log "nexus0.sh v5 — Polymorphic Payload"
log "Started: $(date)"
log "═══════════════════════════════════════════════════"

# =============================================================================
# ARCHITECTURE DETECTION
# =============================================================================

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "${ARCH}" in
    amd64|x86_64)  ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *)
        warn "Unknown architecture '${ARCH}' — defaulting to amd64"
        ARCH="amd64"
        ;;
esac
log "Architecture: ${ARCH}"

# =============================================================================
# ENVIRONMENT DETECTION
# =============================================================================

CONTAINER_MODE=false
LINUXSERVER_MODE=false

# Primary container check
if [ -f /.dockerenv ]; then
    CONTAINER_MODE=true
    log "/.dockerenv found → CONTAINER MODE"
elif grep -q 'container=' /proc/1/environ 2>/dev/null; then
    CONTAINER_MODE=true
    log "container= in PID1 environ → CONTAINER MODE"
fi

# Detect linuxserver base (has /run/s6 and /config managed by init)
if [ -d /run/s6 ] || [ -f /etc/s6-overlay/s6-rc.d/user/type ] || \
   grep -q 'linuxserver' /etc/os-release 2>/dev/null || \
   [ -d /etc/s6-overlay ]; then
    LINUXSERVER_MODE=true
    log "s6-overlay detected → LINUXSERVER MODE"
    log "  User home: /config (abc UID set by PUID env var at runtime)"
fi

if [ "${CONTAINER_MODE}" = "false" ]; then
    log "No container markers → BARE METAL / VM MODE"
fi

# Determine abc's home directory
if [ "${LINUXSERVER_MODE}" = "true" ]; then
    ABC_HOME="/config"
else
    ABC_HOME="/home/abc"
fi
log "abc home: ${ABC_HOME}"

export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# RETRY HELPER
# retry <max_attempts> <delay_secs> <command...>
# =============================================================================

retry() {
    local ATTEMPTS="$1"; shift
    local DELAY="$1"; shift
    local TRY=1
    while [ "${TRY}" -le "${ATTEMPTS}" ]; do
        if "$@"; then return 0; fi
        warn "Attempt ${TRY}/${ATTEMPTS} failed: $*"
        TRY=$((TRY + 1))
        [ "${TRY}" -le "${ATTEMPTS}" ] && sleep "${DELAY}"
    done
    err "All ${ATTEMPTS} attempts failed: $*"
    return 1
}

# =============================================================================
# STEP 1: BASE PACKAGES
# zstd MUST be installed first — Ollama installer silently fails without it.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 1: Base packages"
log "─────────────────────────────────────────────────────"

retry 3 5 apt-get update -qq

retry 3 5 apt-get install -y \
    ssh wget curl nano git \
    ca-certificates apt-transport-https gnupg \
    zstd xz-utils \
    software-properties-common \
    iputils-ping \
    || warn "Some base packages failed — continuing"

ok "Base packages + zstd installed"

# =============================================================================
# STEP 2: CHROME REMOTE DESKTOP
# Primary zero-trust access method. Works via outbound connection only —
# no open inbound ports required. Google only ships amd64.
# On arm64: KasmVNC (:3000) is the primary access method.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 2: Chrome Remote Desktop"
log "─────────────────────────────────────────────────────"

if [ "${ARCH}" = "amd64" ]; then
    CRD_DEB="/tmp/chrome-remote-desktop_current_amd64.deb"
    retry 3 8 wget -q \
        "https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb" \
        -O "${CRD_DEB}" \
        && ok "Chrome RDP deb downloaded" \
        || warn "Chrome RDP download failed"

    if [ -f "${CRD_DEB}" ]; then
        dpkg -i "${CRD_DEB}" 2>/dev/null || true
        apt-get install -y -f 2>/dev/null || true
        ok "Chrome Remote Desktop installed"
    fi
else
    warn "Chrome Remote Desktop is amd64 only — skipped on ${ARCH}"
    log "  Primary access on arm64: KasmVNC at :3000"
fi

# =============================================================================
# STEP 3: GITHUB DESKTOP
# shiftkey Linux fork. Primary: APT repo. Fallback: direct .deb.
# The shiftkey GPG/APT step can fail in some VPN/container network environments
# due to TLS certificate issues. We try twice then fall back to direct download.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 3: GitHub Desktop (shiftkey)"
log "─────────────────────────────────────────────────────"

GH_DESKTOP_OK=false

# Primary: shiftkey APT repo
if retry 2 5 bash -c '
    wget -qO - https://apt.packages.shiftkey.dev/gpg.key \
        | gpg --dearmor \
        | tee /usr/share/keyrings/shiftkey-packages.gpg > /dev/null \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/shiftkey-packages.gpg] https://apt.packages.shiftkey.dev/ubuntu/ any main" \
        > /etc/apt/sources.list.d/shiftkey-packages.list \
    && apt-get update -qq \
    && apt-get install -y github-desktop
'; then
    GH_DESKTOP_OK=true
    ok "GitHub Desktop installed via shiftkey APT"
fi

# Fallback: direct .deb download (amd64 only)
if [ "${GH_DESKTOP_OK}" = "false" ] && [ "${ARCH}" = "amd64" ]; then
    warn "shiftkey APT failed — trying direct .deb fallback"
    retry 3 5 wget -q \
        "https://github.com/shiftkey/desktop/releases/download/release-3.3.9-linux1/GitHubDesktop-linux-amd64-3.3.9-linux1.deb" \
        -O /tmp/github-desktop.deb \
        && dpkg -i /tmp/github-desktop.deb 2>/dev/null || true \
        && apt-get install -y -f 2>/dev/null || true \
        && GH_DESKTOP_OK=true \
        && ok "GitHub Desktop installed via direct .deb" \
        || warn "GitHub Desktop direct .deb also failed — non-fatal"
    rm -f /tmp/github-desktop.deb
fi

[ "${GH_DESKTOP_OK}" = "false" ] && warn "GitHub Desktop not installed (non-fatal)"

# =============================================================================
# STEP 4: GITKRAKEN
# Visual Git client. amd64 deb only. arm64 has no official package.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 4: GitKraken"
log "─────────────────────────────────────────────────────"

if [ "${ARCH}" = "amd64" ]; then
    retry 3 8 wget -q \
        "https://release.gitkraken.com/linux/gitkraken-amd64.deb" \
        -O /tmp/gitkraken-amd64.deb \
        && ok "GitKraken deb downloaded" \
        || warn "GitKraken download failed"

    if [ -f /tmp/gitkraken-amd64.deb ]; then
        dpkg -i /tmp/gitkraken-amd64.deb 2>/dev/null || true
        apt-get install -y -f 2>/dev/null || true
        apt-get upgrade -y --fix-broken 2>/dev/null || true
        ok "GitKraken installed"
        rm -f /tmp/gitkraken-amd64.deb
    fi
else
    warn "GitKraken: amd64 deb only — skipped on ${ARCH}"
fi

# =============================================================================
# STEP 5: KVM / QEMU / VIRT-MANAGER
#
# PACKAGE NAMING NOTE (Ubuntu 22.04+):
#   ubuntu 22.04 (jammy):   qemu-kvm is a direct package
#   ubuntu 24.04 (noble):   qemu-kvm is a metapackage → qemu-system-x86
#   ubuntu 25.04 (resolute):qemu-kvm is VIRTUAL — must use qemu-system-x86
#
# We install both the old and new name so it works across Ubuntu versions.
# || true ensures we never fail on virtual package name mismatches.
#
# KVM IS RUNTIME-ONLY: /dev/kvm is not available during docker build.
# The probe below will find it missing at build time and note Tier 2 mode.
# At runtime with --privileged -v /dev:/dev, Tier 1 is activated.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 5: KVM + QEMU + virt-manager"
log "─────────────────────────────────────────────────────"

# Install the full virtualization stack — works across Ubuntu 22.04–25.04
apt-get install -y \
    qemu-kvm qemu-system qemu-system-x86 \
    cpu-checker \
    virt-manager \
    libvirt-daemon-system libvirt-clients \
    bridge-utils \
    ovmf \
    2>/dev/null || \
apt-get install -y \
    qemu-system-x86 qemu-system qemu-system-x86-hwe \
    cpu-checker \
    virt-manager \
    libvirt-daemon-system libvirt-clients \
    bridge-utils \
    ovmf \
    2>/dev/null || \
warn "KVM/QEMU install had errors — best-effort result"

apt-get install -y -f 2>/dev/null || true

# Start libvirt daemons in background
# These will fail silently during build (expected) and start properly at runtime
/usr/sbin/libvirtd &>/dev/null & disown 2>/dev/null || true
/usr/sbin/virtlogd &>/dev/null & disown 2>/dev/null || true

# Group membership for abc
usermod -aG kvm abc 2>/dev/null || true
usermod -aG libvirt abc 2>/dev/null || true

# KVM probe — announces what's available
log ""
log "  ── VIRTUALIZATION PROBE ──"
if [ -e /dev/kvm ]; then
    chown root:kvm /dev/kvm 2>/dev/null || true
    chmod 660 /dev/kvm 2>/dev/null || true
    log "  ✓ /dev/kvm present → Tier 1: HARDWARE ACCELERATION (KVM native)"
    command -v kvm-ok >/dev/null 2>&1 && log "  kvm-ok: $(kvm-ok 2>&1 | head -1)"
    VIRT_TIER="1-kvm"
else
    log "  ⚠ /dev/kvm not present → Tier 2: QEMU TCG software emulation"
    log "    (normal during docker build — KVM activates at runtime)"
    log "    To enable Tier 1: docker run --privileged -v /dev:/dev ..."
    VIRT_TIER="2-tcg"
fi
log "  ──────────────────────────"
log ""

ok "KVM/QEMU/virt-manager setup complete (tier: ${VIRT_TIER})"

# =============================================================================
# STEP 6: OLLAMA LLM RUNTIME
# Requires zstd (Step 1). Serves inference at localhost:11434.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 6: Ollama LLM Runtime"
log "─────────────────────────────────────────────────────"

if command -v ollama >/dev/null 2>&1; then
    ok "Ollama already installed"
else
    retry 3 10 bash -c 'curl -fsSL https://ollama.com/install.sh | sh' \
        && ok "Ollama installed" \
        || warn "Ollama install failed — install manually: curl -fsSL https://ollama.com/install.sh | sh"
fi

apt-get install -y -f 2>/dev/null || true
ollama serve &>/dev/null & disown 2>/dev/null || true
ok "Ollama serve started (background, localhost:11434)"

# =============================================================================
# STEP 7: CREATIVE SUITE
# Blender, OBS Studio, LibreOffice are MANDATORY (explicitly required).
# OBS: Use obsproject PPA for latest version vs stale Ubuntu archive.
# Blender: apt first, snap fallback.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 7: Creative Suite (Blender, OBS, LibreOffice...)"
log "─────────────────────────────────────────────────────"

# LibreOffice — full suite
retry 3 5 apt-get install -y libreoffice \
    && ok "LibreOffice installed" \
    || warn "LibreOffice install failed"

# OBS Studio — add official PPA for current version
add-apt-repository -y ppa:obsproject/obs-studio 2>/dev/null || true
apt-get update -qq 2>/dev/null || true
retry 3 5 apt-get install -y obs-studio \
    && ok "OBS Studio installed" \
    || warn "OBS Studio install failed"

# Blender — apt, then snap fallback
retry 3 5 apt-get install -y blender \
    && ok "Blender installed" \
    || {
        warn "Blender apt failed — trying snap fallback"
        snap install blender --classic 2>/dev/null \
            && ok "Blender installed via snap" \
            || warn "Blender install failed completely"
    }

# Additional creative tools
retry 3 5 apt-get install -y \
    inkscape gimp audacity kdenlive \
    && ok "Inkscape, GIMP, Audacity, Kdenlive installed" \
    || warn "Some creative tools failed"

ok "Creative suite installation complete"

# =============================================================================
# STEP 8: VISUAL STUDIO CODE
# Uses the Microsoft APT repo via the official setup script.
# DEBIAN_FRONTEND=noninteractive prevents interactive "Continue? [Y/n]" prompts.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 8: Visual Studio Code"
log "─────────────────────────────────────────────────────"

if command -v code >/dev/null 2>&1; then
    ok "VS Code already installed"
else
    retry 3 5 wget -q \
        "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/refs/heads/main/visual-studio-code.sh" \
        -O /tmp/vscode-install.sh \
        && DEBIAN_FRONTEND=noninteractive bash /tmp/vscode-install.sh \
        && ok "VS Code installed" \
        || warn "VS Code install failed"
    rm -f /tmp/vscode-install.sh
fi

# =============================================================================
# STEP 9: DESKTOP APPLICATIONS
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 9: Desktop apps (Terminator, Firefox, gdebi...)"
log "─────────────────────────────────────────────────────"

retry 3 5 apt-get install -y \
    terminator \
    firefox \
    gdebi \
    plasma-discover \
    supervisor \
    || warn "Some desktop apps failed"

ok "Desktop apps installed"

# =============================================================================
# STEP 10: DEVSECOPS TOOLCHAIN
# Dagger, Zarf (multi-arch), K9s, Lazydocker, DEV/SEC/OPS appinator.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 10: DevSecOps toolchain"
log "─────────────────────────────────────────────────────"

# Dagger CI
if ! command -v dagger >/dev/null 2>&1; then
    retry 2 5 bash -c 'curl -fsSL https://dl.dagger.io/dagger/install.sh | BIN_DIR=/usr/local/bin sh' \
        && ok "Dagger CI installed" \
        || warn "Dagger install failed"
fi

# Zarf (multi-arch binary)
if ! command -v zarf >/dev/null 2>&1; then
    ZARF_VER=$(curl -sIX HEAD https://github.com/zarf-dev/zarf/releases/latest \
        | grep -i '^location:' | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null || echo "")
    if [ -n "${ZARF_VER}" ]; then
        retry 3 5 curl -sL \
            "https://github.com/zarf-dev/zarf/releases/download/${ZARF_VER}/zarf_${ZARF_VER}_Linux_${ARCH}" \
            -o /usr/local/bin/zarf \
            && chmod +x /usr/local/bin/zarf \
            && ok "Zarf ${ZARF_VER} installed" \
            || warn "Zarf install failed"
    fi
fi

# K9s Kubernetes TUI
if ! command -v k9s >/dev/null 2>&1; then
    K9S_VER=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4 2>/dev/null || echo "")
    if [ -n "${K9S_VER}" ]; then
        retry 3 5 curl -sL \
            "https://github.com/derailed/k9s/releases/download/${K9S_VER}/k9s_Linux_${ARCH}.tar.gz" \
            | tar -xz -C /usr/local/bin k9s 2>/dev/null \
            && ok "K9s ${K9S_VER} installed" \
            || warn "K9s install failed"
    fi
fi

# Lazydocker Docker TUI
if ! command -v lazydocker >/dev/null 2>&1; then
    retry 3 5 curl -fsSL \
        https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh \
        | DIR=/usr/local/bin bash 2>/dev/null \
        && ok "Lazydocker installed" \
        || warn "Lazydocker install failed"
fi

# DEV/SEC/OPS appinator — writes DEV, DEV-rebuild, DEV-restore etc to /usr/local/bin
retry 3 5 wget -q \
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/refs/heads/main/Dagger%20CI/Scripts/nexus-devsecops-appinator.sh" \
    -O /tmp/appinator.sh \
    && bash /tmp/appinator.sh 2>/dev/null \
    && ok "DEV/SEC/OPS commands written to /usr/local/bin" \
    || warn "Appinator failed"
rm -f /tmp/appinator.sh

ok "DevSecOps toolchain complete"

# =============================================================================
# STEP 11: SSH
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 11: SSH"
log "─────────────────────────────────────────────────────"

mkdir -p /var/run/sshd
service ssh enable 2>/dev/null || true
service ssh start 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true
ok "SSH configured"

# =============================================================================
# STEP 12: USER SETUP
#
# LINUXSERVER CONTAINERS:
#   Do NOT use usermod to change UID. The linuxserver /init process handles
#   UID mapping at container start via -e PUID=1000 -e PGID=1000.
#   abc's home is /config (the mounted volume).
#   We only ensure group memberships and sudo/password are set.
#
# BARE METAL / NON-LINUXSERVER:
#   Create user abc at UID 1000 if it does not exist.
#   abc's home is /home/abc.
#   Set UID to 1000 if abc exists at a different UID.
#
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 12: User abc configuration"
log "─────────────────────────────────────────────────────"

if [ "${LINUXSERVER_MODE}" = "true" ]; then
    log "Linuxserver mode — UID set at runtime via -e PUID=1000 -e PGID=1000"
    log "abc home: /config"
    # abc already exists in linuxserver base — just ensure groups and password
else
    # Bare metal / non-linuxserver container
    if ! id -u abc >/dev/null 2>&1; then
        log "Creating user abc (UID 1000, home: ${ABC_HOME})"
        useradd -m -u 1000 -d "${ABC_HOME}" -s /bin/bash abc 2>/dev/null \
            && ok "User abc created" \
            || warn "useradd failed"
    else
        CURRENT_UID=$(id -u abc 2>/dev/null || echo "0")
        if [ "${CURRENT_UID}" != "1000" ]; then
            log "Correcting abc UID: ${CURRENT_UID} → 1000"
            usermod -u 1000 -d "${ABC_HOME}" abc 2>/dev/null || warn "usermod failed"
            groupmod -g 1000 abc 2>/dev/null || warn "groupmod failed"
            find / -user "${CURRENT_UID}" \
                -not -path "/proc/*" -not -path "/sys/*" -not -path "/dev/*" \
                -exec chown -h abc: {} + 2>/dev/null || true
            ok "abc UID corrected to 1000"
        else
            ok "abc already UID 1000"
        fi
    fi
    mkdir -p "${ABC_HOME}"
fi

# Group memberships (safe in all modes)
for GRP in sudo docker kvm libvirt; do
    getent group "${GRP}" >/dev/null 2>&1 && usermod -aG "${GRP}" abc 2>/dev/null || true
done

# Password — sovereign standard
echo "abc:sovereign" | chpasswd 2>/dev/null || true
ok "Password set: sovereign"

# Sudoers — idempotent
cp -f /etc/sudoers /root/sudoers.bak 2>/dev/null || true
grep -q "abc ALL=(ALL) NOPASSWD: ALL" /etc/sudoers 2>/dev/null || \
    echo "abc ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
grep -q "www-data ALL=(ALL) NOPASSWD: ALL" /etc/sudoers 2>/dev/null || \
    echo "www-data ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
sort /etc/sudoers | uniq > /etc/sudoers-NEW 2>/dev/null && \
    mv -f /etc/sudoers-NEW /etc/sudoers 2>/dev/null || true
ok "Sudoers configured"

# =============================================================================
# STEP 13: NEXUS-BUCKET FILESYSTEM
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 13: /nexus-bucket + Underground Nexus repo"
log "─────────────────────────────────────────────────────"

mkdir -p /nexus-bucket
chown -R abc:abc /nexus-bucket
chmod 755 /nexus-bucket

if [ ! -d "/nexus-bucket/underground-nexus/.git" ]; then
    retry 3 10 git clone \
        https://github.com/Underground-Ops/underground-nexus.git \
        /nexus-bucket/underground-nexus \
        && ok "Underground Nexus repo cloned to /nexus-bucket" \
        || warn "git clone failed — network issue or air-gap mode"
else
    git -C /nexus-bucket/underground-nexus pull --rebase 2>/dev/null || true
    ok "Underground Nexus repo updated"
fi

chown -R abc:abc /nexus-bucket 2>/dev/null || true

# =============================================================================
# STEP 14: WALLPAPERS — THREE-IMAGE ASPECT-RATIO SYSTEM
#
# Exactly mirrors the original nexus0.sh wallpaper logic.
# Three different image files → three aspect ratio families.
# KDE auto-selects closest resolution match at display time.
#
# sea-space-jelly-highres → all widescreen landscape (1280x800 to 2560x1440)
# sea-space-jelly         → standard / near-square (1280x1024, 1024x768)
# moon-jelly              → portrait / vertical (1080x1920, 360x720, 720x1440)
#
# mkdir -p guards against linuxserver webtop variants that don't ship KubuntuLight.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 14: Wallpapers (three-image aspect-ratio system)"
log "─────────────────────────────────────────────────────"

WALLPAPER_BASE="https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/Wallpapers"
WALLPAPER_DIR="/usr/share/wallpapers/KubuntuLight/contents/images"

mkdir -p "${WALLPAPER_DIR}"
cd "${WALLPAPER_DIR}" || warn "Cannot cd to ${WALLPAPER_DIR}"

# IMAGE 1 — sea-space-jelly-highres → all widescreen landscape sizes
retry 3 5 wget -q "${WALLPAPER_BASE}/nexus0-sea-space-jelly-highres.jpg" \
    -O "1440x900.jpg" \
    && ok "sea-space-jelly-highres.jpg downloaded (1440x900 master)" \
    || warn "highres wallpaper download failed"

if [ -f "1440x900.jpg" ]; then
    for SIZE in 1280x800 1366x768 1600x1200 1680x1050 1920x1080 1920x1200 2560x1440; do
        rm -f "${SIZE}.jpg" "${SIZE}.png" 2>/dev/null || true
        cp "1440x900.jpg" "${SIZE}.jpg"
    done
    ok "Widescreen wallpapers set (1280x800 → 2560x1440)"
fi

# IMAGE 2 — sea-space-jelly → standard/square sizes
retry 3 5 wget -q "${WALLPAPER_BASE}/nexus0-sea-space-jelly.jpg" \
    -O "1280x1024.jpg" \
    && ok "sea-space-jelly.jpg downloaded (1280x1024 master)" \
    || warn "standard wallpaper download failed"

if [ -f "1280x1024.jpg" ]; then
    rm -f "1024x768.jpg" "1024x768.png" 2>/dev/null || true
    cp "1280x1024.jpg" "1024x768.jpg"
    ok "Square wallpapers set (1280x1024, 1024x768)"
fi

# IMAGE 3 — moon-jelly → portrait/vertical sizes
retry 3 5 wget -q "${WALLPAPER_BASE}/nexus0-moon-jelly.jpg" \
    -O "1080x1920.jpg" \
    && ok "moon-jelly.jpg downloaded (1080x1920 master)" \
    || warn "portrait wallpaper download failed"

if [ -f "1080x1920.jpg" ]; then
    for SIZE in 360x720 720x1440; do
        rm -f "${SIZE}.jpg" "${SIZE}.png" 2>/dev/null || true
        cp "1080x1920.jpg" "${SIZE}.jpg"
    done
    ok "Portrait wallpapers set (1080x1920, 360x720, 720x1440)"
fi

# Remove all default PNG wallpapers so KDE uses our JPGs
rm -rf ./*.png 2>/dev/null || true
ok "Default PNG wallpapers removed — three-image system active"

cd / || true

# =============================================================================
# STEP 15: CONTROL PANEL
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 15: Nexus Creator Vault control panel"
log "─────────────────────────────────────────────────────"

retry 3 5 wget -q \
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/Production%20Artifacts/Wordpress/nexus-creator-vault/nexus-creator-vault-control-panel.html" \
    -O /nexus-creator-vault-control-panel.html \
    && ok "Control panel → /nexus-creator-vault-control-panel.html" \
    || warn "Control panel download failed"

# Place on desktops (both /config and /home/abc for compatibility)
mkdir -p /config/Desktop /home/abc/Desktop 2>/dev/null || true
cp -f /nexus-creator-vault-control-panel.html \
    /config/Desktop/nexus-creator-vault-control-panel.html 2>/dev/null || true
cp -f /nexus-creator-vault-control-panel.html \
    /home/abc/Desktop/nexus-creator-vault-control-panel.html 2>/dev/null || true

# =============================================================================
# STEP 16: DISPLAY MODE CONFIGURATION
# Container:   Register s6-overlay supervised services (no systemd)
# Bare metal:  Configure SDDM auto-login + systemd unit for sovereign-installer
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 16: Display mode"
log "─────────────────────────────────────────────────────"

if [ "${CONTAINER_MODE}" = "true" ]; then

    log "CONTAINER MODE — s6-overlay service registration"

    # Ensure s6 directories exist
    mkdir -p /etc/s6-overlay/s6-rc.d /etc/s6-overlay/cont-init.d

    # s6: libvirtd
    mkdir -p /etc/s6-overlay/s6-rc.d/libvirtd
    printf '#!/usr/bin/with-contenv bash\nexec /usr/sbin/libvirtd\n' \
        > /etc/s6-overlay/s6-rc.d/libvirtd/run
    echo "longrun" > /etc/s6-overlay/s6-rc.d/libvirtd/type

    # s6: virtlogd
    mkdir -p /etc/s6-overlay/s6-rc.d/virtlogd
    printf '#!/usr/bin/with-contenv bash\nexec /usr/sbin/virtlogd\n' \
        > /etc/s6-overlay/s6-rc.d/virtlogd/run
    echo "longrun" > /etc/s6-overlay/s6-rc.d/virtlogd/type

    # s6: ollama
    mkdir -p /etc/s6-overlay/s6-rc.d/ollama
    printf '#!/usr/bin/with-contenv bash\nexec ollama serve\n' \
        > /etc/s6-overlay/s6-rc.d/ollama/run
    echo "longrun" > /etc/s6-overlay/s6-rc.d/ollama/type

    # s6: chrome-remote-desktop (amd64; arm64 exits cleanly)
    mkdir -p /etc/s6-overlay/s6-rc.d/chrome-remote-desktop
    printf '#!/usr/bin/with-contenv bash\n[ -f /opt/google/chrome-remote-desktop/chrome-remote-desktop ] || exit 0\nexec s6-setuidgid abc /opt/google/chrome-remote-desktop/chrome-remote-desktop --start\n' \
        > /etc/s6-overlay/s6-rc.d/chrome-remote-desktop/run
    echo "longrun" > /etc/s6-overlay/s6-rc.d/chrome-remote-desktop/type

    # s6: supervisor (only if installed)
    if command -v supervisord >/dev/null 2>&1; then
        mkdir -p /etc/s6-overlay/s6-rc.d/supervisor
        printf '#!/usr/bin/with-contenv bash\nexec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf\n' \
            > /etc/s6-overlay/s6-rc.d/supervisor/run
        echo "longrun" > /etc/s6-overlay/s6-rc.d/supervisor/type
    fi

    # Enable in user bundle
    mkdir -p /etc/s6-overlay/s6-rc.d/user/contents.d
    for SVC in libvirtd virtlogd ollama chrome-remote-desktop; do
        touch "/etc/s6-overlay/s6-rc.d/user/contents.d/${SVC}"
    done
    command -v supervisord >/dev/null 2>&1 && \
        touch /etc/s6-overlay/s6-rc.d/user/contents.d/supervisor || true

    # cont-init: KVM permissions at container start
    # (runs after /init, so /dev/kvm is mounted from host by then)
    printf '#!/usr/bin/with-contenv bash\nusermod -aG kvm abc 2>/dev/null||true\nusermod -aG libvirt abc 2>/dev/null||true\nchown root:kvm /dev/kvm 2>/dev/null||true\nchmod 660 /dev/kvm 2>/dev/null||true\n' \
        > /etc/s6-overlay/cont-init.d/01-kvm-permissions
    chmod +x /etc/s6-overlay/cont-init.d/01-kvm-permissions

    # cont-init: nexus-bucket ownership
    printf '#!/usr/bin/with-contenv bash\nmkdir -p /nexus-bucket\nchown -R abc:abc /nexus-bucket\n' \
        > /etc/s6-overlay/cont-init.d/02-nexus-bucket
    chmod +x /etc/s6-overlay/cont-init.d/02-nexus-bucket

    # cont-init: git sync on start
    printf '#!/usr/bin/with-contenv bash\ngit clone https://github.com/Underground-Ops/underground-nexus.git /nexus-bucket/underground-nexus 2>/dev/null||git -C /nexus-bucket/underground-nexus pull --rebase 2>/dev/null||true\nchown -R abc:abc /nexus-bucket/underground-nexus 2>/dev/null||true\n' \
        > /etc/s6-overlay/cont-init.d/03-nexus-sync
    chmod +x /etc/s6-overlay/cont-init.d/03-nexus-sync

    find /etc/s6-overlay -type f -exec chmod +x {} \; 2>/dev/null || true

    log ""
    log "  ── ZERO TRUST ACCESS ──────────────────────────────"
    log "  Primary:   KasmVNC → http://<host>:1050"
    log "  Secondary: Chrome RDP → remotedesktop.google.com/access"
    log "  Tertiary:  SSH → ssh abc@<container-ip>  (password: sovereign)"
    log "  ──────────────────────────────────────────────────"
    log "  Chrome RDP setup (run as abc, NOT root, NO sudo):"
    log "    su - abc"
    log "    DISPLAY= /opt/google/chrome-remote-desktop/start-host \\"
    log "      --code=\"<YOUR-AUTHORIZE-CODE>\" \\"
    log "      --redirect-url=\"https://remotedesktop.google.com/_/oauthredirect\" \\"
    log "      --name=\$(hostname)"
    log "  Get authorize code from: https://remotedesktop.google.com/headless"
    log "  ──────────────────────────────────────────────────"

    ok "Container s6 services registered"

else

    log "BARE METAL / VM MODE (DEV-metal path)"

    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/autologin.conf << 'SDDMEOF'
[Autologin]
User=abc
Session=plasma
Relogin=false
SDDMEOF
    ok "SDDM auto-login set (abc → plasma)"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable sddm 2>/dev/null || true
        systemctl enable libvirtd 2>/dev/null || true
    fi

    # First-boot sovereign-installer service
    cat > /etc/systemd/system/nexus-first-boot.service << 'SVCEOF'
[Unit]
Description=Nexus OS First Boot — Sovereign Installer
After=network-online.target docker.service
ConditionPathExists=!/var/lib/nexus-first-boot-done

[Service]
Type=oneshot
User=root
ExecStart=/bin/bash -c '/usr/local/bin/sovereign-installer && touch /var/lib/nexus-first-boot-done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

    command -v systemctl >/dev/null 2>&1 && {
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable nexus-first-boot.service 2>/dev/null || true
    }

    ok "Bare metal / DEV-metal mode ready"
fi

# =============================================================================
# STEP 17: FINAL CLEANUP AND PERMISSIONS
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 17: Final cleanup"
log "─────────────────────────────────────────────────────"

apt-get install -y -f 2>/dev/null || true
apt-get upgrade -y --fix-broken 2>/dev/null || true
apt-get clean 2>/dev/null || true
rm -rf /var/lib/apt/lists/* 2>/dev/null || true

chown -R abc:abc /nexus-bucket 2>/dev/null || true
[ "${LINUXSERVER_MODE}" = "true" ] && chown -R abc:abc /config 2>/dev/null || true
[ -d /home/abc ] && chown -R abc:abc /home/abc 2>/dev/null || true

ok "Cleanup done"

# =============================================================================
# ARSENAL SUMMARY
# =============================================================================

log ""
log "═══════════════════════════════════════════════════"
log "nexus0.sh v5 COMPLETE"
log "═══════════════════════════════════════════════════"
log "Mode:       $([ "${CONTAINER_MODE}" = "true" ] && echo "CONTAINER" || echo "BARE METAL")"
log "LinuxSrv:   ${LINUXSERVER_MODE}"
log "User home:  ${ABC_HOME}"
log "Arch:       ${ARCH}"
log "KVM tier:   ${VIRT_TIER:-unknown (probe at runtime)}"
log "Password:   sovereign"
log ""
log "INSTALLED ARSENAL:"
command -v code         >/dev/null 2>&1 && log "  ✓ VS Code"         || log "  ✗ VS Code"
command -v dagger       >/dev/null 2>&1 && log "  ✓ Dagger CI"       || log "  ✗ Dagger CI"
command -v zarf         >/dev/null 2>&1 && log "  ✓ Zarf"            || log "  ✗ Zarf"
command -v k9s          >/dev/null 2>&1 && log "  ✓ K9s"             || log "  ✗ K9s"
command -v lazydocker   >/dev/null 2>&1 && log "  ✓ Lazydocker"      || log "  ✗ Lazydocker"
command -v ollama       >/dev/null 2>&1 && log "  ✓ Ollama"          || log "  ✗ Ollama"
command -v blender      >/dev/null 2>&1 && log "  ✓ Blender"         || log "  ✗ Blender"
command -v obs          >/dev/null 2>&1 && log "  ✓ OBS Studio"      || log "  ✗ OBS Studio"
command -v libreoffice  >/dev/null 2>&1 && log "  ✓ LibreOffice"     || log "  ✗ LibreOffice"
command -v inkscape     >/dev/null 2>&1 && log "  ✓ Inkscape"        || log "  ✗ Inkscape"
command -v gimp         >/dev/null 2>&1 && log "  ✓ GIMP"            || log "  ✗ GIMP"
command -v gitkraken    >/dev/null 2>&1 && log "  ✓ GitKraken"       || dpkg -l gitkraken >/dev/null 2>&1 && log "  ✓ GitKraken (dpkg)" || log "  ✗ GitKraken"
command -v github-desktop >/dev/null 2>&1 && log "  ✓ GitHub Desktop" || dpkg -l github-desktop >/dev/null 2>&1 && log "  ✓ GitHub Desktop (dpkg)" || log "  ✗ GitHub Desktop"
[ -f /opt/google/chrome-remote-desktop/chrome-remote-desktop ] \
    && log "  ✓ Chrome RDP" || log "  ✗ Chrome RDP (amd64 only)"
command -v virt-manager >/dev/null 2>&1 && log "  ✓ Virt Manager"    || log "  ✗ Virt Manager"
log ""
log "Full log: /tmp/nexus0-install.log"
log "═══════════════════════════════════════════════════"