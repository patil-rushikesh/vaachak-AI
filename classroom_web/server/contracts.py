"""Stable response contracts. Extra additive fields remain backwards compatible."""

from pydantic import BaseModel, ConfigDict, JsonValue
from typing import Literal


class Response(BaseModel):
    model_config = ConfigDict(extra="allow")


class Ok(Response):
    ok: bool


class User(Response):
    id: int
    name: str
    email: str
    role: Literal["teacher", "student", "learner"]


class Auth(Response):
    token: str
    user: User


class Class(Response):
    id: int
    name: str
    teacher: str
    students: int


class Code(Response):
    code: str


class Recording(Response):
    id: int
    title: str
    duration_ms: int


class Assignment(Response):
    id: int
    class_id: int
    title: str
    item_count: int
    targeted: bool


class Language(Response):
    code: str
    name: str
    sets: list[dict[str, JsonValue]]


class PracticeSet(Response):
    id: str
    title: str
    items: list[dict[str, JsonValue]]
    best: dict[str, int]


class Attempt(Response):
    id: int
    transcript: str
    score: int | None
    accuracy: int | None
    kind: Literal["read", "free", "build", "choice", "fill", "listen"]
    tips: list[str]
    input_mode: str
    transcript_origin: str
    content_version: int
    item_snapshot: dict[str, JsonValue]
    skill_ids: list[str]
    disputed: bool
    has_audio: bool
    rubric_version: str
    # G1 fair feedback (optional; present on fresh evaluations)
    evaluation_status: str = "scored"
    evidence_eligible: bool = True
    uncertainty_reasons: list[str] = []
    basis: str | None = None
    feedback_version: str | None = None
    normalization_version: str | None = None
    sources: list[dict] = []


class History(Response):
    items: list[Attempt]
    next_cursor: int | None


class Submission(Response):
    client_uuid: str
    status: Literal["processing", "completed", "failed", "interrupted"]
    attempt_id: int | None
    error_code: str | None


class Stats(Response):
    attempts: int
    avg_score: float | None


class Performance(Response):
    students: list[dict[str, JsonValue]]
    class_avg: float | None


class StudentDetail(Response):
    student: dict[str, JsonValue]
    stats: Stats
    recent: list[dict[str, JsonValue]]


class Attention(Response):
    rows: list[dict[str, JsonValue]]


class Grid(Response):
    skills: list[dict[str, JsonValue]]
    rows: list[dict[str, JsonValue]]


class Draft(Response):
    items: list[dict[str, JsonValue]]
    asked_for: int


class Course(Response):
    id: int
    title: str
    level: str
    status: str


class CourseList(Response):
    mine: list[Course]
    available: list[Course]


class Unit(Response):
    id: int
    title: str
    lessons: list[dict[str, JsonValue]]


class LessonWrite(Response):
    id: int
    item_count: int


class Lesson(Response):
    id: int
    title: str
    items: list[dict[str, JsonValue]]
    mode: str


class Progress(Response):
    learners: list[dict[str, JsonValue]]
    lessons: list[dict[str, JsonValue]]


class Review(Response):
    items: list[dict[str, JsonValue]]
    title: str
    weak_skills: list[dict[str, JsonValue]]


class Preferences(Response):
    timezone: str
    language: str
    research_consent: bool


class Export(Response):
    profile: dict[str, JsonValue]
    attempts: list[Attempt]
    enrollments: list[dict[str, JsonValue]]


class KnowledgeUnit(Response):
    id: str
    skill_code: str
    title: str
    body: str
    example: str | None
    level: str
    language: str
    source: str
    visibility: Literal["private", "public"]
    status: Literal["draft", "approved", "published", "withdrawn"]
    version: int
    can_manage: bool
    reviewed_by: int | None
    reviewed_at: str | None
    published_at: str | None


class KnowledgeList(Response):
    units: list[KnowledgeUnit]


class KnowledgeCreated(KnowledgeUnit):
    pass


class Items(Response):
    items: list[dict[str, JsonValue]]


class ErrorDetail(BaseModel):
    code: str
    message: str
    request_id: str


class Error(BaseModel):
    detail: str
    error: ErrorDetail
    fields: list[dict[str, JsonValue]] | None = None


ERRORS = {
    status: {"model": Error}
    for status in (400, 401, 403, 404, 409, 413, 415, 422, 429, 500, 502, 503)
}
