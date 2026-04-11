#!/usr/bin/env bash
# =============================================================================
# NEXUS0.SH v5.4 — Pure Package Installer + Runtime Hook Writer
# Cloud Underground · Underground Nexus
# =============================================================================
#
# v5.4 KEY CHANGE:
#   STEP 16 now writes /custom-cont-init.d/01-nexus-setup.sh AND s6 service
#   run/type files using printf (no heredocs, fully BuildKit-compatible).
#
#   The Dockerfile no longer contains any heredoc syntax. Everything that needs
#   to be written as a file is written here via printf in STEP 16.
#
# What this script does NOT do:
#   - No background daemons started during build (no libvirtd &, ollama &)
#   - No /config writes (doesn't exist until container start)
#   - No appinator (installs docker tooling that triggers dockerd inside container)
#
# Runtime flow after this script:
#   Container start → /init → PUID/PGID → /config created
#   → /custom-cont-init.d/01-nexus-setup.sh (Desktop, /nexus-bucket, KVM)
#   → s6 services: libvirtd, virtlogd, ollama
#   → KasmVNC → KDE Plasma at :3000
#
# =============================================================================

set -o pipefail

NX_LOG="/tmp/nexus0-install.log"
mkdir -p /tmp

log()  { echo "[nexus0] $*" | tee -a "${NX_LOG}"; }
ok()   { echo "[nexus0] ✓ $*" | tee -a "${NX_LOG}"; }
warn() { echo "[nexus0] ⚠ $*" | tee -a "${NX_LOG}"; }
err()  { echo "[nexus0] ✗ $*" | tee -a "${NX_LOG}" >&2; }

log "═══════════════════════════════════════════════════"
log "nexus0.sh v5.4 — Pure Package Installer"
log "Started: $(date)"
log "═══════════════════════════════════════════════════"

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "${ARCH}" in
    amd64|x86_64)  ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *)             warn "Unknown arch '${ARCH}' — defaulting to amd64"; ARCH="amd64" ;;
esac
log "Architecture: ${ARCH}"

CONTAINER_MODE=false
LINUXSERVER_MODE=false

[ -f /.dockerenv ] && { CONTAINER_MODE=true; log "/.dockerenv → CONTAINER MODE"; }
grep -q 'container=' /proc/1/environ 2>/dev/null && { CONTAINER_MODE=true; log "PID1 environ → CONTAINER MODE"; }

if [ -d /run/s6 ] || [ -d /etc/s6-overlay ] || grep -q 'linuxserver' /etc/os-release 2>/dev/null; then
    LINUXSERVER_MODE=true
    log "s6-overlay → LINUXSERVER MODE"
fi

if [ "${LINUXSERVER_MODE}" = "true" ] && [ "${CONTAINER_MODE}" = "false" ]; then
    CONTAINER_MODE=true
    log "v5.4: LINUXSERVER detected → forcing CONTAINER_MODE=true"
fi

[ "${CONTAINER_MODE}" = "false" ] && log "No container markers → BARE METAL"

ABC_HOME=$( [ "${LINUXSERVER_MODE}" = "true" ] && echo "/config" || echo "/home/abc" )
log "abc home: ${ABC_HOME} (RUNTIME only in linuxserver mode)"

export DEBIAN_FRONTEND=noninteractive

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

log "STEP 0: Pre-flight — NAME_REGEX fix"

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

log "STEP 1: Base packages"

retry 3 5 apt-get update -qq

retry 3 5 apt-get install -y \
    ssh wget curl nano git \
    ca-certificates apt-transport-https gnupg \
    zstd xz-utils software-properties-common \
    iputils-ping lsb-release \
    || warn "Some base packages failed"

ok "Base packages installed"

# =============================================================================
# STEP 2: CHROME REMOTE DESKTOP (installed, NOT s6 service)
# =============================================================================

log "STEP 2: Chrome Remote Desktop"

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
            warn "CRD postinst failed — purging to prevent cascade"
            dpkg --purge --force-all chrome-remote-desktop 2>/dev/null || true
            clear_dpkg_errors
        else
            ok "Chrome Remote Desktop installed (NOT s6 service — user-configured post-deploy)"
        fi
        rm -f "${CRD_DEB}"
    fi
else
    warn "CRD amd64 only"
fi

# =============================================================================
# STEP 3: GITHUB DESKTOP
# =============================================================================

log "STEP 3: GitHub Desktop"

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

log "STEP 4: GitKraken"

if [ "${ARCH}" = "amd64" ]; then
    retry 3 8 wget -q --timeout=60 \
        "https://release.gitkraken.com/linux/gitkraken-amd64.deb" \
        -O /tmp/gitkraken-amd64.deb && ok "GitKraken downloaded" || warn "GitKraken failed"
    if [ -f /tmp/gitkraken-amd64.deb ] && [ -s /tmp/gitkraken-amd64.deb ]; then
        dpkg -i /tmp/gitkraken-amd64.deb 2>/dev/null || true
        clear_dpkg_errors; ok "GitKraken installed"
        rm -f /tmp/gitkraken-amd64.deb
    fi
fi

# =============================================================================
# STEP 5: KVM / QEMU / VIRT-MANAGER — PACKAGES ONLY
# =============================================================================

log "STEP 5: KVM + QEMU + virt-manager (packages only)"

apt-get install -y \
    qemu-kvm qemu-system qemu-system-x86 cpu-checker \
    virt-manager libvirt-daemon-system libvirt-clients \
    bridge-utils ovmf 2>/dev/null || \
apt-get install -y \
    qemu-system-x86 qemu-system cpu-checker \
    virt-manager libvirt-daemon-system libvirt-clients \
    bridge-utils ovmf 2>/dev/null || \
warn "KVM/QEMU install had errors"

clear_dpkg_errors
usermod -aG kvm abc 2>/dev/null || true
usermod -aG libvirt abc 2>/dev/null || true

[ -e /dev/kvm ] && VIRT_TIER="1-kvm" || VIRT_TIER="2-tcg"
log "  KVM tier at build: ${VIRT_TIER} (Tier 1 activates at runtime with --privileged)"
ok "KVM/QEMU packages installed"

# =============================================================================
# STEP 6: OLLAMA — INSTALLED ONLY
# =============================================================================

log "STEP 6: Ollama (installed — s6 service starts it at runtime)"

command -v ollama >/dev/null 2>&1 && ok "Ollama already installed" || \
    retry 3 10 bash -c 'curl -fsSL https://ollama.com/install.sh | sh' \
        && ok "Ollama installed" \
        || warn "Ollama install failed"

clear_dpkg_errors
ok "Ollama ready (s6 starts at container boot → localhost:11434)"

# =============================================================================
# STEP 7: CREATIVE SUITE
# =============================================================================

log "STEP 7: Creative Suite"

retry 3 5 apt-get install -y libreoffice && ok "LibreOffice" || warn "LibreOffice failed"
clear_dpkg_errors

add-apt-repository -y ppa:obsproject/obs-studio 2>/dev/null || true
apt-get update -qq 2>/dev/null || true
retry 3 5 apt-get install -y obs-studio && ok "OBS Studio" || warn "OBS Studio failed"
clear_dpkg_errors

retry 3 5 apt-get install -y blender && ok "Blender" \
    || { snap install blender --classic 2>/dev/null && ok "Blender via snap" || warn "Blender failed"; }
clear_dpkg_errors

retry 3 5 apt-get install -y inkscape gimp audacity kdenlive \
    && ok "Inkscape, GIMP, Audacity, Kdenlive" || warn "Some creative tools failed"
clear_dpkg_errors

ok "Creative suite complete"

# =============================================================================
# STEP 8: VISUAL STUDIO CODE — 4-method fallback
# =============================================================================

log "STEP 8: Visual Studio Code"

if command -v code >/dev/null 2>&1; then
    ok "VS Code already installed"
else
    VSCODE_OK=false

    if [ "${VSCODE_OK}" = "false" ]; then
        wget -qO- --timeout=30 https://packages.microsoft.com/keys/microsoft.asc \
                | gpg --dearmor > /tmp/packages.microsoft.gpg 2>/dev/null \
            && install -o root -g root -m 644 /tmp/packages.microsoft.gpg \
                /etc/apt/trusted.gpg.d/ \
            && sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list' \
            && apt-get update -qq 2>/dev/null \
            && apt-get install -y code \
            && VSCODE_OK=true && ok "VS Code via Microsoft APT" \
            || warn "Microsoft APT failed"
        rm -f /tmp/packages.microsoft.gpg
    fi

    if [ "${VSCODE_OK}" = "false" ]; then
        curl -fsSL --retry 3 https://packages.microsoft.com/keys/microsoft.asc \
                | gpg --dearmor > /etc/apt/trusted.gpg.d/packages.microsoft.gpg 2>/dev/null \
            && echo "deb [arch=amd64,arm64,armhf] https://packages.microsoft.com/repos/vscode stable main" \
                > /etc/apt/sources.list.d/vscode.list \
            && apt-get update -qq 2>/dev/null \
            && apt-get install -y code \
            && VSCODE_OK=true && ok "VS Code via curl key" \
            || warn "curl key failed"
    fi

    if [ "${VSCODE_OK}" = "false" ]; then
        retry 2 5 wget -q --timeout=60 \
            "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/refs/heads/main/visual-studio-code.sh" \
            -O /tmp/vscode-install.sh \
            && DEBIAN_FRONTEND=noninteractive bash /tmp/vscode-install.sh \
            && VSCODE_OK=true && ok "VS Code via GitHub script" \
            || warn "GitHub script failed"
        rm -f /tmp/vscode-install.sh
    fi

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

log "STEP 9: Desktop apps"

retry 3 5 apt-get install -y terminator firefox gdebi plasma-discover \
    || warn "Some desktop apps failed"
clear_dpkg_errors
ok "Desktop apps installed"

# =============================================================================
# STEP 10: DEVSECOPS CLI TOOLS (no appinator)
# =============================================================================

log "STEP 10: DevSecOps CLI tools"

command -v dagger >/dev/null 2>&1 || \
    retry 2 5 bash -c 'curl -fsSL https://dl.dagger.io/dagger/install.sh | BIN_DIR=/usr/local/bin sh' \
        && ok "Dagger CI" || warn "Dagger failed"

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
        && ok "Lazydocker" || warn "Lazydocker failed"

ok "DevSecOps CLI tools complete"

# =============================================================================
# STEP 11: SSH
# =============================================================================

log "STEP 11: SSH"
mkdir -p /var/run/sshd
service ssh enable 2>/dev/null || true
service ssh start 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true
ok "SSH configured"

# =============================================================================
# STEP 12: USER SETUP
# =============================================================================

log "STEP 12: User abc"

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
# STEP 13: /nexus-bucket
# =============================================================================

log "STEP 13: /nexus-bucket"

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
# STEP 14: WALLPAPERS
# =============================================================================

log "STEP 14: Wallpapers"

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
# STEP 15: CONTROL PANEL HTML
# =============================================================================

log "STEP 15: Control panel HTML"

retry 3 5 wget -q --timeout=60 \
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/Production%20Artifacts/Wordpress/nexus-creator-vault/nexus-creator-vault-control-panel.html" \
    -O /nexus-creator-vault-control-panel.html \
    && ok "Control panel at /nexus-creator-vault-control-panel.html" \
    || warn "Control panel download failed"
log "  Desktop copy deferred to runtime (/custom-cont-init.d/)"

# =============================================================================
# STEP 16: S6 SERVICE DEFINITIONS + /custom-cont-init.d RUNTIME HOOK
#
# v5.4: Uses printf only — NO heredocs. BuildKit-compatible.
#
# In CONTAINER+LINUXSERVER mode this step:
#   A) Writes /custom-cont-init.d/01-nexus-setup.sh — runs at container start
#      AFTER /config is created, BEFORE desktop. Handles /config/Desktop,
#      /nexus-bucket ownership, KVM permissions, git pull.
#   B) Writes s6 service run/type files for libvirtd, virtlogd, ollama.
#      Each service checks its binary exists before exec (graceful exit).
#
# In BARE METAL mode: configures SDDM auto-login.
# =============================================================================

log "STEP 16: s6 service definitions + runtime hook"

if [ "${CONTAINER_MODE}" = "true" ]; then

    log "CONTAINER MODE — writing s6 service run/type files and cont-init hook"

    # Create directories
    mkdir -p /etc/s6-overlay/s6-rc.d /etc/s6-overlay/cont-init.d /custom-cont-init.d

    # --- s6: libvirtd ---
    mkdir -p /etc/s6-overlay/s6-rc.d/libvirtd
    printf '#!/usr/bin/with-contenv bash\n[ -x /usr/sbin/libvirtd ] || { echo "[s6-libvirtd] not found"; exit 0; }\nexec /usr/sbin/libvirtd\n' \
        > /etc/s6-overlay/s6-rc.d/libvirtd/run
    printf 'longrun\n' > /etc/s6-overlay/s6-rc.d/libvirtd/type
    ok "s6 service defined: libvirtd"

    # --- s6: virtlogd ---
    mkdir -p /etc/s6-overlay/s6-rc.d/virtlogd
    printf '#!/usr/bin/with-contenv bash\n[ -x /usr/sbin/virtlogd ] || { echo "[s6-virtlogd] not found"; exit 0; }\nexec /usr/sbin/virtlogd\n' \
        > /etc/s6-overlay/s6-rc.d/virtlogd/run
    printf 'longrun\n' > /etc/s6-overlay/s6-rc.d/virtlogd/type
    ok "s6 service defined: virtlogd"

    # --- s6: ollama ---
    mkdir -p /etc/s6-overlay/s6-rc.d/ollama
    printf '#!/usr/bin/with-contenv bash\ncommand -v ollama >/dev/null 2>&1 || { echo "[s6-ollama] not found"; exit 0; }\nexec ollama serve\n' \
        > /etc/s6-overlay/s6-rc.d/ollama/run
    printf 'longrun\n' > /etc/s6-overlay/s6-rc.d/ollama/type
    ok "s6 service defined: ollama"

    # --- cont-init: KVM permissions (s6 legacy path) ---
    printf '#!/usr/bin/with-contenv bash\n[ -e /dev/kvm ] || exit 0\nchown root:kvm /dev/kvm 2>/dev/null||true\nchmod 660 /dev/kvm 2>/dev/null||true\nusermod -aG kvm abc 2>/dev/null||true\necho "[s6-init] KVM permissions set"\n' \
        > /etc/s6-overlay/cont-init.d/01-kvm-permissions
    chmod +x /etc/s6-overlay/cont-init.d/01-kvm-permissions

    # --- /custom-cont-init.d/01-nexus-setup.sh ---
    # This is the LINUXSERVER hook — runs AFTER /init creates /config.
    # Written using printf only (no heredoc) for BuildKit compatibility.
    printf '#!/usr/bin/with-contenv bash\n' \
        > /custom-cont-init.d/01-nexus-setup.sh
    printf '# Nexus Creator Vault runtime setup — runs after /config exists\n' \
        >> /custom-cont-init.d/01-nexus-setup.sh
    printf 'echo "[nexus-init] Nexus Creator Vault v5.4 runtime setup"\n' \
        >> /custom-cont-init.d/01-nexus-setup.sh
    printf 'mkdir -p /config/Desktop\n' \
        >> /custom-cont-init.d/01-nexus-setup.sh
    printf 'chown abc:abc /config/Desktop 2>/dev/null || chown 1000:1000 /config/Desktop || true\n' \
        >> /custom-cont-init.d/01-nexus-setup.sh
    printf 'echo "[nexus-init] /config/Desktop ready"\n' \
        >> /custom-cont-init.d/01-nexus-setup.sh
    printf '[ -f /nexus-creator-vault-control-panel.html ] && cp -f /nexus-creator-vault-control-panel.html /config/Desktop/ && chown abc:abc /config/Desktop/nexus-creator-vault-control-panel.html 2>/dev/null || true\n' \
        >> /custom-cont-init.d/01-nexus-setup.sh
    printf 'echo "[nexus-init] Control panel copied to Desktop"\n' \
        >> /custom-cont-init.d/01-nexus-setup.sh
    printf 'mkdir -p /nexus-bucket\n' \
        >> /custom-cont-init.d/01-nexus-setup.sh
    printf 'chown -R abc:abc /nexus-bucket 2>/dev/null || chown -R 1000:1000 /nexus-bucket || true\n' \
        >> /custom-cont-init.d/01-nexus-setup.sh
    printf '[ -e /dev/kvm ] && { chown root:kvm /dev/kvm 2>/dev/null||true; chmod 660 /dev/kvm 2>/dev/null||true; usermod -aG kvm abc 2>/dev/null||true; echo "[nexus-init] KVM Tier 1 active"; } || echo "[nexus-init] /dev/kvm absent (add --privileged for Tier 1)"\n' \
        >> /custom-cont-init.d/01-nexus-setup.sh
    printf 'usermod -aG libvirt abc 2>/dev/null || true\n' \
        >> /custom-cont-init.d/01-nexus-setup.sh
    printf '[ -d "/nexus-bucket/underground-nexus/.git" ] && git -C /nexus-bucket/underground-nexus pull --rebase 2>/dev/null || git clone --depth=1 https://github.com/Underground-Ops/underground-nexus.git /nexus-bucket/underground-nexus 2>/dev/null || true\n' \
        >> /custom-cont-init.d/01-nexus-setup.sh
    printf 'chown -R abc:abc /nexus-bucket 2>/dev/null || true\n' \
        >> /custom-cont-init.d/01-nexus-setup.sh
    printf 'echo "[nexus-init] Runtime setup complete"\n' \
        >> /custom-cont-init.d/01-nexus-setup.sh

    chmod +x /custom-cont-init.d/01-nexus-setup.sh
    ok "Runtime hook written: /custom-cont-init.d/01-nexus-setup.sh"

    find /etc/s6-overlay -type f -exec chmod +x {} \; 2>/dev/null || true

    log "  ── ZERO TRUST ACCESS ──"
    log "  Primary:   KasmVNC → http://<host>:1050 (prod) / :2500 (test)"
    log "  SSH:       ssh abc@<host>  (password: sovereign)"
    log "  CRD:       Manual setup post-deploy (NOT s6 service)"
    log "  ──────────────────────"

    ok "Container s6 services and runtime hook complete"

else

    log "BARE METAL MODE — configuring SDDM"
    mkdir -p /etc/sddm.conf.d
    printf '[Autologin]\nUser=abc\nSession=plasma\nRelogin=false\n' \
        > /etc/sddm.conf.d/autologin.conf
    command -v systemctl >/dev/null 2>&1 && {
        systemctl enable sddm 2>/dev/null || true
        systemctl enable libvirtd 2>/dev/null || true
    }
    ok "SDDM auto-login configured"
fi

# =============================================================================
# STEP 17: FINAL CLEANUP
# =============================================================================

log "STEP 17: Final cleanup"

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
log "nexus0.sh v5.4 COMPLETE"
log "═══════════════════════════════════════════════════"
log "Mode:       $([ "${CONTAINER_MODE}" = "true" ] && echo "CONTAINER" || echo "BARE METAL")"
log "LinuxSrv:   ${LINUXSERVER_MODE}"
log "Arch:       ${ARCH}"
log "KVM tier:   ${VIRT_TIER:-unknown}"
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
log "s6 SERVICES (started at container boot):"
log "  ✓ libvirtd  — /etc/s6-overlay/s6-rc.d/libvirtd/run"
log "  ✓ virtlogd  — /etc/s6-overlay/s6-rc.d/virtlogd/run"
log "  ✓ ollama    — /etc/s6-overlay/s6-rc.d/ollama/run"
log "  ✗ CRD       — NOT s6 (user-configured post-deploy)"
log ""
log "RUNTIME HOOK: /custom-cont-init.d/01-nexus-setup.sh"
log "  Runs after /config exists → Desktop, /nexus-bucket, KVM, git pull"
log ""
log "Full log: /tmp/nexus0-install.log"
log "═══════════════════════════════════════════════════"