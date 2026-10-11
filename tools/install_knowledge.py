#!/usr/bin/env python3
"""Install the starter knowledge base into VAACHAK_DATA without resetting user data."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "classroom_web/server"))
import db

if __name__ == "__main__":
    db.init()
    with db.connect() as conn:
        count = conn.execute("SELECT count(*) FROM knowledge_units WHERE id LIKE 'builtin-%'").fetchone()[0]
    print(f"Starter curriculum available: {count} units. Existing user data preserved.")
