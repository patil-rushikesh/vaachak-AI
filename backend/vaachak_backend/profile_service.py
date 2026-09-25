"""Optional, user-entered learning context. Never infer accent or location.

Profile metadata identifies the most recent editor, not an inferred identity.
Audio captures immutable context at upload time; grading does not use it.
"""
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy.dialects.postgresql import insert as postgres_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert

from .db import now
from .domain_models import StudentProfile, TeacherProfile

PROFILE_FIELDS = ("country", "state_region", "city", "first_language", "target_accent")


class LearningProfileInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid", strict=True)
    country: str = Field(default="", max_length=100)
    state_region: str = Field(default="", max_length=100)
    city: str = Field(default="", max_length=100)
    first_language: str = Field(default="", max_length=100)
    target_accent: str = Field(default="", max_length=100)

    @field_validator("*", mode="before")
    @classmethod
    def portable_text(cls, value):
        if isinstance(value, str) and ("\x00" in value or any(0xD800 <= ord(char) <= 0xDFFF for char in value)):
            raise ValueError("Profile text must not contain NUL or invalid Unicode characters")
        return value


class ProfileUpdateInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    learning_profile: LearningProfileInput


def _model(role):
    if role == "teacher":
        return TeacherProfile, "teacher_id"
    if role == "student":
        return StudentProfile, "student_id"
    raise ValueError("Unsupported profile role")


def profile_view(session, role, actor_id):
    model, _ = _model(role)
    row = session.get(model, actor_id, populate_existing=True)
    if row is None:
        return {**dict.fromkeys(PROFILE_FIELDS, ""), "provenance": "not_provided", "entered_by": None, "updated_at": None}
    return {**{field: getattr(row, field) for field in PROFILE_FIELDS},
            "provenance": "self_reported" if row.entered_by == "self" else "teacher_entered",
            "entered_by": row.entered_by, "updated_at": row.updated_at}


def update_profile(session, role, actor_id, profile, *, entered_by):
    """Update supplied columns only, atomically merging concurrent partial edits.

    The caller owns the transaction so account/profile creation and rollback stay
    together. Both supported database engines offer an atomic upsert.
    """
    if entered_by not in {"self", "teacher"} or (role == "teacher" and entered_by != "self"):
        raise ValueError("Invalid profile editor")
    changes = profile.model_dump(exclude_unset=True)
    if not changes:
        return profile_view(session, role, actor_id)
    model, key = _model(role)
    insert = sqlite_insert if session.bind.dialect.name == "sqlite" else postgres_insert
    updates = {**changes, "entered_by": entered_by, "updated_at": now()}
    # Supply blank defaults only for a brand-new row; conflict updates include
    # explicit fields only, so omissions never clear other saved preferences.
    values = {**dict.fromkeys(PROFILE_FIELDS, ""), key: actor_id, **updates}
    session.execute(insert(model).values(**values).on_conflict_do_update(index_elements=[key], set_=updates))
    return profile_view(session, role, actor_id)


def capture_learning_context(session, role, actor_id):
    return {"learning_profile": profile_view(session, role, actor_id), "recorded_at": now()}
