# Git-BIOS Control Panel

**Cloud Underground · Underground Nexus**

A sovereign command-and-control panel that runs as a local web app. Buttons map to shell commands, Docker operations, eBPF probes, kernel modules, GPIO pins, ROS2 nodes, and any other system operation you can express in bash.

---

## What Changed (v2)

| Area | Before | After |
|---|---|---|
| Dependencies | Flask (pip/venv required) | Zero — stdlib only |
| Startup time | 3–10s (venv waterfall) | < 100ms |
| Desktop icon | Browser didn't open (no DISPLAY) | Opens browser automatically |
| Script copies | 3 diverging versions of start script | 1 canonical file |
| Healthcheck | python3 subprocess, 10s max | curl, 5ms |
| Air-gap | Hung 30s/asset on every page load | Background fetch, non-blocking |
| Robotics/eBPF | No profile | `Robotics.json` profile included |
| Privilege | No escalation support | `"privileged": true` per button |

---

## Folder Layout

```
Jelly-Apps/Git-BIOS-Control-Panel/
  server.py                        ← stdlib HTTP server (no Flask)
  start_control_panel.sh           ← canonical launcher (one file, replaces 3)
  install-git-bios-control-panel.sh ← installer/repair script
  launch-desktop-icon.sh           ← delegates to installer
  gitbios-control-panel.html       ← source HTML (the page content)
  requirements-flask.txt           ← kept for reference only, not needed
  profiles/
    Default.json                   ← default buttons
    Robotics.json                  ← eBPF, GPIO, CAN, ROS2, kernel buttons
  static/
    app.js                         ← dock UI logic
    app.css                        ← dock UI styles
    assets/                        ← cached images (auto-created on first run)
```

---

## Quick Install

```bash
# From the workbench container (as abc or root):
bash /config/Desktop/nexus-bucket/underground-nexus/Jelly-Apps/Git-BIOS-Control-Panel/install-git-bios-control-panel.sh
```

That's it. The installer:
- Checks python3 is available (only dependency)
- Writes the canonical `start_control_panel.sh` with correct paths
- Creates the `.desktop` file on your Desktop with the correct `Exec=` path
- Optionally registers an s6 pre-warm service if run as root in a linuxserver container

**No pip. No venv. No Flask. No sudo needed for the app itself.**

---

## Starting the Panel

**From the Desktop icon:** Double-click. Browser opens to `http://localhost:5000`.

**From the terminal:**
```bash
bash /config/Desktop/nexus-bucket/underground-nexus/Jelly-Apps/Git-BIOS-Control-Panel/start_control_panel.sh
```

**Custom port:**
```bash
PORT=8080 bash start_control_panel.sh
```

---

## Button Profile JSON Format

Profiles live in `profiles/` as `.json` files. Each is a list of button objects:

```json
[
  {
    "label":       "Button label shown in the UI",
    "command":     "bash command to run",
    "interactive": false,
    "privileged":  false
  }
]
```

| Field | Type | Description |
|---|---|---|
| `label` | string | Display name. Prefix with `WARNING!` for a confirm dialog. |
| `command` | string | Any bash command. Special: `__INTERNAL_BACKUP__`, `__INTERNAL_RESTORE__` |
| `interactive` | bool | `true` = opens in Terminator window (or tmux fallback) |
| `privileged` | bool | `true` = command is prefixed with `sudo -n` for kernel/eBPF/GPIO use |

---

## Robotics & eBPF Use

Load the `Robotics` profile from the profile selector. It includes buttons for:

- **eBPF:** `bpftool prog list`, bpftrace syscall tracing, I/O latency histograms
- **Kernel modules:** `modprobe` load/unload with privilege escalation
- **GPIO:** `gpioinfo` chip scan, line listing (requires `--privileged` container)
- **I2C:** `i2cdetect` bus scan
- **CAN bus:** interface status, `can0` bring-up at 500kbps
- **ROS2:** environment check, node list, interactive ROS2 CLI
- **Real-time:** PREEMPT_RT check, process priority adjustment

For eBPF and kernel-level operations the container must run with `--privileged`. The `"privileged": true` field in the button JSON adds `sudo -n` before the command — configure passwordless sudo for abc in `/etc/sudoers` if needed.

---

## s6 Pre-warm (linuxserver webtop)

If you run as root during install, an s6 longrun service is registered at `/etc/s6-overlay/s6-rc.d/gitbios/`. This starts the server when the container boots so the desktop icon click is instant — no cold start delay.

Manual registration:
```bash
sudo bash install-git-bios-control-panel.sh
```

---

## Desktop Icon (if missing)

Re-run the installer — it recreates the `.desktop` file with the correct path:

```bash
bash install-git-bios-control-panel.sh
```

The `.desktop` file is written to `~/Desktop/Git-BIOS-Control-Panel.desktop` with the correct `Exec=` path. The previous README had a hardcoded wrong path — this is now dynamic.

---

## API Reference

All APIs are identical to the previous Flask version. No client changes needed.

| Method | Path | Description |
|---|---|---|
| GET | `/healthz` | `{"ok": true}` — used by the launcher |
| GET | `/` | Rendered control panel page |
| GET | `/api/profiles` | List profile names |
| GET | `/api/profiles/<n>` | Get profile buttons |
| POST | `/api/profiles` | Create profile `{name, buttons}` |
| PUT | `/api/profiles/<n>` | Update/append button |
| DELETE | `/api/profiles/<n>` | Delete profile |
| POST | `/api/profiles/import` | Upload profile JSON file |
| GET | `/api/profiles/export/<n>` | Download profile JSON |
| GET | `/api/backup/latest` | Download latest backup |
| POST | `/api/run` | Execute button `{command, interactive, privileged}` |

Optional auth: set `CP_TOKEN` env var. All write/exec APIs then require `Authorization: Bearer <token>`.

---

*Cloud Underground · Underground Nexus · Git-BIOS Control Panel*
