cat >/config/Desktop/nexus-bucket/underground-nexus/Jelly-Apps/Git-BIOS-Control-Panel/start_control_panel.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/config/Desktop/nexus-bucket/underground-nexus/Jelly-Apps/Git-BIOS-Control-Panel"

# Prefer a venv under /nexus-bucket; fall back to $HOME if not writable
DEFAULT_VENV="/config/Desktop/nexus-bucket/underground-nexus/Jelly-Apps/Git-BIOS-Control-Panel/cp-venv"
FALLBACK_VENV="$HOME/.gitbios-venv"
VENV_DIR="${VENV_DIR:-$DEFAULT_VENV}"
if ! mkdir -p "$VENV_DIR" 2>/dev/null; then
  VENV_DIR="$FALLBACK_VENV"
  mkdir -p "$VENV_DIR"
fi

PORT="${PORT:-5000}"
HTML_SOURCE="${HTML_SOURCE:-$APP_DIR/gitbios-control-panel.html}"
LOG="/config/Desktop/nexus-bucket/underground-nexus/Jelly-Apps/Git-BIOS-Control-Panel/control-panel.log"
URL="http://localhost:${PORT}"

healthcheck () {
python3 - "$@" <<'PY'
import sys, urllib.request, urllib.error, time, os
url=os.environ.get('URL')
for _ in range(50):
    try:
        with urllib.request.urlopen(url+'/healthz', timeout=1) as r:
            if r.status==200: sys.exit(0)
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
    [ -n "$B" ] || continue
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

# Check if venv module is available at all (python3-venv might be missing)
if "$PYBIN" -Im venv -h >/dev/null 2>&1; then
  if [ ! -x "$VENV_DIR/bin/python3" ]; then
    # Try to create the venv; if ensurepip explodes, we catch it and continue without venv
    if "$PYBIN" -Im venv "$VENV_DIR" >/dev/null 2>&1; then
      USE_VENV=1
      # Try to ensure pip inside the venv (ignore failure; we'll fall back later)
      "$VENV_DIR/bin/python3" -Im ensurepip --upgrade >/dev/null 2>&1 || true
    fi
  else
    USE_VENV=1
  fi
fi

if [ "$USE_VENV" -eq 1 ]; then
  PYBIN="$VENV_DIR/bin/python3"
  # If Flask missing in venv, try to install (only if pip exists)
  if ! "$PYBIN" -c "import flask" 2>/dev/null; then
    if [ -x "$VENV_DIR/bin/pip" ]; then
      TMPDIR=/var/tmp PIP_NO_CACHE_DIR=1 "$VENV_DIR/bin/pip" install "Flask==3.0.2" || true
    fi
    # If still no Flask, abandon venv and use system Python
    "$PYBIN" -c "import flask" 2>/dev/null || USE_VENV=0
  fi
fi

if [ "$USE_VENV" -eq 0 ]; then
  PYBIN="python3"
  # If Flask missing on the system interpreter, install to user site (no sudo)
  if ! "$PYBIN" -c "import flask" 2>/dev/null; then
    # Try best-effort user install; ignore failures so we can still show logs
    "$PYBIN" -m pip install --user --break-system-packages --no-cache-dir "Flask==3.0.2" || true
  fi
fi

# Final check - bail with a helpful message if Flask is still missing
if ! "$PYBIN" -c "import flask" 2>/dev/null; then
  echo "ERROR: Flask is not available in venv ($VENV_DIR) or system Python." >&2
  echo "Workarounds:" >&2
  echo "  1) Try: sudo apt-get update && sudo apt-get install -y python3-venv" >&2
  echo "  2) Or run once: python3 -m pip install --user --break-system-packages Flask==3.0.2" >&2
  exit 1
fi

# -------------------------
# Start the server if needed
# -------------------------
export URL
if ! healthcheck; then
  cd "$APP_DIR"
  (PORT="$PORT" HTML_SOURCE="$HTML_SOURCE" nohup "$PYBIN" server.py >> "$LOG" 2>&1 &) >/dev/null
  healthcheck || echo "Started; health check not ready yet." >> "$LOG" || true
fi

open_url || true
EOF

chmod +x /config/Desktop/nexus-bucket/underground-nexus/Jelly-Apps/Git-BIOS-Control-Panel