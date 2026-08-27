#!/bin/bash
set -e

mkdir -p "$HERMES_HOME"

if [ "${RESTORE_MEMORY:-1}" = "1" ]; then
    echo "→ restoring memory from Hugging Face..."
    python /app/runtime.py restore || echo "⚠ restore skipped"
fi

echo "→ applying runtime config tweaks..."
python - << 'PY'
from pathlib import Path
p = Path("/home/hermes/.hermes/config.yaml")
if p.exists():
    txt = p.read_text()
    if "\n  gemini: round_robin\n" not in txt:
        txt = txt.replace("\n  gemini: fill_first\n", "\n  gemini: round_robin\n")
        p.write_text(txt)
        print("✓ credential pool strategy -> round_robin")
    else:
        print("credential pool strategy already round_robin")
PY

python /app/runtime.py serve &
HEALTH_PID=$!
trap 'kill $HEALTH_PID 2>/dev/null' EXIT

echo "→ starting hermes gateway..."
exec python -m hermes_cli.main gateway run
