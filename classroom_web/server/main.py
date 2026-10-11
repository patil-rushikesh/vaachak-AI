"""VaachakAI classroom: FastAPI backend (SQLite + local audio files)."""
from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
import sqlite3
import time
import uuid
from contextlib import asynccontextmanager
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Literal

from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

import ai
import db
import feedback
import insights
import skills
from items import QUIZ_KINDS, ItemIn, clean_item, grade_quiz, public_item

ROOT = Path(__file__).resolve().parent.parent
CATALOG = json.loads((Path(__file__).parent / "data" / "catalog.json").read_text(encoding="utf-8"))
SETS = {s["id"]: {**s, "language": lang["code"]} for lang in CATALOG["languages"] for s in lang["sets"]}
AUDIO_TYPES = {"audio/webm": "webm", "audio/ogg": "ogg", "audio/mp4": "m4a", "audio/mpeg": "mp3", "audio/wav": "wav", "audio/x-wav": "wav", "audio/aac": "aac"}
MAX_RECORDING = 20 * 1024 * 1024
MAX_ATTEMPT_AUDIO = 8 * 1024 * 1024
STANDARDS = ["KG", *map(str, range(1, 13)), "adult"]
SESSION_DAYS = 30

@asynccontextmanager
async def lifespan(_: FastAPI):
    ai.load_env_file()
    db.init()
    yield


app = FastAPI(title="VaachakAI Classroom", docs_url="/api/docs", openapi_url="/api/openapi.json", lifespan=lifespan)


# ----------------------------------------------------------------------------- timestamps
# SQLite's CURRENT_TIMESTAMP writes "2026-10-11 04:16:01" while Python writes a full ISO
# string, so the same field could arrive in two shapes. JavaScript's Date() rejects the first
# on iOS, so every timestamp leaving this API is normalised to ISO-8601 UTC here, once.
TS_KEYS = {"created_at", "updated_at", "due_at", "last_active", "joined_at", "last_miss",
           "assigned_at", "expires_at", "day"}
_NAIVE = re.compile(r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(\.\d+)?$")


def to_iso(value: Any) -> Any:
    """A stored timestamp as ISO-8601 UTC. Anything unrecognised is passed through."""
    if not isinstance(value, str) or not _NAIVE.match(value):
        return value
    try:
        return datetime.fromisoformat(value).replace(tzinfo=timezone.utc).isoformat()
    except ValueError:
        return value


def isoify(obj: Any) -> Any:
    if isinstance(obj, dict):
        return {k: (to_iso(v) if k in TS_KEYS else isoify(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [isoify(v) for v in obj]
    return obj


@app.middleware("http")
async def normalise_timestamps(request: Request, call_next):
    response = await call_next(request)
    if not response.headers.get("content-type", "").startswith("application/json"):
        return response  # audio and files stream straight through
    body = b"".join([chunk async for chunk in response.body_iterator])
    try:
        fixed = json.dumps(isoify(json.loads(body))).encode()
    except ValueError:
        fixed = body
    headers = {k: v for k, v in response.headers.items() if k.lower() != "content-length"}
    return Response(content=fixed, status_code=response.status_code, headers=headers,
                    media_type="application/json")


def get_db():
    conn = db.connect()
    try:
        yield conn
    finally:
        conn.close()


# ----------------------------------------------------------------------------- security
def hash_password(password: str, salt: bytes | None = None) -> str:
    salt = salt or secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 200_000)
    return f"pbkdf2${salt.hex()}${digest.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        _, salt, digest = stored.split("$")
        check = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 200_000)
        return hmac.compare_digest(check.hex(), digest)
    except Exception:
        return False


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


_failures: dict[str, list[float]] = defaultdict(list)


def _throttle(key: str) -> None:
    now = time.time()
    _failures[key] = [t for t in _failures[key] if now - t < 600]
    if len(_failures[key]) >= 10:
        raise HTTPException(429, "Too many sign-in attempts. Wait ten minutes and try again.")


def current_user(request: Request, conn: sqlite3.Connection = Depends(get_db)) -> sqlite3.Row:
    header = request.headers.get("authorization", "")
    token = header[7:] if header.lower().startswith("bearer ") else request.query_params.get("token", "")
    if not token:
        raise HTTPException(401, "Sign in to continue.")
    row = conn.execute(
        "SELECT u.* FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.expires_at>?",
        (_hash_token(token), datetime.now(timezone.utc).isoformat()),
    ).fetchone()
    if not row:
        raise HTTPException(401, "Your session has ended. Sign in again.")
    return row


def teacher_only(user: sqlite3.Row = Depends(current_user)) -> sqlite3.Row:
    if user["role"] != "teacher":
        raise HTTPException(403, "Only teachers can do this.")
    return user


def learner_only(user: sqlite3.Row = Depends(current_user)) -> sqlite3.Row:
    if user["role"] == "teacher":
        raise HTTPException(403, "This is a learner action.")
    return user


def public_user(u: sqlite3.Row) -> dict:
    return {"id": u["id"], "name": u["name"], "email": u["email"], "role": u["role"]}


# ----------------------------------------------------------------------------- models
class Register(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    email: str = Field(pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$", max_length=120)
    password: str = Field(min_length=8, max_length=128)
    role: Literal["teacher", "student", "learner"]


class Login(BaseModel):
    email: str
    password: str


class ClassIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    standard: str | None = None
    section: str | None = Field(default=None, max_length=8)
    pincode: str | None = Field(default=None, pattern=r"^[1-9][0-9]{5}$")
    state: str | None = Field(default=None, max_length=60)
    district: str | None = Field(default=None, max_length=60)
    language: str = Field(default="en", pattern=r"^[a-z]{2,3}$")
    academic_year: str | None = Field(default=None, pattern=r"^20[0-9]{2}-[0-9]{2}$")


class JoinIn(BaseModel):
    code: str = Field(min_length=4, max_length=12)


class AssignmentIn(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    instructions: str | None = Field(default=None, max_length=500)
    due_at: str | None = None
    student_id: int | None = None
    recording_id: int | None = None
    set_id: str | None = None
    items: list[ItemIn] | None = Field(default=None, max_length=20)


# ----------------------------------------------------------------------------- helpers
def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_code(conn: sqlite3.Connection) -> str:
    alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    while True:
        code = "".join(secrets.choice(alphabet) for _ in range(6))
        if not conn.execute("SELECT 1 FROM classes WHERE code=?", (code,)).fetchone():
            return code


def class_row(conn, class_id: int) -> sqlite3.Row:
    row = conn.execute("SELECT * FROM classes WHERE id=?", (class_id,)).fetchone()
    if not row:
        raise HTTPException(404, "Class not found.")
    return row


def can_see_class(conn, user, c: sqlite3.Row) -> bool:
    if user["role"] == "teacher":
        return c["teacher_id"] == user["id"]
    return bool(conn.execute("SELECT 1 FROM enrollments WHERE class_id=? AND student_id=?", (c["id"], user["id"])).fetchone())


def need_class(conn, user, class_id: int) -> sqlite3.Row:
    c = class_row(conn, class_id)
    if not can_see_class(conn, user, c):
        raise HTTPException(404, "Class not found.")  # do not reveal other classes exist
    return c


def class_json(conn, c: sqlite3.Row, user) -> dict:
    t = conn.execute("SELECT name FROM users WHERE id=?", (c["teacher_id"],)).fetchone()
    out = {k: c[k] for k in ("id", "name", "standard", "section", "pincode", "state", "district", "language", "academic_year", "color")}
    out["teacher"] = t["name"] if t else ""
    out["students"] = conn.execute("SELECT count(*) n FROM enrollments WHERE class_id=?", (c["id"],)).fetchone()["n"]
    if user["role"] == "teacher":
        out["code"] = c["code"]
    return out


def item_total(a: sqlite3.Row) -> int:
    return len(json.loads(a["items"]))


def visible_assignments(conn, c, user) -> list[sqlite3.Row]:
    if user["role"] == "teacher":
        return conn.execute("SELECT * FROM assignments WHERE class_id=? ORDER BY created_at DESC, id DESC", (c["id"],)).fetchall()
    return conn.execute(
        "SELECT * FROM assignments WHERE class_id=? AND (student_id IS NULL OR student_id=?) ORDER BY created_at DESC, id DESC",
        (c["id"], user["id"]),
    ).fetchall()


def best_scores(conn, user_id: int, assignment_id: int) -> dict[int, int]:
    rows = conn.execute("SELECT item_index, max(score) s FROM attempts WHERE user_id=? AND assignment_id=? GROUP BY item_index", (user_id, assignment_id)).fetchall()
    return {r["item_index"]: r["s"] for r in rows}


def assignment_json(conn, a: sqlite3.Row, user, detail: bool = False) -> dict:
    items = json.loads(a["items"])
    out = {
        "id": a["id"], "class_id": a["class_id"], "title": a["title"], "instructions": a["instructions"], "due_at": a["due_at"],
        "created_at": a["created_at"], "student_id": a["student_id"], "recording_id": a["recording_id"],
        "item_count": len(items), "targeted": a["student_id"] is not None,
    }
    if user["role"] == "teacher":
        enrolled = [r["student_id"] for r in conn.execute("SELECT student_id FROM enrollments WHERE class_id=?", (a["class_id"],))]
        audience = [a["student_id"]] if a["student_id"] else enrolled
        done = 0
        for sid in audience:
            if len(best_scores(conn, sid, a["id"])) >= len(items) > 0:
                done += 1
        out.update({"audience": len(audience), "completed": done})
    else:
        best = best_scores(conn, user["id"], a["id"])
        out.update({"done_items": len(best), "avg_best": round(sum(best.values()) / len(best)) if best else None})
    if detail:
        out["items"] = items if user["role"] == "teacher" else [public_item(i) for i in items]
        if user["role"] != "teacher":
            out["best"] = {str(k): v for k, v in best_scores(conn, user["id"], a["id"]).items()}
    return out


# ----------------------------------------------------------------------------- auth routes
@app.post("/api/auth/register")
def register(body: Register, conn: sqlite3.Connection = Depends(get_db)):
    email = body.email.strip().lower()
    if conn.execute("SELECT 1 FROM users WHERE email=?", (email,)).fetchone():
        raise HTTPException(409, "That email already has an account. Sign in instead.")
    cur = conn.execute("INSERT INTO users(role,name,email,pw_hash) VALUES(?,?,?,?)", (body.role, body.name.strip(), email, hash_password(body.password)))
    conn.commit()
    return _issue(conn, cur.lastrowid)


def _issue(conn, user_id: int) -> dict:
    token = secrets.token_urlsafe(32)
    conn.execute("INSERT INTO sessions VALUES(?,?,?)", (_hash_token(token), user_id, (datetime.now(timezone.utc) + timedelta(days=SESSION_DAYS)).isoformat()))
    conn.commit()
    u = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
    return {"token": token, "user": public_user(u)}


@app.post("/api/auth/login")
def login(body: Login, conn: sqlite3.Connection = Depends(get_db)):
    email = body.email.strip().lower()
    _throttle(email)
    u = conn.execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()
    if not u or not verify_password(body.password, u["pw_hash"]):
        _failures[email].append(time.time())
        raise HTTPException(401, "Email or password is not right.")
    return _issue(conn, u["id"])


@app.post("/api/auth/logout")
def logout(request: Request, user=Depends(current_user), conn: sqlite3.Connection = Depends(get_db)):
    token = request.headers.get("authorization", "")[7:]
    conn.execute("DELETE FROM sessions WHERE token_hash=?", (_hash_token(token),))
    conn.commit()
    return {"ok": True}


@app.get("/api/me")
def me(user=Depends(current_user)):
    return public_user(user)


@app.get("/api/health")
def health(conn: sqlite3.Connection = Depends(get_db)):
    demo = bool(conn.execute("SELECT 1 FROM users WHERE email='teacher@demo.test'").fetchone())
    return {"ok": True, "server_speech_to_text": feedback.server_asr_available(), "demo": demo,
            "ai": ai.configured()}


# ----------------------------------------------------------------------------- classes
@app.post("/api/classes")
def create_class(body: ClassIn, user=Depends(teacher_only), conn: sqlite3.Connection = Depends(get_db)):
    if body.standard is not None and body.standard not in STANDARDS:
        raise HTTPException(422, "Standard must be KG, 1 to 12, or adult.")
    n = conn.execute("SELECT count(*) n FROM classes WHERE teacher_id=?", (user["id"],)).fetchone()["n"]
    cur = conn.execute(
        "INSERT INTO classes(teacher_id,name,standard,section,pincode,state,district,language,academic_year,code,color) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
        (user["id"], body.name.strip(), body.standard, (body.section or "").strip() or None, body.pincode, (body.state or "").strip() or None,
         (body.district or "").strip() or None, body.language, body.academic_year, new_code(conn), n % 6),
    )
    conn.commit()
    return class_json(conn, class_row(conn, cur.lastrowid), user)


@app.get("/api/classes")
def list_classes(user=Depends(current_user), conn: sqlite3.Connection = Depends(get_db)):
    if user["role"] == "teacher":
        rows = conn.execute("SELECT * FROM classes WHERE teacher_id=? ORDER BY created_at DESC, id DESC", (user["id"],)).fetchall()
    else:
        rows = conn.execute("SELECT c.* FROM classes c JOIN enrollments e ON e.class_id=c.id WHERE e.student_id=? ORDER BY e.joined_at DESC", (user["id"],)).fetchall()
    return [class_json(conn, c, user) for c in rows]


@app.post("/api/classes/join")
def join_class(body: JoinIn, user=Depends(learner_only), conn: sqlite3.Connection = Depends(get_db)):
    _throttle(f"join:{user['id']}")
    c = conn.execute("SELECT * FROM classes WHERE code=?", (body.code.strip().upper(),)).fetchone()
    if not c:
        _failures[f"join:{user['id']}"].append(time.time())
        raise HTTPException(404, "No class has that code. Check it with your teacher.")
    conn.execute("INSERT OR IGNORE INTO enrollments(class_id,student_id) VALUES(?,?)", (c["id"], user["id"]))
    conn.commit()
    return class_json(conn, c, user)


@app.get("/api/classes/{class_id}")
def get_class(class_id: int, user=Depends(current_user), conn: sqlite3.Connection = Depends(get_db)):
    c = need_class(conn, user, class_id)
    out = class_json(conn, c, user)
    if user["role"] == "teacher":
        out["roster"] = [dict(r) for r in conn.execute(
            "SELECT u.id,u.name,u.email,e.joined_at FROM enrollments e JOIN users u ON u.id=e.student_id WHERE e.class_id=? ORDER BY u.name", (class_id,))]
    return out


@app.delete("/api/classes/{class_id}/students/{student_id}")
def remove_student(class_id: int, student_id: int, user=Depends(teacher_only), conn: sqlite3.Connection = Depends(get_db)):
    need_class(conn, user, class_id)
    conn.execute("DELETE FROM enrollments WHERE class_id=? AND student_id=?", (class_id, student_id))
    conn.commit()
    return {"ok": True}


@app.post("/api/classes/{class_id}/code")
def new_class_code(class_id: int, user=Depends(teacher_only), conn: sqlite3.Connection = Depends(get_db)):
    need_class(conn, user, class_id)
    code = new_code(conn)
    conn.execute("UPDATE classes SET code=? WHERE id=?", (code, class_id))
    conn.commit()
    return {"code": code}


# ----------------------------------------------------------------------------- recordings
def _save_upload(file: UploadFile, limit: int, subdir: str = "audio") -> tuple[str, str]:
    mime = (file.content_type or "").split(";")[0].strip().lower()
    ext = AUDIO_TYPES.get(mime)
    if not ext:
        raise HTTPException(415, "Unsupported audio type. Use webm, ogg, mp4, mp3 or wav.")
    data = file.file.read(limit + 1)
    if not data or len(data) > limit:
        raise HTTPException(413, "The recording is empty or too large.")
    name = f"{uuid.uuid4().hex}.{ext}"
    (db.data_dir() / subdir / name).write_bytes(data)
    return name, mime


@app.post("/api/recordings")
def upload_recording(title: str = Form(..., min_length=1, max_length=120), duration_ms: int = Form(..., ge=500, le=600_000),
                     file: UploadFile = File(...), user=Depends(teacher_only), conn: sqlite3.Connection = Depends(get_db)):
    name, mime = _save_upload(file, MAX_RECORDING)
    cur = conn.execute("INSERT INTO recordings(teacher_id,title,filename,mime,duration_ms) VALUES(?,?,?,?,?)", (user["id"], title.strip(), name, mime, duration_ms))
    conn.commit()
    return {"id": cur.lastrowid, "title": title.strip(), "duration_ms": duration_ms}


@app.get("/api/recordings")
def my_recordings(user=Depends(teacher_only), conn: sqlite3.Connection = Depends(get_db)):
    return [dict(r) for r in conn.execute("SELECT id,title,mime,duration_ms,created_at FROM recordings WHERE teacher_id=? ORDER BY id DESC", (user["id"],))]


@app.get("/api/recordings/{rec_id}/audio")
def recording_audio(rec_id: int, user=Depends(current_user), conn: sqlite3.Connection = Depends(get_db)):
    r = conn.execute("SELECT * FROM recordings WHERE id=?", (rec_id,)).fetchone()
    allowed = False
    if r:
        if user["role"] == "teacher":
            allowed = r["teacher_id"] == user["id"]
        else:
            allowed = bool(conn.execute(
                "SELECT 1 FROM assignments a JOIN enrollments e ON e.class_id=a.class_id AND e.student_id=? "
                "WHERE a.recording_id=? AND (a.student_id IS NULL OR a.student_id=?)", (user["id"], rec_id, user["id"])).fetchone()) \
                or courses.can_hear_lesson_recording(conn, user, rec_id)
    if not allowed:
        raise HTTPException(404, "Recording not found.")
    return FileResponse(db.data_dir() / "audio" / r["filename"], media_type=r["mime"])


# ----------------------------------------------------------------------------- assignments
@app.post("/api/classes/{class_id}/assignments")
def create_assignment(class_id: int, body: AssignmentIn, user=Depends(teacher_only), conn: sqlite3.Connection = Depends(get_db)):
    need_class(conn, user, class_id)
    if body.set_id:
        s = SETS.get(body.set_id)
        if not s:
            raise HTTPException(422, "Unknown practice set.")
        items = s["items"]
    else:
        items = [clean_item(i) for i in (body.items or [])]
    if not items and not body.recording_id:
        raise HTTPException(422, "Add at least one practice item or a recording.")
    if body.student_id and not conn.execute("SELECT 1 FROM enrollments WHERE class_id=? AND student_id=?", (class_id, body.student_id)).fetchone():
        raise HTTPException(422, "That learner is not in this class.")
    if body.recording_id and not conn.execute("SELECT 1 FROM recordings WHERE id=? AND teacher_id=?", (body.recording_id, user["id"])).fetchone():
        raise HTTPException(422, "Recording not found.")
    if body.due_at:
        try:
            datetime.fromisoformat(body.due_at.replace("Z", "+00:00"))
        except ValueError:
            raise HTTPException(422, "Due date is not valid.")
    cur = conn.execute(
        "INSERT INTO assignments(class_id,teacher_id,student_id,recording_id,title,instructions,due_at,items) VALUES(?,?,?,?,?,?,?,?)",
        (class_id, user["id"], body.student_id, body.recording_id, body.title.strip(), (body.instructions or "").strip() or None, body.due_at, json.dumps(items)),
    )
    conn.commit()
    return assignment_json(conn, conn.execute("SELECT * FROM assignments WHERE id=?", (cur.lastrowid,)).fetchone(), user)


@app.get("/api/classes/{class_id}/assignments")
def list_assignments(class_id: int, user=Depends(current_user), conn: sqlite3.Connection = Depends(get_db)):
    c = need_class(conn, user, class_id)
    return [assignment_json(conn, a, user) for a in visible_assignments(conn, c, user)]


def need_assignment(conn, user, assignment_id: int) -> sqlite3.Row:
    a = conn.execute("SELECT * FROM assignments WHERE id=?", (assignment_id,)).fetchone()
    if not a:
        raise HTTPException(404, "Assignment not found.")
    c = class_row(conn, a["class_id"])
    if not can_see_class(conn, user, c) or (user["role"] != "teacher" and a["student_id"] not in (None, user["id"])):
        raise HTTPException(404, "Assignment not found.")
    return a


@app.get("/api/assignments/{assignment_id}")
def get_assignment(assignment_id: int, user=Depends(current_user), conn: sqlite3.Connection = Depends(get_db)):
    return assignment_json(conn, need_assignment(conn, user, assignment_id), user, detail=True)


@app.delete("/api/assignments/{assignment_id}")
def delete_assignment(assignment_id: int, user=Depends(teacher_only), conn: sqlite3.Connection = Depends(get_db)):
    need_assignment(conn, user, assignment_id)
    conn.execute("DELETE FROM assignments WHERE id=?", (assignment_id,))
    conn.commit()
    return {"ok": True}


# ----------------------------------------------------------------------------- catalog
@app.get("/api/catalog")
def catalog(q: str = "", user=Depends(current_user)):
    needle = q.strip().lower()
    out = []
    for lang in CATALOG["languages"]:
        sets = lang["sets"]
        hit_sets = [s for s in sets if needle in s["title"].lower() or needle in s["skill"].lower() or needle in s["about"].lower()]
        if needle and needle not in lang["name"].lower() and needle not in lang["native"].lower() and not hit_sets:
            continue
        shown = sets if (not needle or needle in lang["name"].lower() or needle in lang["native"].lower()) else hit_sets
        out.append({"code": lang["code"], "name": lang["name"], "native": lang["native"], "status": lang["status"],
                    "sets": [{k: s[k] for k in ("id", "title", "level", "skill", "about")} | {"item_count": len(s["items"])} for s in shown]})
    return out


@app.get("/api/sets/{set_id}")
def get_set(set_id: str, user=Depends(current_user), conn: sqlite3.Connection = Depends(get_db)):
    s = SETS.get(set_id)
    if not s:
        raise HTTPException(404, "Practice set not found.")
    rows = conn.execute("SELECT item_index, max(score) s FROM attempts WHERE user_id=? AND set_id=? GROUP BY item_index", (user["id"], set_id)).fetchall()
    return {**{k: s[k] for k in ("id", "title", "level", "skill", "about", "items", "language")}, "best": {str(r["item_index"]): r["s"] for r in rows}}


# ----------------------------------------------------------------------------- attempts
@app.post("/api/attempts")
def submit_attempt(
    item_index: int = Form(..., ge=0, le=50),
    transcript: str = Form("", max_length=1000),
    choice: int | None = Form(None, ge=0, le=5),
    assignment_id: int | None = Form(None),
    set_id: str | None = Form(None),
    lesson_id: int | None = Form(None),
    audio: UploadFile | None = File(None),
    user=Depends(learner_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    if sum(x is not None for x in (assignment_id, set_id, lesson_id)) != 1:
        raise HTTPException(422, "Send exactly one of: an assignment, a practice set, or a lesson.")
    if assignment_id is not None:
        items = json.loads(need_assignment(conn, user, assignment_id)["items"])
    elif lesson_id is not None:
        items = courses.lesson_items_for_learner(conn, user, lesson_id)
    else:
        if set_id not in SETS:
            raise HTTPException(404, "Practice set not found.")
        items = SETS[set_id]["items"]
    if item_index >= len(items):
        raise HTTPException(422, "That item does not exist.")
    item = items[item_index]
    kind = item["kind"]
    audio_name = audio_mime = None
    if kind in QUIZ_KINDS:
        if choice is None:
            raise HTTPException(422, "Pick an answer first.")
        result = grade_quiz(item, choice)
        result["kind"] = kind
        text, target = result["chosen_text"], result["target"]
    else:
        if audio is not None and audio.filename:
            audio_name, audio_mime = _save_upload(audio, MAX_ATTEMPT_AUDIO)
        text = transcript.strip()
        if not text and audio_name and feedback.server_asr_available():
            text = feedback.transcribe_file(str(db.data_dir() / "audio" / audio_name), audio_mime or "audio/webm")
        if not text:
            raise HTTPException(422, "Nothing was heard. Speak again, or type what you said.")
        target = item.get("text") if kind == "read" else item.get("answer")
        result = feedback.analyse_full(kind, target, text, item.get("answer"), prompt=item.get("prompt"))
        result["kind"], result["target"] = kind, target
        if kind == "build":
            result["answer"] = item["answer"]
    cur = conn.execute(
        "INSERT INTO attempts(user_id,assignment_id,set_id,lesson_id,item_index,kind,target,transcript,score,accuracy,result,audio_file,audio_mime) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (user["id"], assignment_id, set_id, lesson_id, item_index, kind, target, text, result["score"], result["accuracy"], json.dumps(result), audio_name, audio_mime),
    )
    conn.commit()
    return {"id": cur.lastrowid, "transcript": text, **result}


@app.get("/api/attempts/{attempt_id}/audio")
def attempt_audio(attempt_id: int, user=Depends(current_user), conn: sqlite3.Connection = Depends(get_db)):
    a = conn.execute("SELECT * FROM attempts WHERE id=?", (attempt_id,)).fetchone()
    ok = False
    if a and a["audio_file"]:
        if a["user_id"] == user["id"]:
            ok = True
        elif user["role"] == "teacher" and a["assignment_id"]:
            ok = bool(conn.execute("SELECT 1 FROM assignments x JOIN classes c ON c.id=x.class_id WHERE x.id=? AND c.teacher_id=?", (a["assignment_id"], user["id"])).fetchone())
        elif user["role"] == "teacher" and a["lesson_id"]:
            ok = bool(conn.execute("SELECT 1 FROM lessons l JOIN courses c ON c.id=l.course_id WHERE l.id=? AND c.teacher_id=?", (a["lesson_id"], user["id"])).fetchone())
    if not ok:
        raise HTTPException(404, "Recording not found.")
    return FileResponse(db.data_dir() / "audio" / a["audio_file"], media_type=a["audio_mime"])


# ----------------------------------------------------------------------------- stats
def summarize(conn, user_id: int, where: str = "", args: tuple = ()) -> dict:
    rows = conn.execute(f"SELECT * FROM attempts WHERE user_id=? {where} ORDER BY created_at", (user_id, *args)).fetchall()
    days: dict[str, list[int]] = defaultdict(list)
    issues: dict[str, int] = defaultdict(int)
    words: dict[tuple[str, str], int] = defaultdict(int)
    kinds: dict[str, list[int]] = defaultdict(list)
    for r in rows:
        day = r["created_at"][:10]
        days[day].append(r["score"])
        kinds[r["kind"]].append(r["score"])
        res = json.loads(r["result"])
        for g in res.get("grammar", []):
            code = skills.normalise(g.get("skill"))
            if not skills.is_accent_only(code):   # accent is never counted as something to fix
                issues[code] += 1
        for w in res.get("words", []):
            if w["status"] in ("wrong", "close") and w["heard"]:
                words[(w["target"], w["heard"])] += 1
    today = datetime.now(timezone.utc).date()
    streak, d = 0, today
    if str(today) not in days:
        d = today - timedelta(days=1)
    while str(d) in days:
        streak += 1
        d -= timedelta(days=1)
    last14 = []
    for i in range(13, -1, -1):
        day = str(today - timedelta(days=i))
        sc = days.get(day, [])
        last14.append({"day": day, "attempts": len(sc), "avg": round(sum(sc) / len(sc)) if sc else None})
    scores = [r["score"] for r in rows]
    return {
        "attempts": len(rows),
        "avg_score": round(sum(scores) / len(scores)) if scores else None,
        "recent_avg": round(sum(scores[-10:]) / len(scores[-10:])) if scores else None,
        "streak_days": streak,
        "last_active": rows[-1]["created_at"] if rows else None,
        "by_kind": {k: round(sum(v) / len(v)) for k, v in kinds.items()},
        "grammar_focus": sorted(({**skills.describe(k), "skill": k, "count": v} for k, v in issues.items()),
                                key=lambda x: -x["count"])[:5],
        "sound_focus": sorted(({"said": h, "target": t, "count": n} for (t, h), n in words.items()), key=lambda x: -x["count"])[:6],
        "days": last14,
    }


@app.get("/api/me/stats")
def my_stats(user=Depends(learner_only), conn: sqlite3.Connection = Depends(get_db)):
    out = summarize(conn, user["id"])
    out["weak_skills"] = insights.weak_skills(conn, user["id"])
    out["due_count"] = len(insights.due_for_review(conn, user["id"]))
    out["classes"] = []
    for c in conn.execute("SELECT c.* FROM classes c JOIN enrollments e ON e.class_id=c.id WHERE e.student_id=?", (user["id"],)):
        todo = done = 0
        for a in visible_assignments(conn, c, user):
            n = item_total(a)
            if n:
                todo += 1
                done += len(best_scores(conn, user["id"], a["id"])) >= n
        out["classes"].append({"id": c["id"], "name": c["name"], "assignments": todo, "completed": done})
    return out


@app.get("/api/classes/{class_id}/performance")
def class_performance(class_id: int, user=Depends(teacher_only), conn: sqlite3.Connection = Depends(get_db)):
    c = need_class(conn, user, class_id)
    assignments = conn.execute("SELECT * FROM assignments WHERE class_id=?", (class_id,)).fetchall()
    students = []
    for u in conn.execute("SELECT u.id,u.name,u.email FROM enrollments e JOIN users u ON u.id=e.student_id WHERE e.class_id=? ORDER BY u.name", (class_id,)):
        s = summarize(conn, u["id"], "AND assignment_id IN (SELECT id FROM assignments WHERE class_id=?)", (class_id,))
        mine = [a for a in assignments if a["student_id"] in (None, u["id"]) and item_total(a)]
        finished = sum(len(best_scores(conn, u["id"], a["id"])) >= item_total(a) for a in mine)
        students.append({"id": u["id"], "name": u["name"], "email": u["email"], "attempts": s["attempts"], "avg_score": s["avg_score"],
                         "recent_avg": s["recent_avg"], "last_active": s["last_active"], "assigned": len(mine), "completed": finished,
                         "top_issue": s["grammar_focus"][0]["skill"] if s["grammar_focus"] else None,
                         "needs_help": s["recent_avg"] is not None and s["recent_avg"] < 60})
    scored = [s["avg_score"] for s in students if s["avg_score"] is not None]
    return {"class": class_json(conn, c, user), "students": students, "class_avg": round(sum(scored) / len(scored)) if scored else None}


@app.get("/api/classes/{class_id}/students/{student_id}")
def student_detail(class_id: int, student_id: int, user=Depends(teacher_only), conn: sqlite3.Connection = Depends(get_db)):
    need_class(conn, user, class_id)
    u = conn.execute("SELECT u.id,u.name,u.email FROM enrollments e JOIN users u ON u.id=e.student_id WHERE e.class_id=? AND u.id=?", (class_id, student_id)).fetchone()
    if not u:
        raise HTTPException(404, "Learner not found in this class.")
    where, args = "AND assignment_id IN (SELECT id FROM assignments WHERE class_id=?)", (class_id,)
    recent = []
    for r in conn.execute(f"SELECT a.*, x.title assignment_title FROM attempts a JOIN assignments x ON x.id=a.assignment_id WHERE a.user_id=? {where.replace('assignment_id','a.assignment_id')} ORDER BY a.created_at DESC, a.id DESC LIMIT 25", (student_id, *args)):
        res = json.loads(r["result"])
        recent.append({"id": r["id"], "assignment": r["assignment_title"], "kind": r["kind"], "target": r["target"], "transcript": r["transcript"],
                       "score": r["score"], "tips": res.get("tips", [])[:3], "has_audio": bool(r["audio_file"]), "created_at": r["created_at"]})
    return {"student": dict(u), "stats": summarize(conn, student_id, where, args), "recent": recent}


# ----------------------------------------------------------------------------- what needs attention
class DismissIn(BaseModel):
    student_id: int
    reason: str = Field(max_length=40)


@app.get("/api/classes/{class_id}/attention")
def class_attention(class_id: int, user=Depends(teacher_only), conn: sqlite3.Connection = Depends(get_db)):
    c = need_class(conn, user, class_id)
    return {"class": class_json(conn, c, user), "rows": insights.attention(conn, class_id, user["id"])}


@app.post("/api/classes/{class_id}/attention/dismiss")
def dismiss_insight(class_id: int, body: DismissIn, user=Depends(teacher_only), conn: sqlite3.Connection = Depends(get_db)):
    """The teacher says this flag was not useful, so it never comes back for that learner."""
    need_class(conn, user, class_id)
    conn.execute("INSERT OR REPLACE INTO insight_dismissals(class_id,student_id,reason,teacher_id) VALUES(?,?,?,?)",
                 (class_id, body.student_id, body.reason, user["id"]))
    conn.commit()
    return {"ok": True}


@app.get("/api/classes/{class_id}/skill-grid")
def class_skills(class_id: int, user=Depends(teacher_only), conn: sqlite3.Connection = Depends(get_db)):
    need_class(conn, user, class_id)
    return insights.class_skill_grid(conn, class_id)


# ----------------------------------------------------------------------------- AI drafting
class GenerateIn(BaseModel):
    topic: str = Field(min_length=2, max_length=300)
    count: int = Field(default=6, ge=1, le=12)
    kinds: list[Literal["read", "free", "build", "choice", "fill", "listen"]] | None = None
    level: str = Field(default="A1", pattern=r"^(A1|A2|B1|B2|C1|C2)$")
    context: str | None = Field(default=None, max_length=4000)


@app.post("/api/ai/items")
def draft_items(body: GenerateIn, user=Depends(teacher_only)):
    """Draft practice items for the teacher to review. Nothing is saved and no learner sees this."""
    if not ai.configured():
        raise HTTPException(503, "AI is not set up on this computer. Add your key to vaachak.env, then restart.")
    drafted = ai.generate_items(body.topic, body.count, body.kinds, body.level, body.context)
    if not drafted:
        raise HTTPException(502, "The model could not write usable questions this time. Try again, or reword the topic.")
    return {"items": drafted, "asked_for": body.count}


# ----------------------------------------------------------------------------- courses
# courses.py imports helpers from this module, so it is imported here, after they exist.
import courses  # noqa: E402

app.include_router(courses.router)


# ----------------------------------------------------------------------------- web UI
WEB = ROOT / "web"
app.mount("/static", StaticFiles(directory=WEB), name="static")


@app.get("/")
def index():
    return FileResponse(WEB / "index.html", headers={"Cache-Control": "no-cache"})
