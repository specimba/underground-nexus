#!/usr/bin/env bash
# =============================================================================
# Git-BIOS Control Panel — Installer
# Cloud Underground · Underground Nexus
# =============================================================================
#
# Installs or repairs the Git-BIOS Control Panel.
# Idempotent — safe to run multiple times.
#
# What this does:
#   1. Installs python3 system package (only dep — no pip, no venv, no Flask)
#   2. Creates the app directory and ensures server.py is present
#   3. Writes the canonical start_control_panel.sh  (no &; bash syntax)
#   4. Creates the desktop .desktop launcher with correct path
#   5. Optionally adds a gitbios s6 service so the server pre-warms at boot
# =============================================================================

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

TARGET_USER="${TARGET_USER:-abc}"
APP_DIR="${APP_DIR:-/config/Desktop/nexus-bucket/underground-nexus/Jelly-Apps/Git-BIOS-Control-Panel}"
PORT="${PORT:-5000}"
EUID_NOW=$(id -u)
[ "${EUID_NOW}" -eq 0 ] && SUDO="" || SUDO="sudo -n"

echo "[gitbios-install] Starting Git-BIOS Control Panel installation"
echo "[gitbios-install] Target user: ${TARGET_USER}"
echo "[gitbios-install] App dir:     ${APP_DIR}"
echo "[gitbios-install] Port:        ${PORT}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: python3 only — no pip, no venv, no Flask
# ─────────────────────────────────────────────────────────────────────────────
echo "[gitbios-install] Step 1: Checking python3..."
if ! command -v python3 >/dev/null 2>&1; then
    echo "[gitbios-install] Installing python3..."
    ${SUDO} apt-get update -qq 2>/dev/null || true
    ${SUDO} apt-get install -y python3 2>/dev/null || true
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[gitbios-install] ERROR: python3 could not be installed." >&2
    exit 1
fi
echo "[gitbios-install] python3 OK: $(python3 --version)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: App directory
# ─────────────────────────────────────────────────────────────────────────────
echo "[gitbios-install] Step 2: App directory..."
mkdir -p "${APP_DIR}/profiles" "${APP_DIR}/static/assets"

if id "${TARGET_USER}" >/dev/null 2>&1; then
    chown -R "${TARGET_USER}:${TARGET_USER}" "${APP_DIR}" 2>/dev/null || true
else
    chown -R 1000:1000 "${APP_DIR}" 2>/dev/null || true
fi
echo "[gitbios-install] App dir ready: ${APP_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Write start_control_panel.sh
#
# CRITICAL: never use  { cmd &; return 0; }  in generated bash.
# The semicolon after & inside a compound command is a syntax error.
# Use separate lines:  cmd &  then  return 0  on the next line.
# ─────────────────────────────────────────────────────────────────────────────
echo "[gitbios-install] Step 3: Writing start_control_panel.sh..."

START_SCRIPT="${APP_DIR}/start_control_panel.sh"

printf '#!/usr/bin/env bash\n' > "${START_SCRIPT}"
printf '# Git-BIOS Control Panel launcher — written by installer\n\n' >> "${START_SCRIPT}"

printf 'APP_DIR="%s"\n' "${APP_DIR}" >> "${START_SCRIPT}"
printf 'PORT="%s"\n' "${PORT}" >> "${START_SCRIPT}"
printf 'LOG="${APP_DIR}/control-panel.log"\n' >> "${START_SCRIPT}"
printf 'URL="http://localhost:${PORT}"\n' >> "${START_SCRIPT}"
printf 'PYBIN="python3"\n\n' >> "${START_SCRIPT}"

# _setup_display — export DISPLAY from running session
printf '_setup_display() {\n' >> "${START_SCRIPT}"
printf '    [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ] && return 0\n' >> "${START_SCRIPT}"
printf '    for ENV_FILE in \\\n' >> "${START_SCRIPT}"
printf '        "/proc/$(pgrep -u %s -x i3    2>/dev/null | head -1)/environ" \\\n' "${TARGET_USER}" >> "${START_SCRIPT}"
printf '        "/proc/$(pgrep -u 1000 -x kasm 2>/dev/null | head -1)/environ" \\\n' >> "${START_SCRIPT}"
printf '        "/tmp/.display-env" "/config/.display-env"; do\n' >> "${START_SCRIPT}"
printf '        [ -f "${ENV_FILE}" ] || continue\n' >> "${START_SCRIPT}"
printf '        DISP=$(tr '"'"'\\0'"'"' '"'"'\\n'"'"' < "${ENV_FILE}" 2>/dev/null | grep '"'"'^DISPLAY='"'"'    | cut -d= -f2 | head -1)\n' >> "${START_SCRIPT}"
printf '        WAYL=$(tr '"'"'\\0'"'"' '"'"'\\n'"'"' < "${ENV_FILE}" 2>/dev/null | grep '"'"'^WAYLAND_DISPLAY='"'"' | cut -d= -f2 | head -1)\n' >> "${START_SCRIPT}"
printf '        DBUS=$(tr '"'"'\\0'"'"' '"'"'\\n'"'"' < "${ENV_FILE}" 2>/dev/null | grep '"'"'^DBUS_SESSION_BUS_ADDRESS='"'"' | cut -d= -f2- | head -1)\n' >> "${START_SCRIPT}"
printf '        [ -n "${DISP}" ] && export DISPLAY="${DISP}"\n' >> "${START_SCRIPT}"
printf '        [ -n "${WAYL}" ] && export WAYLAND_DISPLAY="${WAYL}"\n' >> "${START_SCRIPT}"
printf '        [ -n "${DBUS}" ] && export DBUS_SESSION_BUS_ADDRESS="${DBUS}"\n' >> "${START_SCRIPT}"
printf '        break\n' >> "${START_SCRIPT}"
printf '    done\n' >> "${START_SCRIPT}"
printf '    [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] && export DISPLAY=":1"\n' >> "${START_SCRIPT}"
printf '}\n\n' >> "${START_SCRIPT}"

# _is_server_running — curl healthcheck
printf '_is_server_running() {\n' >> "${START_SCRIPT}"
printf '    curl -sf --max-time 1 "${URL}/healthz" >/dev/null 2>&1\n' >> "${START_SCRIPT}"
printf '}\n\n' >> "${START_SCRIPT}"

# _wait_for_server
printf '_wait_for_server() {\n' >> "${START_SCRIPT}"
printf '    local i=0\n' >> "${START_SCRIPT}"
printf '    while [ "${i}" -lt 30 ]; do\n' >> "${START_SCRIPT}"
printf '        _is_server_running && return 0\n' >> "${START_SCRIPT}"
printf '        sleep 0.2\n' >> "${START_SCRIPT}"
printf '        i=$((i+1))\n' >> "${START_SCRIPT}"
printf '    done\n' >> "${START_SCRIPT}"
printf '    return 1\n' >> "${START_SCRIPT}"
printf '}\n\n' >> "${START_SCRIPT}"

# _open_browser — firefox first, then fallbacks
# NOTE: each browser attempt is on its own line to avoid &; syntax errors
printf '_open_browser() {\n' >> "${START_SCRIPT}"
printf '    # xdg-open delegates to the session MIME handler — best option\n' >> "${START_SCRIPT}"
printf '    if command -v xdg-open >/dev/null 2>&1; then\n' >> "${START_SCRIPT}"
printf '        xdg-open "${URL}" >/dev/null 2>&1 &\n' >> "${START_SCRIPT}"
printf '        return 0\n' >> "${START_SCRIPT}"
printf '    fi\n' >> "${START_SCRIPT}"
printf '    # Firefox direct — most likely browser in workbench0\n' >> "${START_SCRIPT}"
printf '    if [ -x /usr/bin/firefox ]; then\n' >> "${START_SCRIPT}"
printf '        /usr/bin/firefox "${URL}" >/dev/null 2>&1 &\n' >> "${START_SCRIPT}"
printf '        return 0\n' >> "${START_SCRIPT}"
printf '    fi\n' >> "${START_SCRIPT}"
printf '    if [ -x /snap/bin/firefox ]; then\n' >> "${START_SCRIPT}"
printf '        /snap/bin/firefox "${URL}" >/dev/null 2>&1 &\n' >> "${START_SCRIPT}"
printf '        return 0\n' >> "${START_SCRIPT}"
printf '    fi\n' >> "${START_SCRIPT}"
printf '    # Chromium fallback\n' >> "${START_SCRIPT}"
printf '    if [ -x /usr/bin/chromium ]; then\n' >> "${START_SCRIPT}"
printf '        /usr/bin/chromium "${URL}" >/dev/null 2>&1 &\n' >> "${START_SCRIPT}"
printf '        return 0\n' >> "${START_SCRIPT}"
printf '    fi\n' >> "${START_SCRIPT}"
printf '    if [ -x /usr/bin/chromium-browser ]; then\n' >> "${START_SCRIPT}"
printf '        /usr/bin/chromium-browser "${URL}" >/dev/null 2>&1 &\n' >> "${START_SCRIPT}"
printf '        return 0\n' >> "${START_SCRIPT}"
printf '    fi\n' >> "${START_SCRIPT}"
printf '    # gio open last resort\n' >> "${START_SCRIPT}"
printf '    if command -v gio >/dev/null 2>&1; then\n' >> "${START_SCRIPT}"
printf '        gio open "${URL}" >/dev/null 2>&1 &\n' >> "${START_SCRIPT}"
printf '        return 0\n' >> "${START_SCRIPT}"
printf '    fi\n' >> "${START_SCRIPT}"
printf '    echo "[gitbios] No browser found. Open manually: ${URL}" | tee -a "${LOG}"\n' >> "${START_SCRIPT}"
printf '    return 1\n' >> "${START_SCRIPT}"
printf '}\n\n' >> "${START_SCRIPT}"

# Main body
printf 'mkdir -p "${APP_DIR}"\n' >> "${START_SCRIPT}"
printf '_setup_display\n' >> "${START_SCRIPT}"
printf 'if [ ! -f "${APP_DIR}/server.py" ]; then\n' >> "${START_SCRIPT}"
printf '    echo "[gitbios] ERROR: server.py not found at ${APP_DIR}/server.py" >&2\n' >> "${START_SCRIPT}"
printf '    echo "[gitbios] Re-run: bash ${APP_DIR}/install-git-bios-control-panel.sh" >&2\n' >> "${START_SCRIPT}"
printf '    exit 1\n' >> "${START_SCRIPT}"
printf 'fi\n' >> "${START_SCRIPT}"
printf 'if ! _is_server_running; then\n' >> "${START_SCRIPT}"
printf '    echo "[gitbios] Starting server on port ${PORT}..." | tee -a "${LOG}"\n' >> "${START_SCRIPT}"
printf '    cd "${APP_DIR}"\n' >> "${START_SCRIPT}"
printf '    PORT="${PORT}" nohup "${PYBIN}" server.py >> "${LOG}" 2>&1 &\n' >> "${START_SCRIPT}"
printf '    echo "[gitbios] Server PID: $!" | tee -a "${LOG}"\n' >> "${START_SCRIPT}"
printf '    if ! _wait_for_server; then\n' >> "${START_SCRIPT}"
printf '        echo "[gitbios] Server failed to start. Last log:" >&2\n' >> "${START_SCRIPT}"
printf '        tail -20 "${LOG}" >&2\n' >> "${START_SCRIPT}"
printf '        exit 1\n' >> "${START_SCRIPT}"
printf '    fi\n' >> "${START_SCRIPT}"
printf '    echo "[gitbios] Server ready." | tee -a "${LOG}"\n' >> "${START_SCRIPT}"
printf 'else\n' >> "${START_SCRIPT}"
printf '    echo "[gitbios] Server already running at ${URL}"\n' >> "${START_SCRIPT}"
printf 'fi\n' >> "${START_SCRIPT}"
printf '_open_browser\n' >> "${START_SCRIPT}"
printf 'echo "[gitbios] Control panel: ${URL}"\n' >> "${START_SCRIPT}"

chmod +x "${START_SCRIPT}"
chown "${TARGET_USER}:${TARGET_USER}" "${START_SCRIPT}" 2>/dev/null || true

# Verify the generated script has no syntax errors
if ! bash -n "${START_SCRIPT}" 2>&1; then
    echo "[gitbios-install] ERROR: Generated start_control_panel.sh has syntax errors!" >&2
    bash -n "${START_SCRIPT}" >&2
    exit 1
fi
echo "[gitbios-install] start_control_panel.sh written and verified (syntax OK)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Desktop .desktop launcher
# ─────────────────────────────────────────────────────────────────────────────
echo "[gitbios-install] Step 4: Creating desktop icon..."

USER_HOME=$(getent passwd "${TARGET_USER}" 2>/dev/null | cut -d: -f6 || echo "/config")
DESKTOP_DIR="${USER_HOME}/Desktop"
[ -d "${DESKTOP_DIR}" ] || DESKTOP_DIR="/config/Desktop"
mkdir -p "${DESKTOP_DIR}"

ICON_PATH="${APP_DIR}/static/assets/nexus-logo.png"
DESK_FILE="${DESKTOP_DIR}/Git-BIOS-Control-Panel.desktop"

printf '[Desktop Entry]\n'            > "${DESK_FILE}"
printf 'Version=1.0\n'               >> "${DESK_FILE}"
printf 'Type=Application\n'          >> "${DESK_FILE}"
printf 'Name=Git-BIOS Control Panel\n' >> "${DESK_FILE}"
printf 'Comment=Sovereign command and control — Cloud Underground\n' >> "${DESK_FILE}"
printf 'Exec=%s\n' "${START_SCRIPT}" >> "${DESK_FILE}"
printf 'Path=%s\n' "${APP_DIR}"      >> "${DESK_FILE}"
printf 'Icon=%s\n' "${ICON_PATH}"    >> "${DESK_FILE}"
printf 'Terminal=false\n'            >> "${DESK_FILE}"
printf 'Categories=Utility;System;\n' >> "${DESK_FILE}"
printf 'TryExec=%s\n' "${START_SCRIPT}" >> "${DESK_FILE}"
printf 'StartupNotify=false\n'       >> "${DESK_FILE}"

chown "${TARGET_USER}:${TARGET_USER}" "${DESK_FILE}" 2>/dev/null || true
chmod +x "${DESK_FILE}"
gio set "${DESK_FILE}" metadata::trusted true 2>/dev/null || true
xdg-desktop-menu install "${DESK_FILE}" 2>/dev/null || true

echo "[gitbios-install] Desktop icon: ${DESK_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Optional s6 pre-warm service (linuxserver webtop)
# ─────────────────────────────────────────────────────────────────────────────
S6_SVC_DIR="/etc/s6-overlay/s6-rc.d/gitbios"
if [ -d "/etc/s6-overlay" ] && [ "${EUID_NOW}" -eq 0 ]; then
    echo "[gitbios-install] Step 5: Registering s6 service..."
    mkdir -p "${S6_SVC_DIR}"
    printf '#!/usr/bin/with-contenv bash\n'                                  > "${S6_SVC_DIR}/run"
    printf '# Git-BIOS Control Panel — s6 pre-warm service\n'               >> "${S6_SVC_DIR}/run"
    printf '[ -f "%s/server.py" ] || { echo "[s6-gitbios] server.py not found — sleeping"; sleep infinity; }\n' "${APP_DIR}" >> "${S6_SVC_DIR}/run"
    printf 'cd "%s"\n' "${APP_DIR}"                                          >> "${S6_SVC_DIR}/run"
    printf 'exec python3 server.py\n'                                        >> "${S6_SVC_DIR}/run"
    printf 'longrun\n'                                                       > "${S6_SVC_DIR}/type"
    chmod +x "${S6_SVC_DIR}/run"
    echo "[gitbios-install] s6 service registered: ${S6_SVC_DIR}"
    echo "[gitbios-install] Server will pre-warm at next container start"
else
    echo "[gitbios-install] Step 5: s6 service skipped (not root or no s6-overlay)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[gitbios-install] Installation complete"
echo ""
echo "  Start now:     bash '${START_SCRIPT}'"
echo "  Or open URL:   http://localhost:${PORT}"
echo "  Desktop icon:  ${DESK_FILE}"
echo "  Log file:      ${APP_DIR}/control-panel.log"
echo ""
echo "  No pip. No venv. No Flask. Requires only python3."
echo ""