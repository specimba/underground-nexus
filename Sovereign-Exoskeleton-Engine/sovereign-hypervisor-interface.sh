#!/usr/bin/env bash
# =============================================================================
# SOVEREIGN HYPERVISOR — Branding Injection Script
# Cloud Underground · Underground Nexus · Nexus Creator Vault
# =============================================================================
#
# USAGE — run as root or with sudo:
#   sudo bash sovereign-hypervisor-brand.sh
#
# Self-elevates automatically if not already root.
# =============================================================================

# --- Self-elevate to root if needed ---
if [ "$(id -u)" -ne 0 ]; then
    echo "[sovereign-brand] Not root — re-running with sudo..."
    exec sudo bash "$0" "$@"
fi
#
# DROP-IN USAGE:
#   Paste and run inside a running nexus-creator-vault container shell.
#   Requires: virt-manager already installed (nexus0.sh Step 5 covers this).
#   Safe to run multiple times — idempotent, all operations use || true.
#
# WHAT THIS DOES:
#   1. Checks and installs missing dependencies (wget, imagemagick, python3)
#   2. Downloads Cloud Underground SVG logo from the underground-nexus repo
#   3. Generates PNG icons at all required icon sizes
#   4. Patches virt-manager desktop entry (name, comment, icon)
#   5. Patches Python/UI source files (window titles, about dialog)
#   6. Writes VPAT-compliant GTK3 CSS (dark theme, high contrast, CU palette)
#   7. Writes KDE Plasma color scheme to match GTK theme
#   8. Refreshes icon cache
#
# BRAND PALETTE (Cloud Underground):
#   Deep Navy:     #0b1021  (window backgrounds)
#   Midnight:      #060913  (header bars, panels)
#   Sovereign Cyan:#00e5cc  (primary accent, borders, hover text)
#   Amber Alert:   #ffb300  (warnings, indicators)
#   Pure White:    #ffffff  (body text — 21:1 contrast on navy = WCAG AAA)
#   Light Steel:   #c8d6e5  (secondary text — 9.3:1 on navy = WCAG AAA)
#   Danger Red:    #ff4757  (error states)
#
# WCAG 2.1 / VPAT COMPLIANCE:
#   All text contrast ratios ≥ 4.5:1 (AA) — most ≥ 7:1 (AAA)
#   Button states (normal/hover/focus/active) all defined
#   Focus ring: 2px solid cyan — clearly visible keyboard navigation
#
# KUBEVIRT NOTE:
#   This script brands the LOCAL virt-manager (GTK, KVM-backed VMs).
#   KubeVirt workloads are managed separately via LLM ontology (Golden Twin).
#   The roadmap: virt-manager handles local/dev VMs inside the Creator Vault;
#   KubeVirt handles production distributed VMs via ChatOps approve/deny flow.
#
# =============================================================================

set -o pipefail

SH_LOG="/tmp/sovereign-hypervisor-brand.log"
log()  { echo "[sovereign-brand] $*" | tee -a "${SH_LOG}"; }
ok()   { echo "[sovereign-brand] ✓ $*" | tee -a "${SH_LOG}"; }
warn() { echo "[sovereign-brand] ⚠ $*" | tee -a "${SH_LOG}"; }
err()  { echo "[sovereign-brand] ✗ $*" | tee -a "${SH_LOG}" >&2; }

log "═══════════════════════════════════════════════════════════"
log " Sovereign Hypervisor — Branding Injection"
log " Cloud Underground · Underground Nexus"
log " $(date)"
log "═══════════════════════════════════════════════════════════"

# =============================================================================
# STEP 0: DEPENDENCY CHECK + INSTALL
# =============================================================================

log "STEP 0: Checking dependencies..."

export DEBIAN_FRONTEND=noninteractive

# wget — asset downloads
command -v wget >/dev/null 2>&1 || {
    log "  Installing wget..."
    apt-get install -y -qq wget 2>/dev/null || true
}

# python3 — virt-manager is Python; we need it for file patching verification
command -v python3 >/dev/null 2>&1 || {
    log "  Installing python3..."
    apt-get install -y -qq python3 2>/dev/null || true
}

# imagemagick — PNG generation from SVG at multiple sizes
command -v convert >/dev/null 2>&1 || {
    log "  Installing imagemagick..."
    apt-get install -y -qq imagemagick 2>/dev/null || warn "imagemagick unavailable — icon sizes will be manual copies"
}

# librsvg2-bin — rsvg-convert for higher-quality SVG→PNG (preferred over imagemagick for SVGs)
command -v rsvg-convert >/dev/null 2>&1 || {
    log "  Installing librsvg2-bin..."
    apt-get install -y -qq librsvg2-bin 2>/dev/null || true
}

ok "Dependencies checked"

# =============================================================================
# STEP 1: VERIFY VIRT-MANAGER IS INSTALLED
# =============================================================================

log "STEP 1: Verifying virt-manager installation..."

if ! command -v virt-manager >/dev/null 2>&1; then
    err "virt-manager not found. Run nexus0.sh Step 5 first to install KVM/QEMU/virt-manager."
    err "  sudo apt-get install -y virt-manager libvirt-daemon-system libvirt-clients"
    exit 1
fi

VIRT_VERSION=$(virt-manager --version 2>/dev/null || echo "unknown")
ok "virt-manager found (version: ${VIRT_VERSION})"

# =============================================================================
# STEP 2: ASSET ACQUISITION
# =============================================================================

log "STEP 2: Fetching Cloud Underground brand assets..."

ASSET_DIR="/tmp/sovereign-brand-assets"
mkdir -p "${ASSET_DIR}"

# Primary logo sources — tries multiple paths from the underground-nexus repo
# SVG is preferred (vector, scales to any size perfectly)
SVG_LOGO="${ASSET_DIR}/cu-logo.svg"
PNG_LOGO="${ASSET_DIR}/cu-logo.png"

SVG_URLS=(
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/Production%20Artifacts/Wordpress/nexus-creator-vault/images/CU-Logo.svg"
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/Branding/CU-Logo.svg"
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/branding/cu-logo.svg"
)

PNG_URLS=(
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/Production%20Artifacts/Wordpress/nexus-creator-vault/images/CU-Logo.png"
    "https://raw.githubusercontent.com/Underground-Ops/underground-nexus/main/Branding/CU-Logo.png"
)

LOGO_FOUND=false

# Try SVG first
for URL in "${SVG_URLS[@]}"; do
    if wget -q --timeout=15 "${URL}" -O "${SVG_LOGO}" 2>/dev/null && [ -s "${SVG_LOGO}" ]; then
        ok "SVG logo downloaded from: ${URL}"
        LOGO_FOUND=true
        break
    fi
done

# Try PNG if SVG failed
if [ "${LOGO_FOUND}" = "false" ]; then
    for URL in "${PNG_URLS[@]}"; do
        if wget -q --timeout=15 "${URL}" -O "${PNG_LOGO}" 2>/dev/null && [ -s "${PNG_LOGO}" ]; then
            ok "PNG logo downloaded from: ${URL}"
            LOGO_FOUND=true
            break
        fi
    done
fi

# Fallback: generate the Sovereign Hypervisor logo as SVG inline
# This is a clean geometric mark using Cloud Underground's cyan + navy palette
if [ "${LOGO_FOUND}" = "false" ]; then
    warn "Remote logo fetch failed — generating inline Sovereign Hypervisor mark..."
    cat > "${SVG_LOGO}" << 'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
  <!-- Background: Deep Navy -->
  <rect width="512" height="512" rx="64" fill="#0b1021"/>
  <!-- Outer hexagon ring — Sovereign Cyan -->
  <polygon points="256,40 440,152 440,360 256,472 72,360 72,152"
           fill="none" stroke="#00e5cc" stroke-width="16" stroke-linejoin="round"/>
  <!-- Inner hexagon — Midnight fill -->
  <polygon points="256,96 400,176 400,336 256,416 112,336 112,176"
           fill="#060913" stroke="#00e5cc" stroke-width="8" stroke-linejoin="round"/>
  <!-- CU lettermark — white -->
  <text x="256" y="300" font-family="'Courier New', monospace" font-size="160"
        font-weight="700" text-anchor="middle" fill="#ffffff" letter-spacing="-8">CU</text>
  <!-- Amber accent bar at bottom -->
  <rect x="160" y="420" width="192" height="8" rx="4" fill="#ffb300"/>
</svg>
SVGEOF
    LOGO_FOUND=true
    ok "Inline Sovereign Hypervisor mark generated"
fi

# =============================================================================
# STEP 3: GENERATE PNG ICONS AT ALL REQUIRED SIZES
# =============================================================================

log "STEP 3: Generating PNG icons at all required sizes..."

ICON_SIZES=(16 24 32 48 64 128 256 512)
ICON_BASE_DIR="/usr/share/icons/hicolor"

generate_png() {
    local SIZE="$1"
    local OUTPUT="$2"
    mkdir -p "$(dirname "${OUTPUT}")"

    if [ -f "${SVG_LOGO}" ] && command -v rsvg-convert >/dev/null 2>&1; then
        rsvg-convert -w "${SIZE}" -h "${SIZE}" "${SVG_LOGO}" -o "${OUTPUT}" 2>/dev/null && return 0
    fi

    if [ -f "${SVG_LOGO}" ] && command -v convert >/dev/null 2>&1; then
        convert -background none -size "${SIZE}x${SIZE}" "${SVG_LOGO}" "${OUTPUT}" 2>/dev/null && return 0
    fi

    if [ -f "${PNG_LOGO}" ] && command -v convert >/dev/null 2>&1; then
        convert -resize "${SIZE}x${SIZE}" "${PNG_LOGO}" "${OUTPUT}" 2>/dev/null && return 0
    fi

    # Last resort: copy the source PNG as-is
    if [ -f "${PNG_LOGO}" ]; then
        cp "${PNG_LOGO}" "${OUTPUT}" 2>/dev/null && return 0
    fi

    return 1
}

for SIZE in "${ICON_SIZES[@]}"; do
    OUT="${ICON_BASE_DIR}/${SIZE}x${SIZE}/apps/virt-manager.png"
    generate_png "${SIZE}" "${OUT}" \
        && log "  ✓ ${SIZE}x${SIZE} icon written" \
        || warn "  Could not generate ${SIZE}x${SIZE} icon"
done

# Pixmap (used by some legacy apps and the .desktop file)
if [ -f "${SVG_LOGO}" ] || [ -f "${PNG_LOGO}" ]; then
    generate_png 256 "/usr/share/pixmaps/virt-manager.png" \
        && ok "Pixmap written" || warn "Pixmap write failed"
fi

# Replace SVG icon with Sovereign mark
if [ -f "${SVG_LOGO}" ] && [ -f "/usr/share/icons/hicolor/scalable/apps/virt-manager.svg" ]; then
    cp "/usr/share/icons/hicolor/scalable/apps/virt-manager.svg" \
       "/usr/share/icons/hicolor/scalable/apps/virt-manager.svg.bak" 2>/dev/null || true
    cp "${SVG_LOGO}" "/usr/share/icons/hicolor/scalable/apps/virt-manager.svg" 2>/dev/null \
        && ok "Scalable SVG icon replaced" || warn "Scalable SVG replace failed"
fi

ok "Icon generation complete"

# =============================================================================
# STEP 4: DESKTOP ENTRY PATCH
# =============================================================================

log "STEP 4: Patching .desktop launcher entry..."

DESKTOP_FILE="/usr/share/applications/virt-manager.desktop"

if [ -f "${DESKTOP_FILE}" ]; then
    # Backup original
    cp "${DESKTOP_FILE}" "${DESKTOP_FILE}.bak" 2>/dev/null || true

    # sed -i creates a temp file in the same directory.
    # On some systems /usr/share/applications is on a read-only or restricted fs.
    # Workaround: copy to /tmp, patch there, copy back.
    DESK_TMP="/tmp/virt-manager.desktop.patching"
    cp "${DESKTOP_FILE}" "${DESK_TMP}"

    sed -i 's/^Name=.*/Name=Sovereign Hypervisor/g'               "${DESK_TMP}"
    sed -i '/^Name\[/d'                                             "${DESK_TMP}"
    sed -i 's/^GenericName=.*/GenericName=Sovereign Hypervisor/g' "${DESK_TMP}"
    sed -i 's/^Comment=.*/Comment=Sovereign Exocortex KVM Engine — Cloud Underground/g' "${DESK_TMP}"
    sed -i '/^Comment\[/d'                                          "${DESK_TMP}"
    sed -i 's/^Icon=.*/Icon=virt-manager/g'                        "${DESK_TMP}"

    cp "${DESK_TMP}" "${DESKTOP_FILE}" 2>/dev/null \
        && ok "Desktop entry patched: $(grep '^Name=' "${DESKTOP_FILE}")" \
        || warn "Could not write back desktop entry (check permissions)"
    rm -f "${DESK_TMP}"
else
    warn "Desktop file not found at ${DESKTOP_FILE} — may be at different path"
    find /usr/share/applications -name "*virt*" 2>/dev/null | while read -r f; do
        warn "  Found: ${f}"
    done
fi

# =============================================================================
# STEP 5: PYTHON / UI FILE PATCHES
# =============================================================================

log "STEP 5: Patching virt-manager Python and UI files..."

patch_file() {
    local FILE="$1"
    shift
    if [ -f "${FILE}" ]; then
        # Skip compiled .pyc bytecode — sed cannot patch binary files,
        # and Python regenerates .pyc from source on next run anyway.
        case "${FILE}" in *.pyc) warn "Skipping .pyc (binary): ${FILE}"; return 0 ;; esac

        # Backup on first patch
        [ -f "${FILE}.bak" ] || cp "${FILE}" "${FILE}.bak" 2>/dev/null || true

        # Use temp file to avoid sed permission issues on /usr/share
        local TMP_FILE
        TMP_FILE=$(mktemp /tmp/sovereign-patch.XXXXXX)
        cp "${FILE}" "${TMP_FILE}"

        while [ $# -ge 2 ]; do
            local FROM="$1"; local TO="$2"; shift 2
            sed -i "s|${FROM}|${TO}|g" "${TMP_FILE}" 2>/dev/null || true
        done

        cp "${TMP_FILE}" "${FILE}" 2>/dev/null \
            && ok "Patched: ${FILE}" \
            || warn "Could not write back: ${FILE}"
        rm -f "${TMP_FILE}"
    else
        warn "Not found (skipping): ${FILE}"
    fi
}

# --- About dialog ---
patch_file "/usr/share/virt-manager/ui/vmm-about.ui" \
    "Virtual Machine Manager" "Sovereign Hypervisor" \
    "Powered by libvirt"      "Powered by Sovereign dRAG" \
    "Red Hat"                 "Cloud Underground" \
    "virt-manager"            "sovereign-hypervisor"

# --- Manager window title ---
patch_file "/usr/share/virt-manager/ui/manager.ui" \
    "Virtual Machine Manager" "Sovereign Hypervisor"

# --- Engine (main app title) ---
patch_file "/usr/share/virt-manager/virtManager/engine.py" \
    "Virtual Machine Manager" "Sovereign Hypervisor"

# --- App module (handles window titles in newer versions) ---
patch_file "/usr/share/virt-manager/virtManager/app.py" \
    "Virtual Machine Manager" "Sovereign Hypervisor" \
    "virt-manager"            "sovereign-hypervisor"

# --- Connection manager dialog ---
patch_file "/usr/share/virt-manager/ui/connect.ui" \
    "Virtual Machine Manager" "Sovereign Hypervisor"

# Sweep all Python files for remaining "Virtual Machine Manager" strings
# Explicitly exclude .pyc — they are binary bytecode, patching them corrupts Python
VM_MGR_FILES=$(grep -rl "Virtual Machine Manager" /usr/share/virt-manager/ 2>/dev/null \
    | grep -v '\.pyc$' || true)
if [ -n "${VM_MGR_FILES}" ]; then
    log "  Sweeping remaining files..."
    echo "${VM_MGR_FILES}" | while read -r F; do
        [ -f "${F}.bak" ] || cp "${F}" "${F}.bak" 2>/dev/null || true
        TMP_SW=$(mktemp /tmp/sovereign-sweep.XXXXXX)
        cp "${F}" "${TMP_SW}"
        sed -i 's/Virtual Machine Manager/Sovereign Hypervisor/g' "${TMP_SW}" 2>/dev/null || true
        cp "${TMP_SW}" "${F}" 2>/dev/null && ok "  Swept: ${F}" || warn "  Could not write: ${F}"
        rm -f "${TMP_SW}"
    done
fi

ok "Python/UI patches complete"

# =============================================================================
# STEP 6: INSTALL AS PROPER NAMED GTK3 THEME
# =============================================================================
#
# WHY THE PREVIOUS APPROACH FAILED:
# Writing to /etc/gtk-3.0/gtk.css works in theory but KDE Plasma uses
# Breeze-GTK as its GTK theme engine. Breeze-GTK loads its CSS AFTER
# /etc/gtk-3.0/gtk.css via KDE's GTK integration daemon, overriding
# everything we write there. !important only helps if OUR file loads last.
#
# THE CORRECT APPROACH (how Arc-Dark, Dracula, etc. all work):
# Install CSS as a named GTK3 theme in /usr/share/themes/SovereignHypervisor/
# Then set gtk-theme-name=SovereignHypervisor in settings.ini.
# GTK loads the NAMED THEME css, then /etc/ overrides on top, then user config.
# By being the named theme, we ARE position 2 in the cascade — Breeze is bypassed.
#
# ALSO: set the theme name via gsettings AND xsettings so both X11 and Wayland
# honor it regardless of how KDE's bridge decides to load GTK.
# =============================================================================

log "STEP 6: Installing SovereignHypervisor as named GTK3 theme..."

THEME_DIR="/usr/share/themes/SovereignHypervisor/gtk-3.0"
mkdir -p "${THEME_DIR}"

# Write the GTK index.theme file
cat > "/usr/share/themes/SovereignHypervisor/index.theme" << 'IDXEOF'
[Desktop Entry]
Type=X-GNOME-Metatheme
Name=SovereignHypervisor
Comment=Cloud Underground Sovereign Hypervisor Dark Theme
Encoding=UTF-8

[X-GNOME-Metatheme]
GtkTheme=SovereignHypervisor
MetacityTheme=SovereignHypervisor
IconTheme=hicolor
CursorTheme=default
ButtonLayout=close,minimize,maximize:
IDXEOF

# Write the full GTK3 CSS as the named theme
cat > "${THEME_DIR}/gtk.css" << 'GTKEOF'
/* ==========================================================================
   SOVEREIGN HYPERVISOR — Named GTK3 Theme
   Cloud Underground · VPAT-Compliant Dark Mode
   Installed as /usr/share/themes/SovereignHypervisor/gtk-3.0/gtk.css
   This file IS the theme — it loads at cascade position 2, BEFORE any
   KDE Breeze-GTK override can run. !important is not needed here because
   we own the theme slot.

   Brand Palette (cloudunderground.dev):
     Deep Navy:      #0b1021  bg
     Midnight:       #060913  panels/headers
     Layer 2:        #0d1529  sidebars/toolbars
     Layer 3:        #1a2540  button normal bg
     Border subtle:  #1e2d4a  separators
     Sovereign Cyan: #00e5cc  primary accent (10.2:1 on navy — WCAG AAA)
     Chartreuse:     #c6ef3b  secondary accent / highlight (12.1:1 on navy)
     Amber:          #ffb300  warnings (11.4:1 on navy — AAA)
     White:          #ffffff  body text (21:1 — AAA)
     Steel:          #c8d6e5  secondary text (9.3:1 — AAA)
     Danger Red:     #ff4757  destructive
   ========================================================================== */

/* ---- GLOBAL RESET ---- */
* {
    -gtk-icon-style: regular;
    outline-color: #00e5cc;
    outline-offset: 2px;
}

/* ---- BASE WINDOW ---- */
window, .background, GtkWindow {
    background-color: #0b1021;
    color: #ffffff;
}

/* ---- ALL LABELS default to white ---- */
label { color: #ffffff; }
label.dim-label, label.secondary { color: #c8d6e5; }

/* ---- HEADER BAR ---- */
headerbar, headerbar.titlebar, .titlebar {
    background-color: #060913;
    border-bottom: 2px solid #00e5cc;
    padding: 4px 8px;
    color: #ffffff;
}
headerbar label, .titlebar label { color: #ffffff; font-weight: 700; }
headerbar .title { color: #ffffff; font-weight: 700; font-size: 13px; }
headerbar .subtitle { color: #c8d6e5; font-size: 11px; }

/* ---- TOOLBAR ---- */
toolbar, .toolbar {
    background-color: #0d1529;
    border-bottom: 1px solid #1e2d4a;
    padding: 2px;
}
toolbar image, toolbar button image,
.toolbar image, .toolbar button image,
toolbutton image, toolbutton > button > image {
    color: #ffffff;
    -gtk-icon-style: regular;
}
toolbar button, .toolbar button, toolbutton > button {
    background-color: #1a2540;
    color: #ffffff;
    border: 1px solid #1e2d4a;
    border-radius: 4px;
    padding: 4px 6px;
    min-width: 28px;
    min-height: 28px;
    box-shadow: none;
}
toolbar button:hover, toolbutton > button:hover {
    background-color: #00e5cc;
    color: #0b1021;
    border-color: #00e5cc;
}
toolbar button:hover image { color: #0b1021; }

/* ---- SIDEBAR / TREE ---- */
list, .sidebar, treeview, .view {
    background-color: #0d1529;
    color: #ffffff;
}
treeview:selected, list row:selected, .view:selected {
    background-color: #00e5cc;
    color: #0b1021;
}
treeview:selected label { color: #0b1021; }
treeview header button, treeview header {
    background-color: #060913;
    color: #c8d6e5;
    border-bottom: 1px solid #1e2d4a;
}
treeview header button label { color: #c8d6e5; }

/* ====================================================================
   BUTTONS — THE KEY SECTION
   Being the named theme means these rules are authoritative.
   Breeze-GTK no longer participates. No !important needed.
   ==================================================================== */

/* ---- BASE BUTTON ---- */
button {
    background-color: #1a2540;
    color: #ffffff;
    border: 1px solid #00e5cc;
    border-radius: 6px;
    padding: 5px 12px;
    font-size: 12px;
    box-shadow: none;
    text-shadow: none;
}
button label { color: #ffffff; }
button image { color: #ffffff; -gtk-icon-style: regular; }

button:hover {
    background-color: #00e5cc;
    color: #0b1021;
    border-color: #00e5cc;
}
button:hover label { color: #0b1021; }
button:hover image { color: #0b1021; }

button:active {
    background-color: #009e8e;
    color: #ffffff;
}
button:focus {
    outline: 2px solid #c6ef3b;
    outline-offset: 2px;
    box-shadow: none;
}
button:disabled {
    background-color: #0d1529;
    color: #4a5568;
    border-color: #2d3748;
    opacity: 0.55;
}
button:disabled label, button:disabled image { color: #4a5568; }

/* Flat buttons — override the no-bg Adwaita flat style */
button.flat {
    background-color: #1a2540;
    color: #ffffff;
    border: 1px solid #1e2d4a;
    border-radius: 6px;
    box-shadow: none;
}
button.flat label { color: #ffffff; }
button.flat image { color: #ffffff; }
button.flat:hover {
    background-color: #00e5cc;
    color: #0b1021;
    border-color: #00e5cc;
}
button.flat:hover label { color: #0b1021; }
button.flat:hover image { color: #0b1021; }

/* Destructive (delete / X / remove) */
button.destructive-action {
    background-color: #2d0a0a;
    color: #ff4757;
    border-color: #ff4757;
}
button.destructive-action label { color: #ff4757; }
button.destructive-action image { color: #ff4757; }
button.destructive-action:hover { background-color: #ff4757; color: #ffffff; }
button.destructive-action:hover label, button.destructive-action:hover image { color: #ffffff; }

/* Suggested / primary action (Forward, Finish, Create) */
button.suggested-action {
    background-color: #003d35;
    color: #00e5cc;
    border: 2px solid #00e5cc;
}
button.suggested-action label { color: #00e5cc; }
button.suggested-action image { color: #00e5cc; }
button.suggested-action:hover { background-color: #00e5cc; color: #0b1021; }
button.suggested-action:hover label, button.suggested-action:hover image { color: #0b1021; }

/* Image-only / icon buttons */
button.image-button {
    background-color: #1a2540;
    border: 1px solid #1e2d4a;
    border-radius: 6px;
    padding: 4px 6px;
    min-width: 28px;
    min-height: 28px;
}
button.image-button image { color: #ffffff; }
button.image-button:hover { background-color: #00e5cc; border-color: #00e5cc; }
button.image-button:hover image { color: #0b1021; }

/* Circular icon buttons */
button.circular {
    background-color: #1a2540;
    border: 1px solid #00e5cc;
    border-radius: 50%;
    padding: 4px;
    min-width: 28px;
    min-height: 28px;
}
button.circular image { color: #ffffff; }
button.circular:hover { background-color: #00e5cc; }
button.circular:hover image { color: #0b1021; }

/* Link buttons */
button.link {
    background: transparent;
    border: none;
    color: #00e5cc;
    box-shadow: none;
    padding: 2px 4px;
}
button.link label { color: #00e5cc; }
button.link:hover { color: #c6ef3b; }
button.link:hover label { color: #c6ef3b; }

/* ---- LINKED button groups (Volume +/↺/⊕, etc.) ---- */
.linked > button {
    background-color: #1a2540;
    color: #ffffff;
    border: 1px solid #1e2d4a;
    border-radius: 0;
    padding: 4px 8px;
    box-shadow: none;
}
.linked > button + button { border-left: none; }
.linked > button:first-child { border-radius: 6px 0 0 6px; }
.linked > button:last-child  { border-radius: 0 6px 6px 0; }
.linked > button:only-child  { border-radius: 6px; }
.linked > button label { color: #ffffff; }
.linked > button image { color: #ffffff; }
.linked > button:hover { background-color: #00e5cc; color: #0b1021; border-color: #00e5cc; }
.linked > button:hover label { color: #0b1021; }
.linked > button:hover image { color: #0b1021; }
.linked > button.destructive-action { background-color: #2d0a0a; border-color: #ff4757; }
.linked > button.destructive-action image { color: #ff4757; }
.linked > button.destructive-action:hover { background-color: #ff4757; }
.linked > button.destructive-action:hover image { color: #ffffff; }

/* ---- ACTION BAR (bottom button strip) ---- */
actionbar {
    background-color: #0b1021;
    border-top: 1px solid #1e2d4a;
    padding: 4px 8px;
}
actionbar > revealer > box, actionbar > box {
    background-color: #0b1021;
}
actionbar button {
    background-color: #1a2540;
    color: #ffffff;
    border: 1px solid #00e5cc;
    border-radius: 6px;
    min-width: 32px;
    min-height: 32px;
    padding: 4px 8px;
    box-shadow: none;
}
actionbar button label { color: #ffffff; }
actionbar button image { color: #ffffff; -gtk-icon-style: regular; }
actionbar button:hover { background-color: #00e5cc; color: #0b1021; border-color: #00e5cc; }
actionbar button:hover image { color: #0b1021; }
actionbar button:hover label { color: #0b1021; }
actionbar button.destructive-action { background-color: #2d0a0a; color: #ff4757; border-color: #ff4757; }
actionbar button.destructive-action image { color: #ff4757; }
actionbar button.destructive-action:hover { background-color: #ff4757; color: #ffffff; }
actionbar button.destructive-action:hover image { color: #ffffff; }

/* ---- DIALOG / WIZARD ACTION BUTTONS ---- */
.dialog-action-area, .dialog-action-box {
    background-color: #060913;
    border-top: 1px solid #1e2d4a;
    padding: 8px 12px;
}
.dialog-action-area > button,
dialog > box > box > button,
dialog > box > .dialog-action-area > button {
    background-color: #1a2540;
    color: #ffffff;
    border: 1px solid #00e5cc;
    border-radius: 6px;
    padding: 6px 18px;
    min-height: 32px;
    box-shadow: none;
}
.dialog-action-area > button label { color: #ffffff; }
.dialog-action-area > button image { color: #ffffff; }
.dialog-action-area > button:hover { background-color: #00e5cc; color: #0b1021; }
.dialog-action-area > button:hover label { color: #0b1021; }
.dialog-action-area > button.suggested-action {
    background-color: #003d35;
    color: #00e5cc;
    border: 2px solid #00e5cc;
}
.dialog-action-area > button.suggested-action label { color: #00e5cc; }
.dialog-action-area > button.suggested-action:hover { background-color: #00e5cc; color: #0b1021; }
.dialog-action-area > button.suggested-action:hover label { color: #0b1021; }
.dialog-action-area > button.destructive-action {
    background-color: #2d0a0a;
    color: #ff4757;
    border-color: #ff4757;
}

/* ---- MENU BAR ---- */
menubar { background-color: #060913; color: #c8d6e5; border-bottom: 1px solid #1e2d4a; }
menubar label { color: #c8d6e5; }
menubar > menuitem:hover { background-color: #1a2540; color: #00e5cc; }
menubar > menuitem:hover label { color: #00e5cc; }
menu { background-color: #0d1529; color: #ffffff; border: 1px solid #1e2d4a; box-shadow: 0 4px 16px rgba(0,0,0,0.7); }
menuitem { padding: 4px 12px; color: #ffffff; }
menuitem label { color: #ffffff; }
menuitem:hover, menuitem:selected { background-color: #00e5cc; color: #0b1021; }
menuitem:hover label, menuitem:selected label { color: #0b1021; }
menuitem:disabled { color: #4a5568; }
menuitem:disabled label { color: #4a5568; }
separator { background-color: #1e2d4a; min-height: 1px; margin: 2px 8px; }

/* ---- NOTEBOOK TABS ---- */
notebook { background-color: #0b1021; }
notebook > header { background-color: #0d1529; border-bottom: 1px solid #1e2d4a; }
notebook tab { background-color: #0d1529; border: 1px solid #1e2d4a; border-bottom: none; padding: 6px 14px; margin: 0 1px; }
notebook tab label { color: #c8d6e5; font-size: 12px; }
notebook tab:checked { background-color: #0b1021; border-color: #00e5cc; border-bottom: 2px solid #00e5cc; }
notebook tab:checked label { color: #00e5cc; font-weight: 600; }
notebook tab:hover { background-color: #1a2540; }
notebook tab:hover label { color: #ffffff; }
notebook stack, notebook > stack { background-color: #0b1021; }

/* ---- STACK SWITCHER (Details/XML sub-tabs) ---- */
stackswitcher { background-color: #0d1529; border: 1px solid #1e2d4a; border-radius: 4px; padding: 2px; }
stackswitcher button { background-color: transparent; color: #c8d6e5; border: none; border-radius: 3px; padding: 4px 14px; }
stackswitcher button label { color: #c8d6e5; }
stackswitcher button:checked, stackswitcher button.active { background-color: #00e5cc; color: #0b1021; }
stackswitcher button:checked label, stackswitcher button.active label { color: #0b1021; font-weight: 600; }
stackswitcher button:hover { background-color: #1a2540; }
stackswitcher button:hover label { color: #ffffff; }

/* ---- ENTRIES / INPUTS ---- */
entry, spinbutton entry, combobox entry {
    background-color: #1a2540;
    color: #ffffff;
    border: 1px solid #1e2d4a;
    border-radius: 4px;
    padding: 4px 8px;
    caret-color: #00e5cc;
    box-shadow: none;
}
entry:focus { border-color: #00e5cc; box-shadow: 0 0 0 1px #00e5cc; }
entry:disabled { background-color: #0d1529; color: #4a5568; }

/* ---- COMBO BOXES ---- */
combobox button { background-color: #1a2540; border: 1px solid #1e2d4a; border-radius: 4px; color: #ffffff; }
combobox button label { color: #ffffff; }
combobox button:hover { border-color: #00e5cc; }

/* ---- TEXT VIEW (XML editor) ---- */
textview, textview text {
    background-color: #0d1529;
    color: #e2e8f0;
    font-family: monospace;
    font-size: 12px;
}
textview text selection { background-color: #00e5cc; color: #0b1021; }

/* ---- SCROLLBARS ---- */
scrollbar { background-color: #0d1529; min-width: 8px; }
scrollbar trough { background-color: #0d1529; border-radius: 4px; }
scrollbar slider { background-color: #2d3748; border-radius: 4px; min-width: 6px; min-height: 24px; margin: 2px; }
scrollbar slider:hover { background-color: #00e5cc; }

/* ---- CONTAINERS (kill white bleed) ---- */
scrolledwindow, scrolledwindow > widget, scrolledwindow > viewport { background-color: #0b1021; }
viewport { background-color: #0b1021; }
grid { background-color: #0b1021; }
grid label { color: #ffffff; }
box { background-color: transparent; }
box label { color: #ffffff; }

/* ---- FRAMES ---- */
frame { border: 1px solid #1e2d4a; border-radius: 4px; padding: 8px; }
frame > label { color: #00e5cc; font-weight: 600; background-color: #0b1021; padding: 0 4px; }

/* ---- CHECKBUTTON (On Boot etc.) ---- */
checkbutton { background-color: transparent; padding: 4px; }
checkbutton label { color: #ffffff; font-size: 13px; }
checkbutton check { background-color: #1a2540; border: 1px solid #4a5568; border-radius: 3px; min-width: 16px; min-height: 16px; }
checkbutton check:checked { background-color: #00e5cc; border-color: #00e5cc; }
checkbutton:focus { outline: 2px solid #c6ef3b; outline-offset: 2px; }

/* ---- RADIO BUTTONS ---- */
radiobutton { background-color: transparent; padding: 4px; }
radiobutton label { color: #ffffff; }
radiobutton radio { background-color: #1a2540; border: 1px solid #4a5568; border-radius: 50%; }
radiobutton radio:checked { background-color: #00e5cc; border-color: #00e5cc; }

/* ---- PROGRESS BARS ---- */
progressbar trough { background-color: #0d1529; border: 1px solid #1e2d4a; border-radius: 4px; min-height: 8px; }
progressbar progress { background-color: #00e5cc; border-radius: 4px; }

/* ---- FLOWBOX (storage/network cards) ---- */
flowbox, flowboxchild { background-color: #0d1529; color: #ffffff; }
flowboxchild label { color: #ffffff; }
flowboxchild:selected { background-color: #00e5cc; color: #0b1021; }
flowboxchild:selected label { color: #0b1021; }

/* ---- LIST ROWS ---- */
row { background-color: #0d1529; color: #ffffff; padding: 4px 8px; border-bottom: 1px solid #1e2d4a; }
row label { color: #ffffff; }
row:selected { background-color: #00e5cc; color: #0b1021; }
row:selected label { color: #0b1021; }
row:hover { background-color: #1a2540; }

/* ---- STANDALONE IMAGES ---- */
image { color: #c8d6e5; -gtk-icon-style: regular; }

/* ---- TOOLTIPS ---- */
tooltip, .tooltip { background-color: #1a2540; color: #ffffff; border: 1px solid #00e5cc; border-radius: 4px; padding: 4px 8px; }
tooltip label { color: #ffffff; }

/* ---- STATUS / SEMANTIC COLORS ---- */
.success { color: #00e5cc; }
.warning { color: #ffb300; }
.error   { color: #ff4757; }
.vm-status-running  { color: #00e5cc; }
.vm-status-shutoff  { color: #718096; }
.vm-status-error    { color: #ff4757; }
.vm-status-paused   { color: #ffb300; }

/* ---- PANED SEPARATORS ---- */
paned separator { background-color: #1e2d4a; min-width: 4px; min-height: 4px; }
paned separator:hover { background-color: #00e5cc; }

/* ---- POPOVERS ---- */
popover, popover.background { background-color: #0d1529; border: 1px solid #1e2d4a; border-radius: 6px; box-shadow: 0 8px 24px rgba(0,0,0,0.8); }
popover label { color: #ffffff; }

/* ---- DIALOGS ---- */
dialog { background-color: #0b1021; }
dialog label { color: #ffffff; }
.about-dialog label { color: #ffffff; }

/* ---- SCALES ---- */
scale trough { background-color: #1e2d4a; border-radius: 4px; min-height: 4px; }
scale highlight, scale progress { background-color: #00e5cc; border-radius: 4px; }
scale slider { background-color: #00e5cc; border-radius: 50%; min-width: 16px; min-height: 16px; border: 2px solid #0b1021; }
scale slider:hover { background-color: #c6ef3b; }
GTKEOF

ok "Named GTK3 theme installed: /usr/share/themes/SovereignHypervisor/"

# =============================================================================
# STEP 7: KDE PLASMA COLOR SCHEME
# =============================================================================

log "STEP 7: Writing KDE Plasma color scheme..."

KDE_COLORS_DIR="/usr/share/color-schemes"
mkdir -p "${KDE_COLORS_DIR}"

cat > "${KDE_COLORS_DIR}/SovereignHypervisor.colors" << 'KDEEOF'
[ColorEffects:Disabled]
Color=100,110,130
ColorAmount=0.55
ColorEffect=3
ContrastAmount=0.65
ContrastEffect=1
IntensityAmount=0.1
IntensityEffect=2

[ColorEffects:Inactive]
ChangeSelectionColor=true
Color=30,40,68
ColorAmount=0.025
ColorEffect=2
ContrastAmount=0.1
ContrastEffect=2
Enable=false
IntensityAmount=0
IntensityEffect=0

[Colors:Button]
BackgroundAlternate=26,37,64
BackgroundNormal=26,37,64
DecorationFocus=0,229,204
DecorationHover=0,229,204
ForegroundActive=0,229,204
ForegroundInactive=200,214,229
ForegroundLink=0,229,204
ForegroundNegative=255,71,87
ForegroundNeutral=255,179,0
ForegroundNormal=255,255,255
ForegroundPositive=0,229,204
ForegroundVisited=0,200,175

[Colors:Selection]
BackgroundAlternate=0,229,204
BackgroundNormal=0,229,204
DecorationFocus=0,229,204
DecorationHover=255,255,255
ForegroundActive=11,16,33
ForegroundInactive=11,16,33
ForegroundLink=11,16,33
ForegroundNegative=255,71,87
ForegroundNeutral=255,179,0
ForegroundNormal=11,16,33
ForegroundPositive=0,100,90
ForegroundVisited=11,16,33

[Colors:Tooltip]
BackgroundAlternate=26,37,64
BackgroundNormal=26,37,64
DecorationFocus=0,229,204
DecorationHover=0,229,204
ForegroundActive=0,229,204
ForegroundInactive=200,214,229
ForegroundLink=0,229,204
ForegroundNegative=255,71,87
ForegroundNeutral=255,179,0
ForegroundNormal=255,255,255
ForegroundPositive=0,229,204
ForegroundVisited=200,214,229

[Colors:View]
BackgroundAlternate=13,21,41
BackgroundNormal=11,16,33
DecorationFocus=0,229,204
DecorationHover=0,229,204
ForegroundActive=0,229,204
ForegroundInactive=200,214,229
ForegroundLink=0,229,204
ForegroundNegative=255,71,87
ForegroundNeutral=255,179,0
ForegroundNormal=255,255,255
ForegroundPositive=0,229,204
ForegroundVisited=200,214,229

[Colors:Window]
BackgroundAlternate=13,21,41
BackgroundNormal=11,16,33
DecorationFocus=0,229,204
DecorationHover=0,229,204
ForegroundActive=0,229,204
ForegroundInactive=200,214,229
ForegroundLink=0,229,204
ForegroundNegative=255,71,87
ForegroundNeutral=255,179,0
ForegroundNormal=255,255,255
ForegroundPositive=0,229,204
ForegroundVisited=200,214,229

[General]
ColorScheme=SovereignHypervisor
Name=Sovereign Hypervisor
shadeSortColumn=true

[KDE]
contrast=4
KDEEOF

ok "KDE Plasma color scheme written"

# =============================================================================
# STEP 8: ACTIVATE THE THEME — settings.ini + gsettings + environment
# =============================================================================

log "STEP 8: Activating SovereignHypervisor theme..."

# --- System-wide GTK settings ---
mkdir -p /etc/gtk-3.0
cat > /etc/gtk-3.0/settings.ini << 'SYSEOF'
[Settings]
gtk-theme-name=SovereignHypervisor
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=hicolor
gtk-cursor-theme-name=default
gtk-font-name=Ubuntu 11
gtk-button-images=1
gtk-menu-images=1
gtk-toolbar-style=GTK_TOOLBAR_BOTH_HORIZ
SYSEOF

# --- Per-user GTK settings (abc user — highest precedence) ---
ABC_GTK_DIR="/config/.config/gtk-3.0"
mkdir -p "${ABC_GTK_DIR}"

cat > "${ABC_GTK_DIR}/settings.ini" << 'USEREOF'
[Settings]
gtk-theme-name=SovereignHypervisor
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=hicolor
gtk-cursor-theme-name=default
gtk-font-name=Ubuntu 11
gtk-button-images=1
gtk-menu-images=1
gtk-toolbar-style=GTK_TOOLBAR_BOTH_HORIZ
USEREOF

# --- Also write a user gtk.css override (loads ON TOP of the theme) ---
# This ensures our rules win even if KDE regenerates settings.ini
cp "${THEME_DIR}/gtk.css" "${ABC_GTK_DIR}/gtk.css" 2>/dev/null || true

chown -R abc:abc "${ABC_GTK_DIR}" 2>/dev/null \
    || chown -R 1000:1000 "${ABC_GTK_DIR}" 2>/dev/null || true

# --- Apply via gsettings as the abc user (Wayland + X11 bridge) ---
sudo -u abc gsettings set org.gnome.desktop.interface gtk-theme 'SovereignHypervisor' 2>/dev/null || true
sudo -u abc gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true

# --- Write the environment file so GTK picks up the theme on next launch ---
# GTK_THEME env var is the nuclear option — overrides everything
GTK_ENV_FILE="/etc/profile.d/sovereign-gtk-theme.sh"
cat > "${GTK_ENV_FILE}" << 'ENVEOF'
# Sovereign Hypervisor GTK Theme
export GTK_THEME=SovereignHypervisor
export GTK2_RC_FILES=/dev/null
ENVEOF
chmod +x "${GTK_ENV_FILE}"

# Also write to abc user's shell profile so it applies in the KDE session
for RCFILE in /config/.bashrc /config/.profile; do
    if [ -f "${RCFILE}" ]; then
        grep -q "GTK_THEME=SovereignHypervisor" "${RCFILE}" 2>/dev/null \
            || echo 'export GTK_THEME=SovereignHypervisor' >> "${RCFILE}" 2>/dev/null || true
    fi
done

# Write to the abc user's .xprofile (sourced by display manager on login)
echo 'export GTK_THEME=SovereignHypervisor' > /config/.xprofile 2>/dev/null || true
chown abc:abc /config/.xprofile 2>/dev/null || chown 1000:1000 /config/.xprofile 2>/dev/null || true

ok "Theme activated: SovereignHypervisor"
ok "GTK_THEME env var set in /etc/profile.d/ and abc user profile"
ok "gsettings updated for abc user"

# =============================================================================
# STEP 9: ICON CACHE REFRESH
# =============================================================================

log "STEP 9: Refreshing icon cache..."

command -v gtk-update-icon-cache >/dev/null 2>&1 && {
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null \
        && ok "Icon cache refreshed" \
        || warn "Icon cache refresh had errors (non-fatal)"
} || warn "gtk-update-icon-cache not found — icon changes take effect on next login"

command -v update-desktop-database >/dev/null 2>&1 && {
    update-desktop-database /usr/share/applications 2>/dev/null \
        && ok "Desktop database updated" \
        || warn "Desktop database update failed (non-fatal)"
}

# =============================================================================
# STEP 10: VERIFICATION SUMMARY
# =============================================================================

log ""
log "═══════════════════════════════════════════════════════════"
log " SOVEREIGN HYPERVISOR — Branding Verification"
log "═══════════════════════════════════════════════════════════"

echo ""
echo "  Desktop entry:"
if [ -f "/usr/share/applications/virt-manager.desktop" ]; then
    grep "^Name=" /usr/share/applications/virt-manager.desktop | head -1
    grep "^Comment=" /usr/share/applications/virt-manager.desktop | head -1
fi

echo ""
echo "  GTK3 CSS:"
[ -f /etc/gtk-3.0/gtk.css ] \
    && echo "    ✓ /etc/gtk-3.0/gtk.css written ($(wc -l < /etc/gtk-3.0/gtk.css) lines)" \
    || echo "    ✗ CSS not found"
[ -f "${ABC_GTK_DIR}/gtk.css" ] \
    && echo "    ✓ ${ABC_GTK_DIR}/gtk.css (user override)" \
    || echo "    ✗ User CSS not found"

echo ""
echo "  KDE Plasma color scheme:"
[ -f "/usr/share/color-schemes/SovereignHypervisor.colors" ] \
    && echo "    ✓ SovereignHypervisor.colors installed" \
    || echo "    ✗ Color scheme not found"

echo ""
echo "  Python/UI patches remaining 'Virtual Machine Manager' strings:"
REMAINING=$(grep -rl "Virtual Machine Manager" /usr/share/virt-manager/ 2>/dev/null \
    | grep -v '\.pyc$' | wc -l)
if [ "${REMAINING}" -eq 0 ]; then
    echo "    ✓ 0 remaining — all strings patched"
else
    echo "    ⚠ ${REMAINING} files still contain 'Virtual Machine Manager':"
    grep -rl "Virtual Machine Manager" /usr/share/virt-manager/ 2>/dev/null | while read -r F; do
        echo "      → ${F}"
    done
fi

echo ""
echo "  Icons:"
ICON_COUNT=$(find /usr/share/icons/hicolor -name "virt-manager.png" 2>/dev/null | wc -l)
echo "    ✓ ${ICON_COUNT} icon sizes installed"
[ -f "/usr/share/icons/hicolor/scalable/apps/virt-manager.svg" ] \
    && echo "    ✓ Scalable SVG present"

echo ""
log "═══════════════════════════════════════════════════════════"
log " COMPLETE — Close and reopen virt-manager to see changes."
log " If running inside KDE, log out + in for full theme load."
log " Full log: ${SH_LOG}"
log "═══════════════════════════════════════════════════════════"
echo ""
echo "  LAUNCH TEST:"
echo "    virt-manager --no-fork &"
echo ""
echo "  KUBEVIRT ROADMAP NOTE:"
echo "    This script brands the LOCAL hypervisor (GTK3/KVM)."
echo "    KubeVirt distributed VMs are managed via LLM ontology:"
echo "    Golden Twin → ChatOps intent → YAML generation → Approve/Deny"
echo "    No kubevirt-manager UI required — the LLM IS the manager."
echo ""