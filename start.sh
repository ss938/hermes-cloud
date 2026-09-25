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

echo "→ configuring model provider (Gemini / Nous preferred)..."
python - << 'PY'
import os
import json
import shutil
import yaml
from pathlib import Path
from huggingface_hub import hf_hub_download

home = Path("/home/hermes/.hermes")
envf = home / ".env"
cfg = home / "config.yaml"
authf = home / "auth.json"

NOUS_MODEL = (os.environ.get("NOUS_MODEL") or "upstage/solar-pro4:free").strip()
GEMINI_MODEL = (os.environ.get("GEMINI_MODEL") or "gemini-3-flash").strip()

def has_nous_auth():
    try:
        data = json.loads(authf.read_text())
        providers = data.get("providers") or {}
        return "nous" in providers
    except Exception:
        return False

# 1) استرجاع هوية Nous من مستودع Hugging Face (nous-auth.json) إن لم تكن موجودة
if not has_nous_auth():
    token = (os.environ.get("HERMES_HF_TOKEN") or "").strip()
    repo = (os.environ.get("MEMORY_REPO") or "salah1593/hermes-memory").strip()
    if token:
        try:
            p = hf_hub_download(
                repo_id=repo, filename="nous-auth.json",
                repo_type="dataset", token=token, force_download=True,
            )
            data = json.loads(Path(p).read_text())
            if "nous" in (data.get("providers") or {}):
                authf.write_text(json.dumps(data))
                print("✓ nous-auth.json restored from Hugging Face (Nous identity)")
        except Exception as exc:
            print("⚠ nous-auth.json not on HF yet: %s" % exc)
    else:
        print("⚠ HERMES_HF_TOKEN missing — cannot fetch Nous identity")

if not cfg.exists():
    print("⚠ config.yaml missing — skipping provider switch")
else:
    g_key = (os.environ.get("GEMINI_API_KEY") or "").strip()
    go_key = (os.environ.get("GOOGLE_API_KEY") or "").strip()

    if g_key or go_key:
        # Gemini — مجاني بلا بطاقة مع حدود يومية، نحافظ على حصته عبر جلسة واحدة وتناوب مفاتيح
        key = g_key or go_key
        lines = [l for l in (envf.read_text().splitlines() if envf.exists() else [])
                 if not (l.startswith("GEMINI_API_KEY=") or l.startswith("GOOGLE_API_KEY="))]
        envf.write_text("\n".join(lines + [f"GEMINI_API_KEY={key}"]) + "\n")
        print("✓ Gemini key saved to .env")

        shutil.copy(cfg, home / "config.yaml.gemini.bak")
        data = yaml.safe_load(cfg.read_text()) or {}
        model = data.get("model") if isinstance(data.get("model"), dict) else {}
        model.update({
            "provider": "gemini",
            "default": GEMINI_MODEL,
            "base_url": "",
            "api_mode": "chat_completions",
        })
        data["model"] = model

        # حماية حصة Gemini: جلسة واحدة فقط (طلبات متسلسلة بدل متوازية)
        data["max_concurrent_sessions"] = 1
        print("✓ max_concurrent_sessions = 1 (طلبات متسلسلة — حماية حصة Gemini)")

        # تناوب المفاتيح عند تعددها (round_robin بدل fill_first)
        strategies = data.setdefault("credential_pool_strategies", {})
        if isinstance(strategies, dict):
            strategies["gemini"] = "round_robin"
            print("✓ credential_pool_strategies.gemini = round_robin")

        # تقليل الطلبات المساعدة المهدورة للحصة (عناوين الجلسات + التلخيص)
        aux = data.setdefault("auxiliary", {})
        if isinstance(aux, dict):
            tt = aux.setdefault("title_generation", {})
            if isinstance(tt, dict):
                tt["model_upgrade_enabled"] = False
                print("✓ title_generation.model_upgrade_enabled = False (توفير الحصة)")

        # سلسلة احتياطية تلقائية: إذا رفض Gemini (429/انتهت الحصة) ينتقل الطلب
        # مباشرة إلى مزوّد مجاني آخر دون انقطاع — الحل الأوصى به في 2026.
        chain = []
        providers = data.setdefault("providers", {})
        if not isinstance(providers, dict):
            providers = {}
            data["providers"] = providers

        groq_key = (os.environ.get("GROQ_API_KEY") or "").strip()
        if groq_key:
            # Groq: مجاني، 1000 طلب/يوم (ضعف Gemini تقريباً)، بلا بطاقة
            lines = [l for l in (envf.read_text().splitlines() if envf.exists() else [])
                     if not l.startswith("GROQ_API_KEY=")]
            envf.write_text("\n".join(lines + [f"GROQ_API_KEY={groq_key}"]) + "\n")
            providers["groq"] = {
                "api": "https://api.groq.com/openai/v1",
                "api_key": "${GROQ_API_KEY}",
            }
            chain.append({
                "provider": "groq",
                "model": "openai/gpt-oss-120b",
                "base_url": "https://api.groq.com/openai/v1",
                "api_mode": "chat_completions",
            })
            print("✓ fallback 1 → Groq (openai/gpt-oss-120b) — مجاني 1000 طلب/يوم")

        or_key = (os.environ.get("OPENROUTER_API_KEY") or "").strip()
        if or_key:
            # OpenRouter: شبكة نماذج مجانية بلا بطاقة (خطة 50 طلب/يوم)
            chain.append({
                "provider": "openrouter",
                "model": "openrouter/free",
                "api_mode": "chat_completions",
            })
            print("✓ fallback 2 → OpenRouter (openrouter/free)")

        if chain:
            data["fallback_providers"] = chain
            print("✓ fallback_providers = سلسلة احتياطية تلقائية (لا انقطاع عند نفاد الحصة)")

        cfg.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
        print(f"✓ config.yaml → provider gemini / model {GEMINI_MODEL}")
    elif has_nous_auth():
        # Nous Portal — المزوّد الرسمي لهرمز، يعمل من أي خادم
        shutil.copy(cfg, home / "config.yaml.nous.bak")
        data = yaml.safe_load(cfg.read_text()) or {}
        model = data.get("model") if isinstance(data.get("model"), dict) else {}
        model.update({
            "provider": "nous",
            "default": NOUS_MODEL,
            "base_url": "https://inference-api.nousresearch.com/v1",
            "api_mode": "chat_completions",
        })
        data["model"] = model
        cfg.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
        print(f"✓ config.yaml → provider nous / model {NOUS_MODEL}")
    else:
        or_key = (os.environ.get("OPENROUTER_API_KEY") or "").strip()
        oc_key = (os.environ.get("OPENCODE_API_KEY") or "").strip()

        if or_key:
            # OpenRouter — مجاني بلا بطاقة ويعمل من الخوادم الخارجية
            lines = [l for l in (envf.read_text().splitlines() if envf.exists() else [])
                     if not l.startswith("OPENROUTER_API_KEY=")]
            envf.write_text("\n".join(lines + [f"OPENROUTER_API_KEY={or_key}"]) + "\n")
            print("✓ OPENROUTER_API_KEY saved to .env")

            shutil.copy(cfg, home / "config.yaml.provider.bak")
            data = yaml.safe_load(cfg.read_text()) or {}
            model = data.get("model") if isinstance(data.get("model"), dict) else {}
            model.update({
                "provider": "openrouter",
                "default": "openrouter/free",
                "base_url": "",
                "api_mode": "chat_completions",
            })
            data["model"] = model
            cfg.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
            print("✓ config.yaml → provider openrouter / model openrouter/free")
        elif oc_key:
            # OpenCode Zen — يعمل فقط من داخل OpenCode (غير صالح للخوادم الخارجية)
            lines = [l for l in (envf.read_text().splitlines() if envf.exists() else [])
                     if not l.startswith("OPENCODE_API_KEY=")]
            envf.write_text("\n".join(lines + [f"OPENCODE_API_KEY={oc_key}"]) + "\n")
            print("✓ OPENCODE_API_KEY saved to .env")

            shutil.copy(cfg, home / "config.yaml.opencode.bak")
            data = yaml.safe_load(cfg.read_text()) or {}
            providers = data.setdefault("providers", {})
            providers["opencode"] = {
                "api": "https://opencode.ai/zen/v1",
                "api_key": "${OPENCODE_API_KEY}",
            }
            model = data.get("model") if isinstance(data.get("model"), dict) else {}
            model.update({
                "provider": "opencode",
                "default": "big-pickle",
                "base_url": "",
                "api_mode": "chat_completions",
            })
            data["model"] = model
            cfg.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
            print("✓ config.yaml → provider opencode / model big-pickle (قد يُرفض خارج OpenCode)")
        else:
            print("⚠ لا يوجد أي مزود — ضع GEMINI_API_KEY أو nous-auth.json في Render")
PY

echo "→ initial obsidian vault sync..."
python /app/runtime.py vault-init || echo "⚠ vault init skipped"

python /app/runtime.py serve &
HEALTH_PID=$!
trap 'kill $HEALTH_PID 2>/dev/null' EXIT

echo "→ starting hermes gateway..."
exec python -m hermes_cli.main gateway run
