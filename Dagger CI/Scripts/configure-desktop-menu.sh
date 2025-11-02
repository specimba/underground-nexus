bash -euxo pipefail <<'EOF'
# ---- config / helpers ----
export DEBIAN_FRONTEND=noninteractive

# Resolve HOME safely (already exported by the shell, but ensure non-empty)
: "${HOME:?HOME is not set}"

# Detect the real Desktop dir (XDG or fallback to ~/Desktop)
DESKTOP_DIR="$HOME/Desktop"
if [ -f "$HOME/.config/user-dirs.dirs" ]; then
  # shellcheck disable=SC2046
  eval $(grep -E '^XDG_DESKTOP_DIR=' "$HOME/.config/user-dirs.dirs" | sed -E 's/^XDG_DESKTOP_DIR=(.*)$/DESKTOP_DIR=\1/')
  DESKTOP_DIR="${DESKTOP_DIR/\$HOME/$HOME}"
fi
mkdir -p "$DESKTOP_DIR"

# Local bin for our tiny wrapper
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"

# Sudo if not already root
if [ "${EUID:-$(id -u)}" -ne 0 ]; then SUDO="sudo -n"; else SUDO=""; fi

# ---- ensure rofi is installed ----
if ! command -v rofi >/dev/null 2>&1; then
  # Basic APT hygiene without being too invasive
  $SUDO apt-get update -y
  $SUDO apt-get install -y rofi
fi

# ---- write wrapper that launches rofi drun ----
LAUNCHER="$LOCAL_BIN/open-rofi-drun.sh"
cat > "$LAUNCHER" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec rofi -show drun
SH
chmod +x "$LAUNCHER"

# ---- create desktop shortcut named "Menu" ----
DESKFILE="$DESKTOP_DIR/menu.desktop"
cat > "$DESKFILE" <<EOF2
[Desktop Entry]
Type=Application
Name=Menu
Comment=Open the application menu (rofi drun)
Exec=$LAUNCHER
Icon=applications-system
Terminal=false
Categories=Utility;
StartupNotify=false
EOF2

# Make it executable so GNOME/KDE can run it
chmod +x "$DESKFILE"

# Mark as trusted for GNOME (if gio is available); otherwise user may need to “Trust and Launch” once
if command -v gio >/dev/null 2>&1; then
  gio set "$DESKFILE" "metadata::trusted" yes || true
fi

echo
echo "Created: $DESKFILE"
echo "Click the 'Menu' icon on your Desktop to run: rofi -show drun"
echo
EOF
