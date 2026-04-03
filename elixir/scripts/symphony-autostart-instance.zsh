#!/bin/zsh
emulate -L zsh
set -euo pipefail

WORKFLOW_PATH="${1:-${SYMPHONY_WORKFLOW:-}}"
SYMPHONY_PORT="${2:-${SYMPHONY_PORT:-}}"
SYMPHONY_ELIXIR_DIR="${SYMPHONY_ELIXIR_DIR:-$HOME/Code/symphony/elixir}"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

if [[ -f "$HOME/.zshrc" ]]; then
  set +u
  source "$HOME/.zshrc" >/dev/null 2>&1 || true
  set -u
fi

if [[ -z "$WORKFLOW_PATH" ]]; then
  echo "[symphony-instance] error: workflow path is required" >&2
  exit 1
fi

if [[ -z "$SYMPHONY_PORT" ]]; then
  echo "[symphony-instance] error: port is required" >&2
  exit 1
fi

if [[ ! -d "$SYMPHONY_ELIXIR_DIR" ]]; then
  echo "[symphony-instance] error: missing Symphony Elixir directory: $SYMPHONY_ELIXIR_DIR" >&2
  exit 1
fi

if [[ ! -f "$WORKFLOW_PATH" ]]; then
  echo "[symphony-instance] error: missing workflow file: $WORKFLOW_PATH" >&2
  exit 1
fi

if ! command -v mise >/dev/null 2>&1; then
  echo "[symphony-instance] error: mise is required but was not found in PATH" >&2
  exit 1
fi

if [[ -z "${LINEAR_API_KEY:-}" ]]; then
  echo "[symphony-instance] error: LINEAR_API_KEY is not set" >&2
  echo "[symphony-instance] hint: ensure it exists in ~/.zshrc before using autostart" >&2
  exit 1
fi

cd "$SYMPHONY_ELIXIR_DIR"

echo "[symphony-instance] workflow: $WORKFLOW_PATH"
echo "[symphony-instance] web UI: http://127.0.0.1:$SYMPHONY_PORT"
echo "[symphony-instance] cwd: $SYMPHONY_ELIXIR_DIR"

exec mise exec -- \
  ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port "$SYMPHONY_PORT" \
  "$WORKFLOW_PATH"
