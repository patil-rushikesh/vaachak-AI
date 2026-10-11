"""Additive, transactional migrations. Never infer missing legacy evidence."""

import sqlite3

VERSION = 1


def migrate(conn: sqlite3.Connection):
    conn.execute(
        "CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
    )
    if conn.execute(
        "SELECT 1 FROM schema_migrations WHERE version=?", (VERSION,)
    ).fetchone():
        return
    columns = {
        "users": {
            "timezone": "TEXT NOT NULL DEFAULT 'UTC'",
            "language": "TEXT NOT NULL DEFAULT 'en'",
            "research_consent": "INTEGER NOT NULL DEFAULT 0",
        },
        "classes": {"archived": "INTEGER NOT NULL DEFAULT 0"},
        "courses": {"archived": "INTEGER NOT NULL DEFAULT 0"},
        "assignments": {
            "archived": "INTEGER NOT NULL DEFAULT 0",
            "revision": "INTEGER NOT NULL DEFAULT 1",
        },
        "lessons": {
            "archived": "INTEGER NOT NULL DEFAULT 0",
            "revision": "INTEGER NOT NULL DEFAULT 1",
        },
        "attempts": {
            "content_version": "INTEGER NOT NULL DEFAULT 0",
            "item_snapshot": "TEXT NOT NULL DEFAULT '{}'",
            "input_mode": "TEXT NOT NULL DEFAULT 'legacy_unknown'",
            "transcript_origin": "TEXT NOT NULL DEFAULT 'legacy_unknown'",
            "rubric_version": "TEXT NOT NULL DEFAULT 'legacy_unknown'",
            "retry_of_attempt_id": "INTEGER REFERENCES attempts(id) ON DELETE SET NULL",
            "disputed": "INTEGER NOT NULL DEFAULT 0",
            "skill_ids": "TEXT NOT NULL DEFAULT '[]'",
        },
    }
    try:
        conn.execute("BEGIN IMMEDIATE")
        for table, additions in columns.items():
            have = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
            for column, spec in additions.items():
                if column not in have:
                    conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {spec}")
        for statement in [
            """CREATE TABLE submissions(user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            client_uuid TEXT NOT NULL, request_hash TEXT NOT NULL, status TEXT NOT NULL,
            attempt_id INTEGER REFERENCES attempts(id) ON DELETE SET NULL, error_code TEXT,
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY(user_id,client_uuid))""",
            """CREATE TABLE insight_actions(id INTEGER PRIMARY KEY, class_id INTEGER NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
            student_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, reason TEXT NOT NULL,
            status TEXT NOT NULL, snooze_until TEXT, evidence_id INTEGER NOT NULL DEFAULT 0,
            assignment_id INTEGER REFERENCES assignments(id) ON DELETE SET NULL, updated_at TEXT NOT NULL,
            UNIQUE(class_id,student_id,reason))""",
            """CREATE TABLE reset_tokens(token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            expires_at TEXT NOT NULL)""",
            """CREATE TABLE rate_limits(bucket TEXT NOT NULL, window INTEGER NOT NULL, count INTEGER NOT NULL,
            PRIMARY KEY(bucket,window))""",
            """CREATE TABLE privacy_events(id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
            action TEXT NOT NULL, created_at TEXT NOT NULL)""",
            """CREATE INDEX ix_submissions_status ON submissions(status,updated_at)""",
        ]:
            conn.execute(statement)
        conn.execute("INSERT INTO schema_migrations(version) VALUES(?)", (VERSION,))
        conn.commit()
    except Exception:
        conn.rollback()
        raise
