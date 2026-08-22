#!/usr/bin/env python3
"""Hermes cloud runtime: memory restore, periodic HF backup, health endpoint."""
import io
import logging
import os
import shutil
import sqlite3
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
INTERVAL = int(os.environ.get("BACKUP_INTERVAL", "900"))

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


def backup_loop() -> None:
    tmp = Path("/tmp/hermes-backup.tar.gz")
    time.sleep(60)
    while True:
        if TOKEN and HERMES_HOME.exists():
            try:
                build_snapshot(tmp)
                upload_backup(tmp)
                log.info("memory backup uploaded (%.1f MB)", tmp.stat().st_size / 1e6)
                tmp.unlink(missing_ok=True)
            except Exception as exc:  # noqa: BLE001
                log.warning("backup failed: %s", exc)
        time.sleep(INTERVAL)


class HealthHandler(BaseHTTPRequestHandler):
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
    server = HTTPServer(("0.0.0.0", port), HealthHandler)
    log.info("health endpoint listening on :%s", port)
    server.serve_forever()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "restore":
        restore_from_hub()
    elif cmd == "serve":
        serve_health()
    else:
        print(f"usage: {sys.argv[0]} restore|serve")
