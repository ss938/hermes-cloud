#!/usr/bin/env python3
"""Hermes cloud runtime: memory restore, periodic HF backup, health endpoint, Obsidian vault sync."""
import io
import logging
import os
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s runtime: %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("hermes-cloud")

HERMES_HOME = Path(os.environ.get("HERMES_HOME", str(Path.home() / ".hermes")))
REPO_ID = os.environ.get("MEMORY_REPO", "salah1593/hermes-memory")
TOKEN = os.environ.get("HERMES_HF_TOKEN", "")
INTERVAL = int(os.environ.get("BACKUP_INTERVAL", "86400"))
CHANGE_KEY_FILE = "/tmp/hermes-last-snapshot.key"

# ---- Obsidian vault sync settings ----
OBSIDIAN_REPO = os.environ.get("OBSIDIAN_REPO", "salah1593/obsidian-vault")
OBSIDIAN_DIR = Path(os.environ.get("OBSIDIAN_DIR", "/home/hermes/obsidian-vault"))
VAULT_INTERVAL = int(os.environ.get("VAULT_SYNC_INTERVAL", "300"))
HF_USERNAME = os.environ.get("HF_USERNAME", "salah1593")

SNAPSHOT_ITEMS = [
    "memories", "sessions", "platforms", "pairing", "skills", "hooks",
    "pending_messages", "SOUL.md", "config.yaml", "auth.json",
    "channel_directory.json",
]
SQLITE_DBS = ["state.db", "kanban.db", "cron/executions.db"]


def _backup_sqlite(src: Path, dst: Path) -> None:
    out = sqlite3.connect(dst)
    try:
        inp = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
        try:
            inp.backup(out)
        finally:
            inp.close()
    finally:
        out.close()


def build_snapshot(dest: Path) -> bool:
    staging_root = Path("/tmp/hermes-snapshot")
    if staging_root.exists():
        shutil.rmtree(staging_root)
    home_dir = staging_root / ".hermes"
    home_dir.mkdir(parents=True)

    for rel in SQLITE_DBS:
        src = HERMES_HOME / rel
        if not src.exists():
            continue
        dst = home_dir / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        _backup_sqlite(src, dst)

    for item in SNAPSHOT_ITEMS:
        s = HERMES_HOME / item
        if not s.exists():
            continue
        d = home_dir / item
        if s.is_dir():
            shutil.copytree(s, d, ignore=shutil.ignore_patterns("*.lock", "__pycache__"))
        else:
            d.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(s, d)

    with tarfile.open(dest, "w:gz") as t:
        t.add(staging_root, arcname=".")
    shutil.rmtree(staging_root)
    return True


def restore_from_hub() -> bool:
    if not TOKEN:
        log.warning("HERMES_HF_TOKEN not set - skipping memory restore")
        return False
    from huggingface_hub import hf_hub_download

    try:
        path = hf_hub_download(
            repo_id=REPO_ID,
            filename="hermes-home.tar.gz",
            repo_type="dataset",
            token=TOKEN,
            force_download=True,
        )
        HERMES_HOME.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(path) as t:
            t.extractall(HERMES_HOME.parent)
        log.info("memory restored from %s", REPO_ID)
        return True
    except Exception as exc:  # noqa: BLE001
        log.warning("restore failed (first boot?): %s", exc)
        return False


def upload_backup(tar_path: Path) -> None:
    from huggingface_hub import HfApi

    HfApi(token=TOKEN).upload_file(
        path_or_fileobj=str(tar_path),
        path_in_repo="hermes-home.tar.gz",
        repo_id=REPO_ID,
        repo_type="dataset",
    )


def snapshot_change_key() -> str:
    import hashlib

    h = hashlib.sha256()

    def add(p: Path, tag: str) -> None:
        if not p.exists():
            return
        if p.is_dir():
            for f in sorted(p.rglob("*")):
                if not f.is_file() or f.suffix == ".lock" or "__pycache__" in f.parts:
                    continue
                st = f.stat()
                h.update(b"%s|%s|%d|%d\n" % (tag.encode(), str(f.relative_to(HERMES_HOME)).encode(), st.st_mtime_ns, st.st_size))
        else:
            st = p.stat()
            h.update(b"%s|%s|%d|%d\n" % (tag.encode(), p.name.encode(), st.st_mtime_ns, st.st_size))

    for item in SNAPSHOT_ITEMS:
        add(HERMES_HOME / item, "f")
    for rel in SQLITE_DBS:
        p = HERMES_HOME / rel
        if not p.exists():
            continue
        try:
            con = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
            dv = con.execute("PRAGMA data_version").fetchone()[0]
            con.close()
        except Exception:  # noqa: BLE001
            dv = 0
        h.update(b"sql|%s|%d\n" % (rel.encode(), dv))
    return h.hexdigest()


def backup_loop() -> None:
    tmp = Path("/tmp/hermes-backup.tar.gz")
    time.sleep(60)
    while True:
        if TOKEN and HERMES_HOME.exists():
            try:
                key = snapshot_change_key()
                last_key = None
                if Path(CHANGE_KEY_FILE).exists():
                    last_key = Path(CHANGE_KEY_FILE).read_text().strip()
                if key == last_key:
                    log.info("memory unchanged (key %s) - skipping upload", key[:8])
                else:
                    build_snapshot(tmp)
                    upload_backup(tmp)
                    Path(CHANGE_KEY_FILE).write_text(key)
                    log.info("memory backup uploaded (%.1f MB)", tmp.stat().st_size / 1e6)
                    tmp.unlink(missing_ok=True)
            except Exception as exc:  # noqa: BLE001
                log.warning("backup failed: %s", exc)
        time.sleep(INTERVAL)


# ---- Obsidian vault sync ----

def _run(cmd, cwd=None, timeout=180):
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    try:
        p = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except Exception as exc:  # noqa: BLE001
        return -1, str(exc)


def vault_auth_url() -> str:
    return f"https://{HF_USERNAME}:{TOKEN}@huggingface.co/datasets/{OBSIDIAN_REPO}"


def vault_ensure_clone() -> bool:
    if (OBSIDIAN_DIR / ".git").exists():
        return True
    OBSIDIAN_DIR.parent.mkdir(parents=True, exist_ok=True)
    rc, out = _run(["git", "clone", vault_auth_url(), str(OBSIDIAN_DIR)])
    if rc != 0:
        log.warning("vault clone failed: %s", out)
        return False
    _run(["git", "config", "user.email", "hermes@cloud.local"], cwd=OBSIDIAN_DIR)
    _run(["git", "config", "user.name", "hermes-cloud"], cwd=OBSIDIAN_DIR)
    log.info("obsidian vault cloned -> %s", OBSIDIAN_DIR)
    return True


def vault_sync_once() -> None:
    if not TOKEN:
        log.warning("HERMES_HF_TOKEN not set - skipping vault sync")
        return
    if not vault_ensure_clone():
        return
    # 1) سحب تغييرات المستخدم (من Obsidian على جهازه)
    rc, out = _run(["git", "pull", "--rebase", "--autostash"], cwd=OBSIDIAN_DIR)
    if rc != 0:
        log.warning("vault pull issue: %s", out)
    # 2) دفع تغييرات نبراس (تعديلات كتبها على الملاحظات)
    _run(["git", "add", "-A"], cwd=OBSIDIAN_DIR)
    rc, out = _run(["git", "commit", "-m", "sync via hermes-cloud"], cwd=OBSIDIAN_DIR)
    if rc == 0:
        rc, out = _run(["git", "push"], cwd=OBSIDIAN_DIR)
        if rc != 0:
            log.warning("vault push failed: %s", out)
        else:
            log.info("obsidian vault synced (pushed)")
    else:
        if "nothing to commit" in out or "nothing added" in out:
            log.info("obsidian vault unchanged")
        else:
            log.warning("vault commit skipped: %s", out)


def vault_loop() -> None:
    time.sleep(30)
    while True:
        try:
            vault_sync_once()
        except Exception as exc:  # noqa: BLE001
            log.warning("vault sync error: %s", exc)
        time.sleep(VAULT_INTERVAL)


class HealthHandler(BaseHTTPRequestHandler):
    def do_HEAD(self):  # noqa: N802
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", "2")
        self.end_headers()

    def do_GET(self):  # noqa: N802
        body = b"ok"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # silence per-request noise
        pass


def serve_health() -> None:
    port = int(os.environ.get("PORT", "10000"))
    threading.Thread(target=backup_loop, daemon=True).start()
    threading.Thread(target=vault_loop, daemon=True).start()
    server = HTTPServer(("0.0.0.0", port), HealthHandler)
    log.info("health endpoint listening on :%s", port)
    server.serve_forever()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "restore":
        restore_from_hub()
    elif cmd == "vault-init":
        vault_sync_once()
    elif cmd == "serve":
        serve_health()
    else:
        print(f"usage: {sys.argv[0]} restore|vault-init|serve")
