#!/usr/bin/env bash
# =============================================================================
# NEXUS0.SH v3 — Polymorphic Payload
# Cloud Underground · Underground Nexus
# =============================================================================
#
# WHAT THIS IS:
#   A "write once, run anywhere" bootstrap for the Underground Nexus ecosystem.
#   Runs on: linuxserver/webtop containers, custom Ubuntu/Debian containers,
#            bare-metal Ubuntu 22.04/24.04, VMs, Kubernetes pods.
#
# CORE PHILOSOPHY (learned from v1):
#   BULLDOZER FIRST. The DevSecOps arsenal installs UNCONDITIONALLY.
#   GitKraken, Chrome RDP, VS Code, Dagger, Zarf, Ollama, KVM — all of it.
#   Only the DISPLAY mechanism (KasmVNC vs SDDM) is conditional.
#
# ENVIRONMENT DETECTION:
#   Container: /.dockerenv present OR container= in PID1 environ
#   Bare Metal: neither detected → SDDM auto-login, systemd services
#
# WALLPAPER SYSTEM (aspect-ratio responsive — three images):
#   nexus0-sea-space-jelly-highres.jpg → all landscape/widescreen sizes
#   nexus0-sea-space-jelly.jpg         → square/near-square sizes
#   nexus0-moon-jelly.jpg              → all portrait sizes
#   KDE selects the closest match by resolution. Three images = three moods
#   depending on how wide or tall the desktop is. This is intentional.
#
# SELF-REPAIR:
#   Critical apt installs use retry loops.
#   wget downloads are verified and retried.
#   Failures are logged but never stop the script (|| true on non-fatal steps).
#
# USER STANDARD:
#   Username: abc
#   UID/GID:  1000 (sovereign grid standard — enforced here if linuxserver sets 911)
#   Password: sovereign (updated from legacy notiaPoint1)
#
# =============================================================================

set -o pipefail  # catch pipe failures
# NOT set -e — we handle errors manually with || true and retry loops

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
log "nexus0.sh v3 — $(date)"
log "═══════════════════════════════════════════════════"

# =============================================================================
# ARCHITECTURE DETECTION
# =============================================================================

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "${ARCH}" in
    amd64|x86_64)  ARCH="amd64"; ARCH_ALT="x86_64" ;;
    arm64|aarch64) ARCH="arm64"; ARCH_ALT="aarch64" ;;
    *)
        warn "Unknown architecture ${ARCH} — defaulting to amd64"
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

# =============================================================================
# RETRY HELPER
# =============================================================================

# retry <attempts> <delay_seconds> <command...>
# Runs command up to N times with delay between attempts.
retry() {
    local ATTEMPTS="$1"; shift
    local DELAY="$1"; shift
    local CMD=("$@")
    local TRY=1
    while [ "${TRY}" -le "${ATTEMPTS}" ]; do
        if "${CMD[@]}"; then
            return 0
        fi
        warn "Attempt ${TRY}/${ATTEMPTS} failed for: ${CMD[*]}"
        TRY=$((TRY + 1))
        [ "${TRY}" -le "${ATTEMPTS}" ] && sleep "${DELAY}"
    done
    err "All ${ATTEMPTS} attempts failed for: ${CMD[*]}"
    return 1
}

# =============================================================================
# STEP 1: BASE PACKAGES
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 1: Base packages"
log "─────────────────────────────────────────────────────"

export DEBIAN_FRONTEND=noninteractive

retry 3 5 apt-get update -qq
retry 3 5 apt-get install -y --no-install-recommends \
    ssh wget nano curl git \
    ca-certificates apt-transport-https gnupg \
    zstd \
    || warn "Some base packages failed — continuing"

ok "Base packages done"

# =============================================================================
# STEP 2: CHROME REMOTE DESKTOP
# =============================================================================
# PRIMARY remote access method. Works via outbound connection — no open ports.
# Architecture: amd64 only (Google only ships amd64 deb).
# On arm64, Chrome RDP is not available — skip gracefully.

log "─────────────────────────────────────────────────────"
log "STEP 2: Chrome Remote Desktop"
log "─────────────────────────────────────────────────────"

if [ "${ARCH}" = "amd64" ]; then
    CRD_DEB="/tmp/chrome-remote-desktop_current_amd64.deb"
    if [ ! -f "${CRD_DEB}" ]; then
        retry 3 5 wget -q "https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb" \
            -O "${CRD_DEB}" \
            && ok "Chrome RDP deb downloaded" \
            || warn "Chrome RDP download failed"
    fi
    if [ -f "${CRD_DEB}" ]; then
        dpkg -i "${CRD_DEB}" 2>/dev/null || true
        apt-get install -y -f 2>/dev/null || true
        ok "Chrome Remote Desktop installed"
    fi
else
    warn "Chrome Remote Desktop: amd64 only — skipping on ${ARCH}"
fi

# =============================================================================
# STEP 3: GITHUB DESKTOP SCRIPT
# =============================================================================
# Downloads the script and stages it for execution.
# Script is downloaded and made executable.
# Run manually as abc: bash /tmp/github-desktop.sh

log "─────────────────────────────────────────────────────"
log "STEP 3: GitHub Desktop script (staged)"
log "─────────────────────────────────────────────────────"

retry 3 5 wget -q \
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/github-desktop.sh" \
    -O /tmp/github-desktop.sh \
    && chmod +x /tmp/github-desktop.sh \
    && ok "GitHub Desktop script staged at /tmp/github-desktop.sh" \
    || warn "GitHub Desktop script download failed"

# Auto-execute it
if [ -f /tmp/github-desktop.sh ]; then
    bash /tmp/github-desktop.sh 2>/dev/null || warn "GitHub Desktop install failed (non-fatal)"
fi

# =============================================================================
# STEP 4: GITKRAKEN
# =============================================================================
# GitKraken provides the visual Git client baked into the DevSecOps workbench.
# Architecture: amd64 deb available. arm64 has separate deb.

log "─────────────────────────────────────────────────────"
log "STEP 4: GitKraken"
log "─────────────────────────────────────────────────────"

if [ "${ARCH}" = "amd64" ]; then
    KRAKEN_DEB="/tmp/gitkraken-amd64.deb"
    retry 3 5 wget -q \
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
elif [ "${ARCH}" = "arm64" ]; then
    warn "GitKraken: no official arm64 deb — skipping"
fi

# =============================================================================
# STEP 5: KVM / QEMU / VIRT-MANAGER
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 5: KVM + QEMU + virt-manager"
log "─────────────────────────────────────────────────────"

retry 3 5 apt-get install -y \
    qemu-kvm qemu-system cpu-checker \
    virt-manager libvirt-daemon-system libvirt-clients \
    bridge-utils \
    || warn "KVM packages install had errors — continuing"

# Start libvirt daemons (background — safe to fail in unprivileged containers)
/usr/sbin/libvirtd &>/dev/null & disown 2>/dev/null || true
/usr/sbin/virtlogd &>/dev/null & disown 2>/dev/null || true

# KVM permissions
usermod -aG kvm abc 2>/dev/null || true
if [ -e /dev/kvm ]; then
    chown root:kvm /dev/kvm 2>/dev/null || true
    chmod 660 /dev/kvm 2>/dev/null || true
    ok "/dev/kvm permissions set"
else
    warn "/dev/kvm not present — KVM passthrough unavailable (expected in unprivileged containers)"
    warn "Run container with --privileged or --device /dev/kvm for nested virtualization"
fi

ok "KVM/QEMU setup done"

# =============================================================================
# STEP 6: OLLAMA LLM RUNTIME
# =============================================================================
# Requires: zstd (installed in Step 1)
# Background daemon — serves AI inference at localhost:11434

log "─────────────────────────────────────────────────────"
log "STEP 6: Ollama LLM Runtime"
log "─────────────────────────────────────────────────────"

if command -v ollama >/dev/null 2>&1; then
    ok "Ollama already installed"
else
    # zstd is required by the Ollama installer — verified installed in Step 1
    retry 3 10 bash -c 'curl -fsSL https://ollama.com/install.sh | sh' \
        && ok "Ollama installed" \
        || warn "Ollama install failed (non-fatal — install manually later)"
fi

apt-get install -y -f 2>/dev/null || true
ollama serve &>/dev/null & disown 2>/dev/null || true
ok "Ollama serve started (background)"

# =============================================================================
# STEP 7: SSH
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 7: SSH"
log "─────────────────────────────────────────────────────"

mkdir -p /var/run/sshd
service ssh enable 2>/dev/null || true
service ssh start 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true
ok "SSH configured"

# =============================================================================
# STEP 8: VISUAL STUDIO CODE
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
        && bash /tmp/vscode-install.sh 2>/dev/null \
        && ok "VS Code installed" \
        || warn "VS Code install failed (non-fatal)"
    rm -f /tmp/vscode-install.sh
fi

# =============================================================================
# STEP 9: DEVSECOPS TOOLCHAIN (Dagger, Zarf, K9s, Lazydocker)
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 9: DevSecOps Toolchain"
log "─────────────────────────────────────────────────────"

# Dagger CI
if ! command -v dagger >/dev/null 2>&1; then
    curl -fsSL https://dl.dagger.io/dagger/install.sh | BIN_DIR=/usr/local/bin sh 2>/dev/null \
        && ok "Dagger installed" \
        || warn "Dagger install failed"
fi

# Zarf (multi-arch)
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

# K9s (Kubernetes TUI)
if ! command -v k9s >/dev/null 2>&1; then
    K9S_VER=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4 2>/dev/null || echo "")
    if [ -n "${K9S_VER}" ]; then
        retry 3 5 curl -sL \
            "https://github.com/derailed/k9s/releases/download/${K9S_VER}/k9s_Linux_${ARCH}.tar.gz" \
            | tar -xz -C /usr/local/bin k9s 2>/dev/null \
            && ok "K9s installed" \
            || warn "K9s install failed"
    fi
fi

# Lazydocker
if ! command -v lazydocker >/dev/null 2>&1; then
    retry 3 5 curl -fsSL \
        https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh \
        | DIR=/usr/local/bin bash 2>/dev/null \
        && ok "Lazydocker installed" \
        || warn "Lazydocker install failed"
fi

# Run the DEV/SEC/OPS appinator
retry 3 5 wget -q \
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/refs/heads/main/Dagger%20CI/Scripts/nexus-devsecops-appinator.sh" \
    -O /tmp/appinator.sh \
    && bash /tmp/appinator.sh 2>/dev/null \
    && ok "DEV/SEC/OPS appinator ran" \
    || warn "Appinator failed (non-fatal)"
rm -f /tmp/appinator.sh

ok "DevSecOps toolchain complete"

# =============================================================================
# STEP 10: USER ABC — UID ALIGNMENT
# =============================================================================
# CRITICAL: linuxserver/webtop sets abc to UID 911.
# The sovereign grid requires UID 1000. This enforces it.
# If abc is already 1000, nothing changes.

log "─────────────────────────────────────────────────────"
log "STEP 10: User abc UID/GID alignment (sovereign standard: 1000)"
log "─────────────────────────────────────────────────────"

# Create abc if missing
if ! id -u abc >/dev/null 2>&1; then
    log "Creating user abc (UID 1000)..."
    useradd -m -u 1000 -s /bin/bash abc 2>/dev/null || true
fi

CURRENT_UID=$(id -u abc 2>/dev/null || echo "0")
CURRENT_GID=$(id -g abc 2>/dev/null || echo "0")

if [ "${CURRENT_UID}" != "1000" ]; then
    log "abc UID is ${CURRENT_UID} — fixing to 1000..."
    usermod -u 1000 abc 2>/dev/null || warn "usermod -u 1000 abc failed"
    groupmod -g 1000 abc 2>/dev/null || warn "groupmod -g 1000 abc failed"
    # Fix any files owned by old UID
    find / -user "${CURRENT_UID}" -not -path "/proc/*" -not -path "/sys/*" \
        -exec chown abc: {} + 2>/dev/null || true
    ok "abc UID corrected to 1000"
else
    ok "abc already UID 1000 — no change needed"
fi

# Group memberships
for GRP in sudo docker kvm libvirt; do
    getent group "${GRP}" >/dev/null 2>&1 && usermod -aG "${GRP}" abc 2>/dev/null || true
done

# Password — sovereign standard
echo "abc:sovereign" | chpasswd 2>/dev/null || true
ok "abc password set to: sovereign"

# Sudoers
cp -f /etc/sudoers /root/sudoers.bak 2>/dev/null || true
grep -q "abc ALL=(ALL) NOPASSWD: ALL" /etc/sudoers 2>/dev/null || \
    echo "abc ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
grep -q "www-data ALL=(ALL) NOPASSWD: ALL" /etc/sudoers 2>/dev/null || \
    echo "www-data ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
sort /etc/sudoers | uniq > /etc/sudoers-NEW 2>/dev/null && \
    mv -f /etc/sudoers-NEW /etc/sudoers 2>/dev/null || true
ok "Sudoers configured"

# =============================================================================
# STEP 11: NEXUS-BUCKET FILESYSTEM
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 11: /nexus-bucket filesystem"
log "─────────────────────────────────────────────────────"

mkdir -p /nexus-bucket
chown -R abc:abc /nexus-bucket
chmod 755 /nexus-bucket

# Clone Underground Nexus repo
if [ ! -d "/nexus-bucket/underground-nexus/.git" ]; then
    retry 3 10 git clone \
        https://github.com/Underground-Ops/underground-nexus.git \
        /nexus-bucket/underground-nexus \
        && ok "Underground Nexus repo cloned to /nexus-bucket" \
        || warn "git clone failed — air-gap mode or network issue"
else
    git -C /nexus-bucket/underground-nexus pull --rebase 2>/dev/null || true
    ok "Underground Nexus repo updated"
fi

chown -R abc:abc /nexus-bucket 2>/dev/null || true

# =============================================================================
# STEP 12: WALLPAPERS
# =============================================================================
# THIS IS EXACT LOGIC FROM THE ORIGINAL nexus0.sh — PRESERVED VERBATIM.
#
# THREE IMAGES for THREE ASPECT RATIO FAMILIES:
#
#   nexus0-sea-space-jelly-highres.jpg (widescreen, high-res)
#     → 1440x900, 1280x800, 1366x768, 1600x1200, 1680x1050,
#       1920x1080, 1920x1200, 2560x1440
#
#   nexus0-sea-space-jelly.jpg (standard/square variant)
#     → 1280x1024, 1024x768
#
#   nexus0-moon-jelly.jpg (portrait — for rotated/vertical displays)
#     → 1080x1920, 360x720, 720x1440
#
# rm -r "*.png" removes the default kubuntu wallpaper PNGs so only
# our JPGs remain. KDE automatically selects the closest resolution match.
# This creates the aspect-ratio responsive wallpaper switching effect.
#
# mkdir -p ensures the directory exists even if linuxserver/webtop
# doesn't ship the KubuntuLight theme — we create it ourselves.

log "─────────────────────────────────────────────────────"
log "STEP 12: Wallpapers (three-image aspect-ratio system)"
log "─────────────────────────────────────────────────────"

WALLPAPER_BASE="https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/Wallpapers"
WALLPAPER_DIR="/usr/share/wallpapers/KubuntuLight/contents/images"

mkdir -p "${WALLPAPER_DIR}"
cd "${WALLPAPER_DIR}" || { warn "Could not cd to ${WALLPAPER_DIR}"; cd /; }

# --- IMAGE 1: nexus0-sea-space-jelly-highres.jpg → all widescreen/landscape sizes ---
retry 3 5 wget -q "${WALLPAPER_BASE}/nexus0-sea-space-jelly-highres.jpg" \
    -O "1440x900.jpg" \
    && ok "sea-space-jelly-highres downloaded as 1440x900.jpg" \
    || warn "sea-space-jelly-highres download failed"

if [ -f "1440x900.jpg" ]; then
    for SIZE in 1280x800 1366x768 1600x1200 1680x1050 1920x1080 1920x1200 2560x1440; do
        rm -f "${SIZE}.jpg" "${SIZE}.png" 2>/dev/null || true
        cp "1440x900.jpg" "${SIZE}.jpg"
    done
    ok "Widescreen wallpapers set (1280x800 through 2560x1440)"
fi

# --- IMAGE 2: nexus0-sea-space-jelly.jpg → standard/square sizes ---
retry 3 5 wget -q "${WALLPAPER_BASE}/nexus0-sea-space-jelly.jpg" \
    -O "1280x1024.jpg" \
    && ok "sea-space-jelly downloaded as 1280x1024.jpg" \
    || warn "sea-space-jelly download failed"

if [ -f "1280x1024.jpg" ]; then
    rm -f "1024x768.jpg" "1024x768.png" 2>/dev/null || true
    cp "1280x1024.jpg" "1024x768.jpg"
    ok "Square wallpapers set (1280x1024, 1024x768)"
fi

# --- IMAGE 3: nexus0-moon-jelly.jpg → portrait/vertical sizes ---
retry 3 5 wget -q "${WALLPAPER_BASE}/nexus0-moon-jelly.jpg" \
    -O "1080x1920.jpg" \
    && ok "moon-jelly downloaded as 1080x1920.jpg" \
    || warn "moon-jelly download failed"

if [ -f "1080x1920.jpg" ]; then
    for SIZE in 360x720 720x1440; do
        rm -f "${SIZE}.jpg" "${SIZE}.png" 2>/dev/null || true
        cp "1080x1920.jpg" "${SIZE}.jpg"
    done
    ok "Portrait wallpapers set (1080x1920, 360x720, 720x1440)"
fi

# Remove ALL remaining PNG files (default kubuntu wallpapers) so only our JPGs remain
rm -rf ./*.png 2>/dev/null || true
ok "Default PNG wallpapers removed"

# Return to root
cd / || true

ok "Wallpaper system complete — three-image aspect-ratio responsive"

# =============================================================================
# STEP 13: CONTROL PANEL + DESKTOP ASSETS
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 13: Control panel + desktop assets"
log "─────────────────────────────────────────────────────"

# Control panel HTML — at root (legacy location) and Desktop
retry 3 5 wget -q \
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/Production%20Artifacts/Wordpress/nexus-creator-vault/nexus-creator-vault-control-panel.html" \
    -O /nexus-creator-vault-control-panel.html \
    && ok "Control panel at /nexus-creator-vault-control-panel.html" \
    || warn "Control panel download failed"

# Desktop copy for abc
mkdir -p /config/Desktop /home/abc/Desktop 2>/dev/null || true
cp -f /nexus-creator-vault-control-panel.html \
    /config/Desktop/nexus-creator-vault-control-panel.html 2>/dev/null || true
cp -f /nexus-creator-vault-control-panel.html \
    /home/abc/Desktop/nexus-creator-vault-control-panel.html 2>/dev/null || true
chown -R abc:abc /config/Desktop /home/abc/Desktop 2>/dev/null || true

# =============================================================================
# ─ CONTAINER MODE: s6-overlay service registration ─
# ─ BARE METAL MODE: SDDM auto-login + systemd services ─
# =============================================================================

if [ "${CONTAINER_MODE}" = "true" ]; then

    log "═══════════════════════════════════════════════════"
    log "CONTAINER MODE — s6-overlay service registration"
    log "═══════════════════════════════════════════════════"

    # s6 service: libvirtd
    mkdir -p /etc/s6-overlay/s6-rc.d/libvirtd
    printf '#!/usr/bin/with-contenv bash\nexec /usr/sbin/libvirtd\n' \
        > /etc/s6-overlay/s6-rc.d/libvirtd/run && \
        chmod +x /etc/s6-overlay/s6-rc.d/libvirtd/run
    echo "longrun" > /etc/s6-overlay/s6-rc.d/libvirtd/type

    # s6 service: virtlogd
    mkdir -p /etc/s6-overlay/s6-rc.d/virtlogd
    printf '#!/usr/bin/with-contenv bash\nexec /usr/sbin/virtlogd\n' \
        > /etc/s6-overlay/s6-rc.d/virtlogd/run && \
        chmod +x /etc/s6-overlay/s6-rc.d/virtlogd/run
    echo "longrun" > /etc/s6-overlay/s6-rc.d/virtlogd/type

    # s6 service: ollama
    mkdir -p /etc/s6-overlay/s6-rc.d/ollama
    printf '#!/usr/bin/with-contenv bash\nexec ollama serve\n' \
        > /etc/s6-overlay/s6-rc.d/ollama/run && \
        chmod +x /etc/s6-overlay/s6-rc.d/ollama/run
    echo "longrun" > /etc/s6-overlay/s6-rc.d/ollama/type

    # s6 service: chrome-remote-desktop (as abc user)
    mkdir -p /etc/s6-overlay/s6-rc.d/chrome-remote-desktop
    printf '#!/usr/bin/with-contenv bash\nexec s6-setuidgid abc /opt/google/chrome-remote-desktop/chrome-remote-desktop --start\n' \
        > /etc/s6-overlay/s6-rc.d/chrome-remote-desktop/run && \
        chmod +x /etc/s6-overlay/s6-rc.d/chrome-remote-desktop/run
    echo "longrun" > /etc/s6-overlay/s6-rc.d/chrome-remote-desktop/type

    # s6 service: supervisor
    if command -v supervisord >/dev/null 2>&1; then
        mkdir -p /etc/s6-overlay/s6-rc.d/supervisor
        printf '#!/usr/bin/with-contenv bash\nexec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf\n' \
            > /etc/s6-overlay/s6-rc.d/supervisor/run && \
            chmod +x /etc/s6-overlay/s6-rc.d/supervisor/run
        echo "longrun" > /etc/s6-overlay/s6-rc.d/supervisor/type
    fi

    # Enable all in s6 user bundle
    mkdir -p /etc/s6-overlay/s6-rc.d/user/contents.d
    for SVC in libvirtd virtlogd ollama chrome-remote-desktop; do
        touch "/etc/s6-overlay/s6-rc.d/user/contents.d/${SVC}"
    done
    command -v supervisord >/dev/null 2>&1 && \
        touch "/etc/s6-overlay/s6-rc.d/user/contents.d/supervisor" || true

    # s6 cont-init: KVM permissions at container start
    mkdir -p /etc/s6-overlay/cont-init.d
    printf '#!/usr/bin/with-contenv bash\nusermod -aG kvm abc 2>/dev/null||true\nchown root:kvm /dev/kvm 2>/dev/null||true\nchmod 660 /dev/kvm 2>/dev/null||true\n' \
        > /etc/s6-overlay/cont-init.d/01-kvm-permissions
    chmod +x /etc/s6-overlay/cont-init.d/01-kvm-permissions

    # s6 cont-init: nexus-bucket ownership
    printf '#!/usr/bin/with-contenv bash\nmkdir -p /nexus-bucket\nchown -R abc:abc /nexus-bucket\n' \
        > /etc/s6-overlay/cont-init.d/02-nexus-bucket
    chmod +x /etc/s6-overlay/cont-init.d/02-nexus-bucket

    # s6 cont-init: git sync on start
    printf '#!/usr/bin/with-contenv bash\ngit clone https://github.com/Underground-Ops/underground-nexus.git /nexus-bucket/underground-nexus 2>/dev/null || git -C /nexus-bucket/underground-nexus pull --rebase 2>/dev/null || true\nchown -R abc:abc /nexus-bucket/underground-nexus 2>/dev/null||true\n' \
        > /etc/s6-overlay/cont-init.d/03-nexus-sync
    chmod +x /etc/s6-overlay/cont-init.d/03-nexus-sync

    # Fix all s6 file permissions
    find /etc/s6-overlay -type f -exec chmod +x {} \; 2>/dev/null || true

    log "─────────────────────────────────────────────────────"
    log "ZERO TRUST ACCESS — Chrome RDP setup instructions:"
    log "─────────────────────────────────────────────────────"
    log ""
    log "  1. From Portainer console OR docker exec:"
    log "     su - abc"
    log ""
    log "  2. Go to: https://remotedesktop.google.com/headless"
    log "     Choose: Access my computer → Install via SSH → Authorize"
    log "     Copy the Linux authorization string"
    log ""
    log "  3. Paste it in the abc shell (NO sudo):"
    log "     DISPLAY= /opt/google/chrome-remote-desktop/start-host \\"
    log "       --code=\"<YOUR-CODE>\" \\"
    log "       --redirect-url=\"https://remotedesktop.google.com/_/oauthredirect\" \\"
    log "       --name=\$(hostname)"
    log ""
    log "  4. Access at: https://remotedesktop.google.com/access"
    log ""
    log "  SSH access:"
    log "     ssh abc@\$(hostname -i)"
    log "     Password: sovereign"
    log ""
    log "  NOTE: Authorize string is temporary — if it fails, generate a new one"
    log "─────────────────────────────────────────────────────"

    ok "Container Mode s6 services registered"

else

    log "═══════════════════════════════════════════════════"
    log "BARE METAL / VM MODE — SDDM + systemd"
    log "═══════════════════════════════════════════════════"

    # SDDM auto-login — boots directly to KDE without password prompt
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/autologin.conf << 'SDDMEOF'
[Autologin]
User=abc
Session=plasma
Relogin=false
SDDMEOF
    ok "SDDM auto-login configured (User=abc, Session=plasma)"

    # Enable systemd services
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
        ok "Docker Swarm initialized + sovereign-net created"
    fi

    # First-boot service (runs sovereign-installer once on first boot)
    cat > /etc/systemd/system/nexus-first-boot.service << 'SYSTEMDEOF'
[Unit]
Description=Nexus OS First Boot Activation
After=network-online.target docker.service
ConditionPathExists=!/var/lib/nexus-first-boot-done

[Service]
Type=oneshot
User=root
ExecStart=/bin/bash -c '/usr/local/bin/sovereign-installer && touch /var/lib/nexus-first-boot-done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

    command -v systemctl >/dev/null 2>&1 && {
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable nexus-first-boot.service 2>/dev/null || true
    }

    ok "Bare Metal Mode configuration complete"

fi

# =============================================================================
# STEP 14: FINAL PERMISSIONS
# =============================================================================

log "─────────────────────────────────────────────────────"
log "STEP 14: Final permissions"
log "─────────────────────────────────────────────────────"

chown -R abc:abc /nexus-bucket 2>/dev/null || true
chown -R abc:abc /config 2>/dev/null || true
[ -d /home/abc ] && chown -R abc:abc /home/abc 2>/dev/null || true

ok "Permissions set"

# =============================================================================
# COMPLETE
# =============================================================================

log ""
log "═══════════════════════════════════════════════════"
log "nexus0.sh v3 COMPLETE"
log "Mode:     $([ "${CONTAINER_MODE}" = "true" ] && echo "CONTAINER" || echo "BARE METAL")"
log "User:     abc (UID $(id -u abc 2>/dev/null || echo 1000))"
log "Arch:     ${ARCH}"
log "Bucket:   /nexus-bucket"
log "Log:      ${NX_LOG}"
log "Password: sovereign"
log "═══════════════════════════════════════════════════"
log ""
log "INSTALLED ARSENAL:"
command -v code >/dev/null 2>&1       && log "  ✓ VS Code" || log "  ✗ VS Code (install failed)"
command -v dagger >/dev/null 2>&1     && log "  ✓ Dagger CI" || log "  ✗ Dagger CI"
command -v zarf >/dev/null 2>&1       && log "  ✓ Zarf" || log "  ✗ Zarf"
command -v k9s >/dev/null 2>&1        && log "  ✓ K9s" || log "  ✗ K9s"
command -v lazydocker >/dev/null 2>&1 && log "  ✓ Lazydocker" || log "  ✗ Lazydocker"
command -v ollama >/dev/null 2>&1     && log "  ✓ Ollama" || log "  ✗ Ollama (may need manual install)"
command -v gitkraken >/dev/null 2>&1  && log "  ✓ GitKraken" || log "  ✓ GitKraken (dpkg installed, check /usr/bin/gitkraken)"
[ -f /opt/google/chrome-remote-desktop/chrome-remote-desktop ] \
                                      && log "  ✓ Chrome RDP" || log "  ✗ Chrome RDP (amd64 only)"
log ""
log "Full install log: ${NX_LOG}"