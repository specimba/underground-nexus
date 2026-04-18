#!/usr/bin/env bash
# =============================================================================
# DEV-METAL v2.0 — Sovereign KDE Desktop + Underground Nexus Installer
# Cloud Underground · Underground Nexus
# =============================================================================
#
# USAGE:
#   sudo bash dev-metal.sh
#   curl -fsSL https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/dev-metal.sh | sudo bash
#
# WHAT IT DOES:
#   1.  Detects environment — repair mode if KDE exists, install mode if not
#   2.  Removes snap firefox + shiftkey broken repo (from logs)
#   3.  Installs Firefox (real .deb via Mozilla Team PPA — no snap)
#   4.  Installs Chromium (real .deb via Chromium PPA — no snap)
#   5.  Installs Docker CE
#   6.  Sets up /nexus-bucket + clones underground-nexus
#   7.  Installs KDE Plasma + KVM/libvirt (skip if already present)
#   8.  Configures GDM3 — desktop does NOT start on boot by default
#   9.  Fixes evdev input + SPICE + compositor for VM hosting
#   10. Runs nexus0.sh sovereign arsenal installer
#   11. Post-nexus0 integrity repair pass
#   12. Installs PATH commands: desktop, desktop-stop, desktop-on-boot,
#       desktop-no-boot, desktop-status, nexus-update, kvm-status,
#       browser-repair, apt-repair, nexus-health, ollama-start,
#       ollama-stop, docker-clean, dev-metal-update
#   13. Writes DEV-metal command guide to /nexus-bucket/DEV-METAL-GUIDE.md
#
# DESIGN PHILOSOPHY:
#   - Desktop does NOT autostart — engineers type 'desktop' when they want it
#   - All commands are in PATH at /usr/local/bin/
#   - Repair mode is always safe to re-run
#   - No snap. Ever. For anything.
#
# =============================================================================

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="2.0.0"
LOG="/tmp/dev-metal.log"
NEXUS0_URL="https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/nexus0.sh"
NEXUS_REPO="https://github.com/Underground-Ops/underground-nexus.git"
NEXUS_BUCKET="/nexus-bucket"
ABC_HOME="/home/abc"
COMMANDS_DIR="/usr/local/bin"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[dev-metal]${NC} $*" | tee -a "${LOG}"; }
ok()   { echo -e "${GREEN}[dev-metal] ✓${NC} $*" | tee -a "${LOG}"; }
warn() { echo -e "${YELLOW}[dev-metal] ⚠${NC} $*" | tee -a "${LOG}"; }
err()  { echo -e "${RED}[dev-metal] ✗${NC} $*" | tee -a "${LOG}" >&2; }
sep()  { echo -e "${CYAN}════════════════════════════════════════════════${NC}" | tee -a "${LOG}"; }

[ "$(id -u)" -ne 0 ] && { err "Must run as root: sudo bash dev-metal.sh"; exit 1; }

mkdir -p /tmp
> "${LOG}"

sep
log "DEV-METAL v${SCRIPT_VERSION} — Sovereign KDE + Nexus Installer"
log "Started: $(date)"
log "Host: $(hostname) | Arch: $(dpkg --print-architecture 2>/dev/null || uname -m)"
sep

# =============================================================================
# DETECTION
# =============================================================================

log "Detecting environment..."

HAS_KDE=false; HAS_GDM=false; HAS_SDDM=false; HAS_DOCKER=false
HAS_NEXUS=false; IS_VM=false; REPAIR_ONLY=false
HAS_FIREFOX=false; HAS_CHROMIUM=false

dpkg -l plasma-desktop 2>/dev/null | grep -q "^ii" && HAS_KDE=true
command -v plasmashell >/dev/null 2>&1 && HAS_KDE=true
[ "${HAS_KDE}" = "true" ] && { REPAIR_ONLY=true; log "  KDE: DETECTED → repair mode"; }

dpkg -l gdm3 2>/dev/null | grep -q "^ii" && HAS_GDM=true
dpkg -l sddm 2>/dev/null | grep -q "^ii" && HAS_SDDM=true
command -v docker >/dev/null 2>&1 && HAS_DOCKER=true
[ -d "${NEXUS_BUCKET}/underground-nexus/.git" ] && HAS_NEXUS=true

# Real firefox detection (not snap stub)
if command -v firefox >/dev/null 2>&1; then
    firefox --version 2>/dev/null | grep -q "Mozilla Firefox" && HAS_FIREFOX=true
fi
command -v chromium >/dev/null 2>&1 && HAS_CHROMIUM=true
command -v chromium-browser >/dev/null 2>&1 && HAS_CHROMIUM=true

if systemd-detect-virt --quiet 2>/dev/null || \
   [ -e /dev/vda ] || [ -e /dev/virtio-ports ] || \
   grep -qi "kvm\|qemu\|vmware" /proc/cpuinfo 2>/dev/null; then
    IS_VM=true
fi

log "  KDE:${HAS_KDE} GDM3:${HAS_GDM} SDDM:${HAS_SDDM} Docker:${HAS_DOCKER} VM:${IS_VM}"
log "  Firefox:${HAS_FIREFOX} Chromium:${HAS_CHROMIUM} Nexus:${HAS_NEXUS}"

# =============================================================================
# STEP 1: REMOVE BROKEN REPOS + SNAP FIREFOX
# From dev-logs: shiftkey SSL cert fails on every apt update.
# Ubuntu 24.04 firefox apt package is a snap wrapper — fails in VMs
# with AppArmor errors: aa_is_enabled() failed unexpectedly
# =============================================================================

sep
log "STEP 1: Remove broken repos and snap firefox"

# Remove shiftkey broken SSL repo (seen in all dev-logs)
rm -f /etc/apt/sources.list.d/shiftkey-packages.list \
      /etc/apt/sources.list.d/*shiftkey* \
      /usr/share/keyrings/shiftkey-packages.gpg \
      2>/dev/null || true
ok "Removed shiftkey broken SSL repo"

# Remove snap firefox wrapper
apt-get remove --purge -y firefox 2>/dev/null | grep -v "not installed" | tail -3 || true

# Block Ubuntu's snap-wrapper firefox permanently
cat > /etc/apt/preferences.d/no-snap-browsers << 'PINBLOCK'
# Block Ubuntu snap-wrapper packages
# Real browsers installed from dedicated PPAs
Package: firefox
Pin: release o=Ubuntu
Pin-Priority: -1

Package: firefox-locale-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: chromium-browser
Pin: release o=Ubuntu
Pin-Priority: -1
PINBLOCK
ok "Snap browser wrappers blocked permanently"

# =============================================================================
# STEP 2: BASE PACKAGES
# =============================================================================

sep
log "STEP 2: Base packages"

apt-get update -qq 2>&1 | grep -vE "^(Hit|Ign|Get):" | grep -v "^$" | tail -5

apt-get install -y \
    curl wget git nano ssh \
    ca-certificates apt-transport-https gnupg \
    lsb-release software-properties-common \
    python3 python3-packaging \
    build-essential \
    xinput xdotool \
    mesa-utils libgl1-mesa-dri \
    spice-vdagent \
    dbus-x11 at-spi2-core \
    apparmor apparmor-utils \
    2>/dev/null | tail -5

ok "Base packages ready"

# =============================================================================
# STEP 3: FIREFOX — REAL DEB VIA MOZILLA TEAM PPA
# Fix confirmed in dev-logs: purge snap, add Mozilla PPA, pin priority 1001,
# then apt install firefox gets the real 82MB binary, not the 77KB snap stub
# =============================================================================

sep
log "STEP 3: Firefox (Mozilla Team PPA — real deb, no snap)"

if [ "${HAS_FIREFOX}" = "false" ]; then
    # Add Mozilla Team PPA
    add-apt-repository -y ppa:mozillateam/ppa 2>&1 | tail -5 || \
        warn "Mozilla PPA add failed — trying keyserver method"

    # Pin Mozilla PPA above all else (confirmed working in dev-logs)
    cat > /etc/apt/preferences.d/mozilla-firefox << 'MOZPIN'
Package: *
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
MOZPIN

    apt-get update -qq 2>/dev/null | tail -3
    apt-get install -y firefox 2>&1 | tail -8

    if firefox --version 2>/dev/null | grep -q "Mozilla"; then
        ok "Firefox installed: $(firefox --version 2>/dev/null)"
        HAS_FIREFOX=true
    else
        warn "Firefox install incomplete — run 'browser-repair' after boot"
    fi
else
    ok "Firefox already installed: $(firefox --version 2>/dev/null || echo 'ok')"
fi

# =============================================================================
# STEP 4: CHROMIUM — REAL DEB (NO SNAP)
# Ubuntu 24.04 chromium-browser is also a snap wrapper.
# Use xtradeb/apps PPA which ships real debs.
# =============================================================================

sep
log "STEP 4: Chromium (xtradeb PPA — real deb, no snap)"

if [ "${HAS_CHROMIUM}" = "false" ]; then
    CHROMIUM_OK=false

    # Method 1: xtradeb/apps PPA
    if add-apt-repository -y ppa:xtradeb/apps 2>&1 | tail -3; then
        apt-get update -qq 2>/dev/null | tail -3
        if apt-get install -y chromium 2>&1 | tail -5; then
            command -v chromium >/dev/null 2>&1 && {
                CHROMIUM_OK=true
                ok "Chromium installed via xtradeb PPA: $(chromium --version 2>/dev/null)"
            }
        fi
    fi

    # Method 2: Try chromium-browser from alternative source
    if [ "${CHROMIUM_OK}" = "false" ]; then
        log "  xtradeb failed — trying alternative..."
        apt-get install -y chromium-browser 2>/dev/null | tail -5 && \
            command -v chromium-browser >/dev/null 2>&1 && {
                CHROMIUM_OK=true
                ok "chromium-browser installed"
            } || warn "Chromium unavailable — run 'browser-repair' after boot"
    fi

    # Create unified symlink whichever binary name was installed
    if command -v chromium >/dev/null 2>&1 && ! command -v chromium-browser >/dev/null 2>&1; then
        ln -sf "$(command -v chromium)" /usr/local/bin/chromium-browser
        ok "chromium-browser symlink → chromium"
    fi
else
    ok "Chromium already installed"
fi

# =============================================================================
# STEP 5: USER ABC
# =============================================================================

sep
log "STEP 5: User abc"

id abc >/dev/null 2>&1 || {
    useradd -m -u 1000 -s /bin/bash -d "${ABC_HOME}" abc
    ok "User abc created"
}
echo "abc:sovereign" | chpasswd
mkdir -p "${ABC_HOME}"

for GRP in sudo docker kvm libvirt input video render audio plugdev; do
    getent group "${GRP}" >/dev/null 2>&1 && usermod -aG "${GRP}" abc 2>/dev/null || true
done

grep -q "^abc ALL=(ALL) NOPASSWD" /etc/sudoers 2>/dev/null || \
    echo "abc ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

ok "User abc ready (password: sovereign)"

# =============================================================================
# STEP 6: DOCKER CE
# =============================================================================

sep
log "STEP 6: Docker CE"

if [ "${HAS_DOCKER}" = "false" ]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io \
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
# STEP 7: /nexus-bucket
# =============================================================================

sep
log "STEP 7: /nexus-bucket"

mkdir -p "${NEXUS_BUCKET}"
chown -R abc:abc "${NEXUS_BUCKET}" 2>/dev/null || chown -R 1000:1000 "${NEXUS_BUCKET}" || true

if [ -d "${NEXUS_BUCKET}/underground-nexus/.git" ]; then
    git -C "${NEXUS_BUCKET}/underground-nexus" pull --rebase 2>/dev/null && \
        ok "underground-nexus updated" || warn "git pull failed (non-fatal)"
else
    git clone --depth=1 "${NEXUS_REPO}" "${NEXUS_BUCKET}/underground-nexus" && \
        ok "underground-nexus cloned" || warn "Clone failed — nexus0.sh will retry"
fi

chown -R abc:abc "${NEXUS_BUCKET}" 2>/dev/null || true
ok "/nexus-bucket ready"

# =============================================================================
# STEP 8: KDE PLASMA + KVM (skip if repair mode)
# =============================================================================

if [ "${REPAIR_ONLY}" = "false" ]; then
    sep
    log "STEP 8: KDE Plasma + KVM"

    apt-get install -y \
        qemu-kvm qemu-system-x86 \
        libvirt-daemon-system libvirt-clients \
        virt-manager bridge-utils ovmf cpu-checker \
        2>/dev/null | tail -5 || warn "KVM packages partial"

    usermod -aG kvm abc 2>/dev/null || true
    usermod -aG libvirt abc 2>/dev/null || true

    apt-get install -y \
        kubuntu-desktop plasma-desktop kwin-x11 \
        xorg xdg-utils xdg-user-dirs \
        2>&1 | tail -10

    ok "KDE Plasma installed"
    HAS_KDE=true
else
    sep
    log "STEP 8: KDE detected — skipping install (repair mode)"
fi

# =============================================================================
# STEP 9: GDM3 — DESKTOP DOES NOT START ON BOOT BY DEFAULT
# Engineers work in terminal. Type 'desktop' when the GUI is needed.
# This is intentional sovereign design for a server/hypervisor host.
# =============================================================================

sep
log "STEP 9: GDM3 (manual-launch design — no autoboot)"

apt-get install -y gdm3 2>/dev/null | tail -3 || warn "GDM3 install issue"

[ "${HAS_SDDM}" = "true" ] && systemctl disable sddm 2>/dev/null || true

# GDM3 config — autologin ready for when desktop IS launched
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

mkdir -p /var/lib/AccountsService/users/
cat > /var/lib/AccountsService/users/abc << 'ACCOUNTS'
[User]
Session=plasma
XSession=plasma
SystemAccount=false
ACCOUNTS

cat > "${ABC_HOME}/.dmrc" << 'DMRC'
[Desktop]
Session=plasma
DMRC
chown abc:abc "${ABC_HOME}/.dmrc"

# KEY: GDM3 disabled on boot — desktop is on-demand
systemctl disable gdm3 2>/dev/null || true
systemctl set-default multi-user.target 2>/dev/null || true

ok "GDM3 ready — NOT on boot (type 'desktop' to launch)"

# =============================================================================
# STEP 10: INPUT + SPICE + COMPOSITOR
# evdev confirmed working with virtio video + SPICE tablet in dev-logs.
# libinput was consistently broken. Compositor off = no input freeze.
# =============================================================================

sep
log "STEP 10: Input, SPICE, compositor"

# Clean ALL previous broken xorg configs from repair attempts
rm -f /etc/X11/xorg.conf.d/10-fbdev.conf \
      /etc/X11/xorg.conf.d/10-qxl.conf \
      /etc/X11/xorg.conf.d/40-libinput.conf \
      /etc/X11/xorg.conf.d/40-input.conf \
      /etc/X11/xorg.conf.d/50-evdev-tablet.conf \
      /etc/X11/xorg.conf.d/99-spice-input.rules \
      2>/dev/null || true

mkdir -p /etc/X11/xorg.conf.d

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

apt-get install -y xserver-xorg-input-evdev 2>/dev/null || warn "evdev pkg unavailable"

chmod 660 /dev/input/event* 2>/dev/null || true
chmod 660 /dev/input/mice 2>/dev/null || true
chown root:input /dev/input/event* 2>/dev/null || true
chown root:input /dev/input/mice 2>/dev/null || true

cat > /etc/udev/rules.d/99-input.rules << 'UDEV'
KERNEL=="event*", SUBSYSTEM=="input", GROUP="input", MODE="0660"
KERNEL=="mouse*", SUBSYSTEM=="input", GROUP="input", MODE="0660"
KERNEL=="mice", SUBSYSTEM=="input", GROUP="input", MODE="0660"
UDEV
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true

cat > /etc/X11/Xsession.d/99-spice-vdagent << 'XSESSION'
#!/bin/bash
[ -x /usr/bin/spice-vdagent ] && /usr/bin/spice-vdagent &
XSESSION
chmod +x /etc/X11/Xsession.d/99-spice-vdagent
systemctl enable spice-vdagentd 2>/dev/null || true

ok "evdev + SPICE configured"

# =============================================================================
# STEP 11: KDE USER CONFIG
# =============================================================================

sep
log "STEP 11: KDE user config"

mkdir -p "${ABC_HOME}/.config/plasma-workspace/env"
mkdir -p "${ABC_HOME}/.config/gtk-3.0"

cat > "${ABC_HOME}/.config/kwinrc" << 'KWIN'
[Compositing]
Enabled=false
OpenGLIsUnsafe=true

[Windows]
FocusPolicy=ClickToFocus
FocusPolicyIsResonant=true
KWIN

rm -f "${ABC_HOME}/.config/plasma-workspace/env/00-render.sh" \
      "${ABC_HOME}/.config/plasma-workspace/env/00-software-render.sh" \
      2>/dev/null || true

cat > "${ABC_HOME}/.config/plasma-workspace/env/00-session.sh" << 'ENVSH'
#!/bin/bash
export QT_QPA_PLATFORM=xcb
export LIBGL_ALWAYS_SOFTWARE=1
ENVSH
chmod +x "${ABC_HOME}/.config/plasma-workspace/env/00-session.sh"

cat > "${ABC_HOME}/.config/plasma-welcomerc" << 'WELCOME'
[General]
ShouldShow=false
WELCOME

cat > "${ABC_HOME}/.config/kwalletrc" << 'WALLET'
[Wallet]
Enabled=false
First Use=false
WALLET

cat > "${ABC_HOME}/.config/gtk-3.0/settings.ini" << 'GTK'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Breeze-Dark
GTK

cat > "${ABC_HOME}/.xprofile" << 'XPROFILE'
#!/bin/bash
[ -x /usr/bin/spice-vdagent ] && /usr/bin/spice-vdagent &
export QT_QPA_PLATFORM=xcb
XPROFILE
chmod +x "${ABC_HOME}/.xprofile"

chown -R abc:abc "${ABC_HOME}" 2>/dev/null || chown -R 1000:1000 "${ABC_HOME}" || true
ok "KDE user config ready"

# =============================================================================
# STEP 12: SYSTEM ENVIRONMENT
# =============================================================================

sep
log "STEP 12: System environment"

cat > /etc/environment << 'SYSENV'
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
QT_QPA_PLATFORM=xcb
SYSENV

ok "System environment clean"

# =============================================================================
# STEP 13: NEXUS0.SH — SOVEREIGN ARSENAL
# =============================================================================

sep
log "STEP 13: nexus0.sh — Sovereign Arsenal"

touch /.dockerenv 2>/dev/null || true

NEXUS0_TMP="/tmp/nexus0.sh"
if curl -fsSL --retry 3 --max-time 120 "${NEXUS0_URL}" -o "${NEXUS0_TMP}"; then
    chmod +x "${NEXUS0_TMP}"
    bash "${NEXUS0_TMP}" 2>&1 | tee -a "${LOG}"
    ok "nexus0.sh complete"
else
    warn "nexus0.sh download failed"
    warn "Manual: curl -fsSL ${NEXUS0_URL} | sudo bash"
fi
rm -f "${NEXUS0_TMP}"

# =============================================================================
# STEP 14: POST-NEXUS0 INTEGRITY REPAIR
# nexus0.sh may re-enable SDDM, write libinput, overwrite GDM config,
# and re-add the broken shiftkey repo. Fix everything back.
# =============================================================================

sep
log "STEP 14: Post-nexus0 integrity repair"

# Desktop stays manual-launch
systemctl disable sddm 2>/dev/null || true
systemctl disable gdm3 2>/dev/null || true
systemctl set-default multi-user.target 2>/dev/null || true

# Re-apply GDM3 config
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

# Re-apply evdev (nexus0 may have written libinput)
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

# Re-apply kwinrc
cat > "${ABC_HOME}/.config/kwinrc" << 'KWIN'
[Compositing]
Enabled=false
OpenGLIsUnsafe=true

[Windows]
FocusPolicy=ClickToFocus
KWIN
chown abc:abc "${ABC_HOME}/.config/kwinrc"

# Re-apply environment
cat > /etc/environment << 'SYSENV'
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
QT_QPA_PLATFORM=xcb
SYSENV

# Re-apply browser pins (nexus0 may clear them)
cat > /etc/apt/preferences.d/no-snap-browsers << 'PINBLOCK'
Package: firefox
Pin: release o=Ubuntu
Pin-Priority: -1

Package: chromium-browser
Pin: release o=Ubuntu
Pin-Priority: -1
PINBLOCK

cat > /etc/apt/preferences.d/mozilla-firefox << 'MOZPIN'
Package: *
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
MOZPIN

# Remove shiftkey again (nexus0 re-adds it and it always fails SSL)
rm -f /etc/apt/sources.list.d/shiftkey-packages.list \
      /etc/apt/sources.list.d/*shiftkey* \
      2>/dev/null || true

# Ownership
chown -R abc:abc "${NEXUS_BUCKET}" 2>/dev/null || chown -R 1000:1000 "${NEXUS_BUCKET}" || true
chown -R abc:abc "${ABC_HOME}" 2>/dev/null || true

ok "Post-nexus0 integrity repair complete"

# =============================================================================
# STEP 15: KVM + LIBVIRT
# =============================================================================

sep
log "STEP 15: KVM + libvirt"

systemctl enable libvirtd 2>/dev/null || true
systemctl start libvirtd 2>/dev/null || true
usermod -aG kvm abc 2>/dev/null || true
usermod -aG libvirt abc 2>/dev/null || true

[ -e /dev/kvm ] && {
    chmod 660 /dev/kvm 2>/dev/null || true
    chown root:kvm /dev/kvm 2>/dev/null || true
    ok "KVM: /dev/kvm accessible"
} || warn "KVM: /dev/kvm not found (appears after reboot on bare metal)"

ok "Libvirt enabled"

# =============================================================================
# STEP 16: SOVEREIGN PATH COMMANDS
# All installed to /usr/local/bin — available to all users in any shell
# =============================================================================

sep
log "STEP 16: Installing sovereign PATH commands"

# ── desktop ──────────────────────────────────────────────────────────────────
cat > "${COMMANDS_DIR}/desktop" << 'CMD'
#!/usr/bin/env bash
# Launch KDE Plasma desktop on demand
# Desktop does not start on boot — this is intentional server-first design
echo "[desktop] Starting KDE Plasma desktop..."
if systemctl is-active gdm3 >/dev/null 2>&1; then
    echo "[desktop] Desktop already running"
    echo "[desktop] Connect via SPICE console in virt-manager"
    exit 0
fi
sudo systemctl start gdm3
sleep 2
if systemctl is-active gdm3 >/dev/null 2>&1; then
    echo "[desktop] ✓ KDE Plasma running"
    echo "[desktop] Connect via virt-manager → VM console"
    echo "[desktop] To stop:          desktop-stop"
    echo "[desktop] To start on boot: desktop-on-boot"
else
    echo "[desktop] ✗ GDM3 failed — check: sudo journalctl -u gdm3 -n 20"
fi
CMD
chmod +x "${COMMANDS_DIR}/desktop"
ok "Command: desktop"

# ── desktop-stop ─────────────────────────────────────────────────────────────
cat > "${COMMANDS_DIR}/desktop-stop" << 'CMD'
#!/usr/bin/env bash
echo "[desktop-stop] Stopping KDE Plasma..."
sudo systemctl stop gdm3
echo "[desktop-stop] ✓ Desktop stopped — back to text mode"
echo "[desktop-stop] Type 'desktop' to restart"
CMD
chmod +x "${COMMANDS_DIR}/desktop-stop"
ok "Command: desktop-stop"

# ── desktop-on-boot ──────────────────────────────────────────────────────────
cat > "${COMMANDS_DIR}/desktop-on-boot" << 'CMD'
#!/usr/bin/env bash
echo "[desktop-on-boot] Enabling desktop autostart on boot..."
sudo systemctl enable gdm3
sudo systemctl set-default graphical.target
echo "[desktop-on-boot] ✓ Desktop will start on next reboot"
echo "[desktop-on-boot] To disable: desktop-no-boot"
CMD
chmod +x "${COMMANDS_DIR}/desktop-on-boot"
ok "Command: desktop-on-boot"

# ── desktop-no-boot ──────────────────────────────────────────────────────────
cat > "${COMMANDS_DIR}/desktop-no-boot" << 'CMD'
#!/usr/bin/env bash
echo "[desktop-no-boot] Disabling desktop autostart..."
sudo systemctl disable gdm3
sudo systemctl set-default multi-user.target
echo "[desktop-no-boot] ✓ Boot mode: text/server"
echo "[desktop-no-boot] Type 'desktop' to launch manually"
CMD
chmod +x "${COMMANDS_DIR}/desktop-no-boot"
ok "Command: desktop-no-boot"

# ── desktop-status ───────────────────────────────────────────────────────────
cat > "${COMMANDS_DIR}/desktop-status" << 'CMD'
#!/usr/bin/env bash
echo "=== Desktop Status ==="
echo "GDM3 active:  $(systemctl is-active gdm3 2>/dev/null || echo inactive)"
echo "GDM3 enabled: $(systemctl is-enabled gdm3 2>/dev/null || echo disabled)"
echo "Boot target:  $(systemctl get-default 2>/dev/null)"
echo ""
echo "=== Available Sessions ==="
ls /usr/share/xsessions/ 2>/dev/null | sed 's/^/  /'
CMD
chmod +x "${COMMANDS_DIR}/desktop-status"
ok "Command: desktop-status"

# ── nexus-update ─────────────────────────────────────────────────────────────
cat > "${COMMANDS_DIR}/nexus-update" << 'CMD'
#!/usr/bin/env bash
echo "[nexus-update] Updating underground-nexus..."
if [ -d /nexus-bucket/underground-nexus/.git ]; then
    git -C /nexus-bucket/underground-nexus pull --rebase && \
        echo "[nexus-update] ✓ Updated" || echo "[nexus-update] ✗ Pull failed"
else
    echo "[nexus-update] Cloning..."
    git clone --depth=1 https://github.com/Underground-Ops/underground-nexus.git \
        /nexus-bucket/underground-nexus
fi
chown -R abc:abc /nexus-bucket 2>/dev/null || true
CMD
chmod +x "${COMMANDS_DIR}/nexus-update"
ok "Command: nexus-update"

# ── kvm-status ───────────────────────────────────────────────────────────────
cat > "${COMMANDS_DIR}/kvm-status" << 'CMD'
#!/usr/bin/env bash
echo "=== KVM Status ==="
kvm-ok 2>/dev/null || echo "kvm-ok not available"
echo ""
echo "=== Libvirt ==="
systemctl is-active libvirtd
echo ""
echo "=== Running VMs ==="
sudo virsh list --all 2>/dev/null || echo "libvirtd not running"
echo ""
echo "=== KVM Device ==="
ls -la /dev/kvm 2>/dev/null || echo "/dev/kvm not found"
CMD
chmod +x "${COMMANDS_DIR}/kvm-status"
ok "Command: kvm-status"

# ── browser-repair ───────────────────────────────────────────────────────────
# Full implementation of the fix confirmed in dev-logs
cat > "${COMMANDS_DIR}/browser-repair" << 'CMD'
#!/usr/bin/env bash
echo "[browser-repair] Repairing Firefox + Chromium..."
export DEBIAN_FRONTEND=noninteractive

# Block snap wrappers
cat > /etc/apt/preferences.d/no-snap-browsers << 'PINBLOCK'
Package: firefox
Pin: release o=Ubuntu
Pin-Priority: -1
Package: chromium-browser
Pin: release o=Ubuntu
Pin-Priority: -1
PINBLOCK

# Remove snap firefox if present
apt-get remove --purge -y firefox 2>/dev/null | tail -2 || true

# Mozilla PPA + pin
add-apt-repository -y ppa:mozillateam/ppa 2>/dev/null || true
cat > /etc/apt/preferences.d/mozilla-firefox << 'MOZPIN'
Package: *
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
MOZPIN

# xtradeb for chromium
add-apt-repository -y ppa:xtradeb/apps 2>/dev/null || true

apt-get update -qq 2>/dev/null | tail -3
apt-get install -y firefox 2>&1 | tail -5
apt-get install -y chromium 2>/dev/null | tail -5

echo ""
firefox --version 2>/dev/null && echo "✓ Firefox OK" || echo "✗ Firefox failed"
command -v chromium >/dev/null 2>&1 && echo "✓ Chromium OK" || echo "✗ Chromium failed"
CMD
chmod +x "${COMMANDS_DIR}/browser-repair"
ok "Command: browser-repair"

# ── apt-repair ───────────────────────────────────────────────────────────────
cat > "${COMMANDS_DIR}/apt-repair" << 'CMD'
#!/usr/bin/env bash
echo "[apt-repair] Full apt integrity repair..."
export DEBIAN_FRONTEND=noninteractive

# Remove known broken repos (shiftkey SSL always fails per dev-logs)
echo "  Removing broken repos..."
rm -f /etc/apt/sources.list.d/*shiftkey* 2>/dev/null || true
rm -f /usr/share/keyrings/shiftkey-packages.gpg 2>/dev/null || true

# Fix dpkg
echo "  Fixing dpkg..."
dpkg --configure --force-confold -a 2>/dev/null || true
apt-get install -f -y 2>/dev/null || true

# Update
echo "  Updating..."
apt-get update 2>&1 | grep -E "^(Err|W):" || echo "  All repos OK"

# Upgrade
echo "  Upgrading..."
apt-get upgrade -y --fix-broken 2>&1 | tail -8

# Clean
apt-get autoremove -y -qq 2>/dev/null || true
apt-get clean 2>/dev/null || true

echo "[apt-repair] ✓ Complete"
CMD
chmod +x "${COMMANDS_DIR}/apt-repair"
ok "Command: apt-repair"

# ── nexus-health ─────────────────────────────────────────────────────────────
cat > "${COMMANDS_DIR}/nexus-health" << 'CMD'
#!/usr/bin/env bash
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║     DEV-METAL SOVEREIGN HEALTH CHECK     ║"
echo "╚══════════════════════════════════════════╝"
echo ""

chk() {
    local name="$1"; local cmd="$2"
    eval "${cmd}" >/dev/null 2>&1 && echo "  ✓ ${name}" || echo "  ✗ ${name}"
}

echo "── System ──────────────────────────────────"
chk "User abc"                    "id abc"
chk "Docker running"              "systemctl is-active docker"
chk "libvirtd running"            "systemctl is-active libvirtd"
chk "KVM device"                  "test -e /dev/kvm"
chk "/nexus-bucket"               "test -d /nexus-bucket"
chk "underground-nexus repo"      "test -d /nexus-bucket/underground-nexus/.git"

echo ""
echo "── Desktop ─────────────────────────────────"
chk "KDE Plasma installed"        "command -v plasmashell"
chk "GDM3 installed"              "command -v gdm3"
chk "Desktop currently active"    "systemctl is-active gdm3"
echo "  Boot target: $(systemctl get-default 2>/dev/null)"

echo ""
echo "── Browsers ────────────────────────────────"
chk "Firefox (real deb)"          "firefox --version 2>/dev/null | grep -q Mozilla"
chk "Chromium"                    "command -v chromium || command -v chromium-browser"

echo ""
echo "── Tools ───────────────────────────────────"
chk "VS Code"                     "command -v code"
chk "Docker CLI"                  "command -v docker"
chk "Ollama"                      "command -v ollama"
chk "virt-manager"                "command -v virt-manager"
chk "k9s"                         "command -v k9s"
chk "Zarf"                        "command -v zarf"
chk "Dagger"                      "command -v dagger"
chk "Lazydocker"                  "command -v lazydocker"
chk "Git"                         "command -v git"
chk "Blender"                     "command -v blender"
chk "GIMP"                        "command -v gimp"
chk "Inkscape"                    "command -v inkscape"

echo ""
echo "── Sovereign Commands ──────────────────────"
for C in desktop desktop-stop desktop-on-boot desktop-no-boot desktop-status \
         nexus-update kvm-status browser-repair apt-repair nexus-health \
         ollama-start ollama-stop docker-clean dev-metal-update; do
    chk "${C}" "command -v ${C}"
done

echo ""
echo "── Apt Repo Health ─────────────────────────"
BROKEN=$(apt-get update 2>&1 | grep -c "^Err:" || echo 0)
echo "  Broken repos: ${BROKEN}"
[ "${BROKEN}" -gt 0 ] && echo "  → Run: apt-repair" || echo "  ✓ All repos OK"

echo ""
echo "── Zombie Processes ────────────────────────"
ZOMBIES=$(ps aux | awk '$8=="Z"' | wc -l || echo 0)
echo "  Zombies: ${ZOMBIES}"
[ "${ZOMBIES}" -gt 2 ] && echo "  → Reboot recommended" || echo "  ✓ OK"

echo ""
CMD
chmod +x "${COMMANDS_DIR}/nexus-health"
ok "Command: nexus-health"

# ── ollama-start ─────────────────────────────────────────────────────────────
cat > "${COMMANDS_DIR}/ollama-start" << 'CMD'
#!/usr/bin/env bash
echo "[ollama-start] Starting Ollama..."
command -v ollama >/dev/null 2>&1 || { echo "Ollama not installed"; exit 1; }
pgrep -f "ollama serve" >/dev/null && { echo "[ollama-start] Already running"; exit 0; }
nohup ollama serve > /tmp/ollama.log 2>&1 &
sleep 2
curl -s http://localhost:11434/api/tags >/dev/null 2>&1 && \
    echo "[ollama-start] ✓ Ollama running at http://localhost:11434" || \
    echo "[ollama-start] ✗ Failed — check /tmp/ollama.log"
CMD
chmod +x "${COMMANDS_DIR}/ollama-start"
ok "Command: ollama-start"

# ── ollama-stop ──────────────────────────────────────────────────────────────
cat > "${COMMANDS_DIR}/ollama-stop" << 'CMD'
#!/usr/bin/env bash
pkill -f "ollama serve" 2>/dev/null && \
    echo "[ollama-stop] ✓ Stopped" || echo "[ollama-stop] Not running"
CMD
chmod +x "${COMMANDS_DIR}/ollama-stop"
ok "Command: ollama-stop"

# ── docker-clean ─────────────────────────────────────────────────────────────
cat > "${COMMANDS_DIR}/docker-clean" << 'CMD'
#!/usr/bin/env bash
echo "[docker-clean] Pruning Docker resources..."
docker system prune -f
docker volume prune -f
echo "[docker-clean] ✓ Done"
docker system df
CMD
chmod +x "${COMMANDS_DIR}/docker-clean"
ok "Command: docker-clean"

# ── dev-metal-update ─────────────────────────────────────────────────────────
cat > "${COMMANDS_DIR}/dev-metal-update" << 'DMCMD'
#!/usr/bin/env bash
echo "[dev-metal-update] Running latest dev-metal..."
curl -fsSL https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/dev-metal.sh \
    -o /tmp/dev-metal-latest.sh
chmod +x /tmp/dev-metal-latest.sh
sudo bash /tmp/dev-metal-latest.sh
DMCMD
chmod +x "${COMMANDS_DIR}/dev-metal-update"
ok "Command: dev-metal-update"

# =============================================================================
# STEP 17: DEV-METAL GUIDE
# =============================================================================

sep
log "STEP 17: Writing DEV-METAL-GUIDE.md"

mkdir -p "${NEXUS_BUCKET}"
cat > "${NEXUS_BUCKET}/DEV-METAL-GUIDE.md" << 'GUIDE'
# DEV-METAL Command Guide
**Cloud Underground · Sovereign KDE Desktop · v2.0**

## Philosophy
Server-first. The KDE desktop does **not** start on boot.
Engineers work in the terminal and launch the desktop on demand.
All sovereign commands are in PATH — type them from any shell.

---

## Desktop Commands

| Command | What it does |
|---------|-------------|
| `desktop` | Start KDE Plasma (launches GDM3) |
| `desktop-stop` | Stop desktop, return to text mode |
| `desktop-on-boot` | Enable desktop autostart on boot |
| `desktop-no-boot` | Disable desktop autostart (server mode) |
| `desktop-status` | Show desktop state + boot config |

```bash
# Launch desktop
desktop

# When done, free resources
desktop-stop

# For a workstation that always needs GUI
desktop-on-boot
```

---

## System Health + Repair

| Command | What it does |
|---------|-------------|
| `nexus-health` | Full sovereign stack health check |
| `apt-repair` | Fix dpkg, remove broken repos, update + upgrade |
| `browser-repair` | Reinstall Firefox + Chromium as real debs |
| `dev-metal-update` | Re-run latest dev-metal (repairs everything) |

```bash
# First thing to run when something seems wrong
nexus-health

# Fix apt issues
apt-repair

# Fix browsers
browser-repair
```

---

## Underground Nexus

| Command | What it does |
|---------|-------------|
| `nexus-update` | Pull latest underground-nexus repo |

**Location:** `/nexus-bucket/underground-nexus`

---

## KVM / Hypervisor

| Command | What it does |
|---------|-------------|
| `kvm-status` | KVM device, libvirt state, running VMs |

```bash
kvm-status
desktop  # then launch virt-manager from the GUI
```

---

## AI / Ollama

| Command | What it does |
|---------|-------------|
| `ollama-start` | Start Ollama at localhost:11434 |
| `ollama-stop` | Stop Ollama |

```bash
ollama-start
ollama run mistral
```

---

## Browsers
Two browsers — both real native debs, no snap:
- **Firefox** via Mozilla Team PPA
- **Chromium** via xtradeb PPA

If either fails: `browser-repair`

---

## Docker

| Command | What it does |
|---------|-------------|
| `docker ps` | List containers |
| `lazydocker` | Terminal Docker UI |
| `docker-clean` | Prune images/volumes |

---

## Logs

| File | Contents |
|------|---------|
| `/tmp/dev-metal.log` | Dev-metal install log |
| `/tmp/nexus0-install.log` | nexus0.sh arsenal log |
| `/tmp/ollama.log` | Ollama server log |

---

## Quick Reference

```bash
nexus-health        # health check
desktop             # start GUI
desktop-stop        # stop GUI
apt-repair          # fix packages
browser-repair      # fix browsers
nexus-update        # update repo
kvm-status          # check VMs
ollama-start        # start AI
dev-metal-update    # full repair/update
```

---
*DEV-METAL v2.0.0 · Cloud Underground · Underground Nexus*
GUIDE

chown -R abc:abc "${NEXUS_BUCKET}" 2>/dev/null || true
ok "Guide: ${NEXUS_BUCKET}/DEV-METAL-GUIDE.md"

# =============================================================================
# STEP 18: FINAL CLEANUP
# =============================================================================

sep
log "STEP 18: Final cleanup"

chown -R abc:abc "${ABC_HOME}" 2>/dev/null || true
chown -R abc:abc "${NEXUS_BUCKET}" 2>/dev/null || true
apt-get autoremove -y -qq 2>/dev/null || true
apt-get clean 2>/dev/null || true

ZOMBIE_COUNT=$(ps aux | awk '$8=="Z"' | wc -l 2>/dev/null || echo 0)
[ "${ZOMBIE_COUNT}" -gt 0 ] && \
    warn "Zombie processes: ${ZOMBIE_COUNT} — reboot will clear these" || true

ok "Cleanup complete"

# =============================================================================
# SUMMARY
# =============================================================================

sep
echo -e "${BOLD}${GREEN}  DEV-METAL v${SCRIPT_VERSION} COMPLETE${NC}"
sep
log ""
log "ENVIRONMENT:"
log "  User:        abc / sovereign"
log "  Desktop:     KDE Plasma X11 — type 'desktop' to launch"
log "  Boot mode:   text/server (desktop NOT on boot)"
log "  Input:       evdev (SPICE virtio tablet compatible)"
log "  Browsers:    Firefox (Mozilla PPA) + Chromium (xtradeb PPA)"
log ""
log "SOVEREIGN COMMANDS:"
log "  desktop           start desktop"
log "  desktop-stop      stop desktop"
log "  desktop-on-boot   enable desktop on boot"
log "  desktop-no-boot   disable desktop on boot"
log "  desktop-status    desktop state"
log "  nexus-health      full health check  ← run this first"
log "  apt-repair        fix apt/dpkg"
log "  browser-repair    fix Firefox + Chromium"
log "  nexus-update      pull latest repo"
log "  kvm-status        show VMs"
log "  ollama-start      start AI"
log "  docker-clean      prune docker"
log "  dev-metal-update  full repair/update"
log ""
log "GUIDE: ${NEXUS_BUCKET}/DEV-METAL-GUIDE.md"
log "LOG:   ${LOG}"
log ""
log "AFTER REBOOT:"
log "  ssh abc@<ip>"
log "  nexus-health"
log "  desktop   (when you need the GUI)"
sep

echo ""
read -t 20 -p "Reboot now? [Y/n] " REBOOT_ANS || REBOOT_ANS="y"
if [[ "${REBOOT_ANS,,}" != "n" ]]; then
    log "Rebooting..."
    reboot
else
    log "Run 'sudo reboot' when ready, then: nexus-health"
fi
