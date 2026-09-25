"""Teacher and student workflows, with immutable assignment and submission evidence."""
import copy
import hashlib
import json
import logging
import math
import re
import secrets
import shutil
import tempfile
from collections import defaultdict
from pathlib import Path
from typing import Any, Literal
from uuid import UUID

from fastapi import BackgroundTasks, Depends, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from sqlalchemy import delete, func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .audio import InvalidAudio, MAX_BYTES, digest, normalize
from .db import Problem, Recording, StudentSession, Teacher, new_id, now
from .domain_models import (
    Assignment, AssignmentItem, AssignmentRecipient, AssignmentRequest, Attempt, AttemptReview,
    Classroom, ProblemContent, Student,
)
from .security import hash_password

logger = logging.getLogger(__name__)


class StrictInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid", allow_inf_nan=False)

    @model_validator(mode="before")
    @classmethod
    def portable_text(cls, value):
        # PostgreSQL text cannot contain NUL; lone surrogates cannot be UTF-8.
        # Reject these at the boundary instead of failing after a DB/file write.
        pending = [value]
        while pending:
            item = pending.pop()
            if isinstance(item, str):
                if "\x00" in item:
                    raise ValueError("Text cannot contain a null character")
                try:
                    item.encode("utf-8")
                except UnicodeEncodeError as exc:
                    raise ValueError("Text must contain valid Unicode characters") from exc
            elif isinstance(item, dict):
                pending.extend(item.keys())
                pending.extend(item.values())
            elif isinstance(item, list):
                pending.extend(item)
        return value


class ClassroomInput(StrictInput):
    school_name: str = Field(min_length=1, max_length=200)
    name: str = Field(min_length=1, max_length=100)
    postal_code: str = Field(min_length=1, max_length=20)


class StudentInput(StrictInput):
    model_config = ConfigDict(str_strip_whitespace=False, extra="forbid", allow_inf_nan=False)

    @field_validator("display_name", "login_name", mode="before")
    @classmethod
    def trim_identity_fields(cls, value):
        return value.strip() if isinstance(value, str) else value

    display_name: str = Field(min_length=1, max_length=100)
    login_name: str = Field(min_length=3, max_length=80)
    # Password whitespace is meaningful, unlike display fields.
    password: str = Field(min_length=8, max_length=256)

    @field_validator("login_name")
    @classmethod
    def normalize_login(cls, value):
        value = value.lower()
        if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{2,79}", value):
            raise ValueError("Use 3–80 letters, numbers, dots, underscores or hyphens for the login name")
        return value


class StudentPasswordInput(StrictInput):
    model_config = ConfigDict(str_strip_whitespace=False, extra="forbid", allow_inf_nan=False)
    password: str = Field(min_length=8, max_length=256)


class ProblemInput(StrictInput):
    title: str = Field(min_length=1, max_length=200)
    kind: Literal["read_aloud", "choice", "matching", "meaning"] = "read_aloud"
    expected_text: str = Field(min_length=1, max_length=5000)
    teaching_notes: str = Field(default="", max_length=5000)
    payload: dict[str, Any] = Field(default_factory=dict)

    @model_validator(mode="after")
    def validate_payload(self):
        value = self.payload
        skill = value.get("skill", "vocabulary")
        if self.kind in {"choice", "matching"} and (not isinstance(skill, str) or skill not in {"synonym", "antonym", "vocabulary"}):
            raise ValueError("Choose synonym, antonym or vocabulary as the skill")
        if self.kind == "read_aloud":
            if set(value) - {"expression"}:
                raise ValueError("Read-aloud payload accepts only expression")
            expression = value.get("expression", "")
            if not isinstance(expression, str) or len(expression) > 200:
                raise ValueError("Expression must be text up to 200 characters")
            self.payload = {"expression": expression.strip()}
        elif self.kind == "choice":
            if set(value) - {"options", "correct_option_id", "skill"}:
                raise ValueError("Unexpected choice payload field")
            options = value.get("options")
            self._validate_cards(options, ("id", "text"), 2, 12)
            if not isinstance(value.get("correct_option_id"), str) or value["correct_option_id"] not in {item["id"] for item in options}:
                raise ValueError("The correct option must be one of the options")
            self.payload = {"options": options, "correct_option_id": value["correct_option_id"], "skill": skill}
        elif self.kind == "matching":
            if set(value) - {"pairs", "skill"}:
                raise ValueError("Unexpected matching payload field")
            pairs = value.get("pairs")
            self._validate_cards(pairs, ("id", "left", "right"), 2, 12)
            self.payload = {"pairs": pairs, "skill": skill}
        elif self.kind == "meaning":
            if set(value) - {"accepted_answers", "rubric"}:
                raise ValueError("Unexpected meaning payload field")
            answers = value.get("accepted_answers")
            if not isinstance(answers, list) or not 1 <= len(answers) <= 20:
                raise ValueError("Provide between 1 and 20 accepted meanings")
            if any(not isinstance(answer, str) or not answer.strip() or len(answer) > 2000 for answer in answers):
                raise ValueError("Accepted meanings must be nonempty text up to 2000 characters")
            rubric = value.get("rubric", "")
            if not isinstance(rubric, str) or len(rubric) > 5000:
                raise ValueError("Rubric must be text up to 5000 characters")
            self.payload = {"accepted_answers": [answer.strip() for answer in answers], "rubric": rubric.strip()}
        return self

    @staticmethod
    def _validate_cards(items, keys, minimum, maximum):
        if not isinstance(items, list) or not minimum <= len(items) <= maximum:
            raise ValueError(f"Provide between {minimum} and {maximum} cards")
        for item in items:
            if not isinstance(item, dict) or set(item) != set(keys):
                raise ValueError(f"Each card requires exactly {', '.join(keys)}")
            for key in keys:
                if not isinstance(item[key], str) or not item[key].strip() or len(item[key]) > (80 if key == "id" else 500):
                    raise ValueError("Card values must be nonempty text within the size limit")
                item[key] = item[key].strip()
        for key in keys:
            if len({item[key].casefold() for item in items}) != len(items):
                raise ValueError(f"Card {key} values must be unique")


class AssignmentProblemInput(StrictInput):
    problem_id: UUID
    recording_id: UUID | None = None


class AssignmentInput(StrictInput):
    request_id: UUID | None = None
    title: str = Field(min_length=1, max_length=200)
    classroom_id: UUID | None = None
    student_id: UUID | None = None
    problems: list[AssignmentProblemInput] = Field(min_length=1, max_length=50)

    @model_validator(mode="after")
    def single_target(self):
        if (self.classroom_id is None) == (self.student_id is None):
            raise ValueError("Select exactly one classroom or student")
        if len({item.problem_id for item in self.problems}) != len(self.problems):
            raise ValueError("Each problem can occur only once in an assignment")
        return self


class AttemptInput(StrictInput):
    request_id: UUID
    answer: Any


class ReviewInput(StrictInput):
    score: float = Field(ge=0, le=1, strict=True)
    feedback: str = Field(min_length=1, max_length=5000)


def _identity(actor):
    return actor["id"] if isinstance(actor, dict) else actor


def _hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def _student_view(student):
    return {"id": student.id, "display_name": student.display_name, "login_name": student.login_name,
            "classroom_id": student.classroom_id, "created_at": student.created_at}


def _recording_view(recording):
    return {"id": recording.id, "problem_id": recording.problem_id,
            "duration_seconds": recording.duration_seconds, "measurements": recording.measurements,
            "created_at": recording.created_at, "playback_url": f"/recordings/{recording.id}/audio"}


def _classroom_view(classroom, session):
    count = session.scalar(select(func.count()).select_from(Student).where(Student.classroom_id == classroom.id))
    return {"id": classroom.id, "school_name": classroom.school_name, "name": classroom.name,
            "postal_code": classroom.postal_code, "join_code": classroom.join_code,
            "student_count": count, "created_at": classroom.created_at}


def _owned(model, identifier, teacher, session, label):
    row = session.get(model, str(identifier))
    if row is None or row.teacher_id != _identity(teacher):
        raise HTTPException(404, f"{label} not found")
    return row


def _problem_view(problem, session, include_recordings=True):
    content = session.get(ProblemContent, problem.id)
    result = {field: getattr(problem, field) for field in
              ("id", "title", "kind", "expected_text", "teaching_notes", "language", "created_at")}
    result["payload"] = content.payload if content else {}
    if include_recordings:
        result["recordings"] = [_recording_view(row) for row in session.scalars(
            select(Recording).where(Recording.problem_id == problem.id).order_by(Recording.created_at))]
    return result


def _items(assignment_id, session):
    return list(session.scalars(select(AssignmentItem).where(AssignmentItem.assignment_id == assignment_id)
                               .order_by(AssignmentItem.position)))


def _assignment_view(assignment, session):
    return {"id": assignment.id, "title": assignment.title, "target_label": assignment.target_label,
            "classroom_id": assignment.classroom_id, "student_id": assignment.student_id,
            "created_at": assignment.created_at,
            "student_count": session.scalar(select(func.count()).select_from(AssignmentRecipient).where(
                AssignmentRecipient.assignment_id == assignment.id)),
            "problem_count": session.scalar(select(func.count()).select_from(AssignmentItem).where(
                AssignmentItem.assignment_id == assignment.id))}


def _attempt_view(attempt, session, teacher=False):
    item = session.get(AssignmentItem, attempt.item_id)
    student = session.get(Student, attempt.student_id)
    result = copy.deepcopy(attempt.result)
    if not teacher and item.snapshot["kind"] == "meaning" and result.get("method") == "ai_semantic_review":
        # An unevaluated semantic model's suggestions belong only in the teacher review UI.
        for key in ("suggested_score", "classification", "explanation", "confidence"):
            result.pop(key, None)
    answer_display = attempt.answer
    if item.snapshot["kind"] == "choice":
        answer_display = next((option["text"] for option in item.snapshot["payload"]["options"] if option["id"] == attempt.answer), None)
    elif item.snapshot["kind"] == "matching" and isinstance(attempt.answer, dict):
        left = {card["id"]: card["text"] for card in item.snapshot["matching_public"]["left"]}
        right = {card["id"]: card["text"] for card in item.snapshot["matching_public"]["right"]}
        answer_display = [{"left": left.get(key, "Unknown card"), "right": right.get(value, "Unknown card")}
                          for key, value in attempt.answer.items()]
    return {"id": attempt.id, "assignment_id": attempt.assignment_id, "problem_id": attempt.item_id,
            "source_problem_id": item.problem_id, "problem_title": item.snapshot["title"],
            "kind": item.snapshot["kind"], "student_id": attempt.student_id,
            "student_name": student.display_name, "status": attempt.status, "score": attempt.score,
            "feedback": attempt.feedback, "result": result, "answer": attempt.answer, "answer_display": answer_display,
            "reference_audio_url": f"/recordings/{item.recording_id}/audio" if teacher and item.recording_id else None,
            "created_at": attempt.created_at, "analyzed_at": attempt.analyzed_at,
            "reviewed_at": attempt.reviewed_at,
            "audio_url": f"/attempts/{attempt.id}/audio" if attempt.original_sha256 else None,
            "measurements": attempt.measurements}


def _attempts(student_id, session, assignment_id=None):
    statement = select(Attempt).where(Attempt.student_id == student_id)
    if assignment_id:
        statement = statement.where(Attempt.assignment_id == assignment_id)
    return list(session.scalars(statement.order_by(Attempt.created_at.desc(), Attempt.id.desc())))


def _progress(attempts, session):
    # Every saved answer is submitted. A later pending/failed attempt supersedes
    # the older grade; otherwise dashboards silently present stale achievement.
    latest = {}
    skill_attempt_counts = defaultdict(int)
    for attempt in attempts:
        latest.setdefault(attempt.item_id, attempt)
        item = session.get(AssignmentItem, attempt.item_id)
        skill = item.snapshot["payload"].get("skill", item.snapshot["kind"])
        skill_attempt_counts[skill] += 1
    assessed = [attempt for attempt in latest.values() if attempt.status == "completed" and attempt.score is not None]
    scores = [attempt.score for attempt in assessed]
    groups = defaultdict(list)
    for attempt in latest.values():
        item = session.get(AssignmentItem, attempt.item_id)
        skill = item.snapshot["payload"].get("skill", item.snapshot["kind"])
        groups[skill].append(attempt)
    skills = []
    for skill, group in sorted(groups.items()):
        group_scores = [a.score for a in group if a.status == "completed" and a.score is not None]
        skills.append({"skill": skill, "average_score": round(sum(group_scores) / len(group_scores), 4) if group_scores else None,
                       "attempt_count": skill_attempt_counts[skill], "submitted_problems": len(group),
                       "scored_problems": len(group_scores)})
    return {"average_score": round(sum(scores) / len(scores), 4) if scores else None,
            "completed_problems": sum(a.status == "completed" for a in latest.values()), "submitted_problems": len(latest),
            "reviewed_problems": sum(a.status == "completed" for a in latest.values()),
            "pending_problems": sum(a.status == "pending" for a in latest.values()),
            "failed_problems": sum(a.status == "failed" for a in latest.values()),
            "solved_problems": sum(a.score >= .7 for a in assessed),
            "mastery_threshold": .7, "scored_problems": len(scores), "skills": skills,
            "weaknesses": [item for item in skills if item["average_score"] is not None and item["average_score"] < .7]}


def _assigned(assignment_id, student, session):
    student = _identity(student)
    if session.get(AssignmentRecipient, (str(assignment_id), student)) is None:
        raise HTTPException(404, "Assignment not found")
    return session.get(Assignment, str(assignment_id))


def _assigned_item(assignment_id, problem_id, student, session):
    _assigned(assignment_id, student, session)
    item = session.get(AssignmentItem, str(problem_id))
    if item is None or item.assignment_id != str(assignment_id):
        raise HTTPException(404, "Assigned problem not found")
    return item


def _student_problem(item):
    snapshot = item.snapshot
    payload = snapshot["payload"]
    if snapshot["kind"] == "choice":
        public = {"options": payload["options"], "skill": payload["skill"]}
    elif snapshot["kind"] == "matching":
        public = {"left": snapshot["matching_public"]["left"], "right": snapshot["matching_public"]["right"],
                  "skill": payload["skill"]}
    elif snapshot["kind"] == "meaning":
        public = {}
    else:
        public = {"expression": payload.get("expression", "")}
    return {"id": item.id, "problem_id": item.problem_id,
            "title": snapshot["title"], "kind": snapshot["kind"],
            "expected_text": snapshot["expected_text"], "teaching_notes": snapshot["teaching_notes"],
            "payload": public, "reference_audio_url": f"/student/reference-recordings/{item.recording_id}/audio"
            if item.recording_id else None}


def _make_snapshot(problem, session):
    snapshot = copy.deepcopy(_problem_view(problem, session, include_recordings=False))
    if problem.kind == "matching":
        left, right, answers = [], [], {}
        for pair in snapshot["payload"]["pairs"]:
            left_id, right_id = new_id(), new_id()
            left.append({"id": left_id, "text": pair["left"]})
            right.append({"id": right_id, "text": pair["right"]})
            answers[left_id] = right_id
        secrets.SystemRandom().shuffle(left)
        secrets.SystemRandom().shuffle(right)
        snapshot["matching_public"] = {"left": left, "right": right}
        snapshot["matching_answers"] = answers
    return snapshot


def _check_retry(session, student, request_id, request_hash):
    existing = session.scalar(select(Attempt).where(Attempt.student_id == student, Attempt.request_id == str(request_id)))
    if existing and existing.request_hash != request_hash:
        raise HTTPException(409, "This submission ID was already used with different content; use a new submission ID")
    return existing


def recover_interrupted_attempts(factory):
    """Called once at process startup: a local background job cannot survive a restart."""
    with factory() as session:
        session.execute(update(Attempt).where(Attempt.status == "pending", Attempt.reviewed_at.is_(None)).values(
            status="failed", feedback="Analysis was interrupted by a server restart. Retry analysis; your answer is saved."))
        session.commit()


def _run_analysis(factory, directory, attempt_id):
    # Load inputs, release the DB connection during slow model work, then atomically save.
    try:
        with factory() as session:
            attempt = session.get(Attempt, attempt_id)
            if attempt is None or attempt.status != "pending" or attempt.reviewed_at:
                return
            item = session.get(AssignmentItem, attempt.item_id)
            snapshot, answer, reference_id = copy.deepcopy(item.snapshot), copy.deepcopy(attempt.answer), item.recording_id
        from .speech_service import analyze_reading, evaluate_meaning
        if snapshot["kind"] == "read_aloud":
            outcome = analyze_reading(
                directory / "attempts" / attempt_id / "reference.wav", snapshot["expected_text"],
                directory / "recordings" / reference_id / "reference.wav" if reference_id else None,
            )
        else:
            payload = snapshot["payload"]
            outcome = evaluate_meaning(answer, payload["accepted_answers"], payload.get("rubric", ""))
        status = outcome.get("status")
        score = outcome.get("score")
        if status not in {"completed", "needs_review", "failed"}:
            raise ValueError("Invalid analysis status")
        if score is not None and (isinstance(score, bool) or not isinstance(score, (int, float)) or not math.isfinite(score) or not 0 <= score <= 1):
            raise ValueError("Invalid analysis score")
        if (status == "completed") != (score is not None):
            raise ValueError("Completed analysis requires a score; unfinished analysis must not issue a grade")
        result = outcome.get("result", {})
        if not isinstance(result, dict):
            raise ValueError("Analysis evidence must be an object")
        # Validate before the write: JSON/NaN errors must become retryable failures,
        # rather than leave an attempt pending forever after a model has returned.
        json.dumps(result, allow_nan=False)
        fields = {"status": status, "score": score, "feedback": str(outcome.get("feedback", ""))[:10000],
                  "result": result, "analyzed_at": now()}
    except Exception:
        logger.exception("Analysis failed for attempt %s", attempt_id)
        fields = {"status": "failed", "score": None,
                  "feedback": "Automatic analysis could not finish. Your submission is saved; retry analysis or ask your teacher to review it.",
                  "result": {"analysis_error": True}, "analyzed_at": now()}
    try:
        with factory() as session:
            session.execute(update(Attempt).where(Attempt.id == attempt_id, Attempt.status == "pending", Attempt.reviewed_at.is_(None)).values(**fields))
            session.commit()
    except Exception:
        logger.exception("Could not persist analysis for attempt %s", attempt_id)


def install_domain_routes(app, ctx):
    get = (lambda name: ctx[name]) if isinstance(ctx, dict) else (lambda name: getattr(ctx, name))
    db, current_teacher, current_student, current_actor = (get(name) for name in ("db", "current_teacher", "current_student", "current_actor"))
    directory, factory = Path(get("directory")), get("factory")
    attempt_dir = directory / "attempts"
    attempt_dir.mkdir(exist_ok=True, mode=0o700)

    def schedule_analysis(background_tasks, identifier):
        queue = getattr(app.state, "analysis_queue", None)
        if queue is not None:
            queue.wake()
        else:
            # Explicit deterministic test mode; production lifespan installs
            # the durable single worker before accepting requests.
            background_tasks.add_task(_run_analysis, factory, directory, identifier)

    @app.get("/teacher/classrooms")
    def classrooms(teacher=Depends(current_teacher), session: Session = Depends(db)):
        return [_classroom_view(row, session) for row in session.scalars(select(Classroom).where(
            Classroom.teacher_id == _identity(teacher)).order_by(Classroom.created_at.desc()))]

    @app.post("/teacher/classrooms", status_code=201)
    def create_classroom(body: ClassroomInput, teacher=Depends(current_teacher), session: Session = Depends(db)):
        classroom = Classroom(teacher_id=_identity(teacher), join_code=secrets.token_hex(4).upper(), **body.model_dump())
        session.add(classroom)
        try:
            session.commit()
        except IntegrityError:
            session.rollback()
            raise HTTPException(409, "A classroom with this school, class and postal code already exists")
        return _classroom_view(classroom, session)

    @app.get("/teacher/classrooms/{classroom_id}")
    def classroom_detail(classroom_id: UUID, teacher=Depends(current_teacher), session: Session = Depends(db)):
        classroom = _owned(Classroom, classroom_id, teacher, session, "Classroom")
        value = _classroom_view(classroom, session)
        value["students"] = [_student_view(student) for student in session.scalars(select(Student).where(
            Student.classroom_id == classroom.id).order_by(Student.display_name, Student.id))]
        return value

    @app.post("/teacher/classrooms/{classroom_id}/students", status_code=201)
    def create_student(classroom_id: UUID, body: StudentInput, teacher=Depends(current_teacher), session: Session = Depends(db)):
        classroom = _owned(Classroom, classroom_id, teacher, session, "Classroom")
        student = Student(teacher_id=_identity(teacher), classroom_id=classroom.id, display_name=body.display_name,
                          login_name=body.login_name, password_hash=hash_password(body.password))
        session.add(student)
        try:
            session.commit()
        except IntegrityError:
            session.rollback()
            raise HTTPException(409, "That student login name is already in use; choose another")
        return _student_view(student)

    @app.patch("/teacher/students/{student_id}/password", status_code=204)
    def reset_student_password(student_id: UUID, body: StudentPasswordInput,
                               teacher=Depends(current_teacher), session: Session = Depends(db)):
        student = _owned(Student, student_id, teacher, session, "Student")
        student.password_hash = hash_password(body.password)
        session.flush()
        session.execute(delete(StudentSession).where(StudentSession.student_id == student.id))
        session.commit()

    @app.get("/teacher/problems")
    def problems(teacher=Depends(current_teacher), session: Session = Depends(db)):
        return [_problem_view(row, session) for row in session.scalars(select(Problem).where(
            Problem.teacher_id == _identity(teacher)).order_by(Problem.created_at.desc(), Problem.id))]

    @app.post("/teacher/problems", status_code=201)
    def create_problem(body: ProblemInput, teacher=Depends(current_teacher), session: Session = Depends(db)):
        problem = Problem(teacher_id=_identity(teacher), title=body.title, kind=body.kind,
                          expected_text=body.expected_text, teaching_notes=body.teaching_notes)
        session.add(problem)
        session.flush()
        session.add(ProblemContent(problem_id=problem.id, payload=body.payload))
        session.commit()
        return _problem_view(problem, session)

    @app.get("/teacher/problems/{problem_id}")
    def problem_detail(problem_id: UUID, teacher=Depends(current_teacher), session: Session = Depends(db)):
        return _problem_view(_owned(Problem, problem_id, teacher, session, "Problem"), session)

    @app.get("/teacher/assignments")
    def assignments(teacher=Depends(current_teacher), session: Session = Depends(db)):
        return [_assignment_view(row, session) for row in session.scalars(select(Assignment).where(
            Assignment.teacher_id == _identity(teacher)).order_by(Assignment.created_at.desc(), Assignment.id))]

    @app.post("/teacher/assignments", status_code=201)
    def create_assignment(body: AssignmentInput, teacher=Depends(current_teacher), session: Session = Depends(db)):
        request_hash = _hash(body.model_dump(mode="json", exclude={"request_id"}))
        def previous_assignment():
            request = session.get(AssignmentRequest, (_identity(teacher), str(body.request_id))) if body.request_id else None
            if request and request.request_hash != request_hash:
                raise HTTPException(409, "This assignment request ID was already used with different content")
            return session.get(Assignment, request.assignment_id) if request else None
        previous = previous_assignment()
        if previous:
            return _assignment_view(previous, session)
        if body.classroom_id:
            target = _owned(Classroom, body.classroom_id, teacher, session, "Classroom")
            students = list(session.scalars(select(Student).where(Student.classroom_id == target.id, Student.teacher_id == _identity(teacher))))
            target_label = f"{target.school_name} · {target.name} · {target.postal_code}"
        else:
            target = _owned(Student, body.student_id, teacher, session, "Student")
            students, target_label = [target], target.display_name
        if not students:
            raise HTTPException(422, "Add at least one student before assigning to this classroom")
        item_data = []
        for index, request in enumerate(body.problems):
            problem = _owned(Problem, request.problem_id, teacher, session, "Problem")
            recording_id = str(request.recording_id) if request.recording_id else None
            if problem.kind == "read_aloud":
                recording = session.get(Recording, recording_id) if recording_id else None
                if recording is None or recording.problem_id != problem.id:
                    raise HTTPException(422, f"Choose a reference recording for '{problem.title}'")
                if not (directory / "recordings" / recording.id / "reference.wav").is_file():
                    raise HTTPException(409, f"The reference audio for '{problem.title}' is unavailable; upload it again")
            elif recording_id:
                raise HTTPException(422, "Reference audio is supported only for read-aloud problems")
            item_data.append({"problem_id": problem.id, "recording_id": recording_id,
                              "position": index, "snapshot": _make_snapshot(problem, session)})
        assignment = Assignment(teacher_id=_identity(teacher), title=body.title, target_label=target_label,
                                classroom_id=str(body.classroom_id) if body.classroom_id else None,
                                student_id=str(body.student_id) if body.student_id else None)
        session.add(assignment)
        session.flush()
        session.add_all([AssignmentItem(assignment_id=assignment.id, **values) for values in item_data])
        session.add_all([AssignmentRecipient(assignment_id=assignment.id, student_id=student.id) for student in students])
        if body.request_id:
            session.add(AssignmentRequest(teacher_id=_identity(teacher), request_id=str(body.request_id), request_hash=request_hash, assignment_id=assignment.id))
        try:
            session.commit()
        except IntegrityError:
            session.rollback()
            previous = previous_assignment()
            if previous:
                return _assignment_view(previous, session)
            raise HTTPException(409, "Assignment could not be saved; retry with the same request ID")
        return _assignment_view(assignment, session)

    @app.get("/teacher/assignments/{assignment_id}")
    def assignment_detail(assignment_id: UUID, teacher=Depends(current_teacher), session: Session = Depends(db)):
        assignment = _owned(Assignment, assignment_id, teacher, session, "Assignment")
        value = _assignment_view(assignment, session)
        value["problems"] = [{"id": item.id, "problem_id": item.problem_id, "recording_id": item.recording_id,
                              **{key: item.snapshot[key] for key in ("title", "kind", "expected_text", "teaching_notes", "payload")}}
                             for item in _items(assignment.id, session)]
        value["recipients"] = []
        for student in session.scalars(select(Student).join(AssignmentRecipient, Student.id == AssignmentRecipient.student_id).where(
                AssignmentRecipient.assignment_id == assignment.id).order_by(Student.display_name)):
            attempts = _attempts(student.id, session, assignment.id)
            progress = _progress(attempts, session)
            value["recipients"].append({**_student_view(student), "completed_count": progress["reviewed_problems"], "submitted_count": progress["submitted_problems"],
                                        "problem_count": value["problem_count"], "attempt_count": len(attempts),
                                        "average_score": progress["average_score"],
                                        "attempts": [_attempt_view(a, session, teacher=True) for a in attempts]})
        return value

    def student_summary(student, session, teacher=False):
        attempts = _attempts(student.id, session)
        count = session.scalar(select(func.count()).select_from(AssignmentRecipient).where(AssignmentRecipient.student_id == student.id))
        progress = _progress(attempts, session)
        completed_assignments = 0
        for assignment_id in session.scalars(select(AssignmentRecipient.assignment_id).where(AssignmentRecipient.student_id == student.id)):
            item_count = session.scalar(select(func.count()).select_from(AssignmentItem).where(AssignmentItem.assignment_id == assignment_id))
            assignment_progress = _progress([a for a in attempts if a.assignment_id == assignment_id], session)
            completed_assignments += int(item_count > 0 and assignment_progress["reviewed_problems"] == item_count)
        return {"student": _student_view(student), "classroom": _classroom_view(session.get(Classroom, student.classroom_id), session),
                "counts": {"assignments": count, "attempts": len(attempts), "completed_problems": progress["completed_problems"],
                           "submitted_problems": progress["submitted_problems"], "solved_problems": progress["solved_problems"],
                           "completed_assignments": completed_assignments,
                           "needs_review": sum(a.status == "needs_review" for a in attempts)},
                "progress": progress, "recent_feedback": [_attempt_view(a, session, teacher=teacher) for a in attempts[:10]]}

    @app.get("/teacher/students/{student_id}")
    def student_detail(student_id: UUID, teacher=Depends(current_teacher), session: Session = Depends(db)):
        student = _owned(Student, student_id, teacher, session, "Student")
        value = {**_student_view(student), **student_summary(student, session, teacher=True)}
        value["attempts"] = [_attempt_view(a, session, teacher=True) for a in _attempts(student.id, session)]
        value["assignments"] = student_assignment_list(student.id, session)
        return value

    @app.get("/teacher/overview")
    def teacher_overview(teacher=Depends(current_teacher), session: Session = Depends(db)):
        teacher = _identity(teacher)
        counts = {label: session.scalar(select(func.count()).select_from(model).where(model.teacher_id == teacher))
                  for label, model in (("classrooms", Classroom), ("students", Student), ("problems", Problem), ("assignments", Assignment))}
        condition = select(Attempt).join(Assignment, Attempt.assignment_id == Assignment.id).where(Assignment.teacher_id == teacher)
        attempts = list(session.scalars(condition.order_by(Attempt.created_at.desc(), Attempt.id.desc())))
        counts.update({"attempts": len(attempts), "needs_review": sum(a.status == "needs_review" for a in attempts)})
        return {"counts": counts, "recent_activity": [_attempt_view(a, session, teacher=True) for a in attempts[:12]],
                "review_queue": [_attempt_view(a, session, teacher=True) for a in attempts if a.status in {"needs_review", "failed"}][:30]}

    @app.patch("/teacher/attempts/{attempt_id}/review")
    def review_attempt(attempt_id: UUID, body: ReviewInput, teacher=Depends(current_teacher), session: Session = Depends(db)):
        attempt = session.get(Attempt, str(attempt_id))
        if not attempt:
            raise HTTPException(404, "Attempt not found")
        _owned(Assignment, attempt.assignment_id, teacher, session, "Attempt")
        # A model or another review may commit after the read. Compare the
        # analysis/review stamps, then refresh and merge so automatic evidence
        # cannot be overwritten by a stale review payload. Works on SQLite too.
        for _ in range(3):
            stamp = now()
            original_result = copy.deepcopy(attempt.result)
            original_result["teacher_review"] = {"score": body.score, "feedback": body.feedback, "reviewed_at": stamp}
            if "automatic_score" not in original_result:
                original_result["automatic_score"] = attempt.score
                original_result["automatic_feedback"] = attempt.feedback
            changed = session.execute(update(Attempt).where(
                Attempt.id == attempt.id, Attempt.status == attempt.status,
                Attempt.analyzed_at == attempt.analyzed_at, Attempt.reviewed_at == attempt.reviewed_at,
            ).values(score=body.score, feedback=body.feedback, status="completed", result=original_result, reviewed_at=stamp)
              .execution_options(synchronize_session=False)).rowcount
            if changed:
                session.add(AttemptReview(attempt_id=attempt.id, teacher_id=_identity(teacher), score=body.score,
                                          feedback=body.feedback, created_at=stamp))
                session.commit()
                session.refresh(attempt)
                return _attempt_view(attempt, session, teacher=True)
            session.refresh(attempt)
        session.rollback()
        raise HTTPException(409, "The attempt changed while you reviewed it; reload the latest evidence and try again")

    @app.get("/student/overview")
    def student_overview(student=Depends(current_student), session: Session = Depends(db)):
        return student_summary(session.get(Student, _identity(student)), session)

    def student_assignment_list(student, session):
        values = []
        for assignment in session.scalars(select(Assignment).join(AssignmentRecipient, Assignment.id == AssignmentRecipient.assignment_id).where(
                AssignmentRecipient.student_id == student).order_by(Assignment.created_at.desc(), Assignment.id)):
            value = _assignment_view(assignment, session)
            teacher = session.get(Teacher, assignment.teacher_id)
            progress = _progress(_attempts(student, session, assignment.id), session)
            value.update({"teacher_name": teacher.email.split("@")[0], "completed_count": progress["reviewed_problems"], "submitted_count": progress["submitted_problems"],
                          "average_score": progress["average_score"]})
            values.append(value)
        return values

    @app.get("/student/assignments")
    def student_assignments(student=Depends(current_student), session: Session = Depends(db)):
        return student_assignment_list(_identity(student), session)

    @app.get("/student/assignments/{assignment_id}")
    def student_assignment_detail(assignment_id: UUID, student=Depends(current_student), session: Session = Depends(db)):
        student = _identity(student)
        assignment = _assigned(assignment_id, student, session)
        value = _assignment_view(assignment, session)
        value["problems"] = []
        grouped = defaultdict(list)
        for attempt in _attempts(student, session, assignment.id):
            grouped[attempt.item_id].append(_attempt_view(attempt, session))
        for item in _items(assignment.id, session):
            value["problems"].append({**_student_problem(item), "attempts": grouped[item.id]})
        return value

    @app.get("/student/reference-recordings/{recording_id}/audio")
    def student_reference_audio(recording_id: UUID, student=Depends(current_student), session: Session = Depends(db)):
        assigned = session.scalar(select(AssignmentItem.id).join(AssignmentRecipient, AssignmentItem.assignment_id == AssignmentRecipient.assignment_id).where(
            AssignmentItem.recording_id == str(recording_id), AssignmentRecipient.student_id == _identity(student)).limit(1))
        if assigned is None:
            raise HTTPException(404, "Reference recording not found")
        path = directory / "recordings" / str(recording_id) / "reference.wav"
        if not path.is_file():
            raise HTTPException(503, "Reference audio is unavailable; ask your teacher to restore the recording")
        return FileResponse(path, media_type="audio/wav", headers={"Cache-Control": "no-store"})

    @app.post("/student/assignments/{assignment_id}/problems/{problem_id}/attempts", status_code=201)
    def submit_answer(assignment_id: UUID, problem_id: UUID, body: AttemptInput, background_tasks: BackgroundTasks,
                      student=Depends(current_student), session: Session = Depends(db)):
        student = _identity(student)
        item = _assigned_item(assignment_id, problem_id, student, session)
        kind, payload, answer = item.snapshot["kind"], item.snapshot["payload"], body.answer
        if kind == "read_aloud":
            raise HTTPException(422, "Submit an audio recording for this read-aloud problem")
        if kind == "choice":
            if not isinstance(answer, str) or answer not in {option["id"] for option in payload["options"]}:
                raise HTTPException(422, "Select one of the available options")
        elif kind == "matching":
            left_ids = {card["id"] for card in item.snapshot["matching_public"]["left"]}
            right_ids = {card["id"] for card in item.snapshot["matching_public"]["right"]}
            if (not isinstance(answer, dict) or set(answer) != left_ids or
                    any(not isinstance(value, str) or value not in right_ids for value in answer.values()) or
                    len(set(answer.values())) != len(right_ids)):
                raise HTTPException(422, "Match every left card to a different right card")
        elif kind == "meaning":
            if not isinstance(answer, str) or not answer.strip() or len(answer) > 5000:
                raise HTTPException(422, "Write a meaning between 1 and 5000 characters")
            answer = answer.strip()
        request_hash = _hash({"assignment": str(assignment_id), "item": item.id, "answer": answer})
        existing = _check_retry(session, student, body.request_id, request_hash)
        if existing:
            return _attempt_view(existing, session)
        attempt = Attempt(assignment_id=str(assignment_id), item_id=item.id, student_id=student,
                          request_id=str(body.request_id), request_hash=request_hash, answer=answer)
        if kind == "choice":
            attempt.score = float(answer == payload["correct_option_id"])
            attempt.status = "completed"
            attempt.feedback = "Correct answer. Well done!" if attempt.score == 1 else "That answer is not correct yet. Review the question and try again."
            attempt.result = {"skill": payload["skill"], "score_kind": "choice_accuracy", "correct": bool(attempt.score)}
            attempt.analyzed_at = now()
        elif kind == "matching":
            correct = sum(item.snapshot["matching_answers"][left_id] == right_id for left_id, right_id in answer.items())
            attempt.score = correct / len(answer)
            attempt.status = "completed"
            attempt.feedback = f"{correct} of {len(answer)} matches are correct." + (" Well done!" if correct == len(answer) else " Review the cards and try again.")
            attempt.result = {"skill": payload["skill"], "score_kind": "matching_accuracy", "correct_count": correct, "total_count": len(answer)}
            attempt.analyzed_at = now()
        session.add(attempt)
        try:
            session.commit()
        except IntegrityError:
            session.rollback()
            existing = _check_retry(session, student, body.request_id, request_hash)
            if existing:
                return _attempt_view(existing, session)
            raise HTTPException(409, "Submission could not be saved; retry with the same submission ID")
        value = _attempt_view(attempt, session)
        if kind == "meaning":
            schedule_analysis(background_tasks, attempt.id)
        return value

    @app.post("/student/assignments/{assignment_id}/problems/{problem_id}/recordings", status_code=201)
    def submit_recording(assignment_id: UUID, problem_id: UUID, file: UploadFile, background_tasks: BackgroundTasks,
                         request_id: UUID = Form(...), student=Depends(current_student), session: Session = Depends(db)):
        student = _identity(student)
        item = _assigned_item(assignment_id, problem_id, student, session)
        if item.snapshot["kind"] != "read_aloud":
            raise HTTPException(422, "This problem accepts an answer, not an audio recording")
        identifier = new_id()
        staging = Path(tempfile.mkdtemp(prefix=".upload-", dir=attempt_dir))
        final = attempt_dir / identifier
        committed = False
        try:
            source, normalized = staging / "original", staging / "reference.wav"
            size = 0
            with source.open("wb") as output:
                while chunk := file.file.read(64 * 1024):
                    size += len(chunk)
                    if size > MAX_BYTES:
                        raise HTTPException(413, "Maximum recording upload is 20 MiB")
                    output.write(chunk)
            if size == 0:
                raise HTTPException(422, "Audio file is empty")
            source_digest = digest(source)
            request_hash = _hash({"assignment": str(assignment_id), "item": item.id, "audio_sha256": source_digest})
            existing = _check_retry(session, student, request_id, request_hash)
            if existing:
                return _attempt_view(existing, session)
            measurements = normalize(source, normalized)
            source.chmod(0o600)
            normalized.chmod(0o600)
            attempt = Attempt(id=identifier, assignment_id=str(assignment_id), item_id=item.id, student_id=student,
                              request_id=str(request_id), request_hash=request_hash, original_sha256=source_digest,
                              normalized_sha256=digest(normalized), original_bytes=size, measurements=measurements)
            staging.rename(final)
            session.add(attempt)
            try:
                session.commit()
            except IntegrityError:
                session.rollback()
                existing = _check_retry(session, student, request_id, request_hash)
                if existing:
                    return _attempt_view(existing, session)
                raise HTTPException(409, "Submission could not be saved; retry with the same submission ID")
            committed = True
            value = _attempt_view(attempt, session)
            schedule_analysis(background_tasks, attempt.id)
            return value
        except InvalidAudio as exc:
            raise HTTPException(422, str(exc)) from exc
        except RuntimeError as exc:
            raise HTTPException(503, "Audio processing is unavailable; your recording has not been submitted") from exc
        finally:
            file.file.close()
            shutil.rmtree(staging, ignore_errors=True)
            if not committed:
                session.rollback()
                shutil.rmtree(final, ignore_errors=True)

    @app.get("/student/attempts/{attempt_id}")
    def student_attempt(attempt_id: UUID, student=Depends(current_student), session: Session = Depends(db)):
        attempt = session.get(Attempt, str(attempt_id))
        if attempt is None or attempt.student_id != _identity(student):
            raise HTTPException(404, "Attempt not found")
        return _attempt_view(attempt, session)

    @app.post("/student/attempts/{attempt_id}/retry-analysis", status_code=202)
    def retry_analysis(attempt_id: UUID, background_tasks: BackgroundTasks, student=Depends(current_student), session: Session = Depends(db)):
        attempt = session.get(Attempt, str(attempt_id))
        if attempt is None or attempt.student_id != _identity(student):
            raise HTTPException(404, "Attempt not found")
        item = session.get(AssignmentItem, attempt.item_id)
        if attempt.reviewed_at or item.snapshot["kind"] not in {"read_aloud", "meaning"} or attempt.status not in {"failed", "needs_review"}:
            raise HTTPException(409, "This attempt is already analyzed or analysis is in progress")
        changed = session.execute(update(Attempt).where(Attempt.id == attempt.id, Attempt.status == attempt.status, Attempt.reviewed_at.is_(None)).values(
            status="pending", feedback="Analysis is queued.")).rowcount
        if not changed:
            session.rollback()
            raise HTTPException(409, "Analysis is already in progress")
        session.commit()
        session.refresh(attempt)
        value = _attempt_view(attempt, session)
        schedule_analysis(background_tasks, attempt.id)
        return value

    @app.get("/attempts/{attempt_id}/audio")
    def attempt_audio(attempt_id: UUID, actor=Depends(current_actor), session: Session = Depends(db)):
        attempt = session.get(Attempt, str(attempt_id))
        if attempt is None:
            raise HTTPException(404, "Recording not found")
        assignment = session.get(Assignment, attempt.assignment_id)
        if not ((actor["role"] == "student" and actor["id"] == attempt.student_id) or
                (actor["role"] == "teacher" and actor["id"] == assignment.teacher_id)):
            raise HTTPException(404, "Recording not found")
        if not attempt.original_sha256:
            raise HTTPException(404, "This attempt does not have an audio recording")
        path = attempt_dir / attempt.id / "reference.wav"
        if not path.is_file():
            raise HTTPException(503, "Recording file is unavailable")
        return FileResponse(path, media_type="audio/wav", headers={"Cache-Control": "no-store"})
