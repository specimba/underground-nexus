#!/usr/bin/env python3
from flask import Flask, request, jsonify, send_file, Response, make_response
from pathlib import Path
import json, subprocess, re, uuid, os, shutil
from datetime import datetime, timezone

app = Flask(__name__, static_folder="static", template_folder=None)

# ------------------------------
# Config (env overrides)
# ------------------------------
APP_DIR       = Path(__file__).resolve().parent
PROFILES_DIR  = APP_DIR / "profiles"
BACKUPS_DIR   = PROFILES_DIR / "backups"
ASSETS_DIR    = APP_DIR / "static" / "assets"
HTML_SOURCE   = Path(os.getenv("HTML_SOURCE", APP_DIR / "gitbios-control-panel.html"))
HTML_FALLBACK = Path("/config/Desktop/nexus-bucket/underground-nexus/Jelly-Apps/Git-BIOS-Control-Panel/gitbios-control-panel.html")
HOST          = os.getenv("HOST", "0.0.0.0")
PORT          = int(os.getenv("PORT", "5000"))
CP_TOKEN      = os.getenv("CP_TOKEN", "").strip()  # optional token to protect write/exec APIs

PROFILES_DIR.mkdir(exist_ok=True)
BACKUPS_DIR.mkdir(parents=True, exist_ok=True)
ASSETS_DIR.mkdir(parents=True, exist_ok=True)

# Base for pulling assets referenced by the WP-exported HTML
GITHUB_BASE = ("https://raw.githubusercontent.com/Underground-Ops/underground-nexus"
               "/main/Production%20Artifacts/Wordpress/")

# Replace RPG image with Cloud Jam
CLOUD_JAM_URL = ("https://cdn.shopify.com/s/files/1/0591/0432/9913/files/"
                 "cloud-jam-new-1.png?v=1756790120")
CLOUD_JAM_FILENAME = "cloud-jam-new-1.png"

# Explicit remaps (discovery also handles these)
EXPLICIT_ASSETS = {
    "nexus-logo.png": "nexus-logo.png",
    "cloud-underground-logo.png": "cloud-underground-logo.png",
    "underground-ops-logo.png": "underground-ops-logo.png",
    "gitlab-screenshot1.png": "gitlab-screenshot1.png",
    "gitlab-screenshot2.png": "gitlab-screenshot2.png",
    "rpg-incubator-logo.png": CLOUD_JAM_FILENAME,
}

# ------------------------------
# Security & helpers
# ------------------------------
def _strict_headers(resp):
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["X-Frame-Options"] = "SAMEORIGIN"
    resp.headers["Referrer-Policy"] = "no-referrer-when-downgrade"
    if resp.mimetype and resp.mimetype.startswith("application/json"):
        resp.headers["Cache-Control"] = "no-store"
    return resp

@app.after_request
def _after(resp):
    return _strict_headers(resp)

def _require_token_if_set():
    if not CP_TOKEN:
        return None
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return jsonify({"error": "missing or invalid token"}), 401
    if auth.split(" ", 1)[1].strip() != CP_TOKEN:
        return jsonify({"error": "unauthorized"}), 403
    return None

def _which(cmd: str) -> bool:
    return shutil.which(cmd) is not None

def _can_launch_terminator() -> bool:
    return bool(os.environ.get("DISPLAY")) and _which("terminator")

# ------------------------------
# HTML asset handling
# ------------------------------
def _discover_assets_from_html(html: str):
    found = set(re.findall(r"underground-ops\.me_files/([A-Za-z0-9._-]+)", html))
    mapping = {}
    for fname in found:
        local_name = EXPLICIT_ASSETS.get(fname, fname)
        if local_name == CLOUD_JAM_FILENAME:
            mapping[local_name] = CLOUD_JAM_URL
        else:
            mapping[local_name] = GITHUB_BASE + local_name
    mapping.setdefault(CLOUD_JAM_FILENAME, CLOUD_JAM_URL)
    return mapping

def _ensure_assets(remote_map: dict):
    try:
        import requests
    except Exception:
        return
    for local_name, url in remote_map.items():
        target = ASSETS_DIR / local_name
        if target.exists():
            continue
        try:
            r = requests.get(url, timeout=30)
            r.raise_for_status()
            target.write_bytes(r.content)
        except Exception as e:
            print(f"[assets] failed to fetch {local_name} from {url}: {e}")

def _load_source_html() -> str:
    src = HTML_SOURCE if HTML_SOURCE.exists() else HTML_FALLBACK
    if not src.exists():
        return "<html><head><title>Nexus Control Panel</title></head><body><h1>Nexus Control Panel</h1></body></html>"
    html = src.read_text(encoding="utf-8", errors="ignore")

    # Replace RPG reference with Cloud Jam filename
    html = html.replace("rpg-incubator-logo.png", CLOUD_JAM_FILENAME)

    # Discover/prefetch assets
    remote_map = _discover_assets_from_html(html)
    _ensure_assets(remote_map)

    # Rewrite underground-ops.me_files/* → /static/assets/<file>
    html = re.sub(
        r"underground-ops\.me_files/([A-Za-z0-9._-]+)",
        lambda m: f"/static/assets/{EXPLICIT_ASSETS.get(m.group(1), m.group(1))}",
        html,
    )
    # Rewrite any known remote URLs to cached local
    for local_name, _url in remote_map.items():
        html = html.replace(_url, f"/static/assets/{local_name}")

    # Inject the dock
    dock = '''
<link rel="stylesheet" href="/static/app.css">
<div id="cp-dock" class="cp-dock">
  <div class="cp-header">
    <div class="cp-title">Control panel</div>
    <div class="cp-actions">
      <button id="cp-refresh" class="cp-btn" title="Reload profiles">⟳</button>
      <button id="cp-import" class="cp-btn">Import</button>
      <button id="cp-export" class="cp-btn">Export</button>
      <button id="cp-new" class="cp-btn">New</button>
      <button id="cp-toggle" class="cp-btn">Hide</button>
    </div>
  </div>
  <div class="cp-row">
    <label for="cp-profile">Profile:</label>
    <select id="cp-profile"></select>
  </div>
  <div id="cp-buttons" class="cp-buttons"></div>
  <div class="cp-log">
    <div class="cp-log-header">Command output</div>
    <pre id="cp-log-pre" class="cp-log-pre"></pre>
  </div>
</div>
<button id="cp-fab" class="cp-fab" title="Show control panel">☰</button>
<script src="/static/app.js"></script>
'''
    idx = html.lower().rfind("</body>")
    if idx == -1:
        return html + dock
    return html[:idx] + dock + html[idx:]

# ------------------------------
# Profiles
# ------------------------------
def _profiles_list():
    return sorted([p.stem for p in PROFILES_DIR.glob("*.json")])

def _validate_buttons(data):
    if not isinstance(data, list):
        raise ValueError("Profile must be a list of button objects.")
    cleaned = []
    for i, item in enumerate(data):
        if not isinstance(item, dict):
            raise ValueError(f"Item {i} is not an object.")
        label = item.get("label")
        command = item.get("command")
        interactive = item.get("interactive", False)
        if not isinstance(label, str) or not label.strip():
            raise ValueError(f"Item {i}: 'label' must be a non-empty string.")
        if not isinstance(command, str) or not command.strip():
            raise ValueError(f"Item {i}: 'command' must be a non-empty string.")
        if not isinstance(interactive, bool):
            raise ValueError(f"Item {i}: 'interactive' must be true/false.")
        cleaned.append({"label": label.strip(), "command": command.strip(), "interactive": interactive})
    return cleaned

def _profile_path(name: str) -> Path:
    return PROFILES_DIR / f"{name}.json"

def _seed_default_profile():
    if _profiles_list():
        return
    default_buttons = [
        {"label": "Update Index - Launch Doppelganger Chat",
         "command": "if [ -d /opt/mcp ]; then cd /opt/mcp && python3 chat_with_index.py; else bash /nexus-bucket/digital-twin-production-installer-v2.sh && cd /opt/mcp && python3 chat_with_index.py; fi",
         "interactive": True},
        {"label": "WARNING! Deploy Langgraph RAG API",
         "command": "bash /nexus-bucket/underground-doppelganger/build-langgraph-backend.sh",
         "interactive": False},
        {"label": "WARNING! Launch Doppelganger Shell - Needs RAG API",
         "command": "cd /opt/mcp && python3 doppelganger-shell.py &",
         "interactive": False},
        {"label": "Launch Package Manager - Cerberus Manager",
         "command": "docker exec -it Cerberus-Manager bash",
         "interactive": True},
        {"label": "Deploy OPS for CI/CD runners",
         "command": "docker start Cerberus-Manager || true && docker exec -i Cerberus-Manager bash OPS",
         "interactive": True},
        {"label": "Rebuild the OPS CI/CD pipeline",
         "command": "docker start Cerberus-Manager || true && docker exec -i Cerberus-Manager bash OPS-rebuild",
         "interactive": True},
        {"label": "Deploy Nexus Creator Vault (DEV)",
         "command": "docker exec -i Cerberus-Manager DEV",
         "interactive": False},
        {"label": "Backup All Saved Buttons", "command": "__INTERNAL_BACKUP__", "interactive": False},
        {"label": "Restore Saved Buttons", "command": "__INTERNAL_RESTORE__", "interactive": False},
    ]
    _profile_path("Default").write_text(json.dumps(default_buttons, indent=2), encoding="utf-8")

# ------------------------------
# Routes
# ------------------------------
@app.get("/healthz")
def healthz():
    return jsonify({"ok": True})

@app.get("/")
def home():
    _seed_default_profile()
    html = _load_source_html()
    return Response(html, mimetype="text/html")

@app.get("/api/profiles")
def api_profiles():
    return jsonify(_profiles_list())

@app.get("/api/profiles/<name>")
def api_profile_get(name):
    p = _profile_path(name)
    if not p.exists():
        return jsonify({"error":"not found"}), 404
    data = json.loads(p.read_text(encoding="utf-8"))
    return jsonify(data)

@app.post("/api/profiles")
def api_profile_create():
    if (err := _require_token_if_set()) is not None:
        return err
    payload = request.get_json(silent=True) or {}
    name = payload.get("name")
    if not name:
        return jsonify({"error":"missing name"}), 400
    buttons = _validate_buttons(payload.get("buttons", []))
    _profile_path(name).write_text(json.dumps(buttons, indent=2), encoding="utf-8")
    return jsonify({"ok": True})

@app.put("/api/profiles/<name>")
def api_profile_put(name):
    if (err := _require_token_if_set()) is not None:
        return err
    p = _profile_path(name)
    if not p.exists():
        return jsonify({"error":"not found"}), 404
    data = json.loads(p.read_text(encoding="utf-8"))
    payload = request.get_json(silent=True) or {}
    if "index" in payload and "value" in payload:
        idx = int(payload["index"])
        val = _validate_buttons([payload["value"]])[0]
        if not (0 <= idx < len(data)):
            return jsonify({"error":"index out of range"}), 400
        data[idx] = val
    elif "append" in payload:
        val = _validate_buttons([payload["append"]])[0]
        data.append(val)
    else:
        return jsonify({"error":"unsupported payload"}), 400
    p.write_text(json.dumps(data, indent=2), encoding="utf-8")
    return jsonify(data)

@app.delete("/api/profiles/<name>")
def api_profile_delete(name):
    if (err := _require_token_if_set()) is not None:
        return err
    p = _profile_path(name)
    if not p.exists():
        return jsonify({"error":"not found"}), 404
    p.unlink()
    return jsonify({"ok": True})

@app.post("/api/profiles/import")
def api_profiles_import():
    if (err := _require_token_if_set()) is not None:
        return err
    f = request.files.get("file")
    if not f:
        return jsonify({"error":"no file"}), 400
    try:
        data = json.loads(f.read().decode("utf-8"))
        buttons = _validate_buttons(data)
    except Exception as e:
        return jsonify({"error": f"invalid profile: {e}"}), 400
    name = Path(f.filename).stem
    _profile_path(name).write_text(json.dumps(buttons, indent=2), encoding="utf-8")
    return jsonify({"ok": True, "profile": name})

@app.get("/api/profiles/export/<name>")
def api_profiles_export(name):
    p = _profile_path(name)
    if not p.exists():
        return jsonify({"error":"not found"}), 404
    resp = make_response(send_file(p, as_attachment=True, download_name=f"{name}.json", mimetype="application/json"))
    resp.headers["Cache-Control"] = "private, max-age=120"
    return resp

def _backup_all_profiles() -> Path:
    snapshot = {}
    for name in _profiles_list():
        p = _profile_path(name)
        try:
            snapshot[name] = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            snapshot[name] = []
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    out = (BACKUPS_DIR / f"profiles-backup-{stamp}.json")
    out.write_text(json.dumps(snapshot, indent=2), encoding="utf-8")
    return out

@app.get("/api/backup/latest")
def api_backup_latest():
    files = sorted(BACKUPS_DIR.glob("profiles-backup-*.json"))
    if not files:
        return jsonify({"error":"no backups"}), 404
    return send_file(files[-1], as_attachment=True, download_name=files[-1].name, mimetype="application/json")

# ------------------------------
# Command execution (Terminator-first)
# ------------------------------
def _launch_in_terminator(cmd: str, title: str):
    """
    Launch a new Terminator window that runs cmd within bash -lc, then waits for a keypress.
    """
    # Safely quote for bash -lc via JSON (preserves special chars)
    cmd_json = json.dumps(cmd)
    # Build one shell string to keep quoting rules simple with -x
    shell_line = (
        f"terminator -T {json.dumps(title)} -x bash -lc {cmd_json} ; "
        "read -n1 -r -p 'Press any key to close...'"
    )
    # Launch detached
    subprocess.Popen(shell_line, shell=True, executable="/bin/bash")

@app.post("/api/run")
def api_run():
    if (err := _require_token_if_set()) is not None:
        return err
    payload = request.get_json(silent=True) or {}
    cmd = (payload.get("command") or "").strip()
    interactive = bool(payload.get("interactive", False))

    if not cmd:
        return jsonify({"error":"empty command"}), 400

    # Virtual commands
    if cmd == "__INTERNAL_BACKUP__":
        path = _backup_all_profiles()
        return jsonify({"output": f"Backed up all profiles to {path.name}", "exit_code": 0,
                        "download": "/api/backup/latest"})
    if cmd == "__INTERNAL_RESTORE__":
        return jsonify({"output": "Use Import to restore from a backup JSON.", "exit_code": 0})

    # If NOT interactive, avoid forcing a TTY in docker exec
    if not interactive and "docker exec" in cmd:
        cmd = cmd.replace("docker exec -it", "docker exec -i")

    # Interactive path: prefer Terminator window; fallback to tmux; then to non-interactive
    if interactive:
        if _can_launch_terminator():
            title = payload.get("label") or "Command"
            try:
                _launch_in_terminator(cmd, title)
                return jsonify({"launched": "terminator", "title": title})
            except Exception as e:
                # Fall through to next fallback
                print("[terminator] launch failed:", e)

        if _which("tmux"):
            session = "cp_" + uuid.uuid4().hex[:10]
            cmd_json = json.dumps(cmd)
            tmux_cmd = (
                f"tmux new -d -s {session} 'bash -lc {cmd_json[1:-1]}; "
                f"echo; echo \"[session {session} finished]\"; read -n1 -r -p \"Press any key to close...\"'"
            )
            try:
                subprocess.check_call(tmux_cmd, shell=True, executable="/bin/bash")
                return jsonify({"session": session, "attach": f"tmux attach -t {session}"})
            except Exception as e:
                # Fall through to non-interactive
                print("[tmux] launch failed:", e)

        # Final fallback
        try:
            proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, executable="/bin/bash")
            out, _ = proc.communicate(timeout=3600)
            out = ("[no GUI terminal available – ran non-interactively]\n" + (out or ""))
            return jsonify({"output": out, "exit_code": proc.returncode})
        except subprocess.TimeoutExpired:
            proc.kill()
            return jsonify({"output": "[timeout]", "exit_code": 124})

    # Non-interactive execution
    try:
        proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, executable="/bin/bash")
        out, _ = proc.communicate(timeout=3600)
        return jsonify({"output": out, "exit_code": proc.returncode})
    except subprocess.TimeoutExpired:
        proc.kill()
        return jsonify({"output": "[timeout]", "exit_code": 124})

if __name__ == "__main__":
    app.run(host=HOST, port=PORT, debug=False)
