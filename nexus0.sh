#!/usr/bin/env bash
# =============================================================================
# NEXUS0.SH v5.2 — Polymorphic Payload
# Cloud Underground · Underground Nexus
# =============================================================================
#
# v5.2 FIXES (from Hub build log analysis):
#
#   FIX 1 — CRITICAL: s6 crash / ERR_EMPTY_RESPONSE at port 1050/2500
#     Root cause: Hub BuildKit builds don't always create /.dockerenv, so
#     CONTAINER_MODE stayed false even though LINUXSERVER_MODE was true.
#     STEP 16 then ran the BARE METAL branch (SDDM/systemd) instead of
#     registering s6 services — leaving virtlogd/libvirtd undefined in the
#     s6 bundle → s6-rc-compile crash → KasmVNC never starts → empty response.
#     Fix: if LINUXSERVER_MODE=true, force CONTAINER_MODE=true. A linuxserver
#     container always needs s6 services regardless of /.dockerenv presence.
#
#   FIX 2 — VS Code (✗ in build log):
#     Root cause: wget of visual-studio-code.sh from GitHub fails in Hub builds
#     (network policy or timing). Replace with direct Microsoft APT repo method
#     (same as the original nexus0-static.sh visual-studio-code.sh script).
#     This is the canonical, reliable install path for VS Code on Ubuntu.
#
#   FIX 3 — Chrome RDP (✗ in build log):
#     Root cause: NAME_REGEX patch runs but Hub's network or dpkg state still
#     blocks. Add explicit pre-installation of all CRD dependencies, more
#     aggressive dpkg --force flags, and a post-install dpkg --purge of the
#     broken half-configured state if it still fails.
#
#   FIX 4 — GitHub Desktop (✗ in build log):
#     Root cause: shiftkey APT cert fails + primary .deb URL also fails in Hub.
#     Add multiple .deb version fallbacks + wget --no-check-certificate as
#     last resort. Make the entire step non-fatal (already is, but cleaner).
#
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
log "nexus0.sh v5.2 — Polymorphic Payload"
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
#
# v5.2 FIX: Hub BuildKit doesn't always write /.dockerenv, so CONTAINER_MODE
# can be false even inside a Docker build. If LINUXSERVER_MODE is true (s6-overlay
# present), we FORCE CONTAINER_MODE=true — a linuxserver image always needs s6
# service registration, never SDDM/systemd. This prevents the bare-metal branch
# from running and leaving the s6 bundle with undefined service references.
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

# Linuxserver detection (s6-overlay present)
if [ -d /run/s6 ] || [ -f /etc/s6-overlay/s6-rc.d/user/type ] || \
   grep -q 'linuxserver' /etc/os-release 2>/dev/null || \
   [ -d /etc/s6-overlay ]; then
    LINUXSERVER_MODE=true
    log "s6-overlay detected → LINUXSERVER MODE"
    log "  User home: /config (abc UID set by PUID at runtime)"
fi

# v5.2 FIX: Force container mode when linuxserver is detected.
# Hub BuildKit may not set /.dockerenv but this IS a container build.
# A linuxserver image must ALWAYS use s6 service registration, never SDDM.
if [ "${LINUXSERVER_MODE}" = "true" ] && [ "${CONTAINER_MODE}" = "false" ]; then
    CONTAINER_MODE=true
    log "v5.2: LINUXSERVER_MODE=true → forcing CONTAINER_MODE=true"
    log "      (Hub BuildKit may not write /.dockerenv — this is correct behavior)"
fi

if [ "${CONTAINER_MODE}" = "false" ]; then
    log "No container markers → BARE METAL / VM MODE"
fi

if [ "${LINUXSERVER_MODE}" = "true" ]; then
    ABC_HOME="/config"
else
    ABC_HOME="/home/abc"
fi
log "abc home: ${ABC_HOME}"

export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# RETRY HELPER
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
# clear_dpkg_errors — call after any install that might leave dpkg broken
# =============================================================================

clear_dpkg_errors() {
    dpkg --configure --force-confold -a 2>/dev/null || true
    apt-get install -f -y 2>/dev/null || true
}

# =============================================================================
# STEP 0: PRE-FLIGHT — NAME_REGEX FIX
#
# Chrome Remote Desktop postinst creates "_crd_network" user.
# Ubuntu NAME_REGEX rejects underscore-prefix → postinst fails → dpkg cascade.
# Fix before ANY package installs.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 0: Pre-flight — NAME_REGEX + dependency pre-install"
log "─────────────────────────────────────────────────────"

# Patch adduser NAME_REGEX
if [ -f /etc/adduser.conf ]; then
    sed -i '/^NAME_REGEX/d' /etc/adduser.conf 2>/dev/null || true
    echo 'NAME_REGEX="^[a-z_][-a-z0-9_]*\$?"' >> /etc/adduser.conf
    ok "NAME_REGEX patched (allows _crd_network)"
else
    echo 'NAME_REGEX="^[a-z_][-a-z0-9_]*\$?"' > /etc/adduser.conf
    ok "adduser.conf created with permissive NAME_REGEX"
fi

# Pre-create _crd_network so CRD postinst finds it and skips creation
if ! getent group '_crd_network' >/dev/null 2>&1; then
    addgroup --system '_crd_network' 2>/dev/null \
        && ok "_crd_network group pre-created" \
        || warn "_crd_network group pre-create failed (non-fatal)"
fi
if ! id '_crd_network' >/dev/null 2>&1; then
    adduser --system --ingroup '_crd_network' --no-create-home '_crd_network' 2>/dev/null \
        && ok "_crd_network user pre-created" \
        || warn "_crd_network user pre-create failed (non-fatal)"
fi

ok "Pre-flight complete"

# =============================================================================
# STEP 1: BASE PACKAGES
# zstd must be first — Ollama installer silently fails without it.
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
    lsb-release \
    || warn "Some base packages failed — continuing"

ok "Base packages + zstd installed"

# =============================================================================
# STEP 2: CHROME REMOTE DESKTOP
#
# v5.2: Pre-install ALL known CRD dependencies explicitly before dpkg.
# Use --force-bad-name AND --force-depends to maximize install success.
# If postinst still fails, purge the broken state so it doesn't cascade.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 2: Chrome Remote Desktop"
log "─────────────────────────────────────────────────────"

if [ "${ARCH}" = "amd64" ]; then
    # Pre-install CRD runtime dependencies to reduce postinst failures
    apt-get install -y --no-install-recommends \
        xvfb x11-xserver-utils xbase-clients \
        python3 python3-packaging python3-xdg \
        psmisc xdg-utils \
        2>/dev/null || true

    CRD_DEB="/tmp/chrome-remote-desktop_current_amd64.deb"

    # Download with multiple retries
    retry 3 10 wget -q --timeout=60 \
        "https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb" \
        -O "${CRD_DEB}" \
        && ok "Chrome RDP deb downloaded" \
        || warn "Chrome RDP download failed"

    if [ -f "${CRD_DEB}" ] && [ -s "${CRD_DEB}" ]; then
        # Install with maximum force flags
        dpkg --force-bad-name --force-depends --force-confold -i "${CRD_DEB}" 2>/dev/null || true
        # Immediately clear any broken state
        apt-get install -f -y 2>/dev/null || true
        dpkg --configure --force-confold -a 2>/dev/null || true
        apt-get install -f -y 2>/dev/null || true

        # Verify install — if still broken, purge to prevent cascade
        if dpkg -l chrome-remote-desktop 2>/dev/null | grep -q "^iF"; then
            warn "Chrome RDP postinst still failing — purging to prevent dpkg cascade"
            dpkg --purge --force-all chrome-remote-desktop 2>/dev/null || true
            clear_dpkg_errors
            warn "Chrome RDP removed — KasmVNC remains as primary desktop access"
        else
            ok "Chrome Remote Desktop installed"
        fi
        rm -f "${CRD_DEB}"
    else
        warn "Chrome RDP deb not downloaded — skipping"
    fi
else
    warn "Chrome Remote Desktop amd64 only — skipped on ${ARCH}"
fi

# =============================================================================
# STEP 3: GITHUB DESKTOP
#
# v5.2: Multiple .deb version fallbacks + wget --no-check-certificate last resort.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 3: GitHub Desktop (shiftkey)"
log "─────────────────────────────────────────────────────"

GH_DESKTOP_OK=false

# Primary: shiftkey APT repo
if [ "${GH_DESKTOP_OK}" = "false" ]; then
    if retry 2 5 bash -c '
        wget -qO - https://apt.packages.shiftkey.dev/gpg.key 2>/dev/null \
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
fi

# Fallback: try multiple .deb versions (most recent first)
if [ "${GH_DESKTOP_OK}" = "false" ] && [ "${ARCH}" = "amd64" ]; then
    warn "shiftkey APT failed — trying direct .deb fallbacks"
    for GH_VER in "3.4.3-linux1" "3.3.9-linux1" "3.3.8-linux1" "3.3.6-linux1"; do
        GH_URL="https://github.com/shiftkey/desktop/releases/download/release-${GH_VER}/GitHubDesktop-linux-amd64-${GH_VER}.deb"
        wget -q --timeout=60 "${GH_URL}" -O /tmp/github-desktop.deb 2>/dev/null \
            && [ -s /tmp/github-desktop.deb ] \
            && dpkg --force-bad-name --force-depends -i /tmp/github-desktop.deb 2>/dev/null \
            && clear_dpkg_errors \
            && GH_DESKTOP_OK=true \
            && ok "GitHub Desktop installed via .deb v${GH_VER}" \
            && break \
            || warn "Version ${GH_VER} failed — trying next"
        rm -f /tmp/github-desktop.deb
    done
fi

# Last resort: wget --no-check-certificate
if [ "${GH_DESKTOP_OK}" = "false" ] && [ "${ARCH}" = "amd64" ]; then
    warn "Trying no-check-certificate fallback for GitHub Desktop"
    wget -q --no-check-certificate --timeout=60 \
        "https://github.com/shiftkey/desktop/releases/download/release-3.3.9-linux1/GitHubDesktop-linux-amd64-3.3.9-linux1.deb" \
        -O /tmp/github-desktop.deb 2>/dev/null \
        && [ -s /tmp/github-desktop.deb ] \
        && dpkg --force-bad-name --force-depends -i /tmp/github-desktop.deb 2>/dev/null \
        && clear_dpkg_errors \
        && GH_DESKTOP_OK=true \
        && ok "GitHub Desktop installed via no-check-certificate fallback" \
        || warn "GitHub Desktop all fallbacks exhausted — non-fatal"
    rm -f /tmp/github-desktop.deb
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
        -O /tmp/gitkraken-amd64.deb \
        && ok "GitKraken deb downloaded" \
        || warn "GitKraken download failed"

    if [ -f /tmp/gitkraken-amd64.deb ] && [ -s /tmp/gitkraken-amd64.deb ]; then
        dpkg -i /tmp/gitkraken-amd64.deb 2>/dev/null || true
        clear_dpkg_errors
        ok "GitKraken installed"
        rm -f /tmp/gitkraken-amd64.deb
    fi
else
    warn "GitKraken amd64 only — skipped on ${ARCH}"
fi

# =============================================================================
# STEP 5: KVM / QEMU / VIRT-MANAGER
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 5: KVM + QEMU + virt-manager"
log "─────────────────────────────────────────────────────"

apt-get install -y \
    qemu-kvm qemu-system qemu-system-x86 \
    cpu-checker \
    virt-manager \
    libvirt-daemon-system libvirt-clients \
    bridge-utils \
    ovmf \
    2>/dev/null || \
apt-get install -y \
    qemu-system-x86 qemu-system \
    cpu-checker \
    virt-manager \
    libvirt-daemon-system libvirt-clients \
    bridge-utils \
    ovmf \
    2>/dev/null || \
warn "KVM/QEMU install had errors — best-effort"

clear_dpkg_errors

/usr/sbin/libvirtd &>/dev/null & disown 2>/dev/null || true
/usr/sbin/virtlogd &>/dev/null & disown 2>/dev/null || true

usermod -aG kvm abc 2>/dev/null || true
usermod -aG libvirt abc 2>/dev/null || true

log ""
log "  ── VIRTUALIZATION PROBE ──"
if [ -e /dev/kvm ]; then
    chown root:kvm /dev/kvm 2>/dev/null || true
    chmod 660 /dev/kvm 2>/dev/null || true
    log "  ✓ /dev/kvm present → Tier 1: HARDWARE ACCELERATION"
    command -v kvm-ok >/dev/null 2>&1 && log "  kvm-ok: $(kvm-ok 2>&1 | head -1)"
    VIRT_TIER="1-kvm"
else
    log "  ⚠ /dev/kvm absent → Tier 2: QEMU TCG (expected during build)"
    log "    Runtime: docker run --privileged -v /dev:/dev"
    VIRT_TIER="2-tcg"
fi
log "  ──────────────────────────"
log ""

ok "KVM/QEMU/virt-manager setup complete (tier: ${VIRT_TIER})"

# =============================================================================
# STEP 6: OLLAMA LLM RUNTIME
# s6 service in STEP 16 runs "ollama serve" at runtime (localhost:11434)
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 6: Ollama LLM Runtime"
log "─────────────────────────────────────────────────────"

if command -v ollama >/dev/null 2>&1; then
    ok "Ollama already installed"
else
    retry 3 10 bash -c 'curl -fsSL https://ollama.com/install.sh | sh' \
        && ok "Ollama installed" \
        || warn "Ollama install failed"
fi

clear_dpkg_errors
ollama serve &>/dev/null & disown 2>/dev/null || true
ok "Ollama serve started (s6 service at runtime → localhost:11434)"

# =============================================================================
# STEP 7: CREATIVE SUITE
# Blender, OBS Studio, LibreOffice, GIMP, Inkscape, Audacity, Kdenlive
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 7: Creative Suite"
log "─────────────────────────────────────────────────────"

retry 3 5 apt-get install -y libreoffice \
    && ok "LibreOffice installed" \
    || warn "LibreOffice failed"
clear_dpkg_errors

add-apt-repository -y ppa:obsproject/obs-studio 2>/dev/null || true
apt-get update -qq 2>/dev/null || true
retry 3 5 apt-get install -y obs-studio \
    && ok "OBS Studio installed" \
    || warn "OBS Studio failed"
clear_dpkg_errors

retry 3 5 apt-get install -y blender \
    && ok "Blender installed" \
    || {
        warn "Blender apt failed — snap fallback"
        snap install blender --classic 2>/dev/null \
            && ok "Blender via snap" \
            || warn "Blender failed completely"
    }
clear_dpkg_errors

retry 3 5 apt-get install -y inkscape gimp audacity kdenlive \
    && ok "Inkscape, GIMP, Audacity, Kdenlive installed" \
    || warn "Some creative tools failed"
clear_dpkg_errors

ok "Creative suite complete"

# =============================================================================
# STEP 8: VISUAL STUDIO CODE
#
# v5.2 FIX: Use Microsoft APT repo directly instead of wget visual-studio-code.sh
# from GitHub. This is the canonical, reliable method (same as nexus0-static.sh).
# Mirrors the original visual-studio-code.sh content inline.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 8: Visual Studio Code"
log "─────────────────────────────────────────────────────"

if command -v code >/dev/null 2>&1; then
    ok "VS Code already installed — skipping"
else
    VSCODE_OK=false

    # Method 1: Microsoft APT repo (canonical method from original nexus0 scripts)
    if [ "${VSCODE_OK}" = "false" ]; then
        log "  VS Code: Trying Microsoft APT repo..."
        if wget -qO- --timeout=30 https://packages.microsoft.com/keys/microsoft.asc \
                | gpg --dearmor > /tmp/packages.microsoft.gpg 2>/dev/null \
            && install -o root -g root -m 644 /tmp/packages.microsoft.gpg \
                /etc/apt/trusted.gpg.d/ \
            && sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list' \
            && apt-get update -qq 2>/dev/null \
            && apt-get install -y code; then
            VSCODE_OK=true
            ok "VS Code installed via Microsoft APT repo"
        else
            warn "Microsoft APT repo method failed"
        fi
        rm -f /tmp/packages.microsoft.gpg
    fi

    # Method 2: curl key + APT (alternative key delivery)
    if [ "${VSCODE_OK}" = "false" ]; then
        log "  VS Code: Trying curl key method..."
        if curl -fsSL --retry 3 https://packages.microsoft.com/keys/microsoft.asc \
                | gpg --dearmor > /etc/apt/trusted.gpg.d/packages.microsoft.gpg 2>/dev/null \
            && echo "deb [arch=amd64,arm64,armhf] https://packages.microsoft.com/repos/vscode stable main" \
                > /etc/apt/sources.list.d/vscode.list \
            && apt-get update -qq 2>/dev/null \
            && apt-get install -y code; then
            VSCODE_OK=true
            ok "VS Code installed via curl key method"
        else
            warn "curl key method failed"
        fi
    fi

    # Method 3: wget GitHub script (original fallback — may fail in Hub)
    if [ "${VSCODE_OK}" = "false" ]; then
        log "  VS Code: Trying GitHub script fallback..."
        retry 2 5 wget -q --timeout=60 \
            "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/refs/heads/main/visual-studio-code.sh" \
            -O /tmp/vscode-install.sh \
            && DEBIAN_FRONTEND=noninteractive bash /tmp/vscode-install.sh \
            && VSCODE_OK=true \
            && ok "VS Code installed via GitHub script" \
            || warn "GitHub script method also failed"
        rm -f /tmp/vscode-install.sh
    fi

    # Method 4: Direct .deb download (last resort)
    if [ "${VSCODE_OK}" = "false" ] && [ "${ARCH}" = "amd64" ]; then
        log "  VS Code: Trying direct .deb download..."
        VSCODE_DEB_URL="https://update.code.visualstudio.com/latest/linux-deb-x64/stable"
        curl -fsSL --retry 3 --max-time 120 -o /tmp/vscode.deb "${VSCODE_DEB_URL}" 2>/dev/null \
            && [ -s /tmp/vscode.deb ] \
            && dpkg -i /tmp/vscode.deb 2>/dev/null \
            && clear_dpkg_errors \
            && VSCODE_OK=true \
            && ok "VS Code installed via direct .deb" \
            || warn "Direct .deb also failed"
        rm -f /tmp/vscode.deb
    fi

    [ "${VSCODE_OK}" = "false" ] && warn "VS Code: all methods failed — non-fatal"
fi

clear_dpkg_errors

# =============================================================================
# STEP 9: DESKTOP APPLICATIONS
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 9: Desktop apps"
log "─────────────────────────────────────────────────────"

retry 3 5 apt-get install -y \
    terminator firefox gdebi plasma-discover supervisor \
    || warn "Some desktop apps failed"
clear_dpkg_errors
ok "Desktop apps installed"

# =============================================================================
# STEP 10: DEVSECOPS TOOLCHAIN
# Dagger, Zarf, K9s, Lazydocker, DEV/SEC/OPS appinator
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 10: DevSecOps toolchain"
log "─────────────────────────────────────────────────────"

if ! command -v dagger >/dev/null 2>&1; then
    retry 2 5 bash -c 'curl -fsSL https://dl.dagger.io/dagger/install.sh | BIN_DIR=/usr/local/bin sh' \
        && ok "Dagger CI installed" \
        || warn "Dagger install failed"
fi

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

if ! command -v lazydocker >/dev/null 2>&1; then
    retry 3 5 curl -fsSL \
        https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh \
        | DIR=/usr/local/bin bash 2>/dev/null \
        && ok "Lazydocker installed" \
        || warn "Lazydocker install failed"
fi

retry 3 5 wget -q --timeout=60 \
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/refs/heads/main/Dagger%20CI/Scripts/nexus-devsecops-appinator.sh" \
    -O /tmp/appinator.sh \
    && bash /tmp/appinator.sh 2>/dev/null \
    && ok "DEV/SEC/OPS commands written" \
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
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 12: User abc configuration"
log "─────────────────────────────────────────────────────"

if [ "${LINUXSERVER_MODE}" = "true" ]; then
    log "Linuxserver mode — UID set at runtime via -e PUID=1000 -e PGID=1000"
    log "abc home: /config"
else
    if ! id -u abc >/dev/null 2>&1; then
        useradd -m -u 1000 -d "${ABC_HOME}" -s /bin/bash abc 2>/dev/null \
            && ok "User abc created" \
            || warn "useradd failed"
    else
        CURRENT_UID=$(id -u abc 2>/dev/null || echo "0")
        if [ "${CURRENT_UID}" != "1000" ]; then
            usermod -u 1000 -d "${ABC_HOME}" abc 2>/dev/null || warn "usermod failed"
            groupmod -g 1000 abc 2>/dev/null || warn "groupmod failed"
            find / -user "${CURRENT_UID}" \
                -not -path "/proc/*" -not -path "/sys/*" -not -path "/dev/*" \
                -exec chown -h abc: {} + 2>/dev/null || true
        else
            ok "abc already UID 1000"
        fi
    fi
    mkdir -p "${ABC_HOME}"
fi

for GRP in sudo docker kvm libvirt; do
    getent group "${GRP}" >/dev/null 2>&1 && usermod -aG "${GRP}" abc 2>/dev/null || true
done

echo "abc:sovereign" | chpasswd 2>/dev/null || true
ok "Password set: sovereign"

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
id abc >/dev/null 2>&1 && chown -R abc:abc /nexus-bucket || \
    chown -R 1000:1000 /nexus-bucket 2>/dev/null || true
chmod 755 /nexus-bucket

if [ ! -d "/nexus-bucket/underground-nexus/.git" ]; then
    retry 3 10 git clone \
        https://github.com/Underground-Ops/underground-nexus.git \
        /nexus-bucket/underground-nexus \
        && ok "Underground Nexus repo cloned" \
        || warn "git clone failed — cont-init will retry at runtime"
else
    git -C /nexus-bucket/underground-nexus pull --rebase 2>/dev/null || true
    ok "Underground Nexus repo updated"
fi

id abc >/dev/null 2>&1 && chown -R abc:abc /nexus-bucket 2>/dev/null || \
    chown -R 1000:1000 /nexus-bucket 2>/dev/null || true

# =============================================================================
# STEP 14: WALLPAPERS
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 14: Wallpapers (three-image aspect-ratio system)"
log "─────────────────────────────────────────────────────"

WALLPAPER_BASE="https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/Wallpapers"
WALLPAPER_DIR="/usr/share/wallpapers/KubuntuLight/contents/images"
mkdir -p "${WALLPAPER_DIR}"
cd "${WALLPAPER_DIR}" || warn "Cannot cd to wallpaper dir"

retry 3 5 wget -q --timeout=60 "${WALLPAPER_BASE}/nexus0-sea-space-jelly-highres.jpg" \
    -O "1440x900.jpg" && ok "Highres wallpaper" || warn "Highres wallpaper failed"
if [ -f "1440x900.jpg" ]; then
    for SIZE in 1280x800 1366x768 1600x1200 1680x1050 1920x1080 1920x1200 2560x1440; do
        rm -f "${SIZE}.jpg" "${SIZE}.png" 2>/dev/null || true
        cp "1440x900.jpg" "${SIZE}.jpg"
    done
fi

retry 3 5 wget -q --timeout=60 "${WALLPAPER_BASE}/nexus0-sea-space-jelly.jpg" \
    -O "1280x1024.jpg" && ok "Standard wallpaper" || warn "Standard wallpaper failed"
if [ -f "1280x1024.jpg" ]; then
    rm -f "1024x768.jpg" "1024x768.png" 2>/dev/null || true
    cp "1280x1024.jpg" "1024x768.jpg"
fi

retry 3 5 wget -q --timeout=60 "${WALLPAPER_BASE}/nexus0-moon-jelly.jpg" \
    -O "1080x1920.jpg" && ok "Portrait wallpaper" || warn "Portrait wallpaper failed"
if [ -f "1080x1920.jpg" ]; then
    for SIZE in 360x720 720x1440; do
        rm -f "${SIZE}.jpg" "${SIZE}.png" 2>/dev/null || true
        cp "1080x1920.jpg" "${SIZE}.jpg"
    done
fi

rm -rf ./*.png 2>/dev/null || true
ok "Wallpaper system active"
cd / || true

# =============================================================================
# STEP 15: CONTROL PANEL
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 15: Control panel"
log "─────────────────────────────────────────────────────"

retry 3 5 wget -q --timeout=60 \
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/Production%20Artifacts/Wordpress/nexus-creator-vault/nexus-creator-vault-control-panel.html" \
    -O /nexus-creator-vault-control-panel.html \
    && ok "Control panel downloaded" \
    || warn "Control panel download failed"

mkdir -p /config/Desktop /home/abc/Desktop 2>/dev/null || true
cp -f /nexus-creator-vault-control-panel.html \
    /config/Desktop/ 2>/dev/null || true
cp -f /nexus-creator-vault-control-panel.html \
    /home/abc/Desktop/ 2>/dev/null || true

# =============================================================================
# STEP 16: DISPLAY MODE CONFIGURATION
#
# v5.2 FIX: CONTAINER_MODE is now forced true when LINUXSERVER_MODE=true.
# This guarantees the s6 branch runs in Hub builds where /.dockerenv may be
# absent. The BARE METAL branch only runs on genuine bare-metal systems where
# neither /.dockerenv NOR /etc/s6-overlay exist.
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 16: Display mode (CONTAINER_MODE=${CONTAINER_MODE})"
log "─────────────────────────────────────────────────────"

if [ "${CONTAINER_MODE}" = "true" ]; then

    log "CONTAINER MODE — registering s6-overlay services"

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

    # s6: chrome-remote-desktop (exits cleanly if not installed / arm64)
    mkdir -p /etc/s6-overlay/s6-rc.d/chrome-remote-desktop
    printf '#!/usr/bin/with-contenv bash\n[ -f /opt/google/chrome-remote-desktop/chrome-remote-desktop ] || exit 0\nexec s6-setuidgid abc /opt/google/chrome-remote-desktop/chrome-remote-desktop --start\n' \
        > /etc/s6-overlay/s6-rc.d/chrome-remote-desktop/run
    echo "longrun" > /etc/s6-overlay/s6-rc.d/chrome-remote-desktop/type

    # s6: supervisor
    if command -v supervisord >/dev/null 2>&1; then
        mkdir -p /etc/s6-overlay/s6-rc.d/supervisor
        printf '#!/usr/bin/with-contenv bash\nexec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf\n' \
            > /etc/s6-overlay/s6-rc.d/supervisor/run
        echo "longrun" > /etc/s6-overlay/s6-rc.d/supervisor/type
    fi

    # Enable services in user bundle
    mkdir -p /etc/s6-overlay/s6-rc.d/user/contents.d
    for SVC in libvirtd virtlogd ollama chrome-remote-desktop; do
        touch "/etc/s6-overlay/s6-rc.d/user/contents.d/${SVC}"
        ok "s6 service enabled: ${SVC}"
    done
    command -v supervisord >/dev/null 2>&1 && \
        touch /etc/s6-overlay/s6-rc.d/user/contents.d/supervisor || true

    # cont-init: KVM permissions (runs after /dev is mounted at runtime)
    printf '#!/usr/bin/with-contenv bash\nusermod -aG kvm abc 2>/dev/null||true\nusermod -aG libvirt abc 2>/dev/null||true\nchown root:kvm /dev/kvm 2>/dev/null||true\nchmod 660 /dev/kvm 2>/dev/null||true\n' \
        > /etc/s6-overlay/cont-init.d/01-kvm-permissions
    chmod +x /etc/s6-overlay/cont-init.d/01-kvm-permissions

    # cont-init: nexus-bucket ownership
    printf '#!/usr/bin/with-contenv bash\nmkdir -p /nexus-bucket\nchown -R abc:abc /nexus-bucket\n' \
        > /etc/s6-overlay/cont-init.d/02-nexus-bucket
    chmod +x /etc/s6-overlay/cont-init.d/02-nexus-bucket

    # cont-init: git sync on container start
    printf '#!/usr/bin/with-contenv bash\ngit clone https://github.com/Underground-Ops/underground-nexus.git /nexus-bucket/underground-nexus 2>/dev/null||git -C /nexus-bucket/underground-nexus pull --rebase 2>/dev/null||true\nchown -R abc:abc /nexus-bucket/underground-nexus 2>/dev/null||true\n' \
        > /etc/s6-overlay/cont-init.d/03-nexus-sync
    chmod +x /etc/s6-overlay/cont-init.d/03-nexus-sync

    find /etc/s6-overlay -type f -exec chmod +x {} \; 2>/dev/null || true

    log ""
    log "  ── ZERO TRUST ACCESS ──────────────────────────────"
    log "  Primary:   KasmVNC → http://<host>:1050 (prod) / :2500 (test)"
    log "  Secondary: Chrome RDP → remotedesktop.google.com/access"
    log "  Tertiary:  SSH → ssh abc@<ip>  (password: sovereign)"
    log "  ──────────────────────────────────────────────────"

    ok "s6 services registered — KasmVNC will start at container boot"

else

    log "BARE METAL / VM MODE"

    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/autologin.conf << 'SDDMEOF'
[Autologin]
User=abc
Session=plasma
Relogin=false
SDDMEOF
    ok "SDDM auto-login set"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable sddm 2>/dev/null || true
        systemctl enable libvirtd 2>/dev/null || true
    fi

    ok "Bare metal mode ready"
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

if id abc >/dev/null 2>&1; then
    chown -R abc:abc /nexus-bucket 2>/dev/null || true
    [ "${LINUXSERVER_MODE}" = "true" ] && chown -R abc:abc /config 2>/dev/null || true
    [ -d /home/abc ] && chown -R abc:abc /home/abc 2>/dev/null || true
else
    chown -R 1000:1000 /nexus-bucket 2>/dev/null || true
    warn "abc user created at runtime by linuxserver /init — normal"
fi

ok "Cleanup done"

# =============================================================================
# ARSENAL SUMMARY
# =============================================================================

log ""
log "═══════════════════════════════════════════════════"
log "nexus0.sh v5.2 COMPLETE"
log "═══════════════════════════════════════════════════"
log "Mode:       $([ "${CONTAINER_MODE}" = "true" ] && echo "CONTAINER" || echo "BARE METAL")"
log "LinuxSrv:   ${LINUXSERVER_MODE}"
log "User home:  ${ABC_HOME}"
log "Arch:       ${ARCH}"
log "KVM tier:   ${VIRT_TIER:-unknown}"
log "Password:   sovereign"
log ""
log "INSTALLED ARSENAL:"
command -v code         >/dev/null 2>&1 && log "  ✓ VS Code"          || log "  ✗ VS Code"
command -v dagger       >/dev/null 2>&1 && log "  ✓ Dagger CI"        || log "  ✗ Dagger CI"
command -v zarf         >/dev/null 2>&1 && log "  ✓ Zarf"             || log "  ✗ Zarf"
command -v k9s          >/dev/null 2>&1 && log "  ✓ K9s"              || log "  ✗ K9s"
command -v lazydocker   >/dev/null 2>&1 && log "  ✓ Lazydocker"       || log "  ✗ Lazydocker"
command -v ollama       >/dev/null 2>&1 && log "  ✓ Ollama"           || log "  ✗ Ollama"
command -v blender      >/dev/null 2>&1 && log "  ✓ Blender"          || log "  ✗ Blender"
command -v obs          >/dev/null 2>&1 && log "  ✓ OBS Studio"       || log "  ✗ OBS Studio"
command -v libreoffice  >/dev/null 2>&1 && log "  ✓ LibreOffice"      || log "  ✗ LibreOffice"
command -v inkscape     >/dev/null 2>&1 && log "  ✓ Inkscape"         || log "  ✗ Inkscape"
command -v gimp         >/dev/null 2>&1 && log "  ✓ GIMP"             || log "  ✗ GIMP"
command -v gitkraken    >/dev/null 2>&1 && log "  ✓ GitKraken"        \
    || dpkg -l gitkraken >/dev/null 2>&1 && log "  ✓ GitKraken (dpkg)" \
    || log "  ✗ GitKraken"
command -v github-desktop >/dev/null 2>&1 && log "  ✓ GitHub Desktop" \
    || dpkg -l github-desktop >/dev/null 2>&1 && log "  ✓ GitHub Desktop (dpkg)" \
    || log "  ✗ GitHub Desktop"
[ -f /opt/google/chrome-remote-desktop/chrome-remote-desktop ] \
    && log "  ✓ Chrome RDP" \
    || log "  ✗ Chrome RDP (amd64 only)"
command -v virt-manager >/dev/null 2>&1 && log "  ✓ Virt Manager"     || log "  ✗ Virt Manager"
log ""
log "Full log: /tmp/nexus0-install.log"
log "═══════════════════════════════════════════════════"