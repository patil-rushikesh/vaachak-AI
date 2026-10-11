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
        6,
        [
            "CREATE TABLE knowledge_units(id TEXT PRIMARY KEY, skill_code TEXT NOT NULL, level TEXT NOT NULL DEFAULT 'A1', language TEXT NOT NULL DEFAULT 'en', title TEXT NOT NULL, body TEXT NOT NULL, example TEXT, source TEXT NOT NULL DEFAULT 'Vaachak reviewed', owner_id INTEGER REFERENCES users(id) ON DELETE SET NULL, visibility TEXT NOT NULL DEFAULT 'public', status TEXT NOT NULL DEFAULT 'approved', version INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL)",
            "CREATE INDEX ix_knowledge_skill ON knowledge_units(skill_code,status,visibility)",
        ],
    ),
    (
        5,
        [
            "CREATE TABLE generation_jobs(id TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, request_hash TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL, items TEXT NOT NULL DEFAULT '[]', lease_until TEXT, tries INTEGER NOT NULL DEFAULT 0, error_code TEXT, created_at TEXT NOT NULL, model TEXT)",
            "CREATE INDEX ix_generation_pending ON generation_jobs(status,created_at)",
        ],
    ),
    (
        7,
        [
            "ALTER TABLE knowledge_units ADD COLUMN reviewed_by INTEGER REFERENCES users(id) ON DELETE SET NULL",
            "ALTER TABLE knowledge_units ADD COLUMN reviewed_at TEXT",
            "ALTER TABLE knowledge_units ADD COLUMN published_at TEXT",
            # Previous teacher notes were auto-approved, without a recorded review.
            "UPDATE knowledge_units SET status='draft' WHERE owner_id IS NOT NULL",
            "DELETE FROM knowledge_units WHERE owner_id IS NULL AND (visibility='private' OR source='Teacher note')",
            "UPDATE knowledge_units SET status='published',reviewed_at=created_at,published_at=created_at WHERE owner_id IS NULL AND visibility='public' AND status='approved'",
            "CREATE TRIGGER erase_owned_knowledge BEFORE DELETE ON users BEGIN DELETE FROM knowledge_units WHERE owner_id=OLD.id; END",
            # Historical numeric storage stays compatible; only eligible rows enter progress.
            "CREATE VIEW scored_attempts AS SELECT * FROM attempts WHERE COALESCE(json_extract(result, '$.evaluation_status'), 'scored')='scored'",
            # Repair personal sessions completed by older G1 unscored submissions.
            "UPDATE practice_sessions SET position=COALESCE((SELECT min(CAST(j.key AS INTEGER)) FROM json_each(practice_sessions.items) j WHERE NOT EXISTS(SELECT 1 FROM scored_attempts a WHERE a.practice_session_id=practice_sessions.id AND a.item_index=CAST(j.key AS INTEGER))),json_array_length(items)),revision=revision+1 WHERE id IN (SELECT practice_session_id FROM attempts WHERE json_extract(result,'$.evaluation_status')='unscored')",
            "UPDATE practice_sessions SET completed=(position>=json_array_length(items)) WHERE id IN (SELECT practice_session_id FROM attempts WHERE json_extract(result,'$.evaluation_status')='unscored')",
        ],
    ),
]


def migrate(conn):
    for version, statements in sorted(MIGRATIONS):
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
