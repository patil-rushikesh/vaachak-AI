import os
import sqlite3
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS users(
  id INTEGER PRIMARY KEY, role TEXT NOT NULL CHECK(role IN('teacher','student','learner')),
  name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, pw_hash TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS sessions(
  token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS classes(
  id INTEGER PRIMARY KEY, teacher_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name TEXT NOT NULL, standard TEXT, section TEXT, pincode TEXT, state TEXT, district TEXT,
  language TEXT NOT NULL DEFAULT 'en', academic_year TEXT, code TEXT NOT NULL UNIQUE,
  color INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS enrollments(
  class_id INTEGER NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
  student_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  joined_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(class_id,student_id));
CREATE TABLE IF NOT EXISTS recordings(
  id INTEGER PRIMARY KEY, teacher_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL, filename TEXT NOT NULL, mime TEXT NOT NULL, duration_ms INTEGER NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS assignments(
  id INTEGER PRIMARY KEY, class_id INTEGER NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
  teacher_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  student_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
  recording_id INTEGER REFERENCES recordings(id) ON DELETE SET NULL,
  title TEXT NOT NULL, instructions TEXT, due_at TEXT, items TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS attempts(
  id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  assignment_id INTEGER REFERENCES assignments(id) ON DELETE CASCADE, set_id TEXT,
  lesson_id INTEGER REFERENCES lessons(id) ON DELETE CASCADE,
  item_index INTEGER NOT NULL, kind TEXT NOT NULL, target TEXT, transcript TEXT NOT NULL,
  score INTEGER NOT NULL, accuracy INTEGER, result TEXT NOT NULL, audio_file TEXT, audio_mime TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE INDEX IF NOT EXISTS ix_attempts_user ON attempts(user_id, created_at);
CREATE INDEX IF NOT EXISTS ix_attempts_assignment ON attempts(assignment_id, user_id);
CREATE INDEX IF NOT EXISTS ix_assignments_class ON assignments(class_id, created_at);
CREATE TABLE IF NOT EXISTS courses(
  id INTEGER PRIMARY KEY, teacher_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL, summary TEXT, level TEXT NOT NULL DEFAULT 'A1', language TEXT NOT NULL DEFAULT 'en',
  visibility TEXT NOT NULL DEFAULT 'public' CHECK(visibility IN('public','classes')),
  sequential INTEGER NOT NULL DEFAULT 1, status TEXT NOT NULL DEFAULT 'draft' CHECK(status IN('draft','published')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS units(
  id INTEGER PRIMARY KEY, course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
  position INTEGER NOT NULL, title TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS lessons(
  id INTEGER PRIMARY KEY, unit_id INTEGER NOT NULL REFERENCES units(id) ON DELETE CASCADE,
  course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
  position INTEGER NOT NULL, title TEXT NOT NULL, intro TEXT,
  recording_id INTEGER REFERENCES recordings(id) ON DELETE SET NULL, items TEXT NOT NULL DEFAULT '[]');
CREATE TABLE IF NOT EXISTS course_enrollments(
  course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(course_id,user_id));
CREATE TABLE IF NOT EXISTS class_courses(
  class_id INTEGER NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
  course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
  assigned_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(class_id,course_id));
CREATE TABLE IF NOT EXISTS insight_dismissals(
  class_id INTEGER NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
  student_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  reason TEXT NOT NULL, teacher_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(class_id,student_id,reason));
CREATE INDEX IF NOT EXISTS ix_units_course ON units(course_id, position);
CREATE INDEX IF NOT EXISTS ix_lessons_unit ON lessons(unit_id, position);
"""
AFTER_MIGRATION = """
CREATE INDEX IF NOT EXISTS ix_attempts_lesson ON attempts(lesson_id, user_id);
"""


def data_dir() -> Path:
    d = Path(
        os.environ.get("VAACHAK_DATA", Path(__file__).resolve().parent.parent / "data")
    )
    (d / "audio").mkdir(parents=True, exist_ok=True)
    return d


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(
        data_dir() / "classroom.db", check_same_thread=False, timeout=15
    )
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init() -> None:
    conn = connect()
    conn.executescript(SCHEMA)
    # Databases made before courses existed have no attempts.lesson_id; add it in place.
    if "lesson_id" not in {
        r["name"] for r in conn.execute("PRAGMA table_info(attempts)")
    }:
        conn.execute(
            "ALTER TABLE attempts ADD COLUMN lesson_id INTEGER REFERENCES lessons(id) ON DELETE CASCADE"
        )
    conn.executescript(AFTER_MIGRATION)
    conn.commit()
    from migrations import migrate

    migrate(conn)
    conn.close()
