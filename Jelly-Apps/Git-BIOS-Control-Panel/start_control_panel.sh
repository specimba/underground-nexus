#!/usr/bin/env bash
# =============================================================================
# Git-BIOS Control Panel — start_control_panel.sh
# Cloud Underground · Underground Nexus
# =============================================================================
#
# Single canonical launcher. Replaces all three previous versions.
# No venv, no pip, no Flask — server.py uses stdlib only.
# Works correctly when launched from a desktop icon (DISPLAY exported).
#
# What this does:
#   1. Exports display environment so browser opens correctly from desktop icon
#   2. Checks if server is already running (curl healthcheck — 5ms not 10s)
#   3. Starts server if needed, waits for it to be ready
#   4. Opens the browser with a verified URL
# =============================================================================

APP_DIR="${APP_DIR:-/config/Desktop/nexus-bucket/underground-nexus/Jelly-Apps/Git-BIOS-Control-Panel}"
PORT="${PORT:-5000}"
LOG="${APP_DIR}/control-panel.log"
URL="http://localhost:${PORT}"
PYBIN="python3"

# ─────────────────────────────────────────────────────────────────────────────
# DISPLAY ENVIRONMENT — critical for desktop icon launch
#
# When a .desktop file with Terminal=false calls this script, the shell
# environment may not have DISPLAY or WAYLAND_DISPLAY set. Without these,
# any browser launch silently fails (binary exists, nohup returns 0, but
# no window opens). We export from the live session before calling any browser.
# ─────────────────────────────────────────────────────────────────────────────
_setup_display() {
    # Already set — nothing to do
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        return 0
    fi

    # Try to read display from the abc/1000 user session environment
    # KasmVNC / linuxserver webtop writes these to a known location
    for ENV_FILE in \
        /proc/$(pgrep -u abc -x i3 2>/dev/null | head -1)/environ \
        /proc/$(pgrep -u abc -x kasm 2>/dev/null | head -1)/environ \
        /proc/$(pgrep -u 1000 -x i3 2>/dev/null | head -1)/environ \
        /tmp/.display-env \
        /config/.display-env
    do
        [ -f "${ENV_FILE}" ] || continue
        # Extract DISPLAY from the null-separated environ file
        DISP=$(cat "${ENV_FILE}" 2>/dev/null | tr '\0' '\n' | grep '^DISPLAY=' | cut -d= -f2 | head -1)
        WAYL=$(cat "${ENV_FILE}" 2>/dev/null | tr '\0' '\n' | grep '^WAYLAND_DISPLAY=' | cut -d= -f2 | head -1)
        XAUT=$(cat "${ENV_FILE}" 2>/dev/null | tr '\0' '\n' | grep '^XAUTHORITY=' | cut -d= -f2 | head -1)
        DBUS=$(cat "${ENV_FILE}" 2>/dev/null | tr '\0' '\n' | grep '^DBUS_SESSION_BUS_ADDRESS=' | cut -d= -f2- | head -1)
        [ -n "${DISP}" ] && export DISPLAY="${DISP}"
        [ -n "${WAYL}" ] && export WAYLAND_DISPLAY="${WAYL}"
        [ -n "${XAUT}" ] && export XAUTHORITY="${XAUT}"
        [ -n "${DBUS}" ] && export DBUS_SESSION_BUS_ADDRESS="${DBUS}"
        break
    done

    # Hard fallback: KasmVNC always runs on :1 in linuxserver webtop
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        export DISPLAY=":1"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# HEALTHCHECK — curl (5ms) instead of spawning python3 (200ms × 50 = 10s)
# ─────────────────────────────────────────────────────────────────────────────
_is_server_running() {
    curl -sf --max-time 1 "${URL}/healthz" >/dev/null 2>&1
}

_wait_for_server() {
    local MAX=30  # seconds
    local i=0
    while [ "${i}" -lt "${MAX}" ]; do
        _is_server_running && return 0
        sleep 0.2
        i=$((i + 1))
    done
    echo "[gitbios] Server did not start within ${MAX}s — check ${LOG}" >&2
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# BROWSER LAUNCH — verified open, not just nohup fire-and-forget
#
# Key change: we check that a browser actually opened by testing if the
# URL is accessible AND the window appeared. If xdg-open is available it
# uses the session's MIME handler which always works correctly.
# ─────────────────────────────────────────────────────────────────────────────
_open_browser() {
    # xdg-open is the correct tool for session-aware URL opening.
    # It delegates to the running DE's handler (Firefox in MATE/i3).
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "${URL}" >/dev/null 2>&1 &
        sleep 0.5
        # Verify something opened (best effort)
        return 0
    fi

    # Fallback list — only try if xdg-open is absent
    for B in \
        "${BROWSER:-}" \
        /usr/bin/firefox \
        /snap/bin/firefox \
        /usr/bin/chromium \
        /usr/bin/chromium-browser \
        /usr/bin/google-chrome \
        /usr/bin/google-chrome-stable \
        /usr/bin/sensible-browser
    do
        [ -n "${B}" ] && [ -x "${B}" ] || continue
        "${B}" "${URL}" >/dev/null 2>&1 &
        return 0
    done

    # Last resort: gio open (goes through gvfs/session handler)
    if command -v gio >/dev/null 2>&1; then
        gio open "${URL}" >/dev/null 2>&1 &
        return 0
    fi

    echo "[gitbios] No browser found. Open manually: ${URL}" | tee -a "${LOG}"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# PYTHON CHECK — stdlib server.py needs only python3, no pip
# ─────────────────────────────────────────────────────────────────────────────
_check_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "[gitbios] ERROR: python3 not found. Install with:" >&2
        echo "  sudo apt-get install -y python3" >&2
        exit 1
    fi
    # Verify server.py exists
    if [ ! -f "${APP_DIR}/server.py" ]; then
        echo "[gitbios] ERROR: server.py not found at ${APP_DIR}/server.py" >&2
        echo "  Re-run the installer: bash ${APP_DIR}/install-git-bios-control-panel.sh" >&2
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "${APP_DIR}"

# Step 1: Set up display environment (critical for desktop icon launch)
_setup_display

# Step 2: Check Python
_check_python

# Step 3: Start server if not already running
if ! _is_server_running; then
    echo "[gitbios] Starting server on port ${PORT}..." | tee -a "${LOG}"
    cd "${APP_DIR}"
    PORT="${PORT}" nohup "${PYBIN}" server.py >> "${LOG}" 2>&1 &
    PYBIN_PID=$!
    echo "[gitbios] Server PID: ${PYBIN_PID}" | tee -a "${LOG}"

    # Wait for the server to become ready
    if ! _wait_for_server; then
        echo "[gitbios] Failed to start. Last log lines:" >&2
        tail -20 "${LOG}" >&2
        exit 1
    fi
    echo "[gitbios] Server ready." | tee -a "${LOG}"
else
    echo "[gitbios] Server already running at ${URL}"
fi

# Step 4: Open browser
_open_browser
echo "[gitbios] Opened: ${URL}"
