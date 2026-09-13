#!/usr/bin/env bash
set -Eeuo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$DIR/.venv"

command -v python3 >/dev/null 2>&1 || { echo "[ERR] python3 not found"; exit 1; }
python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/pip" install -r "$DIR/requirements.txt"
chmod +x "$DIR/setup-node-panel.py"

echo
printf '[OK] Installed. Run:\n  %s/bin/python %s/setup-node-panel.py --help\n' "$VENV" "$DIR"
