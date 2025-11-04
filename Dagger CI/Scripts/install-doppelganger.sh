#!/usr/bin/env bash
set -euo pipefail

# =======================
# Robust Doppelganger installer for Ubuntu 24.04 (noble)
# - Survives flaky apt mirrors and bad 3rd-party repos
# - Never uses 'localhost' (127.0.0.1 only)
# =======================

AGENT_USER="abc"
AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
: "${AGENT_HOME:?could not resolve home for user $AGENT_USER}"

APP_DIR="${AGENT_HOME}/underground-doppelganger"
VENV_DIR="${AGENT_HOME}/.doppelganger-venv"
MCP_PORT=7331

# Default models (override in /config/doppelganger.env)
OLLAMA_HOST_DEFAULT="http://127.0.0.1:11434"
OLLAMA_MODEL_DEFAULT="mistral:instruct"
OLLAMA_FALLBACK_MODEL_DEFAULT="phi4:mini"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash $0"; exit 1
fi
export DEBIAN_FRONTEND=noninteractive

# ---------- apt hardening helpers ----------
apt_fix_sources() {
  echo "[apt] Sanitizing sources…"

  # 1) Disable broken Shiftkey repo if present
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list; do
    [ -f "$f" ] || continue
    if grep -q 'apt\.packages\.shiftkey\.dev' "$f"; then
      sed -i 's|^[[:space:]]*deb[[:space:]].*apt\.packages\.shiftkey\.dev|# disabled: &|g' "$f" || true
    fi
  done

  # 2) Ensure noble entries exist (main, universe, multiverse, restricted)
  #    We append if missing; harmless if duplicates exist elsewhere.
  SRC="/etc/apt/sources.list"
  for POCKET in "" "-updates" "-security"; do
    LINE="deb http://archive.ubuntu.com/ubuntu noble${POCKET} main universe multiverse restricted"
    if ! grep -qF "$LINE" "$SRC"; then
      echo "$LINE" >> "$SRC"
    fi
  done
}

apt_retry_update() {
  echo "[apt] update (with retries)…"
  local i
  for i in {1..5}; do
    if apt-get -o Acquire::Retries=3 \
               -o Acquire::http::Timeout=30 \
               -o Acquire::https::Timeout=30 \
               -o Acquire::ForceIPv4=true \
               update; then
      return 0
    fi
    echo "[apt] update failed (attempt $i). Fixing missing indexes, sleeping…"
    sleep $((i*3))
  done
  # As a last-ditch, don't fail the script; continue with partial indexes.
  echo "[apt] continuing despite update warnings (will use ensurepip/virtualenv if needed)."
  return 0
}

apt_retry_install() {
  # Usage: apt_retry_install pkg1 pkg2 …
  local i
  for i in {1..4}; do
    if apt-get install -y --no-install-recommends --fix-missing "$@"; then
      return 0
    fi
    echo "[apt] install failed for: $* (attempt $i). Retrying…"
    apt_retry_update || true
    sleep $((i*2))
  done
  echo "[apt] WARNING: could not install with apt: $* — will try fallbacks if possible."
  return 1
}

echo "[1/9] APT preflight… (clean + sources)"
rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock || true
dpkg --configure -a || true
apt_fix_sources
apt_retry_update

# Core tools — try via apt; if it flakes, continue
apt_retry_install ca-certificates curl jq git iproute2 iptables supervisor || true

# Terminator (best-effort)
if ! command -v terminator >/dev/null 2>&1; then
  apt_retry_install terminator || true
fi

# Python base — try from apt, but we’ll fall back to ensurepip/virtualenv
apt_retry_install python3 || true
PYBIN="$(command -v python3 || true)"
if [ -z "${PYBIN}" ]; then
  echo "[fatal] python3 not found; cannot continue."
  exit 1
fi

# venv via apt if available; otherwise we’ll use virtualenv fallback
apt_retry_install python3-venv python3.12-venv python3-pip || true

echo "[2/9] Bootstrap pip (ensurepip fallback)…"
if ! "$PYBIN" -m pip --version >/dev/null 2>&1; then
  if "$PYBIN" -m ensurepip --upgrade >/dev/null 2>&1; then
    echo "[pip] installed via ensurepip"
  else
    echo "[pip] ensurepip not available — attempting get-pip fallback"
    # Last-resort get-pip (may fail if network blocks raw GitHub; non-fatal if it does)
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py && "$PYBIN" /tmp/get-pip.py || true
  fi
fi

echo "[3/9] Create venv (venv or virtualenv fallback)…"
if "$PYBIN" -c 'import venv' 2>/dev/null; then
  sudo -u "$AGENT_USER" -H bash -lc "$PYBIN -m venv '${VENV_DIR}'"
else
  echo "[venv] stdlib venv missing — using virtualenv fallback"
  "$PYBIN" -m pip install -q --user virtualenv || true
  VENVEXE="$(sudo -u "$AGENT_USER" -H bash -lc 'python3 -m site --user-base')/bin/virtualenv"
  if [ ! -x "$VENVEXE" ]; then
    # try system location as well
    VENVEXE="$(command -v virtualenv || true)"
  fi
  if [ -x "$VENVEXE" ]; then
    sudo -u "$AGENT_USER" -H "$VENVEXE" "$VENV_DIR"
  else
    echo "[fatal] could not provision a virtual environment (virtualenv missing)."
    exit 1
  fi
fi

echo "[4/9] Upgrade pip/setuptools/wheel in venv…"
sudo -u "$AGENT_USER" -H bash -lc "'${VENV_DIR}/bin/python' -m pip install -q --upgrade pip setuptools wheel"

echo "[5/9] Install Python runtime deps in venv…"
sudo -u "$AGENT_USER" -H bash -lc "'${VENV_DIR}/bin/pip' install -q fastapi uvicorn[standard] requests rich pydantic pyyaml"

echo "[6/9] Write MCP server…"
install -d -o "$AGENT_USER" -g "$AGENT_USER" "$APP_DIR"
cat > "${APP_DIR}/doppel_server.py" <<'PY'
#!/usr/bin/env python
import subprocess
from typing import Dict, Any
from fastapi import FastAPI, HTTPException

app = FastAPI(title="Underground-Doppelganger MCP")

def _shell(cmd: str, timeout: int = 600):
    return subprocess.run(["bash","-lc", cmd], capture_output=True, text=True, timeout=timeout)

TOOLS = {
    "net.packet_loss.inject": {
        "desc": "Inject X% packet loss for N seconds on a target interface.",
        "schema": {"target":{"type":"string"},"percent":{"type":"number","minimum":0,"maximum":5},
                   "duration_s":{"type":"integer","minimum":5,"maximum":600},"dry_run":{"type":"boolean"}},
        "command": lambda p: f"tc qdisc add dev {p['target']} root netem loss {p['percent']}% && sleep {p['duration_s']} && tc qdisc del dev {p['target']} root netem"
    },
    "compute.cpu_stress": {
        "desc": "Low-intensity CPU spin for N seconds (demo).",
        "schema": {"percent":{"type":"number","minimum":1,"maximum":50},"duration_s":{"type":"integer","minimum":5,"maximum":300},"dry_run":{"type":"boolean"}},
        "command": lambda p: f"timeout {p['duration_s']} bash -c 'while :; do :; done' &>/dev/null"
    },
    "pihole.sinkhole.domain": {
        "desc": "Demo sinkhole via /etc/hosts (local node only).",
        "schema": {"domain":{"type":"string"},"duration_s":{"type":"integer","minimum":5,"maximum":180},"dry_run":{"type":"boolean"}},
        "command": lambda p: f"echo '0.0.0.0 {p['domain']}' | sudo tee -a /etc/hosts >/dev/null && sleep {p['duration_s']} && sudo sed -i '/ {p['domain']}$/{d}' /etc/hosts"
    }
}

@app.get("/mcp/tools")
def list_tools():
    return {"tools": [{"name": n, "description": s["desc"], "schema": s["schema"]} for n, s in TOOLS.items()]}

@app.post("/mcp/call/{tool_name}")
def call_tool(tool_name: str, req: Dict[str, Any]):
    if tool_name not in TOOLS:
        raise HTTPException(status_code=404, detail=f"Unknown tool '{tool_name}'")
    params = req or {}
    schema = TOOLS[tool_name]["schema"]
    for k in schema:
        if k not in params:
            raise HTTPException(status_code=400, detail=f"Missing parameter '{k}'")
    dry = bool(params.get("dry_run", False))
    cmd = TOOLS[tool_name]["command"](params)

    if dry:
        return {"ok": True, "dry_run": True, "command": ["bash","-lc",cmd]}

    try:
        out = _shell(cmd, timeout=max(10, int(params.get("duration_s", 10)) + 5))
        return {"ok": out.returncode == 0, "returncode": out.returncode,
                "stdout": (out.stdout or "").strip(), "stderr": (out.stderr or "").strip(),
                "command": ["bash","-lc",cmd]}
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=500, detail="Tool timed out")
PY
sed -i "1s|.*|#!${VENV_DIR}/bin/python|" "${APP_DIR}/doppel_server.py"
chmod +x "${APP_DIR}/doppel_server.py"
chown "${AGENT_USER}:${AGENT_USER}" "${APP_DIR}/doppel_server.py"

echo "[7/9] Write chat client (127.0.0.1 only; spinner on think)…"
cat > "${APP_DIR}/doppel_chat.py" <<'PY'
#!/usr/bin/env python
import os, json, time, threading, itertools, requests
from rich.console import Console
from rich.prompt import Prompt

# Force numeric loopback; 'localhost' is unreliable in this environment
OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "mistral:instruct")
MCP_HOST = os.getenv("MCP_HOST", "http://127.0.0.1:7331")

console = Console()

def spinner(msg="Thinking…"):
  stop = {"go": True}
  def run():
    for c in itertools.cycle("|/-\\"):
      if not stop["go"]: break
      console.print(f"[dim]{msg} {c}[/dim]", end="\r", soft_wrap=False)
      time.sleep(0.08)
    console.print(" " * 80, end="\r")
  t = threading.Thread(target=run, daemon=True); t.start()
  return lambda: stop.__setitem__("go", False)

def ollama_generate(prompt: str) -> str:
  url = f"{OLLAMA_HOST}/api/generate"
  payload = {"model": OLLAMA_MODEL, "prompt": prompt, "stream": False}
  r = requests.post(url, json=payload, timeout=300)
  if r.status_code == 404:
    raise RuntimeError(f"Ollama API 404 at {url} — confirm daemon reachable at 127.0.0.1:11434 and model exists.")
  r.raise_for_status()
  data = r.json()
  return (data.get("response") or "").strip()

def mcp_call(tool: str, params: dict) -> dict:
  url = f"{MCP_HOST}/mcp/call/{tool}"
  r = requests.post(url, json=params, timeout=300)
  r.raise_for_status()
  return r.json()

def main():
  console.print("[bold]Underground-Doppelganger[/bold] — type 'exit' to quit.")
  console.print(f"• Chat model: [bold]{OLLAMA_MODEL}[/bold]")
  console.print(f"• Ollama: [bold]{OLLAMA_HOST}[/bold]")
  console.print(f"• MCP: [bold]{MCP_HOST}[/bold]")
  console.print("• Use: [bold]run: TOOL {JSON}[/bold]  e.g.  run: net.packet_loss.inject {\"target\":\"lo\",\"percent\":1,\"duration_s\":10,\"dry_run\":true}\n")

  while True:
    try:
      msg = Prompt.ask("[bold cyan]You[/bold cyan]")
    except (KeyboardInterrupt, EOFError):
      console.print("\n[dim]Exiting…[/dim]"); break

    if msg.strip().lower() in ("exit","quit"): break

    if msg.strip().startswith("run:"):
      try:
        _, rest = msg.split(":", 1)
        rest = rest.strip()
        sp = rest.find(" ")
        tool, params = (rest, {}) if sp == -1 else (rest[:sp].strip(), json.loads(rest[sp:].strip()))
        stop = spinner("Running tool…")
        try:
          res = mcp_call(tool, params)
        finally:
          stop()
        console.print("[green]MCP →[/green] ", res)
      except Exception as e:
        console.print(f"[red]MCP error:[/red] {e}")
      continue

    stop = spinner()
    try:
      reply = ollama_generate(msg)
    except Exception as e:
      reply = f"[red]Ollama error:[/red] {e}"
    finally:
      stop()
    console.print(f"[magenta]Doppelganger:[/magenta] {reply}")

if __name__ == "__main__":
  main()
PY
sed -i "1s|.*|#!${VENV_DIR}/bin/python|" "${APP_DIR}/doppel_chat.py"
chmod +x "${APP_DIR}/doppel_chat.py"
chown "${AGENT_USER}:${AGENT_USER}" "${APP_DIR}/doppel_chat.py"

echo "[8/9] Env + model ensure helpers…"
cat > "/config/doppelganger.env" <<EOF
# Override as needed (keep 127.0.0.1 — do not use localhost)
OLLAMA_HOST=${OLLAMA_HOST_DEFAULT}
OLLAMA_MODEL=${OLLAMA_MODEL_DEFAULT}
OLLAMA_FALLBACK_MODEL=${OLLAMA_FALLBACK_MODEL_DEFAULT}
MCP_HOST=http://127.0.0.1:${MCP_PORT}
EOF
chmod 0644 /config/doppelganger.env

cat > "/config/doppelganger-ensure-models.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${OLLAMA_HOST:=http://127.0.0.1:11434}"
: "${OLLAMA_MODEL:=mistral:instruct}"
: "${OLLAMA_FALLBACK_MODEL:=phi4:mini}"

if ! command -v ollama >/dev/null 2>&1; then
  echo "[doppel] Ollama not installed; skipping model check."
  exit 0
fi

tags_json="$(curl -s "${OLLAMA_HOST}/api/tags" || true)"
have_model() {
  echo "$tags_json" | jq -e --arg m "$1" '.models | any(.name == $m)' >/dev/null 2>&1
}

pull_if_missing() {
  local m="$1"
  if have_model "$m"; then
    echo "[doppel] model present: $m"
  else
    echo "[doppel] pulling: $m"
    ollama pull "$m" || echo "[doppel] pull failed (non-fatal): $m"
  fi
}

pull_if_missing "$OLLAMA_MODEL"
pull_if_missing "$OLLAMA_FALLBACK_MODEL"
EOF
chmod +x /config/doppelganger-ensure-models.sh

echo "[9/9] Launchers + desktop entry…"
cat > "${AGENT_HOME}/doppelganger-chat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -f /config/doppelganger.env ]; then
  set -a; . /config/doppelganger.env; set +a
fi

: "${OLLAMA_HOST:=http://127.0.0.1:11434}"
: "${OLLAMA_MODEL:=mistral:instruct}"
: "${OLLAMA_FALLBACK_MODEL:=phi4:mini}"
: "${MCP_HOST:=http://127.0.0.1:7331}"

# Ensure models (quiet)
[ -x /config/doppelganger-ensure-models.sh ] && /config/doppelganger-ensure-models.sh || true

# Start MCP if not up
if ! curl -s "${MCP_HOST}/mcp/tools" >/dev/null 2>&1; then
  nohup "${HOME}/.doppelganger-venv/bin/python" "${HOME}/underground-doppelganger/doppel_server.py" >/tmp/doppel-mcp.log 2>&1 &
  for i in {1..30}; do
    sleep 0.2
    curl -s "${MCP_HOST}/mcp/tools" >/dev/null 2>&1 && break || true
  done
fi

export OLLAMA_HOST OLLAMA_MODEL MCP_HOST
if ! "${HOME}/.doppelganger-venv/bin/python" "${HOME}/underground-doppelganger/doppel_chat.py"; then
  if [ -n "${OLLAMA_FALLBACK_MODEL:-}" ]; then
    echo "[doppel] retrying with fallback model: ${OLLAMA_FALLBACK_MODEL}"
    export OLLAMA_MODEL="${OLLAMA_FALLBACK_MODEL}"
    exec "${HOME}/.doppelganger-venv/bin/python" "${HOME}/underground-doppelganger/doppel_chat.py"
  else
    exit 1
  fi
fi
EOF
chmod +x "${AGENT_HOME}/doppelganger-chat"
chown "${AGENT_USER}:${AGENT_USER}" "${AGENT_HOME}/doppelganger-chat"

cat > "${AGENT_HOME}/run-doppelganger.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LAUNCH="${HOME}/doppelganger-chat"
if command -v terminator >/dev/null 2>&1; then
  exec terminator -e "bash -lc '${LAUNCH}; echo; read -p \"Press Enter to close…\"'"
else
  exec "${LAUNCH}"
fi
EOF
chmod +x "${AGENT_HOME}/run-doppelganger.sh"
chown "${AGENT_USER}:${AGENT_USER}" "${AGENT_HOME}/run-doppelganger.sh"

DESK="${AGENT_HOME}/Desktop/Underground-Doppelganger.desktop"
cat > "${DESK}" <<EOF
[Desktop Entry]
Type=Application
Name=Underground Doppelganger
Exec=${AGENT_HOME}/run-doppelganger.sh
Terminal=true
Icon=utilities-terminal
EOF
chmod +x "${DESK}"
chown "${AGENT_USER}:${AGENT_USER}" "${DESK}"

# Pin shebangs to venv python
sed -i "1s|.*|#!${VENV_DIR}/bin/python|" "${APP_DIR}/doppel_server.py" "${APP_DIR}/doppel_chat.py"

echo
echo "✅ Install complete (with apt hardening)."
echo "Launch (user):"
echo "  sudo -u ${AGENT_USER} -H ${AGENT_HOME}/doppelganger-chat"
echo "  or: ${AGENT_HOME}/run-doppelganger.sh (opens Terminator if present)"
echo
echo "Env overrides: /config/doppelganger.env"
echo "  OLLAMA_HOST, OLLAMA_MODEL, OLLAMA_FALLBACK_MODEL, MCP_HOST"
echo
echo "MCP check:"
echo "  curl -s http://127.0.0.1:${MCP_PORT}/mcp/tools | jq"
