import os
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from sqlalchemy import JSON, ForeignKey, String, create_engine, event
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker


def new_id():
    return str(uuid4())


def now():
    return datetime.now(timezone.utc).isoformat()


class Base(DeclarativeBase):
    pass


class Teacher(Base):
    __tablename__ = "teachers"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    email: Mapped[str] = mapped_column(String(254), unique=True)
    password_hash: Mapped[str]


class LoginSession(Base):
    __tablename__ = "teacher_sessions"
    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    teacher_id: Mapped[str] = mapped_column(ForeignKey("teachers.id"))
    expires_at: Mapped[float]


class StudentSession(Base):
    __tablename__ = "student_sessions"
    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    student_id: Mapped[str] = mapped_column(ForeignKey("students.id"))
    expires_at: Mapped[float]


class Problem(Base):
    __tablename__ = "problems"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    teacher_id: Mapped[str] = mapped_column(ForeignKey("teachers.id"), index=True)
    title: Mapped[str] = mapped_column(String(200))
    kind: Mapped[str] = mapped_column(default="read_aloud")
    expected_text: Mapped[str]
    teaching_notes: Mapped[str]
    language: Mapped[str] = mapped_column(default="en")
    created_at: Mapped[str] = mapped_column(default=now)


class Recording(Base):
    __tablename__ = "reference_recordings"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    problem_id: Mapped[str] = mapped_column(ForeignKey("problems.id"), index=True)
    original_sha256: Mapped[str]
    normalized_sha256: Mapped[str]
    original_bytes: Mapped[int]
    duration_seconds: Mapped[float]
    measurements: Mapped[dict] = mapped_column(JSON)
    created_at: Mapped[str] = mapped_column(default=now)


class Analysis(Base):
    __tablename__ = "reference_analyses"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    recording_id: Mapped[str] = mapped_column(ForeignKey("reference_recordings.id"), index=True)
    model_id: Mapped[str]
    status: Mapped[str] = mapped_column(default="running")
    result: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[str] = mapped_column(default=now)


def connect(database_url=None, data_dir=None):
    # Register additive domain tables before schema creation (no changes to legacy tables).
    from . import domain_models  # noqa: F401

    directory = Path(data_dir or os.getenv("VAACHAK_DATA_DIR", "data")).resolve()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    url = database_url or os.getenv("DATABASE_URL") or f"sqlite:///{directory / 'vaachak.sqlite3'}"
    kwargs = {"connect_args": {"check_same_thread": False, "timeout": 30}} if url.startswith("sqlite") else {}
    engine = create_engine(url, pool_pre_ping=True, **kwargs)
    if url.startswith("sqlite"):
        @event.listens_for(engine, "connect")
        def enable_foreign_keys(connection, _):
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA busy_timeout=30000")
            connection.execute("PRAGMA journal_mode=WAL")
    # Prototype bootstrap only. Introduce versioned migrations before schema changes.
    Base.metadata.create_all(engine)
    return engine, sessionmaker(engine, expire_on_commit=False), directory
