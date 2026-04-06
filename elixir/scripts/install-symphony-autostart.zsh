#!/bin/zsh
emulate -L zsh
set -euo pipefail

LABEL="com.alex.symphony.autostart"
SYMPHONY_ELIXIR_DIR="${SYMPHONY_ELIXIR_DIR:-$HOME/Code/symphony/elixir}"
SUPERVISOR_SCRIPT="${SUPERVISOR_SCRIPT:-$SYMPHONY_ELIXIR_DIR/scripts/symphony-autostart-supervisor.zsh}"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${SYMPHONY_LOG_DIR:-$HOME/Library/Logs/Symphony}"

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

if [[ ! -x "$SUPERVISOR_SCRIPT" ]]; then
  echo "[install] error: missing executable supervisor script: $SUPERVISOR_SCRIPT" >&2
  exit 1
fi

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${SUPERVISOR_SCRIPT}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SYMPHONY_ELIXIR_DIR</key>
    <string>${SYMPHONY_ELIXIR_DIR}</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>${SYMPHONY_ELIXIR_DIR}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/launchd.err.log</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST_PATH" >/dev/null

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl enable "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"

echo "[install] installed ${PLIST_PATH}"
echo "[install] launch agent label: ${LABEL}"
