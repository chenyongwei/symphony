#!/usr/bin/env bash
set -euo pipefail

SYMPHONY_ELIXIR_DIR="${1:-${SYMPHONY_ELIXIR_DIR:-$HOME/Code/symphony/elixir}}"
BIN_PATH="$SYMPHONY_ELIXIR_DIR/bin/symphony"

if [[ ! -d "$SYMPHONY_ELIXIR_DIR" ]]; then
  echo "[symphony-build] error: missing Symphony Elixir directory: $SYMPHONY_ELIXIR_DIR" >&2
  exit 1
fi

if ! command -v mise >/dev/null 2>&1; then
  echo "[symphony-build] error: mise is required but was not found in PATH" >&2
  exit 1
fi

needs_build="$(
  python3 - "$SYMPHONY_ELIXIR_DIR" "$BIN_PATH" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1]).expanduser()
bin_path = Path(sys.argv[2]).expanduser()

if not bin_path.exists():
    print("yes")
    raise SystemExit

build_mtime = bin_path.stat().st_mtime
watch_files = [root / "mix.exs", root / "mix.lock"]
watch_dirs = [root / "lib", root / "config"]

for path in watch_files:
    if path.exists() and path.stat().st_mtime > build_mtime:
        print("yes")
        raise SystemExit

for directory in watch_dirs:
    if not directory.exists():
        continue
    for file_path in directory.rglob("*"):
        if file_path.is_file() and file_path.stat().st_mtime > build_mtime:
            print("yes")
            raise SystemExit

print("no")
PY
)"

if [[ "$needs_build" != "yes" ]]; then
  exit 0
fi

echo "[symphony-build] rebuilding escript: $BIN_PATH"
cd "$SYMPHONY_ELIXIR_DIR"
mise exec -- mix build
