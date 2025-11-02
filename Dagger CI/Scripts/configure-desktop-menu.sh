bash -euxo pipefail <<'EOF'
# -------------------------------------------
# Install a "Menu" desktop icon for user "abc"
# that launches: rofi -show drun  (MATE/Caja friendly)
# -------------------------------------------

export DEBIAN_FRONTEND=noninteractive
TARGET_USER="abc"

# 1) Resolve abc home and XDG Desktop dir (under abc's context)
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
[ -n "$USER_HOME" ] || USER_HOME="/home/$TARGET_USER"

# Helper to run commands as abc with a clean login shell
as_abc() { sudo -u "$TARGET_USER" -H bash -lc "$*"; }

# Prefer xdg-user-dir DESKTOP; fallback to ~/Desktop
DESKTOP_DIR="$(as_abc 'command -v xdg-user-dir >/dev/null 2>&1 && xdg-user-dir DESKTOP || echo "$HOME/Desktop"')"
[ -n "$DESKTOP_DIR" ] || DESKTOP_DIR="$USER_HOME/Desktop"

APPS_DIR="$USER_HOME/.local/share/applications"
BIN_DIR="$USER_HOME/.local/bin"

mkdir -p "$DESKTOP_DIR" "$APPS_DIR" "$BIN_DIR"
chown -R "$TARGET_USER:$TARGET_USER" "$USER_HOME/.local" "$DESKTOP_DIR"

# 2) Best-effort rofi installation (won't fail the script if repos are noisy)
need_rofi=1
command -v rofi >/dev/null 2>&1 && need_rofi=0
if [ "$need_rofi" -eq 1 ]; then
  # Try a light update; do NOT abort on errors
  apt-get update || true

  # Temporarily ignore known-bad third-party repos if present (don't delete permanently)
  # We "disable" by creating .disabled copies and commenting deb lines; restore manually if needed.
  for repo in shiftkey hashicorp docker microsoft; do
    :
  done
  # Disable ShiftKey (TLS issues in your logs)
  if grep -RIlq 'apt.packages.shiftkey.dev' /etc/apt/sources.list.d 2>/dev/null; then
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
      [ -f "$f" ] || continue
      grep -q 'apt.packages.shiftkey.dev' "$f" 2>/dev/null || continue
      cp -a "$f" "$f.disabled"
      sed -i -E 's/^[[:space:]]*deb/# disabled: &/' "$f" || true
      sed -i -E 's/^[[:space:]]*Enabled:[[:space:]]*yes/Enabled: no/' "$f" || true
    done
  fi
  # If vscode both .list and .sources exist, disable the .list to avoid duplicate warnings
  if [ -f /etc/apt/sources.list.d/vscode.list ] && [ -f /etc/apt/sources.list.d/vscode.sources ]; then
    sed -i -E 's/^[[:space:]]*deb/# disabled duplicate: &/' /etc/apt/sources.list.d/vscode.list || true
  fi

  # Try to install rofi now; don't let failures stop the rest
  apt-get install -y rofi || true
fi

# 3) Create a robust wrapper that launches rofi in abc's session
WRAPPER="$BIN_DIR/open-rofi-drun.sh"
cat > "$WRAPPER" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

# In a desktop session this should be set. If not, try a common default.
if [ -z "${DISPLAY:-}" ]; then
  export DISPLAY=":0"
fi

# Run detached so clicking the icon doesn't block the shell
if command -v setsid >/dev/null 2>&1; then
  setsid -f rofi -show drun >/dev/null 2>&1 || rofi -show drun
else
  rofi -show drun
fi
SH
chmod +x "$WRAPPER"
chown "$TARGET_USER:$TARGET_USER" "$WRAPPER"

# 4) Create .desktop launchers (MATE/Caja shows Desktop items that are +x)
ICON_NAME="applications-system"
DESKTOP_FILE_DESK="$DESKTOP_DIR/Menu.desktop"
DESKTOP_FILE_APPS="$APPS_DIR/Menu.desktop"

make_desktop() {
  local path="$1"
  cat > "$path" <<EOF2
[Desktop Entry]
Type=Application
Name=Menu
Comment=Open the application menu (rofi drun)
TryExec=rofi
Exec=$WRAPPER
Icon=$ICON_NAME
Terminal=false
Categories=Utility;
StartupNotify=false
EOF2
  chmod +x "$path"      # Important for Caja (MATE) to treat it as launchable
}
make_desktop "$DESKTOP_FILE_DESK"
make_desktop "$DESKTOP_FILE_APPS"
chown "$TARGET_USER:$TARGET_USER" "$DESKTOP_FILE_DESK" "$DESKTOP_FILE_APPS"

# 5) Optional validation/registration and trust
command -v desktop-file-validate >/dev/null 2>&1 && desktop-file-validate "$DESKTOP_FILE_DESK" || true
command -v desktop-file-validate >/dev/null 2>&1 && desktop-file-validate "$DESKTOP_FILE_APPS" || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" || true

# MATE/Caja usually doesn't require trust metadata, but set it if gio exists (run as abc)
if command -v gio >/dev/null 2>&1; then
  sudo -u "$TARGET_USER" -H gio set "$DESKTOP_FILE_DESK" "metadata::trusted" yes || true
fi

echo
echo "Installed 'Menu' for user '$TARGET_USER':"
echo " - Desktop:      $DESKTOP_FILE_DESK"
echo " - Applications: $DESKTOP_FILE_APPS"
echo " - Wrapper:      $WRAPPER"
echo
echo "If the icon doesn't show:"
echo " - Ensure Caja is drawing the desktop (MATE: look in Control Center ▸ Desktop)."
echo " - Verify Desktop directory: '$DESKTOP_DIR'."
echo " - You can also search 'Menu' in the Applications menu since we registered a user-local .desktop."
echo
EOF
