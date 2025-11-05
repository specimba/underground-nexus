#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Underground Doppelganger — installer/repair (Ubuntu 24.04)
# - Keeps your working defaults, fixes planner regex + NLP, adds tools
# - MCP server via uvicorn on 127.0.0.1:7331
# - Launchers under /config
# - Optional: --install-service to supervise MCP
# =========================================================

AGENT_USER="abc"
CONFIG_DIR="/config"
APP_DIR="${CONFIG_DIR}/underground-doppelganger"
VENV_DIR="${CONFIG_DIR}/.doppelganger-venv"
DESKTOP_DIR="${CONFIG_DIR}/Desktop"
MCP_PORT=7331

INSTALL_SERVICE="no"
if [[ "${1:-}" == "--install-service" ]]; then
  INSTALL_SERVICE="yes"
fi

# -------- defaults (overridable via /config/doppelganger.env) --------
OLLAMA_HOST_DEFAULT="http://127.0.0.1:11434"
OLLAMA_MODEL_DEFAULT="mistral:7b-instruct-q2_K"      # primary (quantized)
OLLAMA_FALLBACK_MODEL_DEFAULT="mistral:instruct"      # fallback
SMALL_CANDIDATES_DEFAULT="phi4:mini phi4:latest phi3:mini"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash $0 [--install-service]"; exit 1
fi
export DEBIAN_FRONTEND=noninteractive

# ---------- apt helpers ----------
apt_fix_sources() {
  echo "[apt] Sanitizing sources…"
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list; do
    [ -f "$f" ] || continue
    if grep -q 'apt\.packages\.shiftkey\.dev' "$f"; then
      sed -i 's|^[[:space:]]*deb[[:space:]].*apt\.packages\.shiftkey\.dev|# disabled: &|g' "$f" || true
    fi
  done
  if [ -f /etc/apt/sources.list ]; then
    cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%s) || true
  fi
  cat > /etc/apt/sources.list <<'EOF'
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOF
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
    echo "[apt] update failed (attempt $i). Sleeping…"
    sleep $((i*3))
  done
  echo "[apt] continuing despite update warnings."
  return 0
}

apt_retry_install() {
  local i
  for i in {1..4}; do
    if apt-get install -y --no-install-recommends --fix-missing "$@"; then
      return 0
    fi
    echo "[apt] install failed for: $* (attempt $i). Retrying…"
    apt_retry_update || true
    sleep $((i*2))
  done
  echo "[apt] WARNING: could not install with apt: $*"
  return 1
}

echo "[1/9] APT preflight…"
rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock || true
dpkg --configure -a || true
apt_fix_sources
apt_retry_update
apt_retry_install ca-certificates curl jq git iproute2 iptables supervisor || true
apt_retry_install python3 python3-venv python3.12-venv python3-pip || true

# Make sure user exists and has a home
AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6 || true)"
if [ -z "${AGENT_HOME}" ] || [ ! -d "${AGENT_HOME}" ]; then
  echo "[fatal] could not resolve home for user ${AGENT_USER}"; exit 1
fi

PYBIN="$(command -v python3 || true)"
[ -n "$PYBIN" ] || { echo "[fatal] python3 not found"; exit 1; }

echo "[2/9] Bootstrap pip…"
if ! "$PYBIN" -m pip --version >/dev/null 2>&1; then
  "$PYBIN" -m ensurepip --upgrade >/dev/null 2>&1 || {
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
    "$PYBIN" /tmp/get-pip.py || true
  }
fi

echo "[3/9] Create venv under ${VENV_DIR}…"
install -d -o "${AGENT_USER}" -g "${AGENT_USER}" "$(dirname "${VENV_DIR}")"
if [ ! -d "${VENV_DIR}" ]; then
  sudo -u "${AGENT_USER}" -H bash -lc "$PYBIN -m venv '${VENV_DIR}'"
fi

echo "[4/9] Upgrade pip/setuptools/wheel in venv…"
sudo -u "${AGENT_USER}" -H bash -lc "'${VENV_DIR}/bin/python' -m pip install -q --upgrade pip setuptools wheel"

echo "[5/9] Install Python deps (FastAPI + Uvicorn + requests + rich + pydantic + pyyaml)…"
sudo -u "${AGENT_USER}" -H bash -lc "'${VENV_DIR}/bin/pip' install -q fastapi uvicorn[standard] requests rich pydantic pyyaml"

echo "[6/9] Write MCP server (served by uvicorn)…"
install -d -o "${AGENT_USER}" -g "${AGENT_USER}" "${APP_DIR}"

cat > "${APP_DIR}/doppel_server.py" <<'PY'
#!/usr/bin/env python
import subprocess, re, shlex, os
from typing import Dict, Any
from fastapi import FastAPI, HTTPException, Body
from pydantic import BaseModel

app = FastAPI(title="Underground-Doppelganger MCP")

def _shell(cmd: str, timeout: int = 600):
    return subprocess.run(["bash","-lc", cmd], capture_output=True, text=True, timeout=timeout)

# Explicit tools
TOOLS: Dict[str, Dict[str, Any]] = {
    "net.packet_loss.inject": {
        "desc": "Inject X% packet loss for N seconds on a target interface.",
        "schema": {"target":{"type":"string"},"percent":{"type":"number","minimum":0,"maximum":5},"duration_s":{"type":"integer","minimum":5,"maximum":600},"dry_run":{"type":"boolean"}},
        "command": lambda p: f"tc qdisc add dev {shlex.quote(p['target'])} root netem loss {p['percent']}% && sleep {p['duration_s']} && tc qdisc del dev {shlex.quote(p['target'])} root netem"
    },
    "compute.cpu_stress": {
        "desc": "Low-intensity CPU spin for N seconds (demo).",
        "schema": {"percent":{"type":"number","minimum":1,"maximum":50},"duration_s":{"type":"integer","minimum":5,"maximum":300},"dry_run":{"type":"boolean"}},
        "command": lambda p: f"timeout {p['duration_s']} bash -c 'while :; do :; done' &>/dev/null"
    },
    "pihole.sinkhole.domain": {
        "desc": "Demo sinkhole via /etc/hosts (local node only).",
        "schema": {"domain":{"type":"string"},"duration_s":{"type":"integer","minimum":5,"maximum":180},"dry_run":{"type":"boolean"}},
        "command": lambda p: f"echo '0.0.0.0 {p['domain']}' | sudo tee -a /etc/hosts >/dev/null && sleep {p['duration_s']} && sudo sed -i '/ {p['domain']}$/{{d}}' /etc/hosts"
    },
    "fs.create_file": {
        "desc": "Create a file at path with provided content (local).",
        "schema": {"path":{"type":"string"},"content":{"type":"string"},"dry_run":{"type":"boolean"}},
        "command": lambda p: ("mkdir -p \"$(dirname '{path}')\" && printf '%s' \"{content}\" > '{path}'").format(
            path=p['path'].replace("'", "'\"'\"'"),
            content=p['content'].replace("'", "'\"'\"'")
        )
    },
    "pkg.install": {
        "desc": "Install apt package(s) via apt-get (non-interactive).",
        "schema": {"packages":{"type":"array"},"dry_run":{"type":"boolean"}},
        "command": lambda p: ("DEBIAN_FRONTEND=noninteractive apt-get update && "
                              "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "
                              + " ".join(shlex.quote(x) for x in (p.get('packages') or [])))
    },
    "pkg.update": {
        "desc": "apt-get update and (optionally) upgrade -y.",
        "schema": {"full_upgrade":{"type":"boolean"},"dry_run":{"type":"boolean"}},
        "command": lambda p: ("DEBIAN_FRONTEND=noninteractive apt-get update"
                              + (" && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y" if p.get("full_upgrade") else ""))
    },
    "net.scan.nmap": {
        "desc": "Run nmap against a target with flags.",
        "schema": {"target":{"type":"string"},"flags":{"type":"string"},"dry_run":{"type":"boolean"}},
        "command": lambda p: f"nmap {p.get('flags','-p-')} {shlex.quote(p.get('target','127.0.0.1'))}"
    },
    "process.launch": {
        "desc": "Run a process/command on the host.",
        "schema": {"cmd":{"type":"string"},"bg":{"type":"boolean"},"dry_run":{"type":"boolean"}},
        "command": lambda p: (p['cmd'] + (" &" if p.get('bg') else ""))
    }
}

@app.get("/mcp/tools")
def list_tools():
    return {"tools": [{"name": n, "description": s["desc"], "schema": s["schema"]} for n, s in TOOLS.items()]}

class PlanReq(BaseModel):
    text: str

def _capture_int(s: str, default: int) -> int:
    m = re.search(r"(\d+)", s)
    return int(m.group(1)) if m else default

@app.post("/mcp/plan")
def plan(req: PlanReq):
    t = req.text.strip()
    tl = t.lower()

    # CPU stress (e.g., "run cpu stress test for 20 seconds")
    if "cpu" in tl or "stress" in tl:
        dur = _capture_int(tl, 20)
        return {"tool":"compute.cpu_stress","params":{"percent":10,"duration_s":dur,"dry_run": True}}

    # Packet loss / chaos netem
    if any(k in tl for k in ["packet loss","netem","loss on","add loss","network chaos"]):
        dur = _capture_int(tl, 10)
        return {"tool":"net.packet_loss.inject","params":{"target":"lo","percent":1,"duration_s":dur,"dry_run": True}}

    # apt update/upgrade
    if any(kw in tl for kw in ["update ubuntu","upgrade ubuntu","apt update","apt upgrade","update system"]):
        full = ("upgrade" in tl)
        return {"tool":"pkg.update","params":{"full_upgrade": full, "dry_run": True}}

    # install packages (fixed regex: escape '-' to avoid ranges)
    if any(k in tl for k in ["install ", "apt install", "apt-get install", "install package", "install packages"]):
        m = re.search(r"install(?: packages?| package)?(?: of)?[: ]*([A-Za-z0-9+._,\- ]+)", t, re.IGNORECASE)
        pkgs = []
        if m:
            pkgs = [p.strip() for p in re.split(r"[,\s]+", m.group(1)) if p.strip()]
        if not pkgs:
            # last token fallback
            tokens = t.strip().split()
            if tokens: pkgs = [tokens[-1]]
        return {"tool":"pkg.install","params":{"packages":pkgs,"dry_run": True}}

    # nmap / scan
    if "nmap" in tl or "port scan" in tl or "scan " in tl:
        # flags
        flags = "-p-" if "-p" in tl or " -p-" in tl else ""
        # target
        tm = re.search(r"(?:scan|nmap)\s+([A-Za-z0-9\.\-:]+)", tl)
        target = tm.group(1) if tm else "127.0.0.1"
        return {"tool":"net.scan.nmap","params":{"target": target, "flags": flags or "-p-", "dry_run": True}}

    # create/write/make file on Desktop
    if ("desktop" in tl) and any(k in tl for k in ["file","document","note","create","write","make"]):
        path = "/config/Desktop/new-file.txt"
        mm = re.search(r"(?:file|document|note)(?: named| called)?[: ]+([^\s,]+)", t, re.IGNORECASE)
        if mm:
            fn = mm.group(1)
            if not fn.startswith("/"): path = f"/config/Desktop/{fn}"
        content = "# created by doppelganger\n"
        cm = re.search(r"(?:with|containing)[: ]+(.+)$", t, re.IGNORECASE)
        if cm: content = cm.group(1)
        return {"tool":"fs.create_file","params":{"path":path,"content":content,"dry_run": True}}

    # open/launch/run <cmd>
    mm = re.search(r"(?:open|launch|run)\s+([A-Za-z0-9._+\-]+)(?:\s+.*)?", t)
    if mm:
        cmd = mm.group(1)
        return {"tool":"process.launch","params":{"cmd":cmd,"bg":True,"dry_run": True}}

    # sinkhole
    sm = re.search(r"(?:block|sinkhole|blackhole).*(\s|^)([A-Za-z0-9.-]+\.[A-Za-z]{2,})", tl)
    if sm:
        domain = sm.group(2)
        return {"tool":"pihole.sinkhole.domain","params":{"domain":domain,"duration_s":60,"dry_run": True}}

    # graceful fallback (no 500/400)
    return {"tool": None, "params": {}, "message": "Could not infer a specific tool. Try: 'install nmap', 'update ubuntu', 'open firefox', 'create file named notes.txt on Desktop', 'run cpu stress test for 20 seconds', or 'nmap scan 127.0.0.1 -p-'."}

@app.post("/mcp/call/{tool}")
def call(tool: str, params: Dict[str, Any] = Body(...)):
    if tool not in TOOLS:
        raise HTTPException(status_code=404, detail=f"Unknown tool: {tool}")
    params = dict(params)
    if "dry_run" not in params:
        params["dry_run"] = True
    try:
        cmd = TOOLS[tool]["command"](params)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error building command: {e}")
    if params.get("dry_run", True):
        return {"tool": tool, "dry_run": True, "command": cmd}
    res = _shell(cmd)
    return {"tool": tool, "returncode": res.returncode, "stdout": res.stdout, "stderr": res.stderr}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("doppel_server:app", host="127.0.0.1", port=7331, reload=False, workers=1)
PY
sed -i "1s|.*|#!${VENV_DIR}/bin/python|" "${APP_DIR}/doppel_server.py"
chmod +x "${APP_DIR}/doppel_server.py"
chown -R "${AGENT_USER}:${AGENT_USER}" "${APP_DIR}"

echo "[7/9] Write chat client (NLP run:, run -y:, tool fallback)…"
cat > "${APP_DIR}/doppel_chat.py" <<'PY'
#!/usr/bin/env python
import os, json, time, threading, itertools, requests
from rich.console import Console
from rich.prompt import Prompt, Confirm

console = Console()

OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")
PREF_MODELS = [
  os.getenv("OLLAMA_MODEL", "mistral:7b-instruct-q2_K"),
  os.getenv("OLLAMA_FALLBACK_MODEL", "mistral:instruct"),
]
SMALL_MODEL = os.getenv("OLLAMA_SMALL_MODEL", "")
MCP_HOST = os.getenv("MCP_HOST", "http://127.0.0.1:7331")

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

def _ollama_tags():
  try:
    r = requests.get(f"{OLLAMA_HOST}/api/tags", timeout=10); r.raise_for_status()
    return [m.get("name") for m in (r.json().get("models") or [])]
  except Exception:
    return []

def _select_model():
  tags = _ollama_tags()
  for m in PREF_MODELS:
    if m and m in tags: return m
  if SMALL_MODEL and SMALL_MODEL in tags: return SMALL_MODEL
  return tags[0] if tags else PREF_MODELS[0]

def _generate(model: str, prompt: str) -> str:
  url = f"{OLLAMA_HOST}/api/generate"
  payload = {"model": model, "prompt": prompt, "stream": False}
  r = requests.post(url, json=payload, timeout=300)
  if r.status_code == 404:
    raise RuntimeError(f"Ollama 404 at {url} — confirm daemon and model tag.")
  r.raise_for_status()
  return (r.json().get("response") or "").strip()

def mcp_call(tool: str, params: dict) -> dict:
  url = f"{MCP_HOST}/mcp/call/{tool}"
  r = requests.post(url, json=params, timeout=300)
  r.raise_for_status()
  return r.json()

def mcp_plan(text: str) -> dict:
  url = f"{MCP_HOST}/mcp/plan"
  r = requests.post(url, json={"text": text}, timeout=120)
  r.raise_for_status()
  return r.json()

def tool_names() -> set:
  try:
    r = requests.get(f"{MCP_HOST}/mcp/tools", timeout=10); r.raise_for_status()
    return {t["name"] for t in r.json().get("tools", [])}
  except Exception:
    return set()

def parse_explicit(rest: str, known: set):
  tok = rest.strip().split(None, 1)
  if not tok: return (None, None)
  # If there's a JSON part, try to parse it
  if len(tok) == 2:
    tool = tok[0].strip()
    try:
      params = json.loads(tok[1].strip())
    except Exception:
      return (None, None)
    # If the tool isn't known, fall back to planner
    if tool not in known:
      return (None, None)
    return (tool, params)
  # Single word → if not a known tool, let the planner handle it
  if tok[0] not in known:
    return (None, None)
  return (tok[0], {})

def main():
  known_tools = tool_names()
  active_model = _select_model()
  console.print("[bold]Underground-Doppelganger[/bold] — type 'exit' to quit.")
  console.print(f"• Active chat model (auto-selected): [bold]{active_model}[/bold]")
  console.print(f"• Ollama: [bold]{OLLAMA_HOST}[/bold]")
  console.print(f"• MCP: [bold]{MCP_HOST}[/bold]")
  console.print("• Use: [bold]run: TOOL {JSON}[/bold] or natural text after [bold]run:[/bold]. Use [bold]run -y:[/bold] to auto-approve.\n")

  while True:
    try:
      msg = Prompt.ask("[bold cyan]You[/bold cyan]")
    except (KeyboardInterrupt, EOFError):
      console.print("\n[dim]Exiting…[/dim]"); break

    if msg.strip().lower() in ("exit","quit"): break

    # Quick model toggles
    if msg.strip().lower() == "/model small":
      tags = _ollama_tags()
      if SMALL_MODEL and SMALL_MODEL in tags:
        active_model = SMALL_MODEL
        console.print(f"[green]Switched to[/green] [bold]{active_model}[/bold].")
      else:
        console.print("[red]No SMALL model present[/red].")
      continue
    if msg.strip().lower() == "/model mistral":
      active_model = _select_model()
      console.print(f"[green]Restored preference →[/green] [bold]{active_model}[/bold].")
      continue

    if msg.strip().startswith("run"):
      auto = False
      text = msg.strip()
      if text.startswith("run -y:"):
        auto = True; text = text[len("run -y:"):].strip()
      elif text.startswith("run:"):
        text = text[len("run:"):].strip()

      # Try explicit form first (TOOL {JSON}); else planner
      tool, params = parse_explicit(text, known_tools)
      if tool is None:
        try:
          stop = spinner("Planning…")
          planned = mcp_plan(text)
        finally:
          stop()
        if planned.get("tool") is None:
          console.print(f"[yellow]Planner message:[/yellow] {planned.get('message','No suggestion')}")
          continue
        tool = planned["tool"]; params = planned.get("params", {})
        # If user requested run -y:, auto-execute (flip dry_run:false unless user forced true)
        if auto:
          if isinstance(params, dict) and params.get("dry_run", True) is True:
            params["dry_run"] = False
        else:
          console.print(f"[yellow]Proposed:[/yellow] tool=[bold]{tool}[/bold] params={params}")
          if not Confirm.ask("Execute this command?", default=False):
            console.print("[dim]Canceled.[/dim]"); continue

      try:
        stop = spinner("Running tool…")
        res = mcp_call(tool, params)
      except Exception as e:
        console.print(f"[red]MCP error:[/red] {e}")
      else:
        console.print("[green]MCP →[/green] ", res)
      finally:
        stop()
      continue

    # Normal chat
    try:
      stop = spinner()
      reply = _generate(active_model, msg)
    except Exception as e:
      try:
        active_model = _select_model()
        reply = _generate(active_model, msg)
      except Exception as e2:
        reply = f"[red]Ollama error:[/red] {e2}"
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
cat > "${CONFIG_DIR}/doppelganger.env" <<EOF
# Keep 127.0.0.1 — do not use localhost
OLLAMA_HOST=${OLLAMA_HOST_DEFAULT}
OLLAMA_MODEL=${OLLAMA_MODEL_DEFAULT}
OLLAMA_FALLBACK_MODEL=${OLLAMA_FALLBACK_MODEL_DEFAULT}
# Optional tiny model override (auto-detected if present)
# OLLAMA_SMALL_MODEL=phi4:latest
MCP_HOST=http://127.0.0.1:${MCP_PORT}
EOF
chmod 0644 "${CONFIG_DIR}/doppelganger.env"

cat > "${CONFIG_DIR}/doppelganger-ensure-models.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${OLLAMA_HOST:=http://127.0.0.1:11434}"
: "${OLLAMA_MODEL:=mistral:7b-instruct-q2_K}"
: "${OLLAMA_FALLBACK_MODEL:=mistral:instruct}"
: "${OLLAMA_SMALL_MODEL:=}"
: "${SMALL_CANDIDATES:=phi4:mini phi4:latest phi3:mini}"

have_ollama() { command -v ollama >/dev/null 2>&1; }

if ! have_ollama; then
  echo "[doppel] Ollama not installed; skipping model check."
  exit 0
fi

tags_json="$(curl -s "${OLLAMA_HOST}/api/tags" || true)"
have_model() {
  echo "$tags_json" | jq -e --arg m "$1" '.models | any(.name == $m)' >/dev/null 2>&1
}

pull_if_missing() {
  local m="$1"
  [ -z "$m" ] && return 0
  if echo "$tags_json" | jq -e --arg m "$m" '.models | any(.name == $m)' >/dev/null 2>&1; then
    echo "[doppel] model present: $m"
  else
    echo "[doppel] pulling: $m"
    if ! ollama pull "$m"; then
      echo "[doppel] pull failed (non-fatal): $m"
    else
      tags_json="$(curl -s "${OLLAMA_HOST}/api/tags" || true)"
    fi
  fi
}

pull_if_missing "$OLLAMA_MODEL" || true
if ! have_model "$OLLAMA_MODEL"; then
  pull_if_missing "$OLLAMA_FALLBACK_MODEL" || true
fi

if [ -z "$OLLAMA_SMALL_MODEL" ]; then
  for c in $SMALL_CANDIDATES; do
    if ollama pull "$c"; then
      export OLLAMA_SMALL_MODEL="$c"
      echo "[doppel] small model available: $OLLAMA_SMALL_MODEL"
      break
    fi
  done
else
  pull_if_missing "$OLLAMA_SMALL_MODEL" || true
fi
EOF
chmod +x "${CONFIG_DIR}/doppelganger-ensure-models.sh"

echo "[9/9] Launchers + desktop entry (under /config)…"
cat > "${CONFIG_DIR}/doppelganger-chat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -f /config/doppelganger.env ]; then
  set -a; . /config/doppelganger.env; set +a
fi

: "${OLLAMA_HOST:=http://127.0.0.1:11434}"
: "${OLLAMA_MODEL:=mistral:7b-instruct-q2_K}"
: "${OLLAMA_FALLBACK_MODEL:=mistral:instruct}"
: "${OLLAMA_SMALL_MODEL:=}"
: "${MCP_HOST:=http://127.0.0.1:7331}"

# Ensure models (best-effort)
[ -x /config/doppelganger-ensure-models.sh ] && /config/doppelganger-ensure-models.sh || true

start_mcp() {
  if curl -s "${MCP_HOST}/mcp/tools" >/dev/null 2>&1; then
    return 0
  fi
  nohup "/config/.doppelganger-venv/bin/python" "/config/underground-doppelganger/doppel_server.py" \
    >/tmp/doppel-mcp.log 2>&1 &

  for i in {1..60}; do
    sleep 0.2
    if curl -s "${MCP_HOST}/mcp/tools" >/dev/null 2>&1; then
      return 0
    fi
    if ! pgrep -f "doppel_server.py" >/dev/null 2>&1; then
      echo "[doppel] MCP failed to start; last 60 log lines:"
      tail -n 60 /tmp/doppel-mcp.log || true
      return 1
    fi
  done
  echo "[doppel] MCP did not become ready; last 60 log lines:"
  tail -n 60 /tmp/doppel-mcp.log || true
  return 1
}

start_mcp || true

export OLLAMA_HOST OLLAMA_MODEL OLLAMA_FALLBACK_MODEL OLLAMA_SMALL_MODEL MCP_HOST
exec "/config/.doppelganger-venv/bin/python" "/config/underground-doppelganger/doppel_chat.py"
EOF
chmod +x "${CONFIG_DIR}/doppelganger-chat"
chown "${AGENT_USER}:${AGENT_USER}" "${CONFIG_DIR}/doppelganger-chat"

cat > "${CONFIG_DIR}/run-doppelganger.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LAUNCH="/config/doppelganger-chat"
if command -v terminator >/dev/null 2>&1; then
  exec terminator -e "bash -lc '${LAUNCH}; echo; read -p \"Press Enter to close…\"'"
else
  exec "${LAUNCH}"
fi
EOF
chmod +x "${CONFIG_DIR}/run-doppelganger.sh"
chown "${AGENT_USER}:${AGENT_USER}" "${CONFIG_DIR}/run-doppelganger.sh"

install -d -o "${AGENT_USER}" -g "${AGENT_USER}" "${DESKTOP_DIR}"
DESK="${DESKTOP_DIR}/Underground-Doppelganger.desktop"
cat > "${DESK}" <<EOF
[Desktop Entry]
Type=Application
Name=Underground Doppelganger
Exec=/config/run-doppelganger.sh
Terminal=true
Icon=utilities-terminal
EOF
chmod +x "${DESK}"
chown "${AGENT_USER}:${AGENT_USER}" "${DESK}"

# OPTIONAL: Supervisor service for MCP
if [[ "${INSTALL_SERVICE}" == "yes" ]]; then
  echo "[service] Installing Supervisor program: doppel-mcp"
  SUP_CONF_DIR="/etc/supervisor/conf.d"
  install -d "${SUP_CONF_DIR}"

  cat > "${SUP_CONF_DIR}/doppel-mcp.conf" <<EOF
[program:doppel-mcp]
command=${VENV_DIR}/bin/python ${APP_DIR}/doppel_server.py
directory=${APP_DIR}
user=${AGENT_USER}
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/doppel-mcp.log
stopsignal=TERM
stopwaitsecs=10
EOF

  supervisorctl reread || true
  supervisorctl update || true
  supervisorctl status doppel-mcp || true
fi

echo
echo "✅ Install complete."
echo "Launch (manual chat):"
echo "  sudo -u ${AGENT_USER} -H /config/doppelganger-chat"
echo "  or: /config/run-doppelganger.sh"
echo
echo "MCP check:"
echo "  curl -s http://127.0.0.1:${MCP_PORT}/mcp/tools | jq"
echo
if [[ "${INSTALL_SERVICE}" == "yes" ]]; then
  echo "Supervisor service installed: doppel-mcp"
  echo "  supervisorctl status doppel-mcp"
  echo "  supervisorctl restart doppel-mcp"
  echo "  tail -n 100 /var/log/doppel-mcp.log"
fi
