#!/usr/bin/env bash
# =============================================================================
# NEXUS0.SH v5.3 — Pure Package Installer
# Cloud Underground · Underground Nexus
# =============================================================================
#
# v5.3 PHILOSOPHY: THIS SCRIPT ONLY INSTALLS PACKAGES.
#
# What this script does NOT do (and why):
#
#   NO s6 service registration:
#     The Dockerfile owns ALL s6 definitions. nexus0.sh writing s6 files
#     created uncertainty about what was running. The Dockerfile now writes
#     all service run/type files inline, giving complete visibility.
#
#   NO background daemon starts (no libvirtd &, ollama serve &, etc.):
#     Starting daemons during docker build bakes socket files and PID state
#     into the image layers, causing conflicts at container runtime.
#     s6 services start libvirtd, virtlogd, and ollama at container boot.
#
#   NO /config writes:
#     /config does not exist during docker build. The linuxserver /init
#     creates it at container start after PUID/PGID mapping.
#     The Dockerfile's /custom-cont-init.d/01-nexus-setup.sh handles
#     Desktop population, /nexus-bucket, KVM permissions at runtime.
#
#   NO appinator (nexus-devsecops-appinator.sh):
#     The appinator installs docker CLI tooling that may trigger dockerd
#     startup inside the container. With /var/run/docker.sock mounted from
#     the host, any dockerd start attempt causes "device or resource busy"
#     → s6 restart loop → KDE desktop killed repeatedly → ERR_EMPTY_RESPONSE.
#     The appinator can be run manually inside the running container.
#
# What this script DOES:
#   apt-get installs: base packages, CRD, GitKraken, KVM/QEMU, Ollama,
#   creative suite, VS Code, desktop apps, DevSecOps CLI tools (no dockerd)
#
# Environment detection is still present for bare-metal support.
# On bare metal (not linuxserver): configures SDDM and user abc normally.
# =============================================================================

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
log "nexus0.sh v5.3 — Pure Package Installer"
log "Started: $(date)"
log "═══════════════════════════════════════════════════"

# =============================================================================
# ARCHITECTURE DETECTION
# =============================================================================

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "${ARCH}" in
    amd64|x86_64)  ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *)             warn "Unknown arch '${ARCH}' — defaulting to amd64"; ARCH="amd64" ;;
esac
log "Architecture: ${ARCH}"

# =============================================================================
# ENVIRONMENT DETECTION
#
# v5.2 fix: force CONTAINER_MODE=true when LINUXSERVER_MODE=true.
# Hub BuildKit may not write /.dockerenv but s6-overlay IS present.
# =============================================================================

CONTAINER_MODE=false
LINUXSERVER_MODE=false

[ -f /.dockerenv ] && { CONTAINER_MODE=true; log "/.dockerenv → CONTAINER MODE"; }
grep -q 'container=' /proc/1/environ 2>/dev/null && { CONTAINER_MODE=true; log "PID1 environ → CONTAINER MODE"; }

if [ -d /run/s6 ] || [ -d /etc/s6-overlay ] || \
   grep -q 'linuxserver' /etc/os-release 2>/dev/null; then
    LINUXSERVER_MODE=true
    log "s6-overlay → LINUXSERVER MODE"
fi

# Force container mode for linuxserver (Hub BuildKit may not set /.dockerenv)
if [ "${LINUXSERVER_MODE}" = "true" ] && [ "${CONTAINER_MODE}" = "false" ]; then
    CONTAINER_MODE=true
    log "v5.3: LINUXSERVER detected → forcing CONTAINER_MODE=true"
fi

[ "${CONTAINER_MODE}" = "false" ] && log "No container markers → BARE METAL"

ABC_HOME=$( [ "${LINUXSERVER_MODE}" = "true" ] && echo "/config" || echo "/home/abc" )
log "abc home: ${ABC_HOME} (RUNTIME only in linuxserver mode)"

export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# HELPERS
# =============================================================================

retry() {
    local ATTEMPTS="$1"; shift; local DELAY="$1"; shift; local TRY=1
    while [ "${TRY}" -le "${ATTEMPTS}" ]; do
        "$@" && return 0
        warn "Attempt ${TRY}/${ATTEMPTS} failed: $*"
        TRY=$((TRY + 1)); [ "${TRY}" -le "${ATTEMPTS}" ] && sleep "${DELAY}"
    done
    err "All ${ATTEMPTS} attempts failed: $*"; return 1
}

clear_dpkg_errors() {
    dpkg --configure --force-confold -a 2>/dev/null || true
    apt-get install -f -y 2>/dev/null || true
}

# =============================================================================
# STEP 0: PRE-FLIGHT — NAME_REGEX fix
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 0: Pre-flight — NAME_REGEX fix"
log "─────────────────────────────────────────────────────"

if [ -f /etc/adduser.conf ]; then
    sed -i '/^NAME_REGEX/d' /etc/adduser.conf 2>/dev/null || true
    echo 'NAME_REGEX="^[a-z_][-a-z0-9_]*\$?"' >> /etc/adduser.conf
else
    echo 'NAME_REGEX="^[a-z_][-a-z0-9_]*\$?"' > /etc/adduser.conf
fi

! getent group '_crd_network' >/dev/null 2>&1 && \
    addgroup --system '_crd_network' 2>/dev/null || true
! id '_crd_network' >/dev/null 2>&1 && \
    adduser --system --ingroup '_crd_network' --no-create-home '_crd_network' 2>/dev/null || true

ok "Pre-flight complete"

# =============================================================================
# STEP 1: BASE PACKAGES
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 1: Base packages"
log "─────────────────────────────────────────────────────"

retry 3 5 apt-get update -qq

retry 3 5 apt-get install -y \
    ssh wget curl nano git \
    ca-certificates apt-transport-https gnupg \
    zstd xz-utils software-properties-common \
    iputils-ping lsb-release \
    || warn "Some base packages failed"

ok "Base packages installed"

# =============================================================================
# STEP 2: CHROME REMOTE DESKTOP
# Installed but NOT an s6 service (user-configured post-deploy).
# CRD as an s6 service caused the docker.sock crash loop.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 2: Chrome Remote Desktop (user-configured post-deploy)"
log "─────────────────────────────────────────────────────"

if [ "${ARCH}" = "amd64" ]; then
    apt-get install -y --no-install-recommends \
        xvfb x11-xserver-utils xbase-clients \
        python3 python3-packaging python3-xdg psmisc xdg-utils \
        2>/dev/null || true

    CRD_DEB="/tmp/chrome-remote-desktop_current_amd64.deb"
    retry 3 10 wget -q --timeout=60 \
        "https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb" \
        -O "${CRD_DEB}" && ok "CRD downloaded" || warn "CRD download failed"

    if [ -f "${CRD_DEB}" ] && [ -s "${CRD_DEB}" ]; then
        dpkg --force-bad-name --force-depends --force-confold -i "${CRD_DEB}" 2>/dev/null || true
        apt-get install -f -y 2>/dev/null || true
        dpkg --configure --force-confold -a 2>/dev/null || true
        apt-get install -f -y 2>/dev/null || true
        if dpkg -l chrome-remote-desktop 2>/dev/null | grep -q "^iF"; then
            warn "CRD postinst still failing — purging to prevent cascade"
            dpkg --purge --force-all chrome-remote-desktop 2>/dev/null || true
            clear_dpkg_errors
        else
            ok "Chrome Remote Desktop installed (NOT an s6 service — user-configured post-deploy)"
        fi
        rm -f "${CRD_DEB}"
    fi
else
    warn "CRD amd64 only — skipped on ${ARCH}"
fi

# =============================================================================
# STEP 3: GITHUB DESKTOP
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 3: GitHub Desktop"
log "─────────────────────────────────────────────────────"

GH_DESKTOP_OK=false

retry 2 5 bash -c '
    wget -qO - https://apt.packages.shiftkey.dev/gpg.key 2>/dev/null \
        | gpg --dearmor | tee /usr/share/keyrings/shiftkey-packages.gpg > /dev/null \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/shiftkey-packages.gpg] https://apt.packages.shiftkey.dev/ubuntu/ any main" \
        > /etc/apt/sources.list.d/shiftkey-packages.list \
    && apt-get update -qq && apt-get install -y github-desktop
' && GH_DESKTOP_OK=true && ok "GitHub Desktop via shiftkey APT" || true

if [ "${GH_DESKTOP_OK}" = "false" ] && [ "${ARCH}" = "amd64" ]; then
    for GH_VER in "3.4.3-linux1" "3.3.9-linux1" "3.3.8-linux1"; do
        GH_URL="https://github.com/shiftkey/desktop/releases/download/release-${GH_VER}/GitHubDesktop-linux-amd64-${GH_VER}.deb"
        wget -q --timeout=60 "${GH_URL}" -O /tmp/github-desktop.deb 2>/dev/null \
            && [ -s /tmp/github-desktop.deb ] \
            && dpkg --force-bad-name --force-depends -i /tmp/github-desktop.deb 2>/dev/null \
            && clear_dpkg_errors \
            && GH_DESKTOP_OK=true && ok "GitHub Desktop v${GH_VER}" && break \
            || warn "GH Desktop ${GH_VER} failed"
        rm -f /tmp/github-desktop.deb
    done
fi

[ "${GH_DESKTOP_OK}" = "false" ] && warn "GitHub Desktop not installed (non-fatal)"

# =============================================================================
# STEP 4: GITKRAKEN
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 4: GitKraken"
log "─────────────────────────────────────────────────────"

if [ "${ARCH}" = "amd64" ]; then
    retry 3 8 wget -q --timeout=60 \
        "https://release.gitkraken.com/linux/gitkraken-amd64.deb" \
        -O /tmp/gitkraken-amd64.deb && ok "GitKraken downloaded" || warn "GitKraken download failed"
    if [ -f /tmp/gitkraken-amd64.deb ] && [ -s /tmp/gitkraken-amd64.deb ]; then
        dpkg -i /tmp/gitkraken-amd64.deb 2>/dev/null || true
        clear_dpkg_errors; ok "GitKraken installed"
        rm -f /tmp/gitkraken-amd64.deb
    fi
fi

# =============================================================================
# STEP 5: KVM / QEMU / VIRT-MANAGER — PACKAGES ONLY, NO DAEMONS STARTED
# libvirtd and virtlogd are s6 services (defined in Dockerfile LAYER 4).
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 5: KVM + QEMU + virt-manager (packages only)"
log "─────────────────────────────────────────────────────"

apt-get install -y \
    qemu-kvm qemu-system qemu-system-x86 cpu-checker \
    virt-manager libvirt-daemon-system libvirt-clients \
    bridge-utils ovmf 2>/dev/null || \
apt-get install -y \
    qemu-system-x86 qemu-system cpu-checker \
    virt-manager libvirt-daemon-system libvirt-clients \
    bridge-utils ovmf 2>/dev/null || \
warn "KVM/QEMU install had errors — best-effort"

clear_dpkg_errors
usermod -aG kvm abc 2>/dev/null || true
usermod -aG libvirt abc 2>/dev/null || true

# /dev/kvm is a RUNTIME device — only available with --privileged -v /dev:/dev
[ -e /dev/kvm ] && VIRT_TIER="1-kvm" || VIRT_TIER="2-tcg"
log "  KVM tier at build time: ${VIRT_TIER} (Tier 1 activates at runtime)"
ok "KVM/QEMU packages installed (s6 starts libvirtd/virtlogd at container boot)"

# =============================================================================
# STEP 6: OLLAMA — INSTALLED ONLY, NOT STARTED
# s6 service in Dockerfile LAYER 4 runs "ollama serve" at container boot.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 6: Ollama (installed — s6 starts it at runtime)"
log "─────────────────────────────────────────────────────"

command -v ollama >/dev/null 2>&1 && ok "Ollama already installed" || \
    retry 3 10 bash -c 'curl -fsSL https://ollama.com/install.sh | sh' \
        && ok "Ollama installed" \
        || warn "Ollama install failed"

clear_dpkg_errors
ok "Ollama ready (s6 starts it at container boot → localhost:11434)"

# =============================================================================
# STEP 7: CREATIVE SUITE
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 7: Creative Suite"
log "─────────────────────────────────────────────────────"

retry 3 5 apt-get install -y libreoffice \
    && ok "LibreOffice installed" || warn "LibreOffice failed"
clear_dpkg_errors

add-apt-repository -y ppa:obsproject/obs-studio 2>/dev/null || true
apt-get update -qq 2>/dev/null || true
retry 3 5 apt-get install -y obs-studio \
    && ok "OBS Studio installed" || warn "OBS Studio failed"
clear_dpkg_errors

retry 3 5 apt-get install -y blender \
    && ok "Blender installed" \
    || { snap install blender --classic 2>/dev/null && ok "Blender via snap" \
        || warn "Blender failed"; }
clear_dpkg_errors

retry 3 5 apt-get install -y inkscape gimp audacity kdenlive \
    && ok "Inkscape, GIMP, Audacity, Kdenlive installed" || warn "Some creative tools failed"
clear_dpkg_errors

ok "Creative suite complete"

# =============================================================================
# STEP 8: VISUAL STUDIO CODE — 4-method fallback
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 8: Visual Studio Code"
log "─────────────────────────────────────────────────────"

if command -v code >/dev/null 2>&1; then
    ok "VS Code already installed"
else
    VSCODE_OK=false

    # Method 1: Microsoft APT repo (canonical)
    if [ "${VSCODE_OK}" = "false" ]; then
        wget -qO- --timeout=30 https://packages.microsoft.com/keys/microsoft.asc \
                | gpg --dearmor > /tmp/packages.microsoft.gpg 2>/dev/null \
            && install -o root -g root -m 644 /tmp/packages.microsoft.gpg \
                /etc/apt/trusted.gpg.d/ \
            && sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list' \
            && apt-get update -qq 2>/dev/null \
            && apt-get install -y code \
            && VSCODE_OK=true && ok "VS Code via Microsoft APT" \
            || warn "Microsoft APT method failed"
        rm -f /tmp/packages.microsoft.gpg
    fi

    # Method 2: curl key
    if [ "${VSCODE_OK}" = "false" ]; then
        curl -fsSL --retry 3 https://packages.microsoft.com/keys/microsoft.asc \
                | gpg --dearmor > /etc/apt/trusted.gpg.d/packages.microsoft.gpg 2>/dev/null \
            && echo "deb [arch=amd64,arm64,armhf] https://packages.microsoft.com/repos/vscode stable main" \
                > /etc/apt/sources.list.d/vscode.list \
            && apt-get update -qq 2>/dev/null \
            && apt-get install -y code \
            && VSCODE_OK=true && ok "VS Code via curl key" \
            || warn "curl key method failed"
    fi

    # Method 3: GitHub script
    if [ "${VSCODE_OK}" = "false" ]; then
        retry 2 5 wget -q --timeout=60 \
            "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/refs/heads/main/visual-studio-code.sh" \
            -O /tmp/vscode-install.sh \
            && DEBIAN_FRONTEND=noninteractive bash /tmp/vscode-install.sh \
            && VSCODE_OK=true && ok "VS Code via GitHub script" \
            || warn "GitHub script method failed"
        rm -f /tmp/vscode-install.sh
    fi

    # Method 4: Direct .deb
    if [ "${VSCODE_OK}" = "false" ] && [ "${ARCH}" = "amd64" ]; then
        curl -fsSL --retry 3 --max-time 120 \
            -o /tmp/vscode.deb \
            "https://update.code.visualstudio.com/latest/linux-deb-x64/stable" 2>/dev/null \
            && [ -s /tmp/vscode.deb ] \
            && dpkg -i /tmp/vscode.deb 2>/dev/null && clear_dpkg_errors \
            && VSCODE_OK=true && ok "VS Code via direct .deb" \
            || warn "Direct .deb failed"
        rm -f /tmp/vscode.deb
    fi

    [ "${VSCODE_OK}" = "false" ] && warn "VS Code: all methods failed (non-fatal)"
fi

clear_dpkg_errors

# =============================================================================
# STEP 9: DESKTOP APPLICATIONS
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 9: Desktop apps"
log "─────────────────────────────────────────────────────"

retry 3 5 apt-get install -y terminator firefox gdebi plasma-discover \
    || warn "Some desktop apps failed"
clear_dpkg_errors
ok "Desktop apps installed"

# =============================================================================
# STEP 10: DEVSECOPS CLI TOOLS
# NOTE: The appinator (nexus-devsecops-appinator.sh) is NOT called here.
# It installs docker tooling that may trigger dockerd inside the container.
# Run the appinator manually inside the running container if needed:
#   docker exec -it nexus-creator-vault bash
#   wget -q https://raw.githubusercontent.com/Underground-Ops/underground-nexus/refs/heads/main/Dagger%20CI/Scripts/nexus-devsecops-appinator.sh -O /tmp/appinator.sh && bash /tmp/appinator.sh
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 10: DevSecOps CLI tools (no appinator — run manually if needed)"
log "─────────────────────────────────────────────────────"

command -v dagger >/dev/null 2>&1 || \
    retry 2 5 bash -c 'curl -fsSL https://dl.dagger.io/dagger/install.sh | BIN_DIR=/usr/local/bin sh' \
        && ok "Dagger CI installed" || warn "Dagger failed"

if ! command -v zarf >/dev/null 2>&1; then
    ZARF_VER=$(curl -sIX HEAD https://github.com/zarf-dev/zarf/releases/latest \
        | grep -i '^location:' | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null || echo "")
    [ -n "${ZARF_VER}" ] && retry 3 5 curl -sL \
        "https://github.com/zarf-dev/zarf/releases/download/${ZARF_VER}/zarf_${ZARF_VER}_Linux_${ARCH}" \
        -o /usr/local/bin/zarf && chmod +x /usr/local/bin/zarf \
        && ok "Zarf ${ZARF_VER}" || warn "Zarf failed"
fi

if ! command -v k9s >/dev/null 2>&1; then
    K9S_VER=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4 2>/dev/null || echo "")
    [ -n "${K9S_VER}" ] && retry 3 5 curl -sL \
        "https://github.com/derailed/k9s/releases/download/${K9S_VER}/k9s_Linux_${ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin k9s 2>/dev/null \
        && ok "K9s ${K9S_VER}" || warn "K9s failed"
fi

command -v lazydocker >/dev/null 2>&1 || \
    retry 3 5 curl -fsSL \
        https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh \
        | DIR=/usr/local/bin bash 2>/dev/null \
        && ok "Lazydocker installed" || warn "Lazydocker failed"

ok "DevSecOps CLI tools complete"

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
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 12: User abc"
log "─────────────────────────────────────────────────────"

if [ "${LINUXSERVER_MODE}" = "true" ]; then
    log "Linuxserver: abc UID set at runtime via -e PUID=1000 -e PGID=1000"
else
    if ! id -u abc >/dev/null 2>&1; then
        useradd -m -u 1000 -d "${ABC_HOME}" -s /bin/bash abc 2>/dev/null \
            && ok "User abc created" || warn "useradd failed"
    fi
    mkdir -p "${ABC_HOME}"
fi

for GRP in sudo docker kvm libvirt; do
    getent group "${GRP}" >/dev/null 2>&1 && usermod -aG "${GRP}" abc 2>/dev/null || true
done

echo "abc:sovereign" | chpasswd 2>/dev/null || true
ok "Password: sovereign"

grep -q "abc ALL=(ALL) NOPASSWD: ALL" /etc/sudoers 2>/dev/null || \
    echo "abc ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
grep -q "www-data ALL=(ALL) NOPASSWD: ALL" /etc/sudoers 2>/dev/null || \
    echo "www-data ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
ok "Sudoers configured"

# =============================================================================
# STEP 13: /nexus-bucket + repo clone
# NOTE: Does NOT write to /config. That's handled at runtime by
# /custom-cont-init.d/01-nexus-setup.sh (in the Dockerfile).
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 13: /nexus-bucket"
log "─────────────────────────────────────────────────────"

mkdir -p /nexus-bucket
id abc >/dev/null 2>&1 && chown -R abc:abc /nexus-bucket || \
    chown -R 1000:1000 /nexus-bucket 2>/dev/null || true

if [ ! -d "/nexus-bucket/underground-nexus/.git" ]; then
    retry 3 10 git clone --depth=1 \
        https://github.com/Underground-Ops/underground-nexus.git \
        /nexus-bucket/underground-nexus \
        && ok "Underground Nexus repo cloned" \
        || warn "Clone failed — runtime init will retry"
else
    git -C /nexus-bucket/underground-nexus pull --rebase 2>/dev/null || true
    ok "Repo updated"
fi

id abc >/dev/null 2>&1 && chown -R abc:abc /nexus-bucket 2>/dev/null || \
    chown -R 1000:1000 /nexus-bucket 2>/dev/null || true

# =============================================================================
# STEP 14: WALLPAPERS (system-level — safe to write during build)
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 14: Wallpapers"
log "─────────────────────────────────────────────────────"

WALLPAPER_BASE="https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/Wallpapers"
WALLPAPER_DIR="/usr/share/wallpapers/KubuntuLight/contents/images"
mkdir -p "${WALLPAPER_DIR}" && cd "${WALLPAPER_DIR}" || true

retry 3 5 wget -q --timeout=60 "${WALLPAPER_BASE}/nexus0-sea-space-jelly-highres.jpg" \
    -O "1440x900.jpg" && ok "Highres wallpaper" || warn "Highres failed"
[ -f "1440x900.jpg" ] && for SIZE in 1280x800 1366x768 1600x1200 1680x1050 1920x1080 1920x1200 2560x1440; do
    rm -f "${SIZE}.jpg" "${SIZE}.png" 2>/dev/null; cp "1440x900.jpg" "${SIZE}.jpg"; done

retry 3 5 wget -q --timeout=60 "${WALLPAPER_BASE}/nexus0-sea-space-jelly.jpg" \
    -O "1280x1024.jpg" && ok "Standard wallpaper" || warn "Standard failed"
[ -f "1280x1024.jpg" ] && { rm -f "1024x768.jpg" "1024x768.png" 2>/dev/null; cp "1280x1024.jpg" "1024x768.jpg"; }

retry 3 5 wget -q --timeout=60 "${WALLPAPER_BASE}/nexus0-moon-jelly.jpg" \
    -O "1080x1920.jpg" && ok "Portrait wallpaper" || warn "Portrait failed"
[ -f "1080x1920.jpg" ] && for SIZE in 360x720 720x1440; do
    rm -f "${SIZE}.jpg" "${SIZE}.png" 2>/dev/null; cp "1080x1920.jpg" "${SIZE}.jpg"; done

rm -rf ./*.png 2>/dev/null || true
cd / || true
ok "Wallpapers installed"

# =============================================================================
# STEP 15: CONTROL PANEL HTML (system-level)
# Desktop copy happens at runtime via /custom-cont-init.d/01-nexus-setup.sh
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 15: Control panel HTML"
log "─────────────────────────────────────────────────────"

retry 3 5 wget -q --timeout=60 \
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/Production%20Artifacts/Wordpress/nexus-creator-vault/nexus-creator-vault-control-panel.html" \
    -O /nexus-creator-vault-control-panel.html \
    && ok "Control panel at /nexus-creator-vault-control-panel.html" \
    || warn "Control panel download failed"
log "  NOTE: Desktop copy deferred to runtime (/custom-cont-init.d)"

# =============================================================================
# STEP 16: BARE METAL MODE (only for non-linuxserver environments)
# In container/linuxserver mode: s6 registration is handled by the Dockerfile.
# This step only configures SDDM for genuine bare-metal deployments.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 16: Display mode"
log "─────────────────────────────────────────────────────"

if [ "${CONTAINER_MODE}" = "true" ]; then
    log "CONTAINER MODE: s6 services defined by Dockerfile — nothing to do here"
    log "  libvirtd, virtlogd, ollama registered in Dockerfile LAYER 4"
    log "  /config setup deferred to Dockerfile /custom-cont-init.d/"
    ok "Container mode complete — Dockerfile owns all s6 definitions"
else
    log "BARE METAL MODE — configuring SDDM auto-login"
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/autologin.conf << 'SDDMEOF'
[Autologin]
User=abc
Session=plasma
Relogin=false
SDDMEOF
    command -v systemctl >/dev/null 2>&1 && {
        systemctl enable sddm 2>/dev/null || true
        systemctl enable libvirtd 2>/dev/null || true
    }
    ok "SDDM auto-login configured"
fi

# =============================================================================
# STEP 17: FINAL CLEANUP
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 17: Final cleanup"
log "─────────────────────────────────────────────────────"

clear_dpkg_errors
apt-get upgrade -y --fix-broken 2>/dev/null || true
apt-get clean 2>/dev/null || true
rm -rf /var/lib/apt/lists/* 2>/dev/null || true

id abc >/dev/null 2>&1 && chown -R abc:abc /nexus-bucket 2>/dev/null || \
    chown -R 1000:1000 /nexus-bucket 2>/dev/null || true

[ "${LINUXSERVER_MODE}" = "false" ] && \
    [ -d /home/abc ] && chown -R abc:abc /home/abc 2>/dev/null || true

ok "Cleanup done"

# =============================================================================
# ARSENAL SUMMARY
# =============================================================================

log ""
log "═══════════════════════════════════════════════════"
log "nexus0.sh v5.3 COMPLETE — Pure Package Installer"
log "═══════════════════════════════════════════════════"
log "Mode:       $([ "${CONTAINER_MODE}" = "true" ] && echo "CONTAINER" || echo "BARE METAL")"
log "LinuxSrv:   ${LINUXSERVER_MODE}"
log "Arch:       ${ARCH}"
log "KVM tier:   ${VIRT_TIER} (Tier 1 activates at runtime with --privileged)"
log "Password:   sovereign"
log ""
log "INSTALLED ARSENAL:"
command -v code         >/dev/null 2>&1 && log "  ✓ VS Code"       || log "  ✗ VS Code"
command -v dagger       >/dev/null 2>&1 && log "  ✓ Dagger CI"     || log "  ✗ Dagger CI"
command -v zarf         >/dev/null 2>&1 && log "  ✓ Zarf"          || log "  ✗ Zarf"
command -v k9s          >/dev/null 2>&1 && log "  ✓ K9s"           || log "  ✗ K9s"
command -v lazydocker   >/dev/null 2>&1 && log "  ✓ Lazydocker"    || log "  ✗ Lazydocker"
command -v ollama       >/dev/null 2>&1 && log "  ✓ Ollama"        || log "  ✗ Ollama"
command -v blender      >/dev/null 2>&1 && log "  ✓ Blender"       || log "  ✗ Blender"
command -v obs          >/dev/null 2>&1 && log "  ✓ OBS Studio"    || log "  ✗ OBS Studio"
command -v libreoffice  >/dev/null 2>&1 && log "  ✓ LibreOffice"   || log "  ✗ LibreOffice"
command -v inkscape     >/dev/null 2>&1 && log "  ✓ Inkscape"      || log "  ✗ Inkscape"
command -v gimp         >/dev/null 2>&1 && log "  ✓ GIMP"          || log "  ✗ GIMP"
dpkg -l gitkraken >/dev/null 2>&1      && log "  ✓ GitKraken"     || log "  ✗ GitKraken"
dpkg -l github-desktop >/dev/null 2>&1 && log "  ✓ GitHub Desktop" || log "  ✗ GitHub Desktop"
[ -f /opt/google/chrome-remote-desktop/chrome-remote-desktop ] \
    && log "  ✓ Chrome RDP (user-configured post-deploy)" \
    || log "  ✗ Chrome RDP"
command -v virt-manager >/dev/null 2>&1 && log "  ✓ Virt Manager"  || log "  ✗ Virt Manager"
log ""
log "s6 SERVICES (defined in Dockerfile, started at container boot):"
log "  ✓ libvirtd + virtlogd (VM stack)"
log "  ✓ ollama (LLM at localhost:11434)"
log "  ✗ CRD — NOT s6 (user-configured post-deploy)"
log "  ✗ dockerd — NEVER inside container"
log ""
log "RUNTIME HOOK (/custom-cont-init.d/01-nexus-setup.sh):"
log "  Runs after /config exists → copies control panel to Desktop"
log "  Sets /nexus-bucket ownership, KVM permissions, git pull"
log ""
log "Full log: /tmp/nexus0-install.log"
log "═══════════════════════════════════════════════════"