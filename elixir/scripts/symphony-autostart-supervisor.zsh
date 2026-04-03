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
  local workflow port next_port tmp_map
  local -A existing_ports
  local -A assigned_ports
  local -a workflows

  existing_ports=()
  assigned_ports=()
  workflows=("${(@f)$(discover_workflows)}")
  tmp_map="${PORT_MAP_PATH}.tmp"

  if [[ -f "$PORT_MAP_PATH" ]]; then
    while IFS=$'\t' read -r workflow port; do
      [[ -n "$workflow" && -n "$port" ]] || continue
      existing_ports["$workflow"]="$port"
    done < "$PORT_MAP_PATH"
  fi

  : > "$tmp_map"
  next_port=$BASE_PORT

  for workflow in "${workflows[@]}"; do
    port="${existing_ports[$workflow]-}"

    if [[ -n "$port" && -z "${assigned_ports[$port]-}" ]]; then
      assigned_ports["$port"]="$workflow"
    else
      while [[ -n "${assigned_ports[$next_port]-}" ]]; do
        (( next_port++ ))
      done
      port="$next_port"
      assigned_ports["$port"]="$workflow"
      (( next_port++ ))
    fi

    printf '%s\t%s\n' "$workflow" "$port" >> "$tmp_map"
  done

  /bin/mv "$tmp_map" "$PORT_MAP_PATH"
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
  local workflow port slug

  log "symphony autostart supervisor is running"

  while true; do
    refresh_port_map

    if [[ -f "$PORT_MAP_PATH" ]]; then
      while IFS=$'\t' read -r workflow port; do
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
