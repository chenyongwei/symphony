#!/bin/zsh
emulate -L zsh
set -euo pipefail

LABEL="com.alex.symphony.autostart"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl disable "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"

echo "[uninstall] removed ${PLIST_PATH}"
