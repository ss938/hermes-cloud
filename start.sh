#!/bin/bash
set -e

mkdir -p "$HERMES_HOME"

if [ "${RESTORE_MEMORY:-1}" = "1" ]; then
    echo "→ restoring memory from Hugging Face..."
    python /app/runtime.py restore || echo "⚠ restore skipped"
fi

python /app/runtime.py serve &
HEALTH_PID=$!
trap 'kill $HEALTH_PID 2>/dev/null' EXIT

echo "→ starting hermes gateway..."
exec python -m hermes_cli.main gateway run
