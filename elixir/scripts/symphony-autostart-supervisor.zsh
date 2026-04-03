#!/bin/zsh
emulate -L zsh
set -euo pipefail

SYMPHONY_ELIXIR_DIR="${SYMPHONY_ELIXIR_DIR:-$HOME/Code/symphony/elixir}"
INSTANCE_LAUNCHER="${INSTANCE_LAUNCHER:-$SYMPHONY_ELIXIR_DIR/scripts/symphony-autostart-instance.zsh}"
CODE_ROOT="${CODE_ROOT:-$HOME/Code}"
STATE_DIR="${SYMPHONY_STATE_DIR:-$HOME/Library/Application Support/Symphony}"
LOG_DIR="${SYMPHONY_LOG_DIR:-$HOME/Library/Logs/Symphony}"
PORT_MAP_PATH="${PORT_MAP_PATH:-$STATE_DIR/workflow_ports.tsv}"
BASE_PORT="${SYMPHONY_BASE_PORT:-4000}"
SCAN_INTERVAL="${SYMPHONY_SCAN_INTERVAL:-15}"

mkdir -p "$STATE_DIR" "$LOG_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

discover_workflows() {
  /usr/bin/find "$CODE_ROOT" \
    \( -type d \( -name '*-symphony-workspaces' -o -name archive -o -name node_modules -o -name .git \) -prune \) -o \
    -type f -path '*/.symphony/WORKFLOW*.md' -print | LC_ALL=C sort
}

refresh_port_map() {
  python3 - "$CODE_ROOT" "$PORT_MAP_PATH" "$BASE_PORT" <<'PY'
from pathlib import Path
import os
import sys

code_root = Path(sys.argv[1]).expanduser()
port_map_path = Path(sys.argv[2]).expanduser()
base_port = int(sys.argv[3])
tmp_map_path = Path(f"{port_map_path}.tmp")

excluded_dir_names = {"archive", "node_modules", ".git"}

workflows = []
for root, dirs, files in os.walk(code_root):
    dirs[:] = [
        d for d in dirs
        if d not in excluded_dir_names and not d.endswith("-symphony-workspaces")
    ]
    if Path(root).name != ".symphony":
        continue
    for name in files:
        if name.startswith("WORKFLOW") and name.endswith(".md"):
            workflows.append(str(Path(root, name)))

workflows.sort()
workflow_set = set(workflows)
existing_ports = {}
assigned_ports = {}

if port_map_path.exists():
    for raw in port_map_path.read_text().splitlines():
        if "\t" not in raw:
            continue
        workflow, port = raw.split("\t", 1)
        if workflow not in workflow_set:
            continue
        if port in assigned_ports:
            continue
        existing_ports[workflow] = port
        assigned_ports[port] = workflow

next_port = base_port
lines = []
for workflow in workflows:
    port = existing_ports.get(workflow)
    if not port:
        while str(next_port) in assigned_ports:
            next_port += 1
        port = str(next_port)
        assigned_ports[port] = workflow
        next_port += 1
    lines.append(f"{workflow}\t{port}")

tmp_map_path.write_text("\n".join(lines) + ("\n" if lines else ""))
tmp_map_path.replace(port_map_path)
PY
}

is_workflow_running() {
  local workflow="$1"

  pgrep -f -- "$workflow" >/dev/null 2>&1
}

ensure_instance_running() {
  local workflow="$1"
  local port="$2"
  local slug="$3"

  if is_workflow_running "$workflow"; then
    return 0
  fi

  log "starting ${slug} on port ${port}"
  "$INSTANCE_LAUNCHER" "$workflow" "$port" \
    >> "$LOG_DIR/${slug}.out.log" \
    2>> "$LOG_DIR/${slug}.err.log" &
}

main_loop() {
  local workflow port slug line

  log "symphony autostart supervisor is running"

  while true; do
    refresh_port_map

    if [[ -f "$PORT_MAP_PATH" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" == *$'\t'* ]] || continue
        workflow="$(printf '%s\n' "$line" | cut -f1)"
        port="$(printf '%s\n' "$line" | cut -f2)"
        [[ -n "$workflow" && -n "$port" ]] || continue
        slug="${workflow:h:h:t}"
        ensure_instance_running "$workflow" "$port" "$slug"
      done < "$PORT_MAP_PATH"
    fi

    sleep "$SCAN_INTERVAL"
  done
}

if [[ ! -d "$SYMPHONY_ELIXIR_DIR" ]]; then
  echo "[symphony-supervisor] error: missing Symphony Elixir directory: $SYMPHONY_ELIXIR_DIR" >&2
  exit 1
fi

if [[ ! -x "$INSTANCE_LAUNCHER" ]]; then
  echo "[symphony-supervisor] error: missing executable instance launcher: $INSTANCE_LAUNCHER" >&2
  exit 1
fi

main_loop
