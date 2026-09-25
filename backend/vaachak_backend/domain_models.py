"""Classroom and learning records. Assignment content and recipients are frozen."""
from sqlalchemy import JSON, CheckConstraint, ForeignKey, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base, new_id, now


class Classroom(Base):
    __tablename__ = "classrooms"
    __table_args__ = (UniqueConstraint("teacher_id", "school_name", "name", "postal_code", name="uq_teacher_classroom"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    teacher_id: Mapped[str] = mapped_column(ForeignKey("teachers.id"), index=True)
    school_name: Mapped[str] = mapped_column(String(200))
    name: Mapped[str] = mapped_column(String(100))
    postal_code: Mapped[str] = mapped_column(String(20))
    join_code: Mapped[str] = mapped_column(String(16), unique=True)
    created_at: Mapped[str] = mapped_column(default=now)


class Student(Base):
    __tablename__ = "students"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    teacher_id: Mapped[str] = mapped_column(ForeignKey("teachers.id"), index=True)
    classroom_id: Mapped[str] = mapped_column(ForeignKey("classrooms.id"), index=True)
    display_name: Mapped[str] = mapped_column(String(100))
    login_name: Mapped[str] = mapped_column(String(80), unique=True)
    password_hash: Mapped[str]
    created_at: Mapped[str] = mapped_column(default=now)


class ProblemContent(Base):
    __tablename__ = "problem_content"
    problem_id: Mapped[str] = mapped_column(ForeignKey("problems.id"), primary_key=True)
    payload: Mapped[dict] = mapped_column(JSON, default=dict)


class Assignment(Base):
    __tablename__ = "assignments"
    __table_args__ = (CheckConstraint("(classroom_id IS NULL) <> (student_id IS NULL)", name="ck_one_assignment_target"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    teacher_id: Mapped[str] = mapped_column(ForeignKey("teachers.id"), index=True)
    classroom_id: Mapped[str | None] = mapped_column(ForeignKey("classrooms.id"), nullable=True)
    student_id: Mapped[str | None] = mapped_column(ForeignKey("students.id"), nullable=True)
    title: Mapped[str] = mapped_column(String(200))
    target_label: Mapped[str] = mapped_column(String(400))
    created_at: Mapped[str] = mapped_column(default=now)


class AssignmentItem(Base):
    __tablename__ = "assignment_items"
    __table_args__ = (UniqueConstraint("assignment_id", "problem_id", name="uq_assignment_problem"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    assignment_id: Mapped[str] = mapped_column(ForeignKey("assignments.id"), index=True)
    problem_id: Mapped[str] = mapped_column(ForeignKey("problems.id"))
    recording_id: Mapped[str | None] = mapped_column(ForeignKey("reference_recordings.id"), nullable=True)
    position: Mapped[int]
    snapshot: Mapped[dict] = mapped_column(JSON)


class AssignmentRecipient(Base):
    __tablename__ = "assignment_recipients"
    assignment_id: Mapped[str] = mapped_column(ForeignKey("assignments.id"), primary_key=True)
    student_id: Mapped[str] = mapped_column(ForeignKey("students.id"), primary_key=True, index=True)


class Attempt(Base):
    __tablename__ = "student_attempts"
    __table_args__ = (
        UniqueConstraint("student_id", "request_id", name="uq_student_attempt_request"),
        CheckConstraint("score IS NULL OR (score >= 0 AND score <= 1)", name="ck_attempt_score"),
        CheckConstraint("status IN ('pending', 'completed', 'needs_review', 'failed')", name="ck_attempt_status"),
    )
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    assignment_id: Mapped[str] = mapped_column(ForeignKey("assignments.id"), index=True)
    item_id: Mapped[str] = mapped_column(ForeignKey("assignment_items.id"), index=True)
    student_id: Mapped[str] = mapped_column(ForeignKey("students.id"), index=True)
    request_id: Mapped[str] = mapped_column(String(36))
    request_hash: Mapped[str] = mapped_column(String(64))
    answer: Mapped[object | None] = mapped_column(JSON, nullable=True)
    status: Mapped[str] = mapped_column(default="pending")
    score: Mapped[float | None] = mapped_column(nullable=True)
    feedback: Mapped[str] = mapped_column(default="Analysis is queued.")
    result: Mapped[dict] = mapped_column(JSON, default=dict)
    original_sha256: Mapped[str | None] = mapped_column(nullable=True)
    normalized_sha256: Mapped[str | None] = mapped_column(nullable=True)
    original_bytes: Mapped[int | None] = mapped_column(nullable=True)
    measurements: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    created_at: Mapped[str] = mapped_column(default=now)
    analyzed_at: Mapped[str | None] = mapped_column(nullable=True)
    reviewed_at: Mapped[str | None] = mapped_column(nullable=True)


class AttemptReview(Base):
    __tablename__ = "attempt_reviews"
    __table_args__ = (CheckConstraint("score >= 0 AND score <= 1", name="ck_review_score"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    attempt_id: Mapped[str] = mapped_column(ForeignKey("student_attempts.id"), index=True)
    teacher_id: Mapped[str] = mapped_column(ForeignKey("teachers.id"))
    score: Mapped[float]
    feedback: Mapped[str]
    created_at: Mapped[str] = mapped_column(default=now)


class AssignmentRequest(Base):
    """Optional create-assignment idempotency; separate table preserves existing prototype schema."""
    __tablename__ = "assignment_requests"
    teacher_id: Mapped[str] = mapped_column(ForeignKey("teachers.id"), primary_key=True)
    request_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    request_hash: Mapped[str] = mapped_column(String(64))
    assignment_id: Mapped[str] = mapped_column(ForeignKey("assignments.id"), unique=True)


class TeacherProfile(Base):
    """Optional user-entered context, separate from existing account schema."""
    __tablename__ = "teacher_profiles"
    teacher_id: Mapped[str] = mapped_column(ForeignKey("teachers.id"), primary_key=True)
    country: Mapped[str] = mapped_column(String(100), default="")
    state_region: Mapped[str] = mapped_column(String(100), default="")
    city: Mapped[str] = mapped_column(String(100), default="")
    first_language: Mapped[str] = mapped_column(String(100), default="")
    target_accent: Mapped[str] = mapped_column(String(100), default="")
    entered_by: Mapped[str] = mapped_column(String(16))
    updated_at: Mapped[str] = mapped_column(default=now)


class StudentProfile(Base):
    __tablename__ = "student_profiles"
    student_id: Mapped[str] = mapped_column(ForeignKey("students.id"), primary_key=True)
    country: Mapped[str] = mapped_column(String(100), default="")
    state_region: Mapped[str] = mapped_column(String(100), default="")
    city: Mapped[str] = mapped_column(String(100), default="")
    first_language: Mapped[str] = mapped_column(String(100), default="")
    target_accent: Mapped[str] = mapped_column(String(100), default="")
    entered_by: Mapped[str] = mapped_column(String(16))
    updated_at: Mapped[str] = mapped_column(default=now)
