"""Ordered, additive user-value schema; legacy migration v1 is immutable."""

MIGRATIONS = [
    (
        2,
        [
            "CREATE TABLE learning_profiles(user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, goal TEXT NOT NULL DEFAULT 'everyday', difficulty TEXT NOT NULL DEFAULT 'starter', weekly_goal INTEGER NOT NULL DEFAULT 3, analytics INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL)",
            "CREATE TABLE practice_sessions(id TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, request_hash TEXT NOT NULL, title TEXT NOT NULL, items TEXT NOT NULL, reason TEXT NOT NULL, position INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 1, completed INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL)",
            "CREATE INDEX ix_practice_owner ON practice_sessions(user_id,created_at)",
            "ALTER TABLE attempts ADD COLUMN practice_session_id TEXT REFERENCES practice_sessions(id) ON DELETE SET NULL",
            "CREATE TABLE teacher_drafts(id TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, payload TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1, updated_at TEXT NOT NULL)",
            "CREATE TABLE feedback_reports(id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, category TEXT NOT NULL, message TEXT NOT NULL, attempt_id INTEGER REFERENCES attempts(id) ON DELETE SET NULL, helpful INTEGER, created_at TEXT NOT NULL)",
            "CREATE TABLE product_events(id TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, name TEXT NOT NULL, created_at TEXT NOT NULL)",
            "CREATE TABLE conversations(id TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, scenario TEXT NOT NULL, turns TEXT NOT NULL DEFAULT '[]', revision INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL)",
        ],
    ),
    (
        3,
        [
            "CREATE TABLE transcriptions(id TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, audio_file TEXT, mime TEXT, transcript TEXT, status TEXT NOT NULL, expires_at TEXT NOT NULL)",
        ],
    ),
    (
        4,
        [
            "ALTER TABLE practice_sessions ADD COLUMN draft TEXT NOT NULL DEFAULT '{}'",
        ],
    ),
    (
        5,
        [
            "CREATE TABLE generation_jobs(id TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, request_hash TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL, items TEXT NOT NULL DEFAULT '[]', lease_until TEXT, tries INTEGER NOT NULL DEFAULT 0, error_code TEXT, created_at TEXT NOT NULL, model TEXT)",
            "CREATE INDEX ix_generation_pending ON generation_jobs(status,created_at)",
        ],
    ),
]


def migrate(conn):
    for version, statements in MIGRATIONS:
        conn.execute("BEGIN IMMEDIATE")
        try:
            if not conn.execute(
                "SELECT 1 FROM schema_migrations WHERE version=?", (version,)
            ).fetchone():
                for statement in statements:
                    conn.execute(statement)
                conn.execute(
                    "INSERT INTO schema_migrations(version) VALUES(?)", (version,)
                )
            conn.commit()
        except Exception:
            conn.rollback()
            raise
