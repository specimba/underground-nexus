# GitBIOS Control Panel â Nexus Edition

A hybrid (online/offline) control panel that renders your `gitbios-control-panel.html` as a local web app and executes button profiles.
Works inside **Underground Nexus / Nexus Creator Vault** without extra desktop dependencies.

* Backend: Python + Flask (created on the fly)
* Frontend: your static HTML (images cached for offline use)
* Profiles: JSON files under `profiles/` (import/export supported)
* Links open in the **system browser** (external)

---

## Folder layout (expected)

```
/nexus-bucket/GitBIOS-Control-Panel/
  server.py
  start_control_panel.sh
  gitbios-control-panel.html
  static/
    assets/â¦             # icons, logos, cached images
    cache/â¦              # offline cache (auto-created)
  profiles/
    Default.json         # example or your own
```

> If your files arenât in this path yet, move them there before starting.

---

## Quick Start (most user-friendly)

> These steps assume your Desktop is `/config/Desktop`. If your environment uses a different Desktop path, adjust step 3 accordingly.

### 1) Ensure the app directory exists

```bash
sudo install -d -m 755 -o abc -g abc /nexus-bucket/GitBIOS-Control-Panel
sudo chown -R abc:abc /nexus-bucket/GitBIOS-Control-Panel
```

### 2) Make the launcher executable (idempotent)

```bash
chmod +x /nexus-bucket/GitBIOS-Control-Panel/start_control_panel.sh
```

### 3) Create the Desktop launcher

```bash
DESK="/config/Desktop"

sudo install -d -m 755 -o abc -g abc "$DESK"

sudo tee "$DESK/GitBios Control Panel.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=GitBios Control Panel
Comment=Launch the Nexus control panel
Exec=/nexus-bucket/GitBIOS-Control-Panel/start_control_panel.sh
Path=/nexus-bucket/GitBIOS-Control-Panel
Icon=/nexus-bucket/GitBIOS-Control-Panel/static/assets/nexus-logo.png
Terminal=false
Categories=Utility;
TryExec=/nexus-bucket/GitBIOS-Control-Panel/start_control_panel.sh
EOF

sudo chown abc:abc "$DESK/GitBios Control Panel.desktop"
chmod +x "$DESK/GitBios Control Panel.desktop"
gio set "$DESK/GitBios Control Panel.desktop" metadata::trusted true 2>/dev/null || true
```

Double-click **GitBios Control Panel** on the Desktop.

> First run will create a private Python environment if possible; otherwise it falls back to system Python and installs Flask to the user site automatically.

---

## How it works (important behavior)

* `start_control_panel.sh` prefers a venv at `/nexus-bucket/cp-venv`.
  If it canât create/use that (permissions or `ensurepip` missing), it **falls back** to `~/.gitbios-venv`.
  If even that fails, it **uses system Python** and installs Flask **to user site** (no sudo/apt).
* Browser opens to `http://localhost:5000` (default).
  Health endpoint: `http://localhost:5000/healthz`.
* Logs live at `/nexus-bucket/control-panel.log`.

---

## OPTIONAL: Change the port (e.g., 5010)

**One-off run:**

```bash
PORT=5010 /nexus-bucket/GitBIOS-Control-Panel/start_control_panel.sh
```

**Make it permanent via Desktop icon:**

```bash
DESK="/config/Desktop"
# Edit the Exec= line to inject env PORT=5010
sed -i 's#^Exec=.*#Exec=env PORT=5010 /nexus-bucket/GitBIOS-Control-Panel/start_control_panel.sh#' \
  "$DESK/GitBios Control Panel.desktop"
```

---

## Troubleshooting

### 1) âPermission deniedâ creating `/nexus-bucket/cp-venv`

* The launcher now **auto-falls back** to `~/.gitbios-venv`.
* If you want the bucket venv explicitly:

  ```bash
  sudo install -d -m 755 -o abc -g abc /nexus-bucket
  sudo rm -rf /nexus-bucket/cp-venv
  sudo install -d -m 755 -o abc -g abc /nexus-bucket/cp-venv
  ```

### 2) `ensurepip` / venv creation failure

* Normal for minimal images missing `python3-venv`. The launcher will:

  1. Try venv.
  2. Fall back to user-site install for Flask.
* Optional base image improvement:

  ```bash
  sudo apt-get update && sudo apt-get install -y python3-venv
  ```

### 3) âNo browser foundâ / click opens nothing

* The launcher tries `gio open`, Firefox, Chromium/Chrome, and `xdg-open`.
* Install one of those if needed, or set `BROWSER`:

  ```bash
  BROWSER=/usr/bin/firefox /nexus-bucket/GitBIOS-Control-Panel/start_control_panel.sh
  ```

### 4) Desktop icon asks âExecute or View?â

* We set the trust flag, but some DEs ignore it. Right-click â **Properties** â enable **Allow launching**.
* Ensure the file is executable:

  ```bash
  chmod +x "/config/Desktop/GitBios Control Panel.desktop"
  ```

### 5) Health & logs

```bash
curl -fsS http://localhost:5000/healthz && echo OK
tail -n 200 /nexus-bucket/control-panel.log
```

### 6) **Do not** do a recursive `chown` on Desktop

Never run:

```bash
chown -R abc:abc /config/Desktop
```

It will hit bind mounts/repo files and throw **Operation not permitted** repeatedly.
Only touch the specific `.desktop` file or the app folder under `/nexus-bucket`.

---

## Uninstall / Cleanup

```bash
# Stop is just closing the browser tab (server self-manages).
# Remove Desktop launcher
rm -f "/config/Desktop/GitBios Control Panel.desktop"

# Remove app and venvs
rm -rf /nexus-bucket/GitBIOS-Control-Panel
rm -rf /nexus-bucket/cp-venv
rm -rf ~/.gitbios-venv
rm -f  /nexus-bucket/control-panel.log
```

---

## Advanced: override venv location

Prefer keeping venv in `$HOME`? Update the Desktop icon:

```bash
sed -i 's#^Exec=.*#Exec=env VENV_DIR=$HOME/.gitbios-venv /nexus-bucket/GitBIOS-Control-Panel/start_control_panel.sh#' \
  "/config/Desktop/GitBios Control Panel.desktop"
```

---

## Notes

* External links open in your system browser (per your request).
* Cloud Jam Challenge image has been swapped to the Shopify URL you provided; other images resolve from the GitHub WordPress artifact path and are cached for offline.
* No `tmux` required; weâre using the browser + logs for visibility.

---

If you want this wrapped as a Debian post-install or s6 service in your base image later, I can draft those too.
