"""User-owned learning paths, durable practice, drafts and product feedback.

Uses existing grading/evidence. Generated or unreviewed AI content is never
silently promoted into the public pool. Conversation prompts are scripted.
"""

import json
from pathlib import Path
from datetime import datetime, timedelta, timezone
from typing import Literal
from uuid import UUID
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
import contracts
import evidence
from main import current_user, learner_only, teacher_only, get_db, SETS

router = APIRouter(prefix="/api", responses=contracts.ERRORS)
CORE_QUIZZES = json.loads(
    (Path(__file__).parent / "data/growth_practice.json").read_text()
)
GOALS = {
    "everyday": "Everyday English",
    "interview": "Interview confidence",
    "workplace": "Workplace conversations",
    "presentation": "Project presentations",
}
SCENARIOS = {
    "interview": [
        "Tell me about yourself in two sentences.",
        "Describe a project you worked on.",
        "What did you learn from a challenge?",
        "What would you like to ask the interviewer?",
    ],
    "workplace": [
        "Ask a colleague to clarify a task.",
        "Explain when you can finish the task.",
        "Politely ask for help with a problem.",
        "Summarize the next step you agreed on.",
    ],
    "presentation": [
        "Introduce your project and its purpose.",
        "Explain the problem your project addresses.",
        "Describe one result and its limitation.",
        "Invite a question from the audience.",
    ],
    "everyday": [
        "Introduce yourself to a new neighbour.",
        "Ask for directions to a nearby shop.",
        "Explain what you would like to buy.",
        "Thank the person and end the conversation.",
    ],
}


class ProfileIn(BaseModel):
    goal: Literal["everyday", "interview", "workplace", "presentation"] = "everyday"
    difficulty: Literal["starter", "stretch"] = "starter"
    weekly_goal: int = Field(3, ge=1, le=7)
    analytics: bool = False


class ProfileOut(ProfileIn):
    configured: bool


@router.get("/me/learning-profile", response_model=ProfileOut)
def profile(user=Depends(learner_only), conn=Depends(get_db)):
    row = conn.execute(
        "SELECT * FROM learning_profiles WHERE user_id=?", (user["id"],)
    ).fetchone()
    return {**(dict(row) if row else ProfileIn().model_dump()), "configured": bool(row)}


@router.put("/me/learning-profile", response_model=ProfileOut)
def update_profile(body: ProfileIn, user=Depends(learner_only), conn=Depends(get_db)):
    conn.execute(
        "INSERT INTO learning_profiles VALUES(?,?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET goal=excluded.goal,difficulty=excluded.difficulty,weekly_goal=excluded.weekly_goal,analytics=excluded.analytics,updated_at=excluded.updated_at",
        (
            user["id"],
            body.goal,
            body.difficulty,
            body.weekly_goal,
            body.analytics,
            evidence.now(),
        ),
    )
    if not body.analytics:
        conn.execute("DELETE FROM product_events WHERE user_id=?", (user["id"],))
    conn.commit()
    return {**body.model_dump(), "configured": True}


class SessionIn(BaseModel):
    client_uuid: UUID
    mode: Literal["mixed", "review", "assessment"] = "mixed"
    count: int = Field(5, ge=1, le=10)


class PracticeSession(contracts.Response):
    id: str
    title: str
    items: list[dict]
    reason: str
    position: int
    completed: bool
    revision: int


def owned_session(conn, user, session_id):
    row = conn.execute(
        "SELECT * FROM practice_sessions WHERE id=? AND user_id=?",
        (session_id, user["id"]),
    ).fetchone()
    if not row:
        raise HTTPException(404, "Practice session not found.")
    return row


def session_json(row):
    out = dict(row)
    out.pop("request_hash", None)
    out.pop("user_id", None)
    out["draft"] = json.loads(out["draft"])
    out["items"] = [
        {**i, "source": {"practice_session_id": row["id"], "item_index": n}}
        for n, i in enumerate(evidence.public_versioned(json.loads(row["items"])))
    ]
    return out


def review_items(conn, user_id):
    """Recompute a transparent spacing policy from current valid evidence.

    Only personal-session items are used here, so revoked classroom material
    cannot leak. A dispute or immediate retry cannot advance the interval.
    """
    rows = conn.execute(
        "SELECT * FROM scored_attempts WHERE user_id=? AND practice_session_id IS NOT NULL AND disputed=0 AND retry_of_attempt_id IS NULL ORDER BY id DESC LIMIT 2000",
        (user_id,),
    ).fetchall()
    grouped = {}
    for row in rows:
        item = json.loads(row["item_snapshot"])
        grouped.setdefault(evidence.version(item), []).append(row)
    result = []
    for key, attempts in grouped.items():
        last = attempts[0]
        # At most one success on each UTC date is spacing evidence.
        success_days = {a["created_at"][:10] for a in attempts if a["score"] >= 80}
        interval = (
            [1, 3, 7, 14][min(max(len(success_days) - 1, 0), 3)]
            if last["score"] >= 80
            else 1
        )
        created = datetime.fromisoformat(last["created_at"]).replace(
            tzinfo=timezone.utc
        )
        due = created + timedelta(days=interval)
        result.append(
            {
                "key": key,
                "item": json.loads(last["item_snapshot"]),
                "due_at": due.isoformat(),
                "due": due <= datetime.now(timezone.utc),
                "interval_days": interval,
                "evidence_id": last["id"],
            }
        )
    return sorted(result, key=lambda r: r["due_at"])


@router.get("/me/review-queue", response_model=contracts.Response)
def review_queue(user=Depends(learner_only), conn=Depends(get_db)):
    rows = review_items(conn, user["id"])
    return {
        "policy": "personal-spacing-v1",
        "items": [
            {**r, "item": evidence.public_versioned([r["item"]])[0]} for r in rows
        ],
        "due_count": sum(r["due"] for r in rows),
    }


@router.post("/me/practice-sessions", response_model=PracticeSession)
def new_session(body: SessionIn, user=Depends(learner_only), conn=Depends(get_db)):
    evidence.limit(conn, f"practice-session:{user['id']}", 20)
    key = str(body.client_uuid)
    fingerprint = evidence.digest(body.model_dump(mode="json"))
    conn.execute("BEGIN IMMEDIATE")
    try:
        old = conn.execute(
            "SELECT * FROM practice_sessions WHERE id=?", (key,)
        ).fetchone()
        if old:
            if old["user_id"] != user["id"] or old["request_hash"] != fingerprint:
                raise HTTPException(
                    409,
                    "Session identity already used. Keep the original request or start a new session.",
                )
            conn.commit()
            return session_json(old)
        pref = profile(user, conn)
        pool = [i for group in SETS.values() for i in group["items"]] + CORE_QUIZZES
        # Authored prompts, not AI-generated or certified assessment items.
        if body.mode != "assessment":
            pool += [{"kind": "free", "prompt": p} for p in SCENARIOS[pref["goal"]]]
        else:
            pool = [i for i in pool if i["kind"] in ("choice", "fill", "build")]
        unique = {evidence.version(i): i for i in pool}
        if not unique:
            raise HTTPException(
                503, "Practice content is being prepared. Please try again later."
            )
        exposures = {}
        for r in conn.execute(
            "SELECT items FROM practice_sessions WHERE user_id=? ORDER BY created_at DESC LIMIT 100",
            (user["id"],),
        ):
            for item in json.loads(r["items"]):
                v = evidence.version(item)
                exposures[v] = exposures.get(v, 0) + 1
        # Starting checks stay deterministic even when speaking revision is due.
        due = (
            []
            if body.mode == "assessment"
            else [r for r in review_items(conn, user["id"]) if r["due"]]
        )
        chosen = {
            evidence.version(r["item"]): r["item"]
            for r in due[: body.count if body.mode == "review" else 2]
        }
        candidates = sorted(
            unique,
            key=lambda v: (
                exposures.get(v, 0),
                0
                if (unique[v]["kind"] == "free") == (pref["difficulty"] == "stretch")
                else 1,
                evidence.digest([key, v]),
            ),
        )
        for v in candidates:
            if len(chosen) >= body.count:
                break
            chosen.setdefault(v, unique[v])
        reason = (
            "Due revision and fresh practice."
            if due
            else "Practice selected for your chosen goal and recent activity."
        )
        if chosen and all(exposures.get(v, 0) for v in chosen):
            reason = "Purposeful revision: you have seen these activities before. New content is added after review."
        if body.mode == "assessment":
            reason = "A short starting check, not a certified proficiency assessment. You can choose your own difficulty."
        title = "Starting check" if body.mode == "assessment" else GOALS[pref["goal"]]
        conn.execute(
            "INSERT INTO practice_sessions(id,user_id,request_hash,title,items,reason,created_at) VALUES(?,?,?,?,?,?,?)",
            (
                key,
                user["id"],
                fingerprint,
                title,
                json.dumps(list(chosen.values())),
                reason,
                evidence.now(),
            ),
        )
        conn.commit()
        return session_json(owned_session(conn, user, key))
    except Exception:
        conn.rollback()
        raise


@router.get("/me/practice-sessions", response_model=list[PracticeSession])
def sessions(user=Depends(learner_only), conn=Depends(get_db)):
    return [
        session_json(r)
        for r in conn.execute(
            "SELECT * FROM practice_sessions WHERE user_id=? AND completed=0 ORDER BY created_at DESC LIMIT 10",
            (user["id"],),
        )
    ]


@router.get("/me/practice-sessions/{session_id}", response_model=PracticeSession)
def get_session(session_id: UUID, user=Depends(learner_only), conn=Depends(get_db)):
    return session_json(owned_session(conn, user, str(session_id)))


class DraftIn(BaseModel):
    revision: int = Field(0, ge=0)
    payload: dict


class DraftOut(contracts.Response):
    id: str
    revision: int
    payload: dict
    updated_at: str


@router.put("/teacher/drafts/{draft_id}", response_model=DraftOut)
def put_draft(
    draft_id: UUID, body: DraftIn, user=Depends(teacher_only), conn=Depends(get_db)
):
    raw = json.dumps(body.payload)
    if len(raw.encode()) > 100000:
        raise HTTPException(413, "Draft is too large.")
    evidence.limit(conn, f"draft:{user['id']}", 60)
    key = str(draft_id)
    conn.execute("BEGIN IMMEDIATE")
    try:
        old = conn.execute("SELECT * FROM teacher_drafts WHERE id=?", (key,)).fetchone()
        if old and old["user_id"] != user["id"]:
            raise HTTPException(404, "Draft not found.")
        if (old["revision"] if old else 0) != body.revision:
            raise HTTPException(409, "A newer draft exists. Reload it before saving.")
        conn.execute(
            "INSERT INTO teacher_drafts VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,revision=excluded.revision,updated_at=excluded.updated_at",
            (key, user["id"], raw, body.revision + 1, evidence.now()),
        )
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    return {
        "id": key,
        "payload": body.payload,
        "revision": body.revision + 1,
        "updated_at": evidence.now(),
    }


@router.get("/teacher/drafts", response_model=list[DraftOut])
def drafts(user=Depends(teacher_only), conn=Depends(get_db)):
    return [
        {**dict(r), "payload": json.loads(r["payload"])}
        for r in conn.execute(
            "SELECT id,payload,revision,updated_at FROM teacher_drafts WHERE user_id=? ORDER BY updated_at DESC LIMIT 50",
            (user["id"],),
        )
    ]


@router.delete("/teacher/drafts/{draft_id}", response_model=contracts.Ok)
def delete_draft(draft_id: UUID, user=Depends(teacher_only), conn=Depends(get_db)):
    conn.execute(
        "DELETE FROM teacher_drafts WHERE id=? AND user_id=?",
        (str(draft_id), user["id"]),
    )
    conn.commit()
    return {"ok": True}


@router.get("/teacher/archives", response_model=contracts.Response)
def archives(user=Depends(teacher_only), conn=Depends(get_db)):
    result = []
    for table in ("classes", "courses", "assignments", "lessons"):
        owner = (
            "teacher_id=?"
            if table != "lessons"
            else "course_id IN (SELECT id FROM courses WHERE teacher_id=?)"
        )
        title = "name" if table == "classes" else "title"
        result += [
            {"kind": table, **dict(r)}
            for r in conn.execute(
                f"SELECT id,{title} AS title FROM {table} WHERE archived=1 AND {owner} ORDER BY id DESC LIMIT 100",
                (user["id"],),
            )
        ]
    return {"items": result}


class ReportIn(BaseModel):
    category: Literal["feedback", "content", "technical", "suggestion"]
    message: str = Field("", max_length=1500)
    attempt_id: int | None = None
    helpful: bool | None = None


@router.post("/feedback-reports", response_model=contracts.Response)
def report(body: ReportIn, user=Depends(current_user), conn=Depends(get_db)):
    evidence.limit(conn, f"reports:{user['id']}", 10)
    if body.attempt_id:
        evidence.accessible_attempt(conn, user, body.attempt_id)
    row = conn.execute(
        "INSERT INTO feedback_reports(user_id,category,message,attempt_id,helpful,created_at) VALUES(?,?,?,?,?,?)",
        (
            user["id"],
            body.category,
            body.message.strip(),
            body.attempt_id,
            body.helpful,
            evidence.now(),
        ),
    )
    conn.commit()
    return {
        "id": row.lastrowid,
        "message": "Thank you. Your report has been recorded for review.",
    }


class EventIn(BaseModel):
    id: UUID
    name: Literal[
        "onboarding_completed",
        "practice_started",
        "feedback_viewed",
        "retry_completed",
        "review_completed",
    ]


@router.post("/events", response_model=contracts.Ok)
def event(body: EventIn, user=Depends(learner_only), conn=Depends(get_db)):
    if not profile(user, conn)["analytics"]:
        return {"ok": True}
    evidence.limit(conn, f"events:{user['id']}", 60)
    conn.execute(
        "DELETE FROM product_events WHERE created_at<?",
        ((datetime.now(timezone.utc) - timedelta(days=90)).isoformat(),),
    )
    conn.execute(
        "INSERT INTO product_events VALUES(?,?,?,?) ON CONFLICT DO NOTHING",
        (str(body.id), user["id"], body.name, evidence.now()),
    )
    conn.commit()
    return {"ok": True}


class ConversationIn(BaseModel):
    id: UUID
    scenario: Literal["interview", "workplace", "presentation", "everyday"]


class TurnIn(BaseModel):
    id: UUID
    revision: int = Field(ge=1)
    text: str = Field(min_length=1, max_length=1000)


def conversation_json(row):
    turns = json.loads(row["turns"])
    prompts = SCENARIOS[row["scenario"]]
    return {
        "id": row["id"],
        "scenario": row["scenario"],
        "revision": row["revision"],
        "turns": turns,
        "complete": len(turns) >= len(prompts),
        "prompt": prompts[len(turns)] if len(turns) < len(prompts) else None,
        "summary": "You practised introducing an idea, giving detail and closing a conversation. Review your answers and try clearer examples. This guided rehearsal does not award a proficiency score."
        if len(turns) >= len(prompts)
        else None,
    }


@router.post("/conversations", response_model=contracts.Response)
def conversation(
    body: ConversationIn, user=Depends(learner_only), conn=Depends(get_db)
):
    evidence.limit(conn, f"conversation:{user['id']}", 20)
    old = conn.execute(
        "SELECT * FROM conversations WHERE id=?", (str(body.id),)
    ).fetchone()
    if old and (old["user_id"] != user["id"] or old["scenario"] != body.scenario):
        raise HTTPException(409, "Conversation identity already used.")
    if not old:
        conn.execute(
            "INSERT INTO conversations(id,user_id,scenario,created_at) VALUES(?,?,?,?)",
            (str(body.id), user["id"], body.scenario, evidence.now()),
        )
        conn.commit()
    return read_conversation(body.id, user, conn)


@router.get("/conversations/{conversation_id}", response_model=contracts.Response)
def read_conversation(
    conversation_id: UUID, user=Depends(learner_only), conn=Depends(get_db)
):
    row = conn.execute(
        "SELECT * FROM conversations WHERE id=? AND user_id=?",
        (str(conversation_id), user["id"]),
    ).fetchone()
    if not row:
        raise HTTPException(404, "Conversation not found.")
    return conversation_json(row)


@router.post(
    "/conversations/{conversation_id}/turns", response_model=contracts.Response
)
def turn(
    conversation_id: UUID,
    body: TurnIn,
    user=Depends(learner_only),
    conn=Depends(get_db),
):
    if not body.text.strip():
        raise HTTPException(422, "Write an answer first.")
    conn.execute("BEGIN IMMEDIATE")
    try:
        state = read_conversation(conversation_id, user, conn)
        old = next((t for t in state["turns"] if t["id"] == str(body.id)), None)
        if old:
            if old["text"] != body.text.strip():
                raise HTTPException(409, "Turn identity was used for another answer.")
        else:
            if state["revision"] != body.revision or state["complete"]:
                raise HTTPException(
                    409, "Conversation changed. Reload before continuing."
                )
            turns = state["turns"] + [
                {
                    "id": str(body.id),
                    "prompt": state["prompt"],
                    "text": body.text.strip(),
                }
            ]
            conn.execute(
                "UPDATE conversations SET turns=?,revision=revision+1 WHERE id=?",
                (json.dumps(turns), str(conversation_id)),
            )
        conn.commit()
        return read_conversation(conversation_id, user, conn)
    except Exception:
        conn.rollback()
        raise


from fastapi import UploadFile, File, Form
import db
import audio_store
import feedback
from main import _save_upload, MAX_ATTEMPT_AUDIO


@router.post("/transcriptions", response_model=contracts.Response)
def transcribe(
    client_uuid: UUID = Form(...),
    audio: UploadFile = File(...),
    user=Depends(learner_only),
    conn=Depends(get_db),
):
    evidence.limit(conn, f"transcription:{user['id']}", 5)
    if not feedback.server_asr_available():
        raise HTTPException(
            503, "Speech recognition is unavailable. You can type your answer instead."
        )
    key = str(client_uuid)
    conn.execute("BEGIN IMMEDIATE")
    old = conn.execute("SELECT * FROM transcriptions WHERE id=?", (key,)).fetchone()
    if old:
        conn.commit()
        if old["user_id"] != user["id"]:
            raise HTTPException(409, "Transcription identity already exists.")
        return read_transcription(client_uuid, user, conn)
    expiry = (datetime.now(timezone.utc) + timedelta(hours=24)).isoformat()
    conn.execute(
        "INSERT INTO transcriptions(id,user_id,status,expires_at) VALUES(?,?,?,?)",
        (key, user["id"], "processing", expiry),
    )
    conn.commit()
    name = None
    try:
        name, mime = _save_upload(audio, MAX_ATTEMPT_AUDIO)
        with audio_store.local_path(name) as audio_path:
            text = feedback.transcribe_file(str(audio_path), mime)
        if not text or len(text) > 1000:
            raise HTTPException(
                422, "No usable transcript. Record a shorter answer or type it."
            )
        conn.execute(
            "UPDATE transcriptions SET audio_file=?,mime=?,transcript=?,status=? WHERE id=?",
            (name, mime, text, "completed", key),
        )
        conn.commit()
    except Exception:
        conn.rollback()
        if name:
            audio_store.discard(name)
        conn.execute("UPDATE transcriptions SET status=? WHERE id=?", ("failed", key))
        conn.commit()
        raise
    return read_transcription(client_uuid, user, conn)


@router.get("/transcriptions/{transcription_id}", response_model=contracts.Response)
def read_transcription(
    transcription_id: UUID, user=Depends(learner_only), conn=Depends(get_db)
):
    row = conn.execute(
        "SELECT * FROM transcriptions WHERE id=? AND user_id=? AND expires_at>?",
        (str(transcription_id), user["id"], evidence.now()),
    ).fetchone()
    if not row:
        raise HTTPException(
            404, "Transcript expired or not found. Record again or type your answer."
        )
    return {
        "id": row["id"],
        "status": row["status"],
        "transcript": row["transcript"],
        "expires_at": row["expires_at"],
    }


class SessionDraftIn(BaseModel):
    revision: int = Field(ge=1)
    item_index: int = Field(ge=0, le=50)
    text: str = Field("", max_length=1000)
    choice: int | None = Field(None, ge=0, le=5)
    selected: list[int] = Field(default_factory=list, max_length=20)


@router.patch("/me/practice-sessions/{session_id}", response_model=PracticeSession)
def save_session_draft(
    session_id: UUID,
    body: SessionDraftIn,
    user=Depends(learner_only),
    conn=Depends(get_db),
):
    conn.execute("BEGIN IMMEDIATE")
    try:
        row = owned_session(conn, user, str(session_id))
        if (
            row["revision"] != body.revision
            or row["completed"]
            or row["position"] != body.item_index
        ):
            raise HTTPException(
                409,
                "Practice moved forward in another window. Reload your saved session.",
            )
        conn.execute(
            "UPDATE practice_sessions SET draft=?,revision=revision+1 WHERE id=?",
            (json.dumps(body.model_dump(exclude={"revision"})), str(session_id)),
        )
        conn.commit()
        return session_json(owned_session(conn, user, str(session_id)))
    except Exception:
        conn.rollback()
        raise


@router.get("/practice-download", response_model=contracts.Response)
def practice_download(user=Depends(learner_only)):
    # Only existing public catalog quiz content; never private teacher material.
    pool = (
        CORE_QUIZZES
        + [
            i
            for group in SETS.values()
            for i in group["items"]
            if i["kind"] in ("choice", "fill")
        ]
    )[:30]
    return {
        "version": evidence.digest(pool),
        "items": pool,
        "expires_at": (datetime.now(timezone.utc) + timedelta(days=7)).isoformat(),
        "notice": "Offline self-practice only. These results do not change your assessed progress.",
    }


import os
import secrets
import logging
import smtplib
import ssl
from email.message import EmailMessage
from fastapi import BackgroundTasks, Request
from main import _hash_token


class ResetRequest(BaseModel):
    email: str = Field(
        min_length=3, max_length=254, pattern=r"^[^\s@]+@[^\s@]+\.[^\s@]+$"
    )


def deliver_reset(email, token):
    message = EmailMessage()
    message["From"] = os.environ["VAACHAK_SMTP_FROM"]
    message["To"] = email
    message["Subject"] = "Your Vaachak password reset"
    message.set_content(
        "You requested a Vaachak password reset. Paste this single-use token into the reset form within 30 minutes:\n\n"
        + token
        + "\n\nIf you did not request this, ignore this message."
    )
    try:
        with smtplib.SMTP(
            os.environ["VAACHAK_SMTP_HOST"],
            int(os.getenv("VAACHAK_SMTP_PORT", "587")),
            timeout=15,
        ) as smtp:
            smtp.starttls(context=ssl.create_default_context())
            if os.getenv("VAACHAK_SMTP_USER"):
                smtp.login(
                    os.environ["VAACHAK_SMTP_USER"], os.environ["VAACHAK_SMTP_PASSWORD"]
                )
            smtp.send_message(message)
    except Exception:
        logging.getLogger("vaachak.operations").warning(
            "password_reset_delivery_failed"
        )


@router.post("/auth/password-reset-request", response_model=contracts.Response)
def reset_request(
    body: ResetRequest, request: Request, tasks: BackgroundTasks, conn=Depends(get_db)
):
    host = request.client.host if request.client else "unknown"
    evidence.limit(conn, "reset-ip:" + evidence.digest(host), 10)
    email = body.email.strip().lower()
    evidence.limit(conn, "reset-address:" + evidence.digest(email), 3, seconds=1800)
    if not os.getenv("VAACHAK_SMTP_HOST") or not os.getenv("VAACHAK_SMTP_FROM"):
        raise HTTPException(
            503,
            "Email recovery is not configured on this installation. Ask your administrator for a reset token.",
        )
    row = conn.execute("SELECT id FROM users WHERE lower(email)=?", (email,)).fetchone()
    if row:
        token = secrets.token_urlsafe(32)
        conn.execute("DELETE FROM reset_tokens WHERE user_id=?", (row["id"],))
        conn.execute(
            "INSERT INTO reset_tokens VALUES(?,?,?)",
            (
                _hash_token(token),
                row["id"],
                (datetime.now(timezone.utc) + timedelta(minutes=30)).isoformat(),
            ),
        )
        conn.commit()
        tasks.add_task(deliver_reset, email, token)
    return {
        "message": "If this email belongs to an account, reset instructions will be sent. You can also ask your administrator for a reset token."
    }
