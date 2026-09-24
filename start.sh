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
    changed = False
    if "\n  gemini: round_robin\n" not in txt:
        txt = txt.replace("\n  gemini: fill_first\n", "\n  gemini: round_robin\n")
        changed = True
        print("✓ credential pool strategy -> round_robin")
    # إزالة خادم Notion MCP نهائياً (استُبدل بمزامنة Obsidian عبر git)
    if "mcp_servers:" in txt:
        lines = txt.splitlines()
        keep = []
        i = 0
        while i < len(lines):
            if lines[i].startswith("mcp_servers:"):
                i += 1
                while i < len(lines) and (lines[i].startswith("  ") or lines[i].strip() == ""):
                    i += 1
                print("✓ removed notion mcp server block")
                changed = True
                continue
            keep.append(lines[i])
            i += 1
        txt = "\n".join(keep)
    if changed:
        p.write_text(txt)

# تذكير الذاكرة: مجلد ملاحظات Obsidian
um = Path("/home/hermes/.hermes/memories/USER.md")
if um.exists():
    txt = um.read_text()
    note = "\n§\nمنصة الملاحظات أصبحت Obsidian (وليس Notion): مجلد الملاحظات المتزامن موجود في /home/hermes/obsidian-vault — عند أي طلب يتعلق بالملاحظات اقرأ واكتب الملفات هناك مباشرة."
    if "obsidian-vault" not in txt:
        um.write_text(txt.rstrip("\n") + note + "\n")
        print("✓ added obsidian vault note to USER.md")
PY

echo "→ initial obsidian vault sync..."
python /app/runtime.py vault-init || echo "⚠ vault init skipped"

python /app/runtime.py serve &
HEALTH_PID=$!
trap 'kill $HEALTH_PID 2>/dev/null' EXIT

echo "→ starting hermes gateway..."
exec python -m hermes_cli.main gateway run
