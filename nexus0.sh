#!/usr/bin/env bash
# =============================================================================
# NEXUS0.SH v4 — Polymorphic Payload
# Cloud Underground · Underground Nexus
# =============================================================================
#
# WHAT THIS IS:
#   "Write once, run anywhere" bootstrap for the Underground Nexus ecosystem.
#   Works on: natoascode/nexus0 container, linuxserver/webtop containers,
#             custom Ubuntu/Debian KDE containers, bare-metal Ubuntu/Debian,
#             VMs, Kubernetes pods (DEV-metal ready).
#
# PHILOSOPHY: BULLDOZER.
#   Every tool installs unconditionally. Failures are logged and recovered.
#   Only the display mechanism (KasmVNC services vs SDDM) is conditional.
#   Self-repair loops wrap every critical install.
#
# VIRTUALIZATION INTELLIGENCE:
#   1. kvm-ok runs after KVM install to announce acceleration status
#   2. If /dev/kvm exists → native KVM virtualization (fast)
#   3. If /dev/kvm missing → QEMU falls back to TCG emulation (slow but works)
#   4. SR-IOV device detection is logged for hardware pass-through awareness
#   5. Container with --privileged -v /dev:/dev gets full KVM access
#
# ARCHITECTURE:
#   amd64: full arsenal (Chrome RDP, GitKraken, all tools)
#   arm64: everything except amd64-only debs (Chrome RDP, GitKraken)
#
# USER STANDARD: abc / UID 1000 / password: sovereign
#
# =============================================================================

# Strict pipe failures but NOT set -e — we manage errors manually
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
log "nexus0.sh v4 — Polymorphic Payload"
log "Started: $(date)"
log "═══════════════════════════════════════════════════"

# =============================================================================
# ARCHITECTURE DETECTION
# =============================================================================

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "${ARCH}" in
    amd64|x86_64)  ARCH="amd64"; ARCH_ALT="x86_64" ;;
    arm64|aarch64) ARCH="arm64"; ARCH_ALT="aarch64" ;;
    *)
        warn "Unknown architecture '${ARCH}' — defaulting to amd64"
        ARCH="amd64"; ARCH_ALT="x86_64"
        ;;
esac
log "Architecture: ${ARCH} / ${ARCH_ALT}"

# =============================================================================
# ENVIRONMENT DETECTION
# =============================================================================

CONTAINER_MODE=false
if [ -f /.dockerenv ]; then
    CONTAINER_MODE=true
    log "/.dockerenv detected → CONTAINER MODE"
elif grep -q 'container=' /proc/1/environ 2>/dev/null; then
    CONTAINER_MODE=true
    log "container= in PID1 environ → CONTAINER MODE"
elif grep -q 'lxc' /proc/1/environ 2>/dev/null; then
    CONTAINER_MODE=true
    log "lxc in PID1 environ → CONTAINER MODE"
else
    log "No container markers → BARE METAL / VM MODE"
fi

export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# RETRY HELPER
# =============================================================================
# retry <max_attempts> <delay_secs> <command...>

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
# STEP 1: BASE PACKAGES + PREREQUISITES
# =============================================================================
# zstd MUST be first — Ollama installer fails without it.

log "─────────────────────────────────────────────────────"
log "STEP 1: Base packages (zstd, curl, wget, git...)"
log "─────────────────────────────────────────────────────"

retry 3 5 apt-get update -qq

retry 3 5 apt-get install -y \
    ssh wget curl nano git \
    ca-certificates apt-transport-https gnupg \
    zstd xz-utils \
    software-properties-common \
    build-essential \
    iputils-ping \
    || warn "Some base packages failed — continuing"

ok "Base packages + zstd installed"

# =============================================================================
# STEP 2: CHROME REMOTE DESKTOP
# =============================================================================
# Primary zero-trust access. amd64 only (Google does not ship arm64 deb).
# On arm64 we skip gracefully — KasmVNC web UI is the primary access there.

log "─────────────────────────────────────────────────────"
log "STEP 2: Chrome Remote Desktop (amd64 only)"
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
    warn "Chrome Remote Desktop: amd64 only — skipped on ${ARCH}"
    warn "  Access on arm64 via KasmVNC (:3000) or SSH"
fi

# =============================================================================
# STEP 3: GITHUB DESKTOP
# =============================================================================
# Uses the shiftkey APT repository for Linux GitHub Desktop.
# The shiftkey repo has a TLS cert issue in some container/VPN environments.
# We fix this by adding the GPG key manually with --no-check-certificate
# as fallback, and keep the old direct .deb install as a second fallback.

log "─────────────────────────────────────────────────────"
log "STEP 3: GitHub Desktop (shiftkey repo)"
log "─────────────────────────────────────────────────────"

GITHUB_DESKTOP_OK=false

# Primary: shiftkey APT repo (official Linux GitHub Desktop)
if retry 2 5 bash -c \
    'wget -qO - https://apt.packages.shiftkey.dev/gpg.key \
        | gpg --dearmor \
        | tee /usr/share/keyrings/shiftkey-packages.gpg > /dev/null \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/shiftkey-packages.gpg] https://apt.packages.shiftkey.dev/ubuntu/ any main" \
        > /etc/apt/sources.list.d/shiftkey-packages.list \
    && apt-get update -qq \
    && apt-get install -y github-desktop'; then
    GITHUB_DESKTOP_OK=true
    ok "GitHub Desktop installed via shiftkey APT repo"
fi

# Fallback: direct .deb download (pinned known-good version)
if [ "${GITHUB_DESKTOP_OK}" = "false" ] && [ "${ARCH}" = "amd64" ]; then
    warn "Shiftkey repo failed — trying direct .deb fallback..."
    GH_DEB_URL="https://github.com/shiftkey/desktop/releases/download/release-3.3.9-linux1/GitHubDesktop-linux-amd64-3.3.9-linux1.deb"
    retry 3 5 wget -q "${GH_DEB_URL}" -O /tmp/github-desktop.deb \
        && dpkg -i /tmp/github-desktop.deb 2>/dev/null || true \
        && apt-get install -y -f 2>/dev/null || true \
        && GITHUB_DESKTOP_OK=true \
        && ok "GitHub Desktop installed via direct deb" \
        || warn "GitHub Desktop direct deb also failed — non-fatal"
fi

[ "${GITHUB_DESKTOP_OK}" = "false" ] && warn "GitHub Desktop not installed — can be installed manually"

# =============================================================================
# STEP 4: GITKRAKEN
# =============================================================================
# Visual Git client. amd64 deb only. arm64 has no official package.

log "─────────────────────────────────────────────────────"
log "STEP 4: GitKraken"
log "─────────────────────────────────────────────────────"

if [ "${ARCH}" = "amd64" ]; then
    KRAKEN_DEB="/tmp/gitkraken-amd64.deb"
    retry 3 8 wget -q \
        "https://release.gitkraken.com/linux/gitkraken-amd64.deb" \
        -O "${KRAKEN_DEB}" \
        && ok "GitKraken deb downloaded" \
        || warn "GitKraken download failed"

    if [ -f "${KRAKEN_DEB}" ]; then
        dpkg -i "${KRAKEN_DEB}" 2>/dev/null || true
        apt-get install -y -f 2>/dev/null || true
        apt-get upgrade -y --fix-broken 2>/dev/null || true
        ok "GitKraken installed"
    fi
else
    warn "GitKraken: amd64 deb only — skipped on ${ARCH}"
fi

# =============================================================================
# STEP 5: KVM / QEMU / VIRT-MANAGER + VIRTUALIZATION INTELLIGENCE
# =============================================================================
# Critical for the DEV-metal path and the VM-as-container paradigm.
# Always installs the full stack. Then probes what's actually available.
#
# Intelligence tier:
#   Tier 1 (best):  /dev/kvm present + hardware acceleration → native KVM
#   Tier 2 (ok):    /dev/kvm missing → QEMU TCG emulation (slower but works)
#   Tier 3 (bonus): SR-IOV VFs detected → hardware passthrough available
#
# Container with --privileged -v /dev:/dev hits Tier 1.
# Unprivileged container hits Tier 2 (emulation still works for VMs).

log "─────────────────────────────────────────────────────"
log "STEP 5: KVM + QEMU + virt-manager + virtualization probe"
log "─────────────────────────────────────────────────────"

retry 3 5 apt-get install -y \
    qemu-kvm qemu-system cpu-checker \
    virt-manager libvirt-daemon-system libvirt-clients \
    bridge-utils ovmf \
    || warn "KVM/QEMU packages had errors — continuing"

# Start libvirt daemons (background — expected to fail in unprivileged containers)
/usr/sbin/libvirtd &>/dev/null &  disown 2>/dev/null || true
/usr/sbin/virtlogd &>/dev/null &  disown 2>/dev/null || true

# Group membership
usermod -aG kvm abc 2>/dev/null || true
usermod -aG libvirt abc 2>/dev/null || true

log ""
log "--- VIRTUALIZATION PROBE ---"

# KVM hardware acceleration check
if [ -e /dev/kvm ]; then
    chown root:kvm /dev/kvm 2>/dev/null || true
    chmod 660 /dev/kvm 2>/dev/null || true
    log "✓ /dev/kvm present — hardware virtualization AVAILABLE"
    log "  KVM acceleration: ENABLED (Tier 1 — native speed)"

    # kvm-ok — announces to user whether acceleration works
    if command -v kvm-ok >/dev/null 2>&1; then
        KVM_OK_OUT=$(kvm-ok 2>&1 || true)
        log "  kvm-ok output: ${KVM_OK_OUT}"
    fi

    VIRT_MODE="kvm"
else
    log "⚠ /dev/kvm not present"
    log "  KVM acceleration: UNAVAILABLE"
    log "  Falling back to QEMU TCG emulation (Tier 2 — software emulation)"
    log "  To enable Tier 1: run container with --privileged and -v /dev:/dev"
    VIRT_MODE="tcg"
fi

# SR-IOV detection (Tier 3 — hardware passthrough probe)
SRIOV_DEVICES=$(find /sys/class/net -name "sriov_numvfs" 2>/dev/null || true)
if [ -n "${SRIOV_DEVICES}" ]; then
    log "✓ SR-IOV capable devices detected:"
    echo "${SRIOV_DEVICES}" | while read -r DEV; do
        NIC=$(echo "${DEV}" | sed 's|/sys/class/net/||;s|/sriov_numvfs||')
        VFS=$(cat "${DEV}" 2>/dev/null || echo "0")
        log "    ${NIC}: ${VFS} VFs active"
    done
    log "  SR-IOV passthrough available for bare-metal deployment"
else
    log "  SR-IOV: not detected (normal for containers and VMs)"
fi

# IOMMU check
IOMMU_GROUPS=$(ls /sys/kernel/iommu_groups/ 2>/dev/null | wc -l || echo "0")
if [ "${IOMMU_GROUPS}" -gt "0" ]; then
    log "✓ IOMMU active — ${IOMMU_GROUPS} IOMMU groups (GPU/device passthrough ready)"
else
    log "  IOMMU: not active (normal for containers)"
fi

log "  Virtualization mode: ${VIRT_MODE}"
log "--- END VIRTUALIZATION PROBE ---"

ok "KVM/QEMU/virt-manager setup done (mode: ${VIRT_MODE})"

# =============================================================================
# STEP 6: OLLAMA LLM RUNTIME
# =============================================================================
# Requires zstd (installed in Step 1). Background AI inference server.

log "─────────────────────────────────────────────────────"
log "STEP 6: Ollama LLM Runtime"
log "─────────────────────────────────────────────────────"

if command -v ollama >/dev/null 2>&1; then
    ok "Ollama already installed — skipping"
else
    retry 3 10 bash -c 'curl -fsSL https://ollama.com/install.sh | sh' \
        && ok "Ollama installed" \
        || warn "Ollama install failed — install manually: curl -fsSL https://ollama.com/install.sh | sh"
fi

apt-get install -y -f 2>/dev/null || true
ollama serve &>/dev/null & disown 2>/dev/null || true
ok "Ollama serve started in background (localhost:11434)"

# =============================================================================
# STEP 7: CREATIVE SUITE
# =============================================================================
# Blender, OBS Studio, LibreOffice — mandatory per requirements.
# Inkscape, GIMP, Audacity, Kdenlive also installed.

log "─────────────────────────────────────────────────────"
log "STEP 7: Creative Suite (Blender, OBS, LibreOffice...)"
log "─────────────────────────────────────────────────────"

# LibreOffice
retry 3 5 apt-get install -y libreoffice \
    && ok "LibreOffice installed" \
    || warn "LibreOffice install failed"

# Blender
retry 3 5 apt-get install -y blender \
    && ok "Blender installed" \
    || warn "Blender install failed — trying snap fallback..."
if ! command -v blender >/dev/null 2>&1; then
    snap install blender --classic 2>/dev/null \
        && ok "Blender installed via snap" \
        || warn "Blender snap also failed"
fi

# OBS Studio
if ! command -v obs >/dev/null 2>&1; then
    # Add OBS PPA for latest version
    add-apt-repository -y ppa:obsproject/obs-studio 2>/dev/null || true
    apt-get update -qq 2>/dev/null || true
    retry 3 5 apt-get install -y obs-studio \
        && ok "OBS Studio installed" \
        || warn "OBS Studio install failed"
fi

# Additional creative apps
retry 3 5 apt-get install -y \
    inkscape \
    gimp \
    audacity \
    kdenlive \
    || warn "Some creative apps failed — continuing"

ok "Creative suite installed"

# =============================================================================
# STEP 8: SSH
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 8: SSH"
log "─────────────────────────────────────────────────────"

mkdir -p /var/run/sshd
service ssh enable 2>/dev/null || true
service ssh start 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true
ok "SSH configured"

# =============================================================================
# STEP 9: VISUAL STUDIO CODE
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 9: Visual Studio Code"
log "─────────────────────────────────────────────────────"

if command -v code >/dev/null 2>&1; then
    ok "VS Code already installed — skipping"
else
    retry 3 5 wget -q \
        "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/refs/heads/main/visual-studio-code.sh" \
        -O /tmp/vscode-install.sh \
        && bash /tmp/vscode-install.sh 2>/dev/null \
        && ok "VS Code installed" \
        || warn "VS Code install failed"
    rm -f /tmp/vscode-install.sh
fi

# =============================================================================
# STEP 10: DEVSECOPS TOOLCHAIN
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 10: DevSecOps Toolchain (Dagger, Zarf, K9s, Lazydocker)"
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

# Lazydocker TUI
if ! command -v lazydocker >/dev/null 2>&1; then
    retry 3 5 curl -fsSL \
        https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh \
        | DIR=/usr/local/bin bash 2>/dev/null \
        && ok "Lazydocker installed" \
        || warn "Lazydocker install failed"
fi

# DEV/SEC/OPS appinator — writes DEV, SEC, OPS, DEV-rebuild etc to /usr/local/bin
retry 3 5 wget -q \
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/refs/heads/main/Dagger%20CI/Scripts/nexus-devsecops-appinator.sh" \
    -O /tmp/appinator.sh \
    && bash /tmp/appinator.sh 2>/dev/null \
    && ok "DEV/SEC/OPS commands written to /usr/local/bin" \
    || warn "Appinator failed — DEV/SEC/OPS commands may be missing"
rm -f /tmp/appinator.sh

ok "DevSecOps toolchain complete"

# =============================================================================
# STEP 11: TERMINATOR + FIREFOX + DESKTOP APPS
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 11: Desktop apps (Terminator, Firefox, gdebi...)"
log "─────────────────────────────────────────────────────"

retry 3 5 apt-get install -y \
    terminator \
    firefox \
    gdebi \
    plasma-discover \
    || warn "Some desktop apps failed — continuing"

ok "Desktop apps installed"

# =============================================================================
# STEP 12: USER ABC — UID ALIGNMENT
# =============================================================================
# linuxserver/webtop creates abc as UID 911.
# Sovereign grid standard is UID 1000. Enforce it here.

log "─────────────────────────────────────────────────────"
log "STEP 12: User abc UID alignment → sovereign standard 1000"
log "─────────────────────────────────────────────────────"

if ! id -u abc >/dev/null 2>&1; then
    useradd -m -u 1000 -s /bin/bash abc 2>/dev/null || true
    log "Created user abc (UID 1000)"
fi

CURRENT_UID=$(id -u abc 2>/dev/null || echo "0")

if [ "${CURRENT_UID}" != "1000" ]; then
    log "abc is UID ${CURRENT_UID} — correcting to 1000..."
    usermod -u 1000 abc 2>/dev/null || warn "usermod failed"
    groupmod -g 1000 abc 2>/dev/null || warn "groupmod failed"
    # Fix ownership of files owned by the old UID
    find / -user "${CURRENT_UID}" \
        -not -path "/proc/*" \
        -not -path "/sys/*" \
        -not -path "/dev/*" \
        -exec chown -h abc: {} + 2>/dev/null || true
    ok "abc UID corrected: ${CURRENT_UID} → 1000"
else
    ok "abc already UID 1000 — no change"
fi

# Group memberships
for GRP in sudo docker kvm libvirt; do
    getent group "${GRP}" >/dev/null 2>&1 && usermod -aG "${GRP}" abc 2>/dev/null || true
done

# Password
echo "abc:sovereign" | chpasswd 2>/dev/null || true
ok "Password: sovereign"

# Sudoers (idempotent)
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
log "STEP 13: /nexus-bucket filesystem + Underground Nexus repo"
log "─────────────────────────────────────────────────────"

mkdir -p /nexus-bucket
chown -R abc:abc /nexus-bucket
chmod 755 /nexus-bucket

if [ ! -d "/nexus-bucket/underground-nexus/.git" ]; then
    retry 3 10 git clone \
        https://github.com/Underground-Ops/underground-nexus.git \
        /nexus-bucket/underground-nexus \
        && ok "Underground Nexus repo cloned" \
        || warn "git clone failed — air-gap or network issue"
else
    git -C /nexus-bucket/underground-nexus pull --rebase 2>/dev/null || true
    ok "Underground Nexus repo updated"
fi

chown -R abc:abc /nexus-bucket 2>/dev/null || true

# =============================================================================
# STEP 14: WALLPAPERS — THREE-IMAGE ASPECT-RATIO SYSTEM
# =============================================================================
#
# This is the exact logic from the original nexus0.sh — preserved and improved.
#
# HOW IT WORKS:
#   KDE loads wallpaper by matching the desktop resolution to the closest
#   filename in the wallpaper directory. Three different images cover three
#   different aspect ratio families. The desktop wallpaper CHANGES
#   automatically when the window is resized or the screen rotates.
#
# THE THREE IMAGES:
#
#   nexus0-sea-space-jelly-highres.jpg (wide landscape — the main image)
#     Assigned to: 1440x900 (MASTER), then cp to:
#     1280x800, 1366x768, 1600x1200, 1680x1050,
#     1920x1080, 1920x1200, 2560x1440
#
#   nexus0-sea-space-jelly.jpg (standard/square variant — slightly different)
#     Assigned to: 1280x1024 (MASTER), then cp to:
#     1024x768
#
#   nexus0-moon-jelly.jpg (portrait — vertical/rotated screens)
#     Assigned to: 1080x1920 (MASTER), then cp to:
#     360x720, 720x1440
#
# rm -rf ./*.png → removes all default kubuntu PNG wallpapers so KDE
# picks our JPGs instead of defaulting to the kubuntu theme PNG.
#
# mkdir -p before cd → linuxserver/webtop may not ship KubuntuLight.
# We create the directory ourselves if needed.

log "─────────────────────────────────────────────────────"
log "STEP 14: Wallpapers (three-image aspect-ratio system)"
log "─────────────────────────────────────────────────────"

WALLPAPER_BASE="https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/Wallpapers"
WALLPAPER_DIR="/usr/share/wallpapers/KubuntuLight/contents/images"

mkdir -p "${WALLPAPER_DIR}"
cd "${WALLPAPER_DIR}" || { warn "Cannot cd to ${WALLPAPER_DIR}"; }

# IMAGE 1: nexus0-sea-space-jelly-highres.jpg → all widescreen landscape sizes
retry 3 5 wget -q "${WALLPAPER_BASE}/nexus0-sea-space-jelly-highres.jpg" \
    -O "1440x900.jpg" \
    && ok "sea-space-jelly-highres → 1440x900.jpg (master)" \
    || warn "sea-space-jelly-highres download failed"

if [ -f "1440x900.jpg" ]; then
    for SIZE in 1280x800 1366x768 1600x1200 1680x1050 1920x1080 1920x1200 2560x1440; do
        rm -f "${SIZE}.jpg" "${SIZE}.png" 2>/dev/null || true
        cp "1440x900.jpg" "${SIZE}.jpg"
    done
    ok "Widescreen sizes set (1280x800 → 2560x1440)"
fi

# IMAGE 2: nexus0-sea-space-jelly.jpg → standard/square sizes
retry 3 5 wget -q "${WALLPAPER_BASE}/nexus0-sea-space-jelly.jpg" \
    -O "1280x1024.jpg" \
    && ok "sea-space-jelly → 1280x1024.jpg (master)" \
    || warn "sea-space-jelly download failed"

if [ -f "1280x1024.jpg" ]; then
    rm -f "1024x768.jpg" "1024x768.png" 2>/dev/null || true
    cp "1280x1024.jpg" "1024x768.jpg"
    ok "Square sizes set (1280x1024, 1024x768)"
fi

# IMAGE 3: nexus0-moon-jelly.jpg → portrait/vertical sizes
retry 3 5 wget -q "${WALLPAPER_BASE}/nexus0-moon-jelly.jpg" \
    -O "1080x1920.jpg" \
    && ok "moon-jelly → 1080x1920.jpg (master)" \
    || warn "moon-jelly download failed"

if [ -f "1080x1920.jpg" ]; then
    for SIZE in 360x720 720x1440; do
        rm -f "${SIZE}.jpg" "${SIZE}.png" 2>/dev/null || true
        cp "1080x1920.jpg" "${SIZE}.jpg"
    done
    ok "Portrait sizes set (1080x1920, 360x720, 720x1440)"
fi

# Remove all default PNG wallpapers so our JPGs are selected
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
    && ok "Control panel saved to /nexus-creator-vault-control-panel.html" \
    || warn "Control panel download failed"

mkdir -p /config/Desktop /home/abc/Desktop 2>/dev/null || true
cp -f /nexus-creator-vault-control-panel.html \
    /config/Desktop/nexus-creator-vault-control-panel.html 2>/dev/null || true
cp -f /nexus-creator-vault-control-panel.html \
    /home/abc/Desktop/nexus-creator-vault-control-panel.html 2>/dev/null || true

# =============================================================================
# STEP 16: DISPLAY MODE — CONTAINER vs BARE METAL
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 16: Display mode configuration"
log "─────────────────────────────────────────────────────"

if [ "${CONTAINER_MODE}" = "true" ]; then

    log "═══════════════════════════════════════════════════"
    log "CONTAINER MODE — s6-overlay service registration"
    log "═══════════════════════════════════════════════════"

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

    # s6: chrome-remote-desktop (amd64 only — no-op gracefully on arm64)
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

    # Enable in user bundle
    mkdir -p /etc/s6-overlay/s6-rc.d/user/contents.d
    for SVC in libvirtd virtlogd ollama chrome-remote-desktop; do
        touch "/etc/s6-overlay/s6-rc.d/user/contents.d/${SVC}"
    done
    command -v supervisord >/dev/null 2>&1 && \
        touch /etc/s6-overlay/s6-rc.d/user/contents.d/supervisor || true

    # cont-init: KVM at start
    mkdir -p /etc/s6-overlay/cont-init.d
    printf '#!/usr/bin/with-contenv bash\nusermod -aG kvm abc 2>/dev/null||true\nusermod -aG libvirt abc 2>/dev/null||true\nchown root:kvm /dev/kvm 2>/dev/null||true\nchmod 660 /dev/kvm 2>/dev/null||true\n' \
        > /etc/s6-overlay/cont-init.d/01-kvm-permissions
    chmod +x /etc/s6-overlay/cont-init.d/01-kvm-permissions

    # cont-init: nexus-bucket
    printf '#!/usr/bin/with-contenv bash\nmkdir -p /nexus-bucket\nchown -R abc:abc /nexus-bucket\n' \
        > /etc/s6-overlay/cont-init.d/02-nexus-bucket
    chmod +x /etc/s6-overlay/cont-init.d/02-nexus-bucket

    # cont-init: git sync
    printf '#!/usr/bin/with-contenv bash\ngit clone https://github.com/Underground-Ops/underground-nexus.git /nexus-bucket/underground-nexus 2>/dev/null||git -C /nexus-bucket/underground-nexus pull --rebase 2>/dev/null||true\nchown -R abc:abc /nexus-bucket/underground-nexus 2>/dev/null||true\n' \
        > /etc/s6-overlay/cont-init.d/03-nexus-sync
    chmod +x /etc/s6-overlay/cont-init.d/03-nexus-sync

    find /etc/s6-overlay -type f -exec chmod +x {} \; 2>/dev/null || true

    log "─────────────────────────────────────────────────────"
    log "ZERO TRUST ACCESS — Chrome RDP (primary)"
    log "─────────────────────────────────────────────────────"
    log ""
    log "  FROM PORTAINER CONSOLE (or docker exec -it nexus-creator-vault bash):"
    log "    su - abc"
    log ""
    log "  GO TO: https://remotedesktop.google.com/headless"
    log "    Access my computer → Install via SSH → Authorize"
    log "    Copy the Linux auth string and paste it in the abc shell (NO sudo)"
    log ""
    log "    DISPLAY= /opt/google/chrome-remote-desktop/start-host \\"
    log "      --code=\"<YOUR-CODE>\" \\"
    log "      --redirect-url=\"https://remotedesktop.google.com/_/oauthredirect\" \\"
    log "      --name=\$(hostname)"
    log ""
    log "  ACCESS: https://remotedesktop.google.com/access"
    log "  SSH:    ssh abc@<container-ip>   password: sovereign"
    log "  KASMVNC: http://<host>:1050  (or :2500 if remapped)"
    log "─────────────────────────────────────────────────────"

    ok "Container Mode s6 services registered"

else

    log "═══════════════════════════════════════════════════"
    log "BARE METAL / VM MODE (DEV-metal path)"
    log "═══════════════════════════════════════════════════"

    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/autologin.conf << 'SDDMEOF'
[Autologin]
User=abc
Session=plasma
Relogin=false
SDDMEOF
    ok "SDDM auto-login configured (abc → plasma)"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable sddm 2>/dev/null || true
        systemctl enable docker 2>/dev/null || true
        systemctl start docker 2>/dev/null || true
        systemctl enable libvirtd 2>/dev/null || true
        systemctl start libvirtd 2>/dev/null || true
    fi

    # Docker Swarm + sovereign-net
    if docker info 2>/dev/null | grep -q "Swarm: inactive"; then
        PRIMARY_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || \
                     hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
        docker swarm init --advertise-addr "${PRIMARY_IP}" 2>/dev/null || true
        docker network create --driver overlay --attachable sovereign-net 2>/dev/null || true
        ok "Docker Swarm + sovereign-net ready"
    fi

    # First-boot systemd service
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

    # Desktop launchers for abc
    mkdir -p /home/abc/Desktop
    cat > /home/abc/Desktop/sovereign-installer.desktop << 'DEOF'
[Desktop Entry]
Type=Application
Name=Sovereign Installer
Exec=bash -c "sudo /usr/local/bin/sovereign-installer; read -p 'Press Enter...'"
Icon=utilities-terminal
Terminal=true
Categories=System;
DEOF
    chmod +x /home/abc/Desktop/sovereign-installer.desktop 2>/dev/null || true
    chown abc:abc /home/abc/Desktop/sovereign-installer.desktop 2>/dev/null || true

    ok "Bare Metal / DEV-metal mode ready"
fi

# =============================================================================
# STEP 17: FINAL PERMISSIONS
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 17: Final permissions"
log "─────────────────────────────────────────────────────"

chown -R abc:abc /nexus-bucket 2>/dev/null || true
chown -R abc:abc /config 2>/dev/null || true
[ -d /home/abc ] && chown -R abc:abc /home/abc 2>/dev/null || true

apt-get install -f -y 2>/dev/null || true
apt-get upgrade -y --fix-broken 2>/dev/null || true

ok "Final permissions set"

# =============================================================================
# ARSENAL SUMMARY
# =============================================================================

log ""
log "═══════════════════════════════════════════════════"
log "nexus0.sh v4 COMPLETE"
log "═══════════════════════════════════════════════════"
log "Mode:       $([ "${CONTAINER_MODE}" = "true" ] && echo "CONTAINER" || echo "BARE METAL")"
log "User:       abc (UID $(id -u abc 2>/dev/null || echo 1000))"
log "Arch:       ${ARCH}"
log "Virt:       ${VIRT_MODE:-unknown}"
log "Bucket:     /nexus-bucket"
log "Password:   sovereign"
log "Log:        ${NX_LOG}"
log ""
log "ARSENAL CHECK:"
command -v code          >/dev/null 2>&1 && log "  ✓ VS Code"            || log "  ✗ VS Code"
command -v dagger        >/dev/null 2>&1 && log "  ✓ Dagger CI"          || log "  ✗ Dagger CI"
command -v zarf          >/dev/null 2>&1 && log "  ✓ Zarf"               || log "  ✗ Zarf"
command -v k9s           >/dev/null 2>&1 && log "  ✓ K9s"                || log "  ✗ K9s"
command -v lazydocker    >/dev/null 2>&1 && log "  ✓ Lazydocker"         || log "  ✗ Lazydocker"
command -v ollama        >/dev/null 2>&1 && log "  ✓ Ollama"             || log "  ✗ Ollama"
command -v blender       >/dev/null 2>&1 && log "  ✓ Blender"            || log "  ✗ Blender"
command -v obs           >/dev/null 2>&1 && log "  ✓ OBS Studio"         || log "  ✗ OBS Studio"
command -v libreoffice   >/dev/null 2>&1 && log "  ✓ LibreOffice"        || log "  ✗ LibreOffice"
command -v inkscape      >/dev/null 2>&1 && log "  ✓ Inkscape"           || log "  ✗ Inkscape"
command -v gimp          >/dev/null 2>&1 && log "  ✓ GIMP"               || log "  ✗ GIMP"
command -v gitkraken     >/dev/null 2>&1 && log "  ✓ GitKraken"          || log "  ✗ GitKraken (check dpkg -l)"
command -v github-desktop >/dev/null 2>&1 && log "  ✓ GitHub Desktop"    || log "  ✗ GitHub Desktop"
[ -f /opt/google/chrome-remote-desktop/chrome-remote-desktop ] \
                                           && log "  ✓ Chrome RDP"        || log "  ✗ Chrome RDP (amd64 only)"
log ""
log "KVM status: ${VIRT_MODE:-probe failed}"
log "Full log: ${NX_LOG}"
log "═══════════════════════════════════════════════════"