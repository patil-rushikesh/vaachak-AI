import errno
import logging
import secrets
import shutil
import tempfile
import threading
import time
from collections import defaultdict
from contextlib import asynccontextmanager
from pathlib import Path
from types import SimpleNamespace
from typing import Literal
from uuid import UUID

from fastapi import Depends, FastAPI, HTTPException, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import delete, insert, literal, select
from sqlalchemy.exc import IntegrityError, InterfaceError, OperationalError
from sqlalchemy.orm import Session

from .audio import InvalidAudio, MAX_BYTES, digest, normalize
from .db import Analysis, LoginSession, Problem, Recording, StudentSession, Teacher, connect, new_id
from .security import hash_password, token_hash, verify_password
from .profile_service import LearningProfileInput, capture_learning_context, update_profile


class TextInput(BaseModel):
    @field_validator("*", mode="before")
    @classmethod
    def safe_text(cls, value):
        if isinstance(value, str) and ("\x00" in value or any(0xD800 <= ord(char) <= 0xDFFF for char in value)):
            raise ValueError("Text must not contain NUL or invalid Unicode characters")
        return value


class Credentials(TextInput):
    model_config = ConfigDict(extra="forbid")
    email: str | None = Field(default=None, min_length=3, max_length=254)
    identifier: str | None = Field(default=None, min_length=1, max_length=254)
    password: str = Field(min_length=1, max_length=256)
    role: Literal["teacher", "student"] = "teacher"


class Registration(TextInput):
    model_config = ConfigDict(str_strip_whitespace=False, extra="forbid")
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=12, max_length=256)
    learning_profile: LearningProfileInput = Field(default_factory=LearningProfileInput)


class ProblemInput(TextInput):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    title: str = Field(min_length=1, max_length=200)
    expected_text: str = Field(min_length=1, max_length=5000)
    teaching_notes: str = Field(default="", max_length=5000)


def problem_view(problem):
    return {field: getattr(problem, field) for field in (
        "id", "title", "kind", "expected_text", "teaching_notes", "language", "created_at"
    )}


def recording_view(recording):
    return {
        "id": recording.id, "problem_id": recording.problem_id,
        "original_sha256": recording.original_sha256,
        "normalized_sha256": recording.normalized_sha256,
        "original_bytes": recording.original_bytes,
        "duration_seconds": recording.duration_seconds,
        "measurements": recording.measurements, "created_at": recording.created_at,
        "playback_url": f"/recordings/{recording.id}/audio",
    }


def create_app(database_url=None, data_dir=None, *, recover_jobs=True, analysis_worker=True):
    engine, factory, directory = connect(database_url, data_dir)
    recordings = directory / "recordings"
    recordings.mkdir(exist_ok=True, mode=0o700)

    @asynccontextmanager
    async def lifespan(_):
        queue = None
        if analysis_worker:
            from .job_service import AnalysisQueue
            queue = AnalysisQueue(factory, directory)
            queue.start()
            app.state.analysis_queue = queue
        elif recover_jobs:
            # Deterministic inline execution remains available for API tests.
            from .domain_api import recover_interrupted_attempts
            recover_interrupted_attempts(factory)
        try:
            yield
        finally:
            if queue:
                queue.stop()
            engine.dispose()

    app = FastAPI(title="Vachak AI — Learning Studio", version="0.2.0", lifespan=lifespan)
    from .middleware import ApiResponseHeaders, RequestSizeLimit
    app.add_middleware(RequestSizeLimit)
    app.add_middleware(ApiResponseHeaders)
    app.state.session_factory = factory
    app.state.data_directory = directory
    bearer = HTTPBearer(auto_error=False)
    login_attempts = defaultdict(list)
    login_lock = threading.Lock()
    dummy_hash = hash_password(secrets.token_urlsafe(32))

    @app.exception_handler(RequestValidationError)
    async def invalid_request(_, exc):
        # Do not reflect passwords, complete recordings metadata, or non-JSON
        # numeric values (NaN/Infinity) from invalid inputs back in errors.
        detail = [{key: error[key] for key in ("type", "loc", "msg")} for error in exc.errors()]
        return JSONResponse(status_code=422, content={"detail": detail})

    @app.exception_handler(OperationalError)
    @app.exception_handler(InterfaceError)
    async def database_unavailable(_, exc):
        # Exception strings may contain SQL values or connection credentials.
        logging.getLogger(__name__).error("Database request failed (%s)", type(exc).__name__)
        return JSONResponse(status_code=503, content={"detail": "Database is temporarily unavailable. Retry with the same request ID where supported."})

    @app.exception_handler(OSError)
    async def storage_unavailable(_, exc):
        logging.getLogger(__name__).error("Local storage request failed (errno=%s)", exc.errno)
        full = exc.errno in {errno.ENOSPC, errno.EDQUOT}
        return JSONResponse(status_code=507 if full else 503, content={
            "detail": "Local storage is full; free space before retrying." if full else "Local storage is temporarily unavailable; please retry."})

    def db():
        with factory() as session:
            yield session

    def current_actor(
        credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
        session: Session = Depends(db),
    ):
        if credentials is None:
            raise HTTPException(401, "Sign in required", headers={"WWW-Authenticate": "Bearer"})
        from .domain_models import Student

        hashed = token_hash(credentials.credentials)
        login = session.get(LoginSession, hashed)
        if login is not None and login.expires_at > time.time():
            teacher = session.get(Teacher, login.teacher_id)
            if teacher:
                return {"id": teacher.id, "role": "teacher", "display_name": teacher.email}
        login = session.get(StudentSession, hashed)
        if login is not None and login.expires_at > time.time():
            student = session.get(Student, login.student_id)
            if student:
                return {"id": student.id, "role": "student", "display_name": student.display_name}
        raise HTTPException(401, "Session expired or invalid")

    def current_teacher(actor=Depends(current_actor)):
        if actor["role"] != "teacher":
            raise HTTPException(403, "Teacher access required")
        return actor["id"]

    def current_student(actor=Depends(current_actor)):
        if actor["role"] != "student":
            raise HTTPException(403, "Student access required")
        return actor["id"]

    def issue_session(actor, role, session):
        token = secrets.token_urlsafe(32)
        values = {"token_hash": token_hash(token), "expires_at": time.time() + 28800}
        # Expired bearer tokens are not useful history and should not grow forever.
        session.execute(delete(LoginSession).where(LoginSession.expires_at <= time.time()))
        session.execute(delete(StudentSession).where(StudentSession.expires_at <= time.time()))
        if role == "teacher":
            session.add(LoginSession(teacher_id=actor.id, **values))
            name = actor.email
        else:
            from .domain_models import Student
            # Reset and login can overlap: a login that verified the old hash
            # must not create a valid session after the password was replaced.
            created = session.execute(insert(StudentSession).from_select(
                ["token_hash", "student_id", "expires_at"],
                select(literal(values["token_hash"]), Student.id, literal(values["expires_at"]))
                .where(Student.id == actor.id, Student.password_hash == actor.password_hash),
            ).returning(StudentSession.token_hash)).scalar_one_or_none()
            if not created:
                session.rollback()
                raise HTTPException(401, "Sign-in details changed; please sign in again")
            name = actor.display_name
        session.commit()
        return {"access_token": token, "token_type": "bearer", "expires_in": 28800,
                "user": {"id": actor.id, "role": role, "display_name": name}}

    def check_email(email):
        import re
        value = email.strip().lower()
        if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", value):
            raise HTTPException(422, "Enter a valid email address")
        return value

    @app.post("/auth/register", status_code=201)
    def register(body: Registration, session: Session = Depends(db)):
        teacher = Teacher(email=check_email(body.email), password_hash=hash_password(body.password))
        session.add(teacher)
        try:
            session.flush()
            update_profile(session, "teacher", teacher.id, body.learning_profile, entered_by="self")
            return issue_session(teacher, "teacher", session)
        except IntegrityError as exc:
            session.rollback()
            raise HTTPException(409, "This email is already registered; sign in instead") from exc

    @app.get("/auth/me")
    def me(actor=Depends(current_actor)):
        return actor

    def owned_problem(identifier, teacher, session):
        problem = session.get(Problem, str(identifier))
        if problem is None or problem.teacher_id != teacher:
            raise HTTPException(404, "Problem not found")
        return problem

    def owned_recording(identifier, teacher, session):
        recording = session.get(Recording, str(identifier))
        if recording is None:
            raise HTTPException(404, "Recording not found")
        owned_problem(recording.problem_id, teacher, session)
        return recording

    @app.get("/health")
    def health():
        return {"status": "ok", "scope": "learning_studio_prototype", "version": "0.2.0"}

    @app.post("/auth/login")
    def login(body: Credentials, session: Session = Depends(db)):
        from .domain_models import Student
        identifier = (body.identifier or body.email or "").strip().lower()
        if not identifier:
            raise HTTPException(422, "Email or student username is required")
        key = f"{body.role}:{identifier}"
        now = time.time()
        with login_lock:
            # Local prototype throttle. A deployed multi-worker API needs shared limiting.
            for existing_key in list(login_attempts):
                login_attempts[existing_key] = [stamp for stamp in login_attempts[existing_key] if stamp > now - 300]
                if not login_attempts[existing_key]:
                    del login_attempts[existing_key]
            attempts = login_attempts[key]
            if len(attempts) >= 5:
                raise HTTPException(429, "Too many attempts; retry after five minutes")
            attempts.append(now)
        if body.role == "teacher":
            actor = session.scalar(select(Teacher).where(Teacher.email == identifier))
        else:
            actor = session.scalar(select(Student).where(Student.login_name == identifier))
        valid = verify_password(body.password, actor.password_hash if actor else dummy_hash)
        if not actor or not valid:
            raise HTTPException(401, "Invalid sign-in details")
        with login_lock:
            login_attempts.pop(key, None)
        return issue_session(actor, body.role, session)

    @app.post("/auth/logout", status_code=204)
    def logout(
        actor=Depends(current_actor), credentials=Depends(bearer), session: Session = Depends(db)
    ):
        model = LoginSession if actor["role"] == "teacher" else StudentSession
        # Two requests can both authenticate before either revokes the token.
        session.execute(delete(model).where(model.token_hash == token_hash(credentials.credentials)))
        session.commit()

    @app.post("/problems", status_code=201)
    def create_problem(body: ProblemInput, teacher=Depends(current_teacher), session: Session = Depends(db)):
        problem = Problem(teacher_id=teacher, **body.model_dump())
        session.add(problem)
        session.commit()
        return problem_view(problem)

    @app.get("/problems")
    def list_problems(
        offset: int = 0, limit: int = 50, teacher=Depends(current_teacher), session: Session = Depends(db)
    ):
        if offset < 0 or not 1 <= limit <= 100:
            raise HTTPException(422, "Use offset >= 0 and limit between 1 and 100")
        problems = session.scalars(select(Problem).where(Problem.teacher_id == teacher)
                                   .order_by(Problem.created_at, Problem.id).offset(offset).limit(limit))
        return [problem_view(problem) for problem in problems]

    @app.get("/problems/{problem_id}")
    def get_problem(problem_id: UUID, teacher=Depends(current_teacher), session: Session = Depends(db)):
        return problem_view(owned_problem(problem_id, teacher, session))

    @app.post("/problems/{problem_id}/recordings", status_code=201)
    def upload_recording(
        problem_id: UUID, file: UploadFile,
        teacher=Depends(current_teacher), session: Session = Depends(db),
    ):
        problem = owned_problem(problem_id, teacher, session)
        if problem.kind != "read_aloud":
            raise HTTPException(422, "Reference recordings belong to read-aloud problems")
        identifier = new_id()
        final = recordings / identifier
        staging = Path(tempfile.mkdtemp(prefix=".upload-", dir=recordings))
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
            measurements = normalize(source, normalized)
            measurements["learning_context"] = capture_learning_context(session, "teacher", teacher)
            from .prosody import analyze_pitch
            measurements["pitch"] = analyze_pitch(normalized)
            measurements["preservation"]["pitch_analysis"] = measurements["pitch"]["algorithm_version"]
            source.chmod(0o600)
            normalized.chmod(0o600)
            recording = Recording(
                id=identifier, problem_id=problem.id, original_sha256=digest(source),
                normalized_sha256=digest(normalized), original_bytes=size,
                duration_seconds=measurements["duration_seconds"], measurements=measurements,
            )
            staging.rename(final)
            session.add(recording)
            session.commit()
            committed = True
            return recording_view(recording)
        except InvalidAudio as exc:
            raise HTTPException(422, str(exc)) from exc
        except RuntimeError as exc:
            raise HTTPException(503, str(exc)) from exc
        finally:
            file.file.close()
            shutil.rmtree(staging, ignore_errors=True)
            if not committed:
                session.rollback()
                shutil.rmtree(final, ignore_errors=True)

    @app.get("/problems/{problem_id}/recordings")
    def list_recordings(problem_id: UUID, teacher=Depends(current_teacher), session: Session = Depends(db)):
        owned_problem(problem_id, teacher, session)
        return [recording_view(recording) for recording in session.scalars(
            select(Recording).where(Recording.problem_id == str(problem_id)).order_by(Recording.created_at)
        )]

    @app.get("/recordings/{recording_id}/audio")
    def playback(recording_id: UUID, teacher=Depends(current_teacher), session: Session = Depends(db)):
        owned_recording(recording_id, teacher, session)
        path = recordings / str(recording_id) / "reference.wav"
        if not path.is_file():
            raise HTTPException(503, "Recording file is unavailable")
        return FileResponse(path, media_type="audio/wav", headers={"Cache-Control": "no-store"})

    @app.get("/recordings/{recording_id}/analyses")
    def analyses(recording_id: UUID, teacher=Depends(current_teacher), session: Session = Depends(db)):
        owned_recording(recording_id, teacher, session)
        return [{"id": a.id, "model_id": a.model_id, "status": a.status,
                 "result": a.result, "created_at": a.created_at}
                for a in session.scalars(select(Analysis).where(Analysis.recording_id == str(recording_id))
                                         .order_by(Analysis.created_at))]

    from .domain_api import install_domain_routes
    install_domain_routes(app, SimpleNamespace(
        db=db, current_teacher=current_teacher, current_student=current_student,
        current_actor=current_actor, directory=directory, factory=factory,
    ))
    frontend = Path(__file__).resolve().parent.parent / "frontend"
    if frontend.is_dir():
        app.mount("/assets", StaticFiles(directory=frontend), name="assets")

        @app.get("/", include_in_schema=False)
        def homepage():
            return FileResponse(frontend / "index.html", headers={"Cache-Control": "no-cache"})

    return app
