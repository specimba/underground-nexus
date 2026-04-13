#!/usr/bin/env bash
# =============================================================================
# Git-BIOS Control Panel — start_control_panel.sh
# Cloud Underground · Underground Nexus
# =============================================================================
#
# Starts the Git-BIOS Control Panel server and opens a browser.
# No venv, no pip, no Flask — server.py uses Python stdlib only.
#
# Usage:
#   bash start_control_panel.sh
#   PORT=8080 bash start_control_panel.sh
# =============================================================================

APP_DIR="${APP_DIR:-/config/Desktop/nexus-bucket/underground-nexus/Jelly-Apps/Git-BIOS-Control-Panel}"
PORT="${PORT:-5000}"
LOG="${APP_DIR}/control-panel.log"
URL="http://localhost:${PORT}"
PYBIN="python3"

# ─────────────────────────────────────────────────────────────────────────────
# DISPLAY ENVIRONMENT
# When launched from a .desktop icon with Terminal=false, DISPLAY may not be
# set. Read it from the running session's /proc environ before opening browser.
# ─────────────────────────────────────────────────────────────────────────────
_setup_display() {
    [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ] && return 0

    for ENV_FILE in \
        "/proc/$(pgrep -u abc   -x i3   2>/dev/null | head -1)/environ" \
        "/proc/$(pgrep -u abc   -x mate 2>/dev/null | head -1)/environ" \
        "/proc/$(pgrep -u 1000  -x i3   2>/dev/null | head -1)/environ" \
        "/proc/$(pgrep -u 1000  -x kasm 2>/dev/null | head -1)/environ" \
        "/tmp/.display-env" \
        "/config/.display-env"
    do
        [ -f "${ENV_FILE}" ] || continue
        DISP=$(tr '\0' '\n' < "${ENV_FILE}" 2>/dev/null | grep '^DISPLAY='               | cut -d= -f2  | head -1)
        WAYL=$(tr '\0' '\n' < "${ENV_FILE}" 2>/dev/null | grep '^WAYLAND_DISPLAY='       | cut -d= -f2  | head -1)
        DBUS=$(tr '\0' '\n' < "${ENV_FILE}" 2>/dev/null | grep '^DBUS_SESSION_BUS_ADDRESS=' | cut -d= -f2- | head -1)
        XAUT=$(tr '\0' '\n' < "${ENV_FILE}" 2>/dev/null | grep '^XAUTHORITY='            | cut -d= -f2  | head -1)
        [ -n "${DISP}" ] && export DISPLAY="${DISP}"
        [ -n "${WAYL}" ] && export WAYLAND_DISPLAY="${WAYL}"
        [ -n "${DBUS}" ] && export DBUS_SESSION_BUS_ADDRESS="${DBUS}"
        [ -n "${XAUT}" ] && export XAUTHORITY="${XAUT}"
        break
    done

    # Hard fallback — KasmVNC in linuxserver webtop always uses :1
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        export DISPLAY=":1"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# HEALTHCHECK — curl is 5ms vs spawning python3 which takes 200ms+
# ─────────────────────────────────────────────────────────────────────────────
_is_server_running() {
    curl -sf --max-time 1 "${URL}/healthz" >/dev/null 2>&1
}

_wait_for_server() {
    local i=0
    while [ "${i}" -lt 30 ]; do
        _is_server_running && return 0
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# BROWSER LAUNCH
# Each browser attempt is its own if-block so there is no &; syntax.
# Firefox first (installed in workbench0), then chromium, then fallbacks.
# xdg-open is tried first because it uses the session's MIME handler which
# works correctly when DISPLAY is set — it routes to whatever the user's
# default browser is without needing to know the binary path.
# ─────────────────────────────────────────────────────────────────────────────
_open_browser() {
    # xdg-open: session-aware, always correct when DISPLAY is set
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "${URL}" >/dev/null 2>&1 &
        return 0
    fi
    # Firefox — primary browser in workbench0
    if [ -x /usr/bin/firefox ]; then
        /usr/bin/firefox "${URL}" >/dev/null 2>&1 &
        return 0
    fi
    if [ -x /snap/bin/firefox ]; then
        /snap/bin/firefox "${URL}" >/dev/null 2>&1 &
        return 0
    fi
    # Chromium — installed in workbench0 as secondary browser
    if [ -x /usr/bin/chromium ]; then
        /usr/bin/chromium "${URL}" >/dev/null 2>&1 &
        return 0
    fi
    if [ -x /usr/bin/chromium-browser ]; then
        /usr/bin/chromium-browser "${URL}" >/dev/null 2>&1 &
        return 0
    fi
    if [ -x /usr/bin/google-chrome ]; then
        /usr/bin/google-chrome "${URL}" >/dev/null 2>&1 &
        return 0
    fi
    if [ -x /usr/bin/google-chrome-stable ]; then
        /usr/bin/google-chrome-stable "${URL}" >/dev/null 2>&1 &
        return 0
    fi
    # gio open — gvfs session handler, last resort
    if command -v gio >/dev/null 2>&1; then
        gio open "${URL}" >/dev/null 2>&1 &
        return 0
    fi
    echo "[gitbios] No browser found. Open manually: ${URL}" | tee -a "${LOG}"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "${APP_DIR}"

# Step 1: Export display environment before any browser call
_setup_display

# Step 2: Verify server.py is present
if [ ! -f "${APP_DIR}/server.py" ]; then
    echo "[gitbios] ERROR: server.py not found at ${APP_DIR}/server.py" >&2
    echo "[gitbios] Run the installer first:" >&2
    echo "[gitbios]   bash ${APP_DIR}/install-git-bios-control-panel.sh" >&2
    exit 1
fi

# Step 3: Start server if not already running
if ! _is_server_running; then
    echo "[gitbios] Starting server on port ${PORT}..." | tee -a "${LOG}"
    cd "${APP_DIR}"
    PORT="${PORT}" nohup "${PYBIN}" server.py >> "${LOG}" 2>&1 &
    echo "[gitbios] Server PID: $!" | tee -a "${LOG}"

    if ! _wait_for_server; then
        echo "[gitbios] Server failed to start within 6s. Last log:" >&2
        tail -20 "${LOG}" >&2
        exit 1
    fi
    echo "[gitbios] Server ready." | tee -a "${LOG}"
else
    echo "[gitbios] Server already running at ${URL}"
fi

# Step 4: Open browser
_open_browser
echo "[gitbios] Control panel: ${URL}"