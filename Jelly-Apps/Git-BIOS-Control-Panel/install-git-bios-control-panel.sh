bash -euxo pipefail <<'EOF'
# ============================================================
# Git-BIOS Control Panel - install/repair script (Ubuntu/MATE)
# - Follows README flow: venv, start_control_panel.sh, desktop icon
# - Repairs if present; installs if missing.
# - Target user = abc (change TARGET_USER to adjust)
# ============================================================

export DEBIAN_FRONTEND=noninteractive

# --- settings ---
TARGET_USER="${TARGET_USER:-abc}"
APP_DIR_DEFAULT="/config/Desktop/nexus-bucket/underground-nexus/Jelly-Apps/Git-BIOS-Control-Panel"
APP_DIR="${APP_DIR:-$APP_DIR_DEFAULT}"
PORT="${PORT:-5000}"

# Resolve abc's HOME and Desktop
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
[ -n "$USER_HOME" ] || USER_HOME="/home/$TARGET_USER"

as_abc() { sudo -u "$TARGET_USER" -H bash -lc "$*"; }

DESKTOP_DIR="$(as_abc 'command -v xdg-user-dir >/dev/null 2>&1 && xdg-user-dir DESKTOP || echo "$HOME/Desktop"')"
[ -n "$DESKTOP_DIR" ] || DESKTOP_DIR="$USER_HOME/Desktop"

# Use sudo for system changes if not root
if [ "${EUID:-$(id -u)}" -ne 0 ]; then SUDO="sudo -n"; else SUDO=""; fi

# --- ensure minimal system deps (best-effort) ---
$SUDO apt-get update || true
$SUDO apt-get install -y python3 python3-venv python3-pip xdg-utils desktop-file-utils gio || true

# --- create app dir if missing; do not overwrite your code ---
mkdir -p "$APP_DIR"
chown -R "$TARGET_USER:$TARGET_USER" "$APP_DIR"

# If requirements are missing entirely, write a minimal one so we can proceed.
if [ ! -f "$APP_DIR/requirements-flask.txt" ] && [ ! -f "$APP_DIR/requirements.txt" ]; then
  echo "flask==3.0.2" > "$APP_DIR/requirements-flask.txt"
  chown "$TARGET_USER:$TARGET_USER" "$APP_DIR/requirements-flask.txt"
fi

# If there's no server.py yet, create a tiny compatible stub so the launcher works.
if [ ! -f "$APP_DIR/server.py" ]; then
  cat > "$APP_DIR/server.py" <<'PY'
from flask import Flask
app = Flask(__name__)

@app.get("/")
def index():
    return "<h1>Git-BIOS Control Panel</h1><p>Stub running.</p>"

@app.get("/healthz")
def healthz():
    return "ok", 200

if __name__ == "__main__":
    import os
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT","5000")))
PY
  chown "$TARGET_USER:$TARGET_USER" "$APP_DIR/server.py"
fi

# --- write the exact start_control_panel.sh described in README ---
# (slightly hardened but functionally identical to the README version) :contentReference[oaicite:1]{index=1}
cat > "$APP_DIR/start_control_panel.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="{{APP_DIR}}"
# Prefer a venv under app dir; fall back to $HOME if not writable
DEFAULT_VENV="{{APP_DIR}}/cp-venv"
FALLBACK_VENV="$HOME/.gitbios-venv"
VENV_DIR="${VENV_DIR:-$DEFAULT_VENV}"

if ! mkdir -p "$VENV_DIR" 2>/dev/null; then
  VENV_DIR="$FALLBACK_VENV"
  mkdir -p "$VENV_DIR"
fi

PORT="${PORT:-5000}"
HTML_SOURCE="${HTML_SOURCE:-$APP_DIR/gitbios-control-panel.html}"
LOG="$APP_DIR/control-panel.log"
URL="http://localhost:${PORT}"

healthcheck () {
  python3 - "$@" <<'PY'
import sys, urllib.request, urllib.error, time, os
url=os.environ.get('URL')
for _ in range(50):
    try:
        with urllib.request.urlopen(url+'/healthz', timeout=1) as r:
            if r.status==200:
                sys.exit(0)
    except Exception:
        time.sleep(0.2)
sys.exit(1)
PY
}

open_url () {
  for B in \
    "${BROWSER:-}" \
    /usr/bin/firefox /snap/bin/firefox \
    /usr/bin/chromium /usr/bin/chromium-browser \
    /usr/bin/google-chrome /usr/bin/google-chrome-stable \
    /usr/bin/sensible-browser \
    /usr/bin/gio /usr/bin/xdg-open
  do
    [ -n "${B}" ] || continue
    if [ "$B" = "/usr/bin/gio" ]; then
      nohup gio open "$URL" >/dev/null 2>&1 && return 0
    elif [ -x "$B" ]; then
      nohup "$B" "$URL" >/dev/null 2>&1 && return 0
    fi
  done
  echo "Could not find a browser to open $URL" >> "$LOG"
  return 1
}

# -------------------------
# Robust interpreter select
# -------------------------
PYBIN="python3"
USE_VENV=0

# Create venv if python3-venv exists; otherwise run system Python
if "$PYBIN" -Im venv -h >/dev/null 2>&1; then
  if [ ! -x "$VENV_DIR/bin/python3" ]; then
    if "$PYBIN" -Im venv "$VENV_DIR" >/dev/null 2>&1; then
      USE_VENV=1
      "$VENV_DIR/bin/python3" -Im ensurepip --upgrade >/dev/null 2>&1 || true
    fi
  else
    USE_VENV=1
  fi
fi

if [ "$USE_VENV" -eq 1 ]; then
  PYBIN="$VENV_DIR/bin/python3"
  # Ensure Flask in venv
  if ! "$PYBIN" -c "import flask" 2>/dev/null; then
    if [ -x "$VENV_DIR/bin/pip" ]; then
      TMPDIR=/var/tmp PIP_NO_CACHE_DIR=1 "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements-flask.txt" --break-system-packages || \
      "$VENV_DIR/bin/pip" install "Flask==3.0.2" || true
    fi
    "$PYBIN" -c "import flask" 2>/dev/null || USE_VENV=0
  fi
fi

if [ "$USE_VENV" -eq 0 ]; then
  PYBIN="python3"
  # Ensure Flask on system user site if needed
  if ! "$PYBIN" -c "import flask" 2>/dev/null; then
    "$PYBIN" -m pip install --user --no-cache-dir --break-system-packages "Flask==3.0.2" || true
  fi
fi

# Final guard
if ! "$PYBIN" -c "import flask" 2>/dev/null; then
  echo "ERROR: Flask not available. Try: sudo apt-get install -y python3-venv && rerun." >&2
  exit 1
fi

# -------------------------
# Start server if not alive
# -------------------------
export URL
if ! healthcheck; then
  cd "$APP_DIR"
  (PORT="$PORT" HTML_SOURCE="$HTML_SOURCE" nohup "$PYBIN" server.py >> "$LOG" 2>&1 &) >/dev/null
fi

open_url || true
SH

# Fill in APP_DIR placeholder, make executable
sed -i "s|{{APP_DIR}}|$APP_DIR|g" "$APP_DIR/start_control_panel.sh"
chmod +x "$APP_DIR/start_control_panel.sh"
chown "$TARGET_USER:$TARGET_USER" "$APP_DIR/start_control_panel.sh"

# --- build/repair venv once up-front (mirrors README step 1) :contentReference[oaicite:2]{index=2}
if ! as_abc "cd '$APP_DIR' && python3 -m venv .venv"; then
  echo "Note: python3-venv not available or failed; will fall back to system Python at runtime."
else
  as_abc "'$APP_DIR/.venv/bin/python' -m pip install --upgrade pip setuptools wheel"
  if [ -f "$APP_DIR/requirements-flask.txt" ]; then
    as_abc "'$APP_DIR/.venv/bin/pip' install -r '$APP_DIR/requirements-flask.txt' --break-system-packages || true"
  elif [ -f "$APP_DIR/requirements.txt" ]; then
    as_abc "'$APP_DIR/.venv/bin/pip' install -r '$APP_DIR/requirements.txt' --break-system-packages || true"
  else
    as_abc "'$APP_DIR/.venv/bin/pip' install flask==3.0.2 --break-system-packages || true"
  fi
fi

# --- create desktop icon per README (MATE friendly) :contentReference[oaicite:3]{index=3}
install -d -m 755 -o "$TARGET_USER" -g "$TARGET_USER" "$DESKTOP_DIR"

ICON_PATH="$APP_DIR/static/assets/nexus-logo.png"
[ -f "$ICON_PATH" ] || ICON_PATH="/config/Desktop/nexus-bucket/underground-nexus/Jelly-Apps/Git-BIOS-Control-Panel/static/assets/nexus-logo.png"

DESK_FILE="$DESKTOP_DIR/Git-Bios Control Panel.desktop"
cat > "$DESK_FILE" <<EOF2
[Desktop Entry]
Version=1.0
Type=Application
Name=Git-Bios Control Panel
Comment=Launch the Git-BIOS Control Panel
Exec=$APP_DIR/start_control_panel.sh
Path=$APP_DIR
Icon=$ICON_PATH
Terminal=false
Categories=Utility;
TryExec=$APP_DIR/start_control_panel.sh
EOF2

chown "$TARGET_USER:$TARGET_USER" "$DESK_FILE"
chmod +x "$DESK_FILE"
# Mark trusted (MATE/Caja respects this; harmless if gio not present)
gio set "$DESK_FILE" metadata::trusted true 2>/dev/null || true

echo
echo "==> Done."
echo "Start now (foreground):   sudo -u '$TARGET_USER' -H bash -lc '$APP_DIR/start_control_panel.sh'"
echo "Desktop icon created at:  $DESKTOP_DIR"
echo "App dir:                  $APP_DIR"
echo
EOF
