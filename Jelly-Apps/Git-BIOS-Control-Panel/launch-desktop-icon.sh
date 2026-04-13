#!/usr/bin/env bash
# =============================================================================
# Git-BIOS Control Panel — launch-desktop-icon.sh
# Cloud Underground · Underground Nexus
# =============================================================================
#
# This file creates or repairs the desktop .desktop launcher and the
# start_control_panel.sh script by re-running the installer.
#
# Usage:
#   bash launch-desktop-icon.sh
#
# Previously this file contained a full copy of start_control_panel.sh
# embedded as a heredoc, creating three diverging versions of the same
# script. This has been simplified: it delegates entirely to the installer,
# which is the single source of truth.
# =============================================================================

APP_DIR="${APP_DIR:-/config/Desktop/nexus-bucket/underground-nexus/Jelly-Apps/Git-BIOS-Control-Panel}"
INSTALLER="${APP_DIR}/install-git-bios-control-panel.sh"

echo "[gitbios] Launching desktop icon setup..."

if [ -f "${INSTALLER}" ]; then
    bash "${INSTALLER}"
else
    echo "[gitbios] Installer not found at ${INSTALLER}"
    echo "[gitbios] Cloning or re-pulling the underground-nexus repo first:"
    echo "  git -C /nexus-bucket/underground-nexus pull --rebase"
    exit 1
fi
