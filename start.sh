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

echo "→ configuring OpenCode Zen provider (Big Pickle)..."
python - << 'PY'
import os
import shutil
import yaml
from pathlib import Path

key = (os.environ.get("OPENCODE_API_KEY") or "").strip()
if not key:
    print("⚠ OPENCODE_API_KEY not set — skipping model switch")
else:
    home = Path("/home/hermes/.hermes")
    envf = home / ".env"
    cfg = home / "config.yaml"

    if not cfg.exists():
        print("⚠ config.yaml missing — skipping model switch")
    else:
        # 1) المفتاح في .env (لا يُرفع إلى Hugging Face — غير موجود في قائمة SNAPSHOT_ITEMS)
        lines = [l for l in (envf.read_text().splitlines() if envf.exists() else [])
                 if not l.startswith("OPENCODE_API_KEY=")]
        envf.write_text("\n".join(lines + [f"OPENCODE_API_KEY={key}"]) + "\n")
        print("✓ OPENCODE_API_KEY saved to .env")

        # 2) نسخة احتياطية قبل التعديل
        shutil.copy(cfg, home / f"config.yaml.opencode.bak")

        # 3) تحديث config.yaml: مزود opencode + موديل big-pickle
        data = yaml.safe_load(cfg.read_text()) or {}
        providers = data.setdefault("providers", {})
        providers["opencode"] = {
            "api": "https://opencode.ai/zen/v1",
            "api_key": "${OPENCODE_API_KEY}",
        }
        # تحديث الموديل الأساسي مع الحفاظ على أي مفاتيح أخرى داخل model:
        model = data.get("model") if isinstance(data.get("model"), dict) else {}
        model.update({
            "provider": "opencode",
            "default": "big-pickle",
            "base_url": "",
            "api_mode": "chat_completions",
        })
        data["model"] = model
        cfg.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
        print("✓ config.yaml → provider opencode / model big-pickle")
PY

echo "→ initial obsidian vault sync..."
python /app/runtime.py vault-init || echo "⚠ vault init skipped"

python /app/runtime.py serve &
HEALTH_PID=$!
trap 'kill $HEALTH_PID 2>/dev/null' EXIT

echo "→ starting hermes gateway..."
exec python -m hermes_cli.main gateway run
