#!/usr/bin/env python3
"""
Git-BIOS Control Panel — server.py
Cloud Underground · Underground Nexus

ZERO external dependencies. Uses only Python 3.7+ stdlib.
No Flask, no pip, no venv required — starts in < 100ms.

Retained functionality (100% API-compatible with Flask version):
  GET  /                         → rendered control panel HTML
  GET  /healthz                  → {"ok": true}
  GET  /static/<path>            → static files (app.js, app.css, assets/)
  GET  /api/profiles             → list of profile names
  GET  /api/profiles/<n>         → get profile buttons
  POST /api/profiles             → create profile
  PUT  /api/profiles/<n>         → update button in profile
  DELETE /api/profiles/<n>       → delete profile
  POST /api/profiles/import      → upload a profile JSON file
  GET  /api/profiles/export/<n>  → download profile JSON
  GET  /api/backup/latest        → download latest backup
  POST /api/run                  → execute button command
"""

import http.server
import json
import os
import re
import shutil
import subprocess
import threading
import urllib.parse
import uuid
from datetime import datetime, timezone
from http import HTTPStatus
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# Config (env overrides — identical to Flask version)
# ─────────────────────────────────────────────────────────────────────────────
APP_DIR       = Path(__file__).resolve().parent
PROFILES_DIR  = APP_DIR / "profiles"
BACKUPS_DIR   = PROFILES_DIR / "backups"
ASSETS_DIR    = APP_DIR / "static" / "assets"
HTML_SOURCE   = Path(os.getenv("HTML_SOURCE",
                  str(APP_DIR / "gitbios-control-panel.html")))
HTML_FALLBACK = Path("/config/Desktop/nexus-bucket/underground-nexus/"
                     "Jelly-Apps/Git-BIOS-Control-Panel/gitbios-control-panel.html")
HOST          = os.getenv("HOST", "0.0.0.0")
PORT          = int(os.getenv("PORT", "5000"))
CP_TOKEN      = os.getenv("CP_TOKEN", "").strip()

PROFILES_DIR.mkdir(exist_ok=True)
BACKUPS_DIR.mkdir(parents=True, exist_ok=True)
ASSETS_DIR.mkdir(parents=True, exist_ok=True)

GITHUB_BASE   = ("https://raw.githubusercontent.com/Underground-Ops/"
                 "underground-nexus/main/Production%20Artifacts/Wordpress/")
CLOUD_JAM_URL = ("https://cdn.shopify.com/s/files/1/0591/0432/9913/files/"
                 "cloud-jam-new-1.png?v=1756790120")
CLOUD_JAM_FILENAME = "cloud-jam-new-1.png"
EXPLICIT_ASSETS = {
    "nexus-logo.png":              "nexus-logo.png",
    "cloud-underground-logo.png":  "cloud-underground-logo.png",
    "underground-ops-logo.png":    "underground-ops-logo.png",
    "gitlab-screenshot1.png":      "gitlab-screenshot1.png",
    "gitlab-screenshot2.png":      "gitlab-screenshot2.png",
    "rpg-incubator-logo.png":      CLOUD_JAM_FILENAME,
}

# Asset fetch state — fetched once at startup in a background thread
# so page loads are never blocked waiting for remote images
_ASSETS_READY  = threading.Event()
_ASSETS_LOCK   = threading.Lock()

# Cached rendered HTML — rebuilt if source file changes
_html_cache: dict = {}   # {"mtime": float, "html": str}
_html_lock  = threading.Lock()


# ─────────────────────────────────────────────────────────────────────────────
# Asset helpers (background, air-gap safe)
# ─────────────────────────────────────────────────────────────────────────────
def _discover_assets_from_html(html: str) -> dict:
    found = set(re.findall(r"underground-ops\.me_files/([A-Za-z0-9._-]+)", html))
    mapping: dict = {}
    for fname in found:
        local_name = EXPLICIT_ASSETS.get(fname, fname)
        if local_name == CLOUD_JAM_FILENAME:
            mapping[local_name] = CLOUD_JAM_URL
        else:
            mapping[local_name] = GITHUB_BASE + local_name
    mapping.setdefault(CLOUD_JAM_FILENAME, CLOUD_JAM_URL)
    return mapping


def _fetch_assets_background(remote_map: dict) -> None:
    """
    Fetch missing assets in a background thread.
    Uses urllib (stdlib) — no requests package needed.
    Times out quickly per asset so air-gap mode doesn't hang.
    """
    import urllib.request
    import urllib.error
    for local_name, url in remote_map.items():
        target = ASSETS_DIR / local_name
        if target.exists():
            continue
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "gitbios/1.0"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                target.write_bytes(resp.read())
        except Exception as e:
            # Air-gap or network error — skip silently, app still works
            pass
    _ASSETS_READY.set()


def _start_asset_fetch(html: str) -> None:
    """Kick off background asset fetch once, never block the request thread."""
    if _ASSETS_READY.is_set():
        return
    remote_map = _discover_assets_from_html(html)
    t = threading.Thread(target=_fetch_assets_background,
                         args=(remote_map,), daemon=True)
    t.start()


# ─────────────────────────────────────────────────────────────────────────────
# HTML rendering
# ─────────────────────────────────────────────────────────────────────────────
_DOCK = """\
<link rel="stylesheet" href="/static/app.css">
<div id="cp-dock" class="cp-dock">
  <div class="cp-header">
    <div class="cp-title">Control panel</div>
    <div class="cp-actions">
      <button id="cp-refresh" class="cp-btn" title="Reload profiles">&#x27F3;</button>
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
<button id="cp-fab" class="cp-fab" title="Show control panel">&#x2630;</button>
<script src="/static/app.js"></script>
"""


def _load_html() -> str:
    """
    Load and render the control-panel HTML.
    Caches by mtime so repeated page loads are instant.
    Asset rewrite runs on every load from cache (regex replace is fast).
    """
    src = HTML_SOURCE if HTML_SOURCE.exists() else HTML_FALLBACK
    try:
        mtime = src.stat().st_mtime
    except OSError:
        mtime = 0.0

    with _html_lock:
        cached = _html_cache.get("mtime")
        if cached == mtime and "html" in _html_cache:
            return _html_cache["html"]

    if mtime == 0.0:
        raw = ("<html><head><title>Nexus Control Panel</title></head>"
               "<body><h1>Nexus Control Panel</h1></body></html>")
    else:
        raw = src.read_text(encoding="utf-8", errors="ignore")

    # Kick off background asset fetch (non-blocking)
    _start_asset_fetch(raw)

    # Rewrite references
    raw = raw.replace("rpg-incubator-logo.png", CLOUD_JAM_FILENAME)
    raw = re.sub(
        r"underground-ops\.me_files/([A-Za-z0-9._-]+)",
        lambda m: f"/static/assets/{EXPLICIT_ASSETS.get(m.group(1), m.group(1))}",
        raw,
    )

    # Inject dock before </body>
    idx = raw.lower().rfind("</body>")
    html = (raw[:idx] + _DOCK + raw[idx:]) if idx != -1 else (raw + _DOCK)

    with _html_lock:
        _html_cache["mtime"] = mtime
        _html_cache["html"]  = html

    return html


# ─────────────────────────────────────────────────────────────────────────────
# Profile helpers
# ─────────────────────────────────────────────────────────────────────────────
def _profiles_list() -> list:
    return sorted(p.stem for p in PROFILES_DIR.glob("*.json"))


def _profile_path(name: str) -> Path:
    return PROFILES_DIR / f"{name}.json"


def _validate_buttons(data) -> list:
    if not isinstance(data, list):
        raise ValueError("Profile must be a list of button objects.")
    cleaned = []
    for i, item in enumerate(data):
        if not isinstance(item, dict):
            raise ValueError(f"Item {i} is not an object.")
        label   = item.get("label")
        command = item.get("command")
        interactive  = item.get("interactive", False)
        privileged   = item.get("privileged", False)   # NEW: optional field
        if not isinstance(label, str) or not label.strip():
            raise ValueError(f"Item {i}: 'label' must be a non-empty string.")
        if not isinstance(command, str) or not command.strip():
            raise ValueError(f"Item {i}: 'command' must be a non-empty string.")
        if not isinstance(interactive, bool):
            raise ValueError(f"Item {i}: 'interactive' must be true/false.")
        if not isinstance(privileged, bool):
            raise ValueError(f"Item {i}: 'privileged' must be true/false.")
        cleaned.append({
            "label":       label.strip(),
            "command":     command.strip(),
            "interactive": interactive,
            "privileged":  privileged,
        })
    return cleaned


def _seed_default_profile() -> None:
    if _profiles_list():
        return
    default_buttons = [
        {"label": "Update Index - Launch Doppelganger Chat",
         "command": ("if [ -d /opt/mcp ]; then cd /opt/mcp && python3 chat_with_index.py; "
                     "else bash /nexus-bucket/digital-twin-production-installer-v2.sh "
                     "&& cd /opt/mcp && python3 chat_with_index.py; fi"),
         "interactive": True, "privileged": False},
        {"label": "WARNING! Deploy Langgraph RAG API",
         "command": "bash /nexus-bucket/underground-doppelganger/build-langgraph-backend.sh",
         "interactive": False, "privileged": False},
        {"label": "WARNING! Launch Doppelganger Shell - Needs RAG API",
         "command": "cd /opt/mcp && python3 doppelganger-shell.py &",
         "interactive": False, "privileged": False},
        {"label": "Launch Package Manager - Cerberus Manager",
         "command": "docker exec -it Cerberus-Manager bash",
         "interactive": True, "privileged": False},
        {"label": "Deploy OPS for CI/CD runners",
         "command": "docker start Cerberus-Manager || true && docker exec -i Cerberus-Manager bash OPS",
         "interactive": True, "privileged": False},
        {"label": "Rebuild the OPS CI/CD pipeline",
         "command": "docker start Cerberus-Manager || true && docker exec -i Cerberus-Manager bash OPS-rebuild",
         "interactive": True, "privileged": False},
        {"label": "Deploy Nexus Creator Vault (DEV)",
         "command": "docker exec -i Cerberus-Manager DEV",
         "interactive": False, "privileged": False},
        {"label": "Backup All Saved Buttons",
         "command": "__INTERNAL_BACKUP__",
         "interactive": False, "privileged": False},
        {"label": "Restore Saved Buttons",
         "command": "__INTERNAL_RESTORE__",
         "interactive": False, "privileged": False},
    ]
    _profile_path("Default").write_text(
        json.dumps(default_buttons, indent=2), encoding="utf-8")


def _backup_all_profiles() -> Path:
    snapshot: dict = {}
    for name in _profiles_list():
        p = _profile_path(name)
        try:
            snapshot[name] = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            snapshot[name] = []
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    out = BACKUPS_DIR / f"profiles-backup-{stamp}.json"
    out.write_text(json.dumps(snapshot, indent=2), encoding="utf-8")
    return out


# ─────────────────────────────────────────────────────────────────────────────
# Command execution helpers (identical logic to Flask version)
# ─────────────────────────────────────────────────────────────────────────────
def _which(cmd: str) -> bool:
    return bool(shutil.which(cmd))


def _can_launch_terminator() -> bool:
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")) \
           and _which("terminator")


def _launch_in_terminator(cmd: str, title: str) -> None:
    cmd_json = json.dumps(cmd)
    shell_line = (
        f"terminator -T {json.dumps(title)} -x bash -lc {cmd_json} ; "
        "read -n1 -r -p 'Press any key to close...'"
    )
    subprocess.Popen(shell_line, shell=True, executable="/bin/bash")


def _run_command(payload: dict) -> dict:
    cmd         = (payload.get("command") or "").strip()
    interactive = bool(payload.get("interactive", False))
    privileged  = bool(payload.get("privileged", False))
    label       = payload.get("label") or "Command"

    if not cmd:
        return {"error": "empty command"}

    # Virtual commands
    if cmd == "__INTERNAL_BACKUP__":
        path = _backup_all_profiles()
        return {"output": f"Backed up all profiles to {path.name}",
                "exit_code": 0, "download": "/api/backup/latest"}
    if cmd == "__INTERNAL_RESTORE__":
        return {"output": "Use Import to restore from a backup JSON.",
                "exit_code": 0}

    # Privilege escalation for eBPF / kernel / robotics buttons
    if privileged and not cmd.startswith("sudo "):
        cmd = "sudo -n " + cmd

    # Strip -t from non-interactive docker exec
    if not interactive and "docker exec" in cmd:
        cmd = cmd.replace("docker exec -it", "docker exec -i")

    # Interactive path
    if interactive:
        if _can_launch_terminator():
            try:
                _launch_in_terminator(cmd, label)
                return {"launched": "terminator", "title": label}
            except Exception as e:
                pass  # fall through

        if _which("tmux"):
            session = "cp_" + uuid.uuid4().hex[:10]
            cmd_json = json.dumps(cmd)
            tmux_cmd = (
                f"tmux new -d -s {session} "
                f"'bash -lc {cmd_json[1:-1]}; echo; "
                f"echo \"[session {session} finished]\"; "
                f"read -n1 -r -p \"Press any key to close...\"'"
            )
            try:
                subprocess.check_call(tmux_cmd, shell=True, executable="/bin/bash")
                return {"session": session, "attach": f"tmux attach -t {session}"}
            except Exception:
                pass  # fall through

        try:
            proc = subprocess.Popen(
                cmd, shell=True, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, executable="/bin/bash")
            out, _ = proc.communicate(timeout=3600)
            return {"output": "[no GUI terminal available – ran non-interactively]\n" + (out or ""),
                    "exit_code": proc.returncode}
        except subprocess.TimeoutExpired:
            proc.kill()
            return {"output": "[timeout]", "exit_code": 124}

    # Non-interactive
    try:
        proc = subprocess.Popen(
            cmd, shell=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, executable="/bin/bash")
        out, _ = proc.communicate(timeout=3600)
        return {"output": out, "exit_code": proc.returncode}
    except subprocess.TimeoutExpired:
        proc.kill()
        return {"output": "[timeout]", "exit_code": 124}


# ─────────────────────────────────────────────────────────────────────────────
# HTTP handler — stdlib BaseHTTPRequestHandler
# ─────────────────────────────────────────────────────────────────────────────
MIME_MAP = {
    ".html": "text/html; charset=utf-8",
    ".js":   "application/javascript; charset=utf-8",
    ".css":  "text/css; charset=utf-8",
    ".json": "application/json",
    ".png":  "image/png",
    ".jpg":  "image/jpeg",
    ".jpeg": "image/jpeg",
    ".svg":  "image/svg+xml",
    ".ico":  "image/x-icon",
    ".txt":  "text/plain; charset=utf-8",
}

SECURE_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options":        "SAMEORIGIN",
    "Referrer-Policy":        "no-referrer-when-downgrade",
}


class ControlPanelHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        # Quiet logging — suppress static asset noise
        if "/static/" not in (args[0] if args else ""):
            print(f"[gitbios] {self.address_string()} {fmt % args}")

    # ── helpers ────────────────────────────────────────────────────────────

    def _send(self, status: int, body: bytes, content_type: str,
              extra_headers: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for k, v in SECURE_HEADERS.items():
            self.send_header(k, v)
        if content_type.startswith("application/json"):
            self.send_header("Cache-Control", "no-store")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status: int, obj) -> None:
        body = json.dumps(obj).encode()
        self._send(status, body, "application/json")

    def _check_token(self) -> bool:
        """Returns True if auth passes (or no token required)."""
        if not CP_TOKEN:
            return True
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            self._json(401, {"error": "missing or invalid token"})
            return False
        if auth.split(" ", 1)[1].strip() != CP_TOKEN:
            self._json(403, {"error": "unauthorized"})
            return False
        return True

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length else b""

    def _parse_json(self) -> dict | list | None:
        try:
            return json.loads(self._read_body().decode("utf-8"))
        except Exception:
            return None

    # ── routing ────────────────────────────────────────────────────────────

    def do_GET(self)  -> None: self._route("GET")
    def do_POST(self) -> None: self._route("POST")
    def do_PUT(self)  -> None: self._route("PUT")
    def do_DELETE(self) -> None: self._route("DELETE")

    def _route(self, method: str) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path   = parsed.path.rstrip("/") or "/"
        parts  = [p for p in path.split("/") if p]

        # ── GET /healthz ────────────────────────────────────────────────
        if method == "GET" and path == "/healthz":
            self._json(200, {"ok": True})

        # ── GET / ───────────────────────────────────────────────────────
        elif method == "GET" and path == "/":
            _seed_default_profile()
            html = _load_html()
            self._send(200, html.encode("utf-8"), "text/html; charset=utf-8")

        # ── GET /static/* ───────────────────────────────────────────────
        elif method == "GET" and parts and parts[0] == "static":
            self._serve_static(path)

        # ── GET /api/profiles ───────────────────────────────────────────
        elif method == "GET" and path == "/api/profiles":
            self._json(200, _profiles_list())

        # ── POST /api/profiles/import ───────────────────────────────────
        elif method == "POST" and path == "/api/profiles/import":
            if not self._check_token(): return
            self._handle_import()

        # ── POST /api/profiles ──────────────────────────────────────────
        elif method == "POST" and path == "/api/profiles":
            if not self._check_token(): return
            payload = self._parse_json() or {}
            name = payload.get("name")
            if not name:
                self._json(400, {"error": "missing name"}); return
            try:
                buttons = _validate_buttons(payload.get("buttons", []))
            except ValueError as e:
                self._json(400, {"error": str(e)}); return
            _profile_path(name).write_text(
                json.dumps(buttons, indent=2), encoding="utf-8")
            self._json(200, {"ok": True})

        # ── /api/profiles/<name> ────────────────────────────────────────
        elif parts[:1] == ["api"] and parts[1:2] == ["profiles"] and len(parts) >= 3:
            name = parts[2]

            if method == "GET" and len(parts) == 3:
                p = _profile_path(name)
                if not p.exists():
                    self._json(404, {"error": "not found"}); return
                data = json.loads(p.read_text(encoding="utf-8"))
                self._json(200, data)

            elif method == "PUT" and len(parts) == 3:
                if not self._check_token(): return
                p = _profile_path(name)
                if not p.exists():
                    self._json(404, {"error": "not found"}); return
                data    = json.loads(p.read_text(encoding="utf-8"))
                payload = self._parse_json() or {}
                try:
                    if "index" in payload and "value" in payload:
                        idx = int(payload["index"])
                        val = _validate_buttons([payload["value"]])[0]
                        if not (0 <= idx < len(data)):
                            self._json(400, {"error": "index out of range"}); return
                        data[idx] = val
                    elif "append" in payload:
                        val = _validate_buttons([payload["append"]])[0]
                        data.append(val)
                    else:
                        self._json(400, {"error": "unsupported payload"}); return
                except ValueError as e:
                    self._json(400, {"error": str(e)}); return
                p.write_text(json.dumps(data, indent=2), encoding="utf-8")
                self._json(200, data)

            elif method == "DELETE" and len(parts) == 3:
                if not self._check_token(): return
                p = _profile_path(name)
                if not p.exists():
                    self._json(404, {"error": "not found"}); return
                p.unlink()
                self._json(200, {"ok": True})

            # GET /api/profiles/export/<name>
            elif method == "GET" and len(parts) == 4 and parts[2] == "export":
                export_name = parts[3]
                p = _profile_path(export_name)
                if not p.exists():
                    self._json(404, {"error": "not found"}); return
                body = p.read_bytes()
                self._send(200, body, "application/json", {
                    "Content-Disposition": f'attachment; filename="{export_name}.json"',
                    "Cache-Control": "private, max-age=120",
                })

            else:
                self._json(404, {"error": "not found"})

        # ── GET /api/backup/latest ──────────────────────────────────────
        elif method == "GET" and path == "/api/backup/latest":
            files = sorted(BACKUPS_DIR.glob("profiles-backup-*.json"))
            if not files:
                self._json(404, {"error": "no backups"}); return
            latest = files[-1]
            body   = latest.read_bytes()
            self._send(200, body, "application/json", {
                "Content-Disposition": f'attachment; filename="{latest.name}"',
            })

        # ── POST /api/run ───────────────────────────────────────────────
        elif method == "POST" and path == "/api/run":
            if not self._check_token(): return
            payload = self._parse_json() or {}
            result  = _run_command(payload)
            if "error" in result and "exit_code" not in result:
                self._json(400, result)
            else:
                self._json(200, result)

        else:
            self._json(404, {"error": "not found"})

    # ── static file serving ────────────────────────────────────────────────

    def _serve_static(self, path: str) -> None:
        # Prevent path traversal
        rel = path.lstrip("/")  # e.g. "static/app.js"
        if ".." in rel:
            self._json(403, {"error": "forbidden"}); return
        disk_path = APP_DIR / rel
        if not disk_path.exists() or not disk_path.is_file():
            self._json(404, {"error": "not found"}); return
        suffix = disk_path.suffix.lower()
        mime   = MIME_MAP.get(suffix, "application/octet-stream")
        body   = disk_path.read_bytes()
        # Cache static assets aggressively (1 day) except JS/CSS in dev
        cache  = "public, max-age=86400" if suffix in {".png",".jpg",".svg",".ico"} \
                 else "public, max-age=300"
        self._send(200, body, mime, {"Cache-Control": cache})

    # ── multipart import ───────────────────────────────────────────────────

    def _handle_import(self) -> None:
        content_type = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in content_type:
            self._json(400, {"error": "expected multipart/form-data"}); return
        # Extract boundary
        boundary = None
        for part in content_type.split(";"):
            p = part.strip()
            if p.startswith("boundary="):
                boundary = p[9:].strip('"')
                break
        if not boundary:
            self._json(400, {"error": "missing boundary"}); return
        body = self._read_body()
        # Find JSON content between boundaries
        sep = ("--" + boundary).encode()
        sections = body.split(sep)
        for section in sections:
            if b"filename=" not in section:
                continue
            # Extract filename
            lines = section.split(b"\r\n")
            fname = ""
            for line in lines:
                if b"filename=" in line:
                    m = re.search(rb'filename="([^"]+)"', line)
                    if m:
                        fname = m.group(1).decode(errors="ignore")
            # Find body after blank line
            blank = section.find(b"\r\n\r\n")
            if blank == -1:
                continue
            raw_json = section[blank + 4:].rstrip(b"\r\n-")
            try:
                data    = json.loads(raw_json.decode("utf-8"))
                buttons = _validate_buttons(data)
            except Exception as e:
                self._json(400, {"error": f"invalid profile: {e}"}); return
            name = Path(fname).stem if fname else "imported"
            _profile_path(name).write_text(
                json.dumps(buttons, indent=2), encoding="utf-8")
            self._json(200, {"ok": True, "profile": name})
            return
        self._json(400, {"error": "no file found in upload"})


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    _seed_default_profile()
    server = http.server.ThreadingHTTPServer((HOST, PORT), ControlPanelHandler)
    print(f"[gitbios] Git-BIOS Control Panel running on http://{HOST}:{PORT}")
    print(f"[gitbios] App dir:  {APP_DIR}")
    print(f"[gitbios] Profiles: {PROFILES_DIR}")
    server.serve_forever()
