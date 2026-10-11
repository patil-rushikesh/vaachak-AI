#!/usr/bin/env python3
"""Local operator CLI. Run with access to the deployed data volume, never as an HTTP admin API."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "classroom_web/server"))
import db


def backup(destination):
    destination = Path(destination)
    if destination.exists():
        raise ValueError("Backup destination already exists.")
    destination.mkdir(parents=True, mode=0o700)
    conn = db.connect()
    try:
        # Writer lock held while a separate reader takes the consistent database snapshot.
        conn.execute("BEGIN IMMEDIATE")
        with (
            db.connect() as source,
            sqlite3.connect(destination / "classroom.db") as target,
        ):
            source.backup(target)
        shutil.copytree(db.data_dir() / "audio", destination / "audio")
        manifest = {
            str(p.relative_to(destination)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in destination.rglob("*")
            if p.is_file()
        }
        (destination / "manifest.json").write_text(json.dumps(manifest, indent=2))
        for p in destination.rglob("*"):
            if p.is_file():
                p.chmod(0o600)
    finally:
        conn.rollback()
        conn.close()
    return destination


def restore(source, destination):
    source, destination = Path(source), Path(destination)
    if destination.exists() and any(destination.iterdir()):
        raise ValueError("Restore requires an empty destination and a stopped server.")
    manifest = json.loads((source / "manifest.json").read_text())
    for name, expected in manifest.items():
        candidate = (source / name).resolve()
        if (
            not candidate.is_relative_to(source.resolve())
            or hashlib.sha256(candidate.read_bytes()).hexdigest() != expected
        ):
            raise ValueError("Backup integrity check failed.")
    if "classroom.db" not in manifest:
        raise ValueError("Backup has no database.")
    # Restore only verified manifest members, never unlisted files or links.
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name in manifest:
        source_file = source / name
        if source_file.is_symlink():
            raise ValueError("Symlinks are not supported in backups.")
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copyfile(source_file, target)
        target.chmod(0o600)
    (destination / "audio").mkdir(exist_ok=True, mode=0o700)
    with sqlite3.connect(destination / "classroom.db") as conn:
        if conn.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("Database integrity check failed.")
    return destination


def cleanup(days=30):
    if days < 1:
        raise ValueError("Retention must be at least one day.")
    with db.connect() as conn:
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
        expired = [
            r[0]
            for r in conn.execute(
                "SELECT audio_file FROM attempts WHERE audio_file IS NOT NULL AND datetime(created_at)<datetime(?)",
                (cutoff,),
            )
        ]
        conn.execute(
            "UPDATE attempts SET audio_file=NULL,audio_mime=NULL WHERE audio_file IS NOT NULL AND datetime(created_at)<datetime(?)",
            (cutoff,),
        )
        conn.execute(
            "DELETE FROM reset_tokens WHERE expires_at<?",
            (datetime.now(timezone.utc).isoformat(),),
        )
        conn.execute(
            "DELETE FROM sessions WHERE expires_at<?",
            (datetime.now(timezone.utc).isoformat(),),
        )
        conn.execute(
            "DELETE FROM rate_limits WHERE window < ?",
            (int(datetime.now(timezone.utc).timestamp()) // 60 - 1440,),
        )
        conn.commit()
        live = {
            r[0]
            for r in conn.execute(
                "SELECT audio_file FROM attempts WHERE audio_file IS NOT NULL UNION SELECT filename FROM recordings"
            )
        }
    count = 0
    for p in (db.data_dir() / "audio").iterdir():
        # Leave recent in-flight files alone. Expired referenced files can be removed now.
        if (
            p.is_file()
            and p.name not in live
            and (
                p.name in expired
                or p.stat().st_mtime < datetime.now().timestamp() - 86400
            )
        ):
            p.unlink()
            count += 1
    return {"removed_audio_files": count}


def issue_reset(email, output):
    with db.connect() as conn:
        user = conn.execute(
            "SELECT id FROM users WHERE email=?", (email.strip().lower(),)
        ).fetchone()
        if not user:
            raise ValueError("Account not found.")
        token = secrets.token_urlsafe(32)
        # Exclusive creation prevents overwrite or symlink attacks. Token is never printed.
        fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(token + "\n")
        conn.execute("DELETE FROM reset_tokens WHERE user_id=?", (user["id"],))
        conn.execute(
            "INSERT INTO reset_tokens VALUES(?,?,?)",
            (
                hashlib.sha256(token.encode()).hexdigest(),
                user["id"],
                (datetime.now(timezone.utc) + timedelta(minutes=20)).isoformat(),
            ),
        )
        conn.commit()
    return {"reset_token_file": str(output), "expires_minutes": 20}


def transfer(old_id, new_id):
    with db.connect() as conn:
        for uid in (old_id, new_id):
            if not conn.execute(
                "SELECT 1 FROM users WHERE id=? AND role='teacher'", (uid,)
            ).fetchone():
                raise ValueError("Both accounts must be instructors.")
        for table in ("classes", "courses", "assignments", "recordings"):
            conn.execute(
                f"UPDATE {table} SET teacher_id=? WHERE teacher_id=?", (new_id, old_id)
            )
        conn.commit()
    return {"transferred": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("migrate")
    b = sub.add_parser("backup")
    b.add_argument("destination")
    r = sub.add_parser("restore")
    r.add_argument("source")
    r.add_argument("destination")
    c = sub.add_parser("cleanup")
    c.add_argument("--audio-days", type=int, default=30)
    r = sub.add_parser("issue-reset")
    r.add_argument("email")
    r.add_argument("--output", required=True)
    t = sub.add_parser("transfer")
    t.add_argument("old_id", type=int)
    t.add_argument("new_id", type=int)
    args = parser.parse_args()
    if args.command == "restore":
        result = restore(args.source, args.destination)
    else:
        if args.command != "backup":
            db.init()
        if args.command == "migrate":
            result = {"migrated": True}
        elif args.command == "backup":
            result = backup(args.destination)
        elif args.command == "cleanup":
            result = cleanup(args.audio_days)
        elif args.command == "issue-reset":
            result = issue_reset(args.email, args.output)
        elif args.command == "transfer":
            result = transfer(args.old_id, args.new_id)
    print(json.dumps(result, default=str))


if __name__ == "__main__":
    main()
