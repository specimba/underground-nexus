#!/usr/bin/env bash
# =============================================================================
# DEV-METAL — Sovereign KDE Desktop + Underground Nexus Installer
# Cloud Underground · Underground Nexus
# =============================================================================
#
# USAGE:
#   # From Cerberus Manager or any shell:
#   curl -fsSL https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/dev-metal.sh | sudo bash
#
#   # Or copy to target and run:
#   sudo bash dev-metal.sh
#
# WHAT IT DOES:
#   1. Detects Ubuntu Server 24.04 bare metal
#   2. Repairs KDE if already installed (mouse/input/compositor fixes)
#   3. Installs KDE Plasma + GDM3 autologin if not present
#   4. Installs Docker CE
#   5. Sets up /nexus-bucket + git clones underground-nexus
#   6. Runs nexus0.sh (the full sovereign arsenal installer)
#   7. Configures SPICE/evdev input, disables compositor for VM hosting
#   8. Sets user abc with sovereign password
#
# REPAIR MODE:
#   If KDE is detected, skips install and runs repair sequence only.
#   Safe to re-run at any time.
#
# =============================================================================

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="1.0.0"
LOG="/tmp/dev-metal.log"
NEXUS0_URL="https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/nexus0.sh"
NEXUS_REPO="https://github.com/Underground-Ops/underground-nexus.git"
NEXUS_BUCKET="/nexus-bucket"
ABC_HOME="/home/abc"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[dev-metal]${NC} $*" | tee -a "${LOG}"; }
ok()   { echo -e "${GREEN}[dev-metal] ✓${NC} $*" | tee -a "${LOG}"; }
warn() { echo -e "${YELLOW}[dev-metal] ⚠${NC} $*" | tee -a "${LOG}"; }
err()  { echo -e "${RED}[dev-metal] ✗${NC} $*" | tee -a "${LOG}" >&2; }
sep()  { echo -e "${CYAN}════════════════════════════════════════════════${NC}" | tee -a "${LOG}"; }

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    err "Must run as root: sudo bash dev-metal.sh"
    exit 1
fi

sep
log "DEV-METAL v${SCRIPT_VERSION} — Sovereign KDE + Nexus Installer"
log "Started: $(date)"
log "Host: $(hostname) | Arch: $(dpkg --print-architecture 2>/dev/null || uname -m)"
sep

# =============================================================================
# DETECTION
# =============================================================================

log "Detecting environment..."

HAS_KDE=false
HAS_GDM=false
HAS_SDDM=false
HAS_DOCKER=false
HAS_NEXUS0=false
IS_VM=false
REPAIR_ONLY=false

# KDE
if dpkg -l plasma-desktop 2>/dev/null | grep -q "^ii" || \
   dpkg -l kubuntu-desktop 2>/dev/null | grep -q "^ii" || \
   command -v plasmashell >/dev/null 2>&1; then
    HAS_KDE=true
    log "  KDE Plasma: DETECTED → will run repair"
    REPAIR_ONLY=true
fi

# Display managers
dpkg -l gdm3 2>/dev/null | grep -q "^ii" && HAS_GDM=true
dpkg -l sddm 2>/dev/null | grep -q "^ii" && HAS_SDDM=true

# Docker
command -v docker >/dev/null 2>&1 && HAS_DOCKER=true

# nexus-bucket
[ -d "${NEXUS_BUCKET}/underground-nexus/.git" ] && HAS_NEXUS0=true

# VM / software rendering detection
if systemd-detect-virt --quiet 2>/dev/null || \
   grep -qi "kvm\|qemu\|vmware\|virtualbox\|hyperv" /proc/cpuinfo 2>/dev/null || \
   [ -e /dev/vda ] || [ -e /dev/virtio-ports ]; then
    IS_VM=true
    log "  Running in VM: YES (will apply SPICE/evdev input fixes)"
fi

log "  KDE: ${HAS_KDE} | GDM3: ${HAS_GDM} | SDDM: ${HAS_SDDM}"
log "  Docker: ${HAS_DOCKER} | Nexus bucket: ${HAS_NEXUS0} | VM: ${IS_VM}"

# =============================================================================
# STEP 1: BASE PACKAGES
# =============================================================================

sep
log "STEP 1: Base packages + apt prep"

apt-get update -qq 2>&1 | tail -3

apt-get install -y \
    curl wget git nano ssh \
    ca-certificates apt-transport-https gnupg \
    lsb-release software-properties-common \
    python3 python3-packaging \
    build-essential \
    xinput xdotool \
    mesa-utils libgl1-mesa-dri \
    spice-vdagent \
    dbus-x11 \
    at-spi2-core \
    2>/dev/null | tail -5

ok "Base packages ready"

# =============================================================================
# STEP 2: USER ABC
# =============================================================================

sep
log "STEP 2: User abc"

if ! id abc >/dev/null 2>&1; then
    useradd -m -u 1000 -s /bin/bash -d "${ABC_HOME}" abc
    ok "User abc created"
else
    ok "User abc exists"
fi

echo "abc:sovereign" | chpasswd
mkdir -p "${ABC_HOME}"

# Groups — add all relevant ones
for GRP in sudo docker kvm libvirt input video render audio plugdev; do
    getent group "${GRP}" >/dev/null 2>&1 && usermod -aG "${GRP}" abc 2>/dev/null || true
done

# Passwordless sudo
grep -q "^abc ALL=(ALL) NOPASSWD" /etc/sudoers 2>/dev/null || \
    echo "abc ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

ok "User abc configured (password: sovereign)"

# =============================================================================
# STEP 3: DOCKER CE
# =============================================================================

sep
log "STEP 3: Docker CE"

if [ "${HAS_DOCKER}" = "false" ]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker
    usermod -aG docker abc
    ok "Docker CE installed"
else
    ok "Docker already installed"
    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
fi

# =============================================================================
# STEP 4: /nexus-bucket
# =============================================================================

sep
log "STEP 4: /nexus-bucket setup"

mkdir -p "${NEXUS_BUCKET}"
chown -R abc:abc "${NEXUS_BUCKET}" 2>/dev/null || chown -R 1000:1000 "${NEXUS_BUCKET}" || true

if [ -d "${NEXUS_BUCKET}/underground-nexus/.git" ]; then
    log "  Updating existing repo..."
    git -C "${NEXUS_BUCKET}/underground-nexus" pull --rebase 2>/dev/null && \
        ok "underground-nexus updated" || warn "git pull failed (non-fatal)"
else
    log "  Cloning underground-nexus..."
    git clone --depth=1 "${NEXUS_REPO}" "${NEXUS_BUCKET}/underground-nexus" && \
        ok "underground-nexus cloned" || warn "Clone failed (nexus0.sh will retry)"
fi

chown -R abc:abc "${NEXUS_BUCKET}" 2>/dev/null || true
ok "/nexus-bucket ready at ${NEXUS_BUCKET}"

# =============================================================================
# STEP 5: KDE PLASMA INSTALL (skip if already installed)
# =============================================================================

if [ "${REPAIR_ONLY}" = "false" ]; then
    sep
    log "STEP 5: KDE Plasma installation"

    # KVM/libvirt for the hypervisor
    apt-get install -y \
        qemu-kvm qemu-system-x86 \
        libvirt-daemon-system libvirt-clients \
        virt-manager bridge-utils ovmf cpu-checker \
        2>/dev/null | tail -5 || warn "KVM packages partial"

    usermod -aG kvm abc 2>/dev/null || true
    usermod -aG libvirt abc 2>/dev/null || true

    # KDE Plasma full desktop
    apt-get install -y \
        kubuntu-desktop \
        plasma-desktop \
        kwin-x11 \
        xorg \
        xdg-utils xdg-user-dirs \
        2>&1 | tail -10

    ok "KDE Plasma installed"
    HAS_KDE=true
else
    sep
    log "STEP 5: KDE already installed — skipping install"
fi

# =============================================================================
# STEP 6: GDM3 DISPLAY MANAGER (replaces SDDM — more reliable with SPICE)
# =============================================================================

sep
log "STEP 6: GDM3 display manager"

apt-get install -y gdm3 2>/dev/null | tail -3 || warn "GDM3 install issue"

# Disable SDDM if present
if [ "${HAS_SDDM}" = "true" ]; then
    systemctl disable sddm 2>/dev/null || true
    log "  SDDM disabled"
fi

# Configure GDM3 for autologin to KDE X11
cat > /etc/gdm3/custom.conf << 'GDM'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=abc
WaylandEnable=false

[security]

[xdmcp]

[chooser]

[debug]
GDM

# Set abc's session to plasma via AccountsService
mkdir -p /var/lib/AccountsService/users/
cat > /var/lib/AccountsService/users/abc << 'ACCOUNTS'
[User]
Session=plasma
XSession=plasma
SystemAccount=false
ACCOUNTS

# .dmrc fallback
cat > "${ABC_HOME}/.dmrc" << 'DMRC'
[Desktop]
Session=plasma
DMRC
chown abc:abc "${ABC_HOME}/.dmrc"

systemctl enable gdm3 2>/dev/null || true
systemctl set-default graphical.target 2>/dev/null || true

ok "GDM3 configured (autologin: abc → plasma X11)"

# =============================================================================
# STEP 7: INPUT FIX — evdev + SPICE + compositor off
# =============================================================================

sep
log "STEP 7: Input, SPICE, compositor fixes"

# Clean ALL previous broken xorg configs
rm -f /etc/X11/xorg.conf.d/10-fbdev.conf \
      /etc/X11/xorg.conf.d/10-qxl.conf \
      /etc/X11/xorg.conf.d/40-libinput.conf \
      /etc/X11/xorg.conf.d/40-input.conf \
      /etc/X11/xorg.conf.d/50-evdev-tablet.conf \
      /etc/X11/xorg.conf.d/99-spice-input.rules \
      2>/dev/null || true

mkdir -p /etc/X11/xorg.conf.d

# evdev for QEMU virtual tablet (works with virtio video + SPICE)
cat > /etc/X11/xorg.conf.d/50-evdev.conf << 'EVDEV'
Section "InputClass"
    Identifier "evdev pointer catchall"
    MatchIsPointer "on"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
    Option "Emulate3Buttons" "false"
EndSection

Section "InputClass"
    Identifier "evdev keyboard catchall"
    MatchIsKeyboard "on"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
EndSection

Section "InputClass"
    Identifier "evdev tablet catchall"
    MatchIsTablet "on"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
EndSection
EVDEV

# Install evdev driver
apt-get install -y xserver-xorg-input-evdev 2>/dev/null || warn "evdev package unavailable"

# Input device permissions
chmod 660 /dev/input/event* 2>/dev/null || true
chmod 660 /dev/input/mice 2>/dev/null || true
chown root:input /dev/input/event* 2>/dev/null || true
chown root:input /dev/input/mice 2>/dev/null || true

# Persist via udev
cat > /etc/udev/rules.d/99-input.rules << 'UDEV'
KERNEL=="event*", SUBSYSTEM=="input", GROUP="input", MODE="0660"
KERNEL=="mouse*", SUBSYSTEM=="input", GROUP="input", MODE="0660"
KERNEL=="mice", SUBSYSTEM=="input", GROUP="input", MODE="0660"
UDEV
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true

# SPICE agent in Xsession startup
cat > /etc/X11/Xsession.d/99-spice-vdagent << 'XSESSION'
#!/bin/bash
[ -x /usr/bin/spice-vdagent ] && /usr/bin/spice-vdagent &
XSESSION
chmod +x /etc/X11/Xsession.d/99-spice-vdagent

systemctl enable spice-vdagentd 2>/dev/null || true

ok "evdev input driver configured"
ok "SPICE vdagent enabled"

# =============================================================================
# STEP 8: KDE USER CONFIG
# =============================================================================

sep
log "STEP 8: KDE user configuration for abc"

mkdir -p "${ABC_HOME}/.config/plasma-workspace/env"
mkdir -p "${ABC_HOME}/.config/gtk-3.0"

# Minimal working kwinrc — compositor OFF (critical for VM/llvmpipe)
cat > "${ABC_HOME}/.config/kwinrc" << 'KWIN'
[Compositing]
Enabled=false
OpenGLIsUnsafe=true

[Windows]
FocusPolicy=ClickToFocus
FocusPolicyIsResonant=true
KWIN

# Clean plasma env — minimal, no XI2 disable, no broken flags
cat > "${ABC_HOME}/.config/plasma-workspace/env/00-session.sh" << 'ENVSH'
#!/bin/bash
export QT_QPA_PLATFORM=xcb
export LIBGL_ALWAYS_SOFTWARE=1
ENVSH
chmod +x "${ABC_HOME}/.config/plasma-workspace/env/00-session.sh"

# Remove all broken env scripts from previous attempts
rm -f "${ABC_HOME}/.config/plasma-workspace/env/00-render.sh" \
      "${ABC_HOME}/.config/plasma-workspace/env/00-software-render.sh" \
      2>/dev/null || true

# Disable welcome screen
cat > "${ABC_HOME}/.config/plasma-welcomerc" << 'WELCOME'
[General]
ShouldShow=false
WELCOME

# Disable kwallet popup
cat > "${ABC_HOME}/.config/kwalletrc" << 'WALLET'
[Wallet]
Enabled=false
First Use=false
WALLET

# GTK settings
cat > "${ABC_HOME}/.config/gtk-3.0/settings.ini" << 'GTK'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Breeze-Dark
GTK

# xprofile for SPICE agent
cat > "${ABC_HOME}/.xprofile" << 'XPROFILE'
#!/bin/bash
[ -x /usr/bin/spice-vdagent ] && /usr/bin/spice-vdagent &
export QT_QPA_PLATFORM=xcb
XPROFILE
chmod +x "${ABC_HOME}/.xprofile"

# Fix ownership of all abc config
chown -R abc:abc "${ABC_HOME}" 2>/dev/null || chown -R 1000:1000 "${ABC_HOME}" || true

ok "KDE user config ready"

# =============================================================================
# STEP 9: CLEAN SYSTEM ENVIRONMENT
# =============================================================================

sep
log "STEP 9: System environment"

# Minimal clean /etc/environment — no broken flags from previous attempts
cat > /etc/environment << 'SYSENV'
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
QT_QPA_PLATFORM=xcb
SYSENV

ok "System environment clean"

# =============================================================================
# STEP 10: NEXUS0.SH — THE SOVEREIGN ARSENAL
# =============================================================================

sep
log "STEP 10: Running nexus0.sh — Sovereign Arsenal Installer"
log "  Source: ${NEXUS0_URL}"

# Fake /.dockerenv so nexus0.sh knows to write s6 services + cont-init hooks
# On bare metal we want these written so the runtime hook activates at login
touch /.dockerenv 2>/dev/null || true

# Download and run nexus0.sh
NEXUS0_TMP="/tmp/nexus0.sh"
if curl -fsSL --retry 3 --max-time 60 "${NEXUS0_URL}" -o "${NEXUS0_TMP}"; then
    chmod +x "${NEXUS0_TMP}"
    bash "${NEXUS0_TMP}" 2>&1 | tee -a "${LOG}"
    ok "nexus0.sh complete"
else
    warn "Could not download nexus0.sh — will retry on next run"
    warn "Manual: curl -fsSL ${NEXUS0_URL} | sudo bash"
fi

rm -f "${NEXUS0_TMP}"

# =============================================================================
# STEP 11: POST-NEXUS0 OVERRIDES
# =============================================================================
# nexus0.sh may write SDDM configs or set s6 services.
# We override what needs to stay correct for bare metal.

sep
log "STEP 11: Post-nexus0 bare metal overrides"

# Ensure GDM3 stays as display manager (nexus0 may have re-enabled SDDM)
systemctl disable sddm 2>/dev/null || true
systemctl enable gdm3 2>/dev/null || true

# Re-apply GDM3 autologin (nexus0 may have overwritten it)
cat > /etc/gdm3/custom.conf << 'GDM'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=abc
WaylandEnable=false

[security]

[xdmcp]

[chooser]

[debug]
GDM

# Re-apply evdev (nexus0 may have written libinput config)
cat > /etc/X11/xorg.conf.d/50-evdev.conf << 'EVDEV'
Section "InputClass"
    Identifier "evdev pointer catchall"
    MatchIsPointer "on"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
EndSection

Section "InputClass"
    Identifier "evdev keyboard catchall"
    MatchIsKeyboard "on"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
EndSection
EVDEV

# Re-apply clean kwinrc (compositor off)
cat > "${ABC_HOME}/.config/kwinrc" << 'KWIN'
[Compositing]
Enabled=false
OpenGLIsUnsafe=true

[Windows]
FocusPolicy=ClickToFocus
KWIN
chown abc:abc "${ABC_HOME}/.config/kwinrc"

# Re-apply clean environment
cat > /etc/environment << 'SYSENV'
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
QT_QPA_PLATFORM=xcb
SYSENV

# Ensure /nexus-bucket ownership is correct after nexus0
chown -R abc:abc "${NEXUS_BUCKET}" 2>/dev/null || chown -R 1000:1000 "${NEXUS_BUCKET}" || true

ok "Bare metal overrides applied"

# =============================================================================
# STEP 12: LIBVIRT + KVM SERVICES
# =============================================================================

sep
log "STEP 12: Libvirt + KVM services"

systemctl enable libvirtd 2>/dev/null || true
systemctl start libvirtd 2>/dev/null || true
usermod -aG kvm abc 2>/dev/null || true
usermod -aG libvirt abc 2>/dev/null || true

[ -e /dev/kvm ] && {
    chmod 660 /dev/kvm 2>/dev/null || true
    chown root:kvm /dev/kvm 2>/dev/null || true
    ok "KVM: /dev/kvm accessible"
} || warn "KVM: /dev/kvm not found (may appear after reboot)"

ok "Libvirt services enabled"

# =============================================================================
# STEP 13: FINAL OWNERSHIP + CLEANUP
# =============================================================================

sep
log "STEP 13: Final cleanup"

chown -R abc:abc "${ABC_HOME}" 2>/dev/null || true
chown -R abc:abc "${NEXUS_BUCKET}" 2>/dev/null || true
apt-get autoremove -y -qq 2>/dev/null || true
apt-get clean 2>/dev/null || true

ok "Cleanup complete"

# =============================================================================
# SUMMARY
# =============================================================================

sep
log ""
log "DEV-METAL COMPLETE"
sep
log ""
log "ENVIRONMENT:"
log "  User:      abc / sovereign"
log "  Desktop:   KDE Plasma (X11, compositor off)"
log "  Login:     GDM3 autologin → plasma session"
log "  Input:     evdev driver (SPICE tablet compatible)"
log "  /nexus-bucket: $(ls ${NEXUS_BUCKET} 2>/dev/null | tr '\n' ' ')"
log ""
log "INSTALLED TOOLS:"
command -v code         >/dev/null 2>&1 && log "  ✓ VS Code"          || log "  ✗ VS Code"
command -v dagger       >/dev/null 2>&1 && log "  ✓ Dagger CI"        || log "  ✗ Dagger CI"
command -v zarf         >/dev/null 2>&1 && log "  ✓ Zarf"             || log "  ✗ Zarf"
command -v k9s          >/dev/null 2>&1 && log "  ✓ K9s"              || log "  ✗ K9s"
command -v docker       >/dev/null 2>&1 && log "  ✓ Docker CE"        || log "  ✗ Docker CE"
command -v ollama       >/dev/null 2>&1 && log "  ✓ Ollama"           || log "  ✗ Ollama"
command -v virt-manager >/dev/null 2>&1 && log "  ✓ Sovereign Hypervisor" || log "  ✗ Sovereign Hypervisor"
command -v lazydocker   >/dev/null 2>&1 && log "  ✓ Lazydocker"       || log "  ✗ Lazydocker"
command -v blender      >/dev/null 2>&1 && log "  ✓ Blender"          || log "  ✗ Blender"
command -v gimp         >/dev/null 2>&1 && log "  ✓ GIMP"             || log "  ✗ GIMP"
log ""
log "DISPLAY:"
ls /usr/share/xsessions/ 2>/dev/null | while read s; do log "  ✓ Session: $s"; done
log ""
log "NEXT STEP: sudo reboot"
log ""
log "After reboot:"
log "  - KDE Plasma loads automatically as abc"
log "  - Mouse and keyboard work via evdev + SPICE"
log "  - /nexus-bucket/underground-nexus is ready"
log "  - Ollama, virt-manager, VS Code all available"
log "  - Docker socket at /var/run/docker.sock"
log ""
log "REPAIR: Re-run this script any time — it auto-detects and repairs"
log "LOG:    ${LOG}"
sep

echo ""
read -t 15 -p "Reboot now? [Y/n] " REBOOT_ANS || REBOOT_ANS="y"
if [[ "${REBOOT_ANS,,}" != "n" ]]; then
    log "Rebooting..."
    reboot
else
    log "Skipping reboot — run 'sudo reboot' when ready"
fi
