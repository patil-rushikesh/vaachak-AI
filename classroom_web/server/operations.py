"""Mobile evidence, account lifecycle and instructor follow-up operations."""

import json
import os
import shutil
from datetime import datetime, timezone
from typing import Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
import contracts
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
import db
import evidence
from main import (
    current_user,
    learner_only,
    teacher_only,
    get_db,
    need_class,
    need_assignment,
    hash_password,
    verify_password,
    _hash_token,
)

router = APIRouter(prefix="/api", responses=contracts.ERRORS)


@router.get("/attempts/{attempt_id}", response_model=contracts.Attempt)
def attempt_detail(attempt_id: int, user=Depends(current_user), conn=Depends(get_db)):
    a = evidence.accessible_attempt(conn, user, attempt_id)
    result = evidence.attempt_json(a)
    result["retries"] = [
        r[0]
        for r in conn.execute(
            "SELECT id FROM attempts WHERE retry_of_attempt_id=? AND user_id=? ORDER BY id",
            (attempt_id, a["user_id"]),
        )
    ]
    return result


@router.get("/me/attempts", response_model=contracts.History)
def history(
    cursor: int | None = Query(None, ge=1),
    limit: int = Query(20, ge=1, le=100),
    user=Depends(learner_only),
    conn=Depends(get_db),
):
    rows = conn.execute(
        "SELECT * FROM attempts WHERE user_id=? AND id<? ORDER BY id DESC LIMIT ?",
        (user["id"], cursor or 9223372036854775807, limit + 1),
    ).fetchall()
    return {
        "items": [evidence.attempt_json(r) for r in rows[:limit]],
        "next_cursor": rows[limit - 1]["id"] if len(rows) > limit else None,
    }


@router.get("/me/submissions/{client_uuid}", response_model=contracts.Submission)
def submission(client_uuid: str, user=Depends(learner_only), conn=Depends(get_db)):
    row = conn.execute(
        "SELECT client_uuid,status,attempt_id,error_code,created_at,updated_at FROM submissions WHERE user_id=? AND client_uuid=?",
        (user["id"], client_uuid),
    ).fetchone()
    if not row:
        raise HTTPException(404, "Submission not found.")
    return dict(row)


class DisputeIn(BaseModel):
    disputed: bool


@router.patch("/attempts/{attempt_id}/dispute", response_model=contracts.Ok)
def dispute(
    attempt_id: int, body: DisputeIn, user=Depends(learner_only), conn=Depends(get_db)
):
    a = evidence.accessible_attempt(conn, user, attempt_id)
    conn.execute("UPDATE attempts SET disputed=? WHERE id=?", (body.disputed, a["id"]))
    conn.commit()
    return {"ok": True}


class Preferences(BaseModel):
    timezone: str | None = Field(None, max_length=80)
    language: Literal["en", "mr", "hi"] | None = None
    research_consent: bool | None = None


@router.get("/me/preferences", response_model=contracts.Preferences)
def preferences(user=Depends(current_user)):
    return {k: user[k] for k in ("timezone", "language", "research_consent")}


@router.patch("/me/preferences", response_model=contracts.Preferences)
def update_preferences(
    body: Preferences, user=Depends(current_user), conn=Depends(get_db)
):
    values = body.model_dump(exclude_none=True)
    if body.timezone:
        try:
            ZoneInfo(body.timezone)
        except (ZoneInfoNotFoundError, ValueError):
            raise HTTPException(422, "Unknown timezone.")
    if values:
        conn.execute(
            "UPDATE users SET " + ",".join(k + "=?" for k in values) + " WHERE id=?",
            (*values.values(), user["id"]),
        )
        if "research_consent" in values:
            conn.execute(
                "INSERT INTO privacy_events(user_id,action,created_at) VALUES(?,?,?)",
                (
                    user["id"],
                    "research_granted"
                    if body.research_consent
                    else "research_withdrawn",
                    evidence.now(),
                ),
            )
        conn.commit()
    return preferences(
        conn.execute("SELECT * FROM users WHERE id=?", (user["id"],)).fetchone()
    )


class PasswordChange(BaseModel):
    current_password: str = Field(max_length=128)
    new_password: str = Field(min_length=8, max_length=128)


@router.post("/me/password", response_model=contracts.Ok)
def password(body: PasswordChange, user=Depends(current_user), conn=Depends(get_db)):
    evidence.limit(conn, f"password:{user['id']}", 5)
    if not verify_password(body.current_password, user["pw_hash"]):
        raise HTTPException(401, "Current password is incorrect.")
    conn.execute(
        "UPDATE users SET pw_hash=? WHERE id=?",
        (hash_password(body.new_password), user["id"]),
    )
    conn.execute("DELETE FROM sessions WHERE user_id=?", (user["id"],))
    conn.execute("DELETE FROM reset_tokens WHERE user_id=?", (user["id"],))
    conn.commit()
    return {"ok": True}


class ResetIn(BaseModel):
    token: str = Field(min_length=20, max_length=200)
    new_password: str = Field(min_length=8, max_length=128)


@router.post("/auth/reset-password", response_model=contracts.Ok)
def reset_password(body: ResetIn, conn=Depends(get_db)):
    conn.execute("BEGIN IMMEDIATE")
    row = conn.execute(
        "SELECT * FROM reset_tokens WHERE token_hash=? AND expires_at>?",
        (_hash_token(body.token), evidence.now()),
    ).fetchone()
    if not row:
        conn.rollback()
        raise HTTPException(400, "Reset link is invalid or expired.")
    conn.execute(
        "UPDATE users SET pw_hash=? WHERE id=?",
        (hash_password(body.new_password), row["user_id"]),
    )
    conn.execute("DELETE FROM sessions WHERE user_id=?", (row["user_id"],))
    conn.execute("DELETE FROM reset_tokens WHERE user_id=?", (row["user_id"],))
    conn.commit()
    return {"ok": True}


@router.get("/me/export", response_model=contracts.Export)
def export_data(user=Depends(current_user), conn=Depends(get_db)):
    profile = {k: user[k] for k in user.keys() if k != "pw_hash"}
    attempts = [
        evidence.attempt_json(a)
        for a in conn.execute(
            "SELECT * FROM attempts WHERE user_id=? ORDER BY id", (user["id"],)
        )
    ]
    owned = {}
    if user["role"] == "teacher":
        for table in ("classes", "courses", "assignments"):
            owned[table] = [
                dict(r)
                for r in conn.execute(
                    f"SELECT * FROM {table} WHERE teacher_id=?", (user["id"],)
                )
            ]
        owned["lessons"] = [
            dict(r)
            for r in conn.execute(
                "SELECT l.* FROM lessons l JOIN courses c ON c.id=l.course_id WHERE c.teacher_id=?",
                (user["id"],),
            )
        ]
        owned["units"] = [
            dict(r)
            for r in conn.execute(
                "SELECT u.* FROM units u JOIN courses c ON c.id=u.course_id WHERE c.teacher_id=?",
                (user["id"],),
            )
        ]
    return {
        "profile": profile,
        "attempts": attempts,
        "owned_content": owned,
        "enrollments": [
            dict(r)
            for r in conn.execute(
                "SELECT * FROM enrollments WHERE student_id=?", (user["id"],)
            )
        ],
        "course_enrollments": [
            dict(r)
            for r in conn.execute(
                "SELECT * FROM course_enrollments WHERE user_id=?", (user["id"],)
            )
        ],
        "privacy_events": [
            dict(r)
            for r in conn.execute(
                "SELECT action,created_at FROM privacy_events WHERE user_id=?",
                (user["id"],),
            )
        ],
        "recordings": [
            dict(r)
            for r in conn.execute(
                "SELECT id,title,mime,duration_ms,created_at FROM recordings WHERE teacher_id=?",
                (user["id"],),
            )
        ],
        "audio_downloads": [
            {"attempt_id": a["id"], "url": f"/api/attempts/{a['id']}/audio"}
            for a in attempts
            if a["has_audio"]
        ],
    }


class DeleteAccount(BaseModel):
    password: str = Field(max_length=128)


@router.delete("/me", response_model=contracts.Ok)
def delete_account(
    body: DeleteAccount, user=Depends(current_user), conn=Depends(get_db)
):
    evidence.limit(conn, f"erase:{user['id']}", 5)
    if not verify_password(body.password, user["pw_hash"]):
        raise HTTPException(401, "Password is incorrect.")
    # A teacher owns other users' educational records. Require an operator transfer before erasure.
    if user["role"] == "teacher" and (
        conn.execute(
            "SELECT 1 FROM classes WHERE teacher_id=?", (user["id"],)
        ).fetchone()
        or conn.execute(
            "SELECT 1 FROM courses WHERE teacher_id=?", (user["id"],)
        ).fetchone()
    ):
        raise HTTPException(
            409,
            {
                "code": "ownership_transfer_required",
                "message": "Transfer owned classes and courses to another instructor before deleting this account.",
            },
        )
    files = [
        r[0]
        for r in conn.execute(
            "SELECT audio_file FROM attempts WHERE user_id=? AND audio_file IS NOT NULL",
            (user["id"],),
        )
    ]
    files += [
        r[0]
        for r in conn.execute(
            "SELECT filename FROM recordings WHERE teacher_id=?", (user["id"],)
        )
    ]
    conn.execute("DELETE FROM users WHERE id=?", (user["id"],))
    conn.commit()
    for name in files:
        (db.data_dir() / "audio" / name).unlink(missing_ok=True)
    return {"ok": True}


class InsightAction(BaseModel):
    student_id: int
    reason: Literal[
        "never_started",
        "inactive",
        "quiet",
        "stuck_skill",
        "declining",
        "below_proficient",
    ]
    status: Literal["open", "snoozed", "resolved"]
    snooze_until: datetime | None = None
    assignment_id: int | None = None


@router.post("/classes/{class_id}/attention/actions", response_model=contracts.Ok)
def act(
    class_id: int, body: InsightAction, user=Depends(teacher_only), conn=Depends(get_db)
):
    need_class(conn, user, class_id)
    if not conn.execute(
        "SELECT 1 FROM enrollments WHERE class_id=? AND student_id=?",
        (class_id, body.student_id),
    ).fetchone():
        raise HTTPException(404, "Learner not in class.")
    if body.status == "snoozed" and (
        not body.snooze_until
        or body.snooze_until.tzinfo is None
        or body.snooze_until <= datetime.now(timezone.utc)
    ):
        raise HTTPException(422, "Snooze requires a future timezone-aware date.")
    if body.assignment_id:
        a = need_assignment(conn, user, body.assignment_id)
        if a["class_id"] != class_id or a["student_id"] != body.student_id:
            raise HTTPException(
                422, "Follow-up must target this learner in this class."
            )
    latest = conn.execute(
        "SELECT COALESCE(max(id),0) FROM attempts WHERE user_id=? "
        + evidence.CLASS_SCOPE,
        (body.student_id, class_id, class_id),
    ).fetchone()[0]
    conn.execute(
        """INSERT INTO insight_actions(class_id,student_id,reason,status,snooze_until,evidence_id,assignment_id,updated_at)
        VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(class_id,student_id,reason) DO UPDATE SET status=excluded.status,
        snooze_until=excluded.snooze_until,evidence_id=excluded.evidence_id,assignment_id=excluded.assignment_id,updated_at=excluded.updated_at""",
        (
            class_id,
            body.student_id,
            body.reason,
            body.status,
            body.snooze_until.isoformat() if body.snooze_until else None,
            latest,
            body.assignment_id,
            evidence.now(),
        ),
    )
    conn.execute(
        "DELETE FROM insight_dismissals WHERE class_id=? AND student_id=? AND reason=?",
        (class_id, body.student_id, body.reason),
    )
    conn.commit()
    return {"ok": True}


@router.get("/classes/{class_id}/attention/actions", response_model=contracts.Items)
def actions(class_id: int, user=Depends(teacher_only), conn=Depends(get_db)):
    need_class(conn, user, class_id)
    rows = []
    for r in conn.execute(
        "SELECT * FROM insight_actions WHERE class_id=? ORDER BY id", (class_id,)
    ):
        value = dict(r)
        value["follow_up_attempts"] = [
            dict(a)
            for a in conn.execute(
                "SELECT id,score,disputed,created_at FROM attempts WHERE user_id=? AND assignment_id=? ORDER BY id",
                (r["student_id"], r["assignment_id"]),
            )
        ]
        rows.append(value)
    return {"items": rows}


class ArchiveIn(BaseModel):
    archived: bool = True


@router.patch("/classes/{class_id}/archive", response_model=contracts.Ok)
def archive_class(
    class_id: int, body: ArchiveIn, user=Depends(teacher_only), conn=Depends(get_db)
):
    if not conn.execute(
        "SELECT 1 FROM classes WHERE id=? AND teacher_id=?", (class_id, user["id"])
    ).fetchone():
        raise HTTPException(404, "Class not found.")
    conn.execute("UPDATE classes SET archived=? WHERE id=?", (body.archived, class_id))
    conn.commit()
    return {"ok": True}


@router.patch("/courses/{course_id}/archive", response_model=contracts.Ok)
def archive_course(
    course_id: int, body: ArchiveIn, user=Depends(teacher_only), conn=Depends(get_db)
):
    if not conn.execute(
        "SELECT 1 FROM courses WHERE id=? AND teacher_id=?", (course_id, user["id"])
    ).fetchone():
        raise HTTPException(404, "Course not found.")
    conn.execute("UPDATE courses SET archived=? WHERE id=?", (body.archived, course_id))
    conn.commit()
    return {"ok": True}


@router.patch("/assignments/{assignment_id}/archive", response_model=contracts.Ok)
def archive_assignment(
    assignment_id: int,
    body: ArchiveIn,
    user=Depends(teacher_only),
    conn=Depends(get_db),
):
    if not conn.execute(
        "SELECT 1 FROM assignments WHERE id=? AND teacher_id=?",
        (assignment_id, user["id"]),
    ).fetchone():
        raise HTTPException(404, "Assignment not found.")
    conn.execute(
        "UPDATE assignments SET archived=? WHERE id=?", (body.archived, assignment_id)
    )
    conn.commit()
    return {"ok": True}


@router.patch("/lessons/{lesson_id}/archive", response_model=contracts.Ok)
def archive_lesson(
    lesson_id: int, body: ArchiveIn, user=Depends(teacher_only), conn=Depends(get_db)
):
    if not conn.execute(
        "SELECT 1 FROM lessons l JOIN courses c ON c.id=l.course_id WHERE l.id=? AND c.teacher_id=?",
        (lesson_id, user["id"]),
    ).fetchone():
        raise HTTPException(404, "Lesson not found.")
    conn.execute("UPDATE lessons SET archived=? WHERE id=?", (body.archived, lesson_id))
    conn.commit()
    return {"ok": True}


class AssignmentPatch(BaseModel):
    title: str | None = Field(None, min_length=1, max_length=120)
    instructions: str | None = Field(None, max_length=500)
    due_at: datetime | None = None


@router.patch("/assignments/{assignment_id}", response_model=contracts.Ok)
def edit_assignment(
    assignment_id: int,
    body: AssignmentPatch,
    user=Depends(teacher_only),
    conn=Depends(get_db),
):
    need_assignment(conn, user, assignment_id)
    values = body.model_dump(exclude_unset=True)
    if values.get("due_at"):
        if body.due_at.tzinfo is None:
            raise HTTPException(422, "Due date requires timezone.")
        values["due_at"] = body.due_at.isoformat()
    if "title" in values and not (values["title"] or "").strip():
        raise HTTPException(422, "Title must not be blank.")
    if values:
        conn.execute(
            "UPDATE assignments SET "
            + ",".join(k + "=?" for k in values)
            + " WHERE id=?",
            (*values.values(), assignment_id),
        )
        conn.commit()
    return {"ok": True}


@router.delete("/recordings/{rec_id}", response_model=contracts.Ok)
def delete_recording(rec_id: int, user=Depends(teacher_only), conn=Depends(get_db)):
    row = conn.execute(
        "SELECT * FROM recordings WHERE id=? AND teacher_id=?", (rec_id, user["id"])
    ).fetchone()
    if not row:
        raise HTTPException(404, "Recording not found.")
    conn.execute("DELETE FROM recordings WHERE id=?", (rec_id,))
    conn.commit()
    (db.data_dir() / "audio" / row["filename"]).unlink(missing_ok=True)
    return {"ok": True}


@router.get("/ready", response_model=contracts.Ok)
def ready(conn=Depends(get_db)):
    conn.execute("SELECT 1").fetchone()
    writable = os.access(db.data_dir(), os.W_OK)
    decoder = bool(shutil.which("ffprobe"))
    if not writable or not decoder:
        raise HTTPException(503, "Storage or media decoder is unavailable.")
    return {
        "ok": True,
        "schema_version": conn.execute(
            "SELECT max(version) FROM schema_migrations"
        ).fetchone()[0],
        "storage": True,
        "media_decoder": True,
        "provider_check": "configuration_only",
    }


@router.get("/me/recommendations", response_model=contracts.Items)
def recommendations(user=Depends(learner_only), conn=Depends(get_db)):
    """Find a different accessible task for a relevant skill; never infer untagged success."""
    import courses
    import insights
    from main import SETS, visible_assignments
    from items import public_item

    states = insights.skill_counts(conn, user["id"])
    candidates = []
    for sid, s in SETS.items():
        candidates.extend(
            ({"set_id": sid, "item_index": i}, item)
            for i, item in enumerate(s["items"])
        )
    for c in conn.execute(
        "SELECT c.* FROM classes c JOIN enrollments e ON e.class_id=c.id WHERE e.student_id=? AND c.archived=0",
        (user["id"],),
    ):
        for a in visible_assignments(conn, c, user):
            candidates.extend(
                ({"assignment_id": a["id"], "item_index": i}, item)
                for i, item in enumerate(json.loads(a["items"]))
            )
    for l in conn.execute("SELECT id FROM lessons WHERE archived=0"):
        try:
            items = courses.lesson_items_for_learner(conn, user, l["id"])
            candidates.extend(
                ({"lesson_id": l["id"], "item_index": i}, item)
                for i, item in enumerate(items)
            )
        except HTTPException:
            continue
    out = []
    for source, item in candidates:
        for code in item.get("skill_ids", []):
            state = states.get(code)
            if (
                not state
                or state["clean_since"] >= 2
                or state["last_miss_task"] == json.dumps(item)
            ):
                continue
            rows = conn.execute(
                "SELECT id,score,created_at,result,item_snapshot FROM attempts WHERE user_id=? AND disputed=0 ORDER BY created_at DESC,id DESC",
                (user["id"],),
            ).fetchall()
            relevant = []
            for r in rows:
                result = json.loads(r["result"])
                if code in result.get("assessed_skills", []) or any(
                    g.get("skill") == code for g in result.get("grammar", [])
                ):
                    relevant.append(r)
                if len(relevant) == 5:
                    break
            if not relevant:
                continue
            error_rate = sum(r["score"] < insights.PASS_SCORE for r in relevant) / len(
                relevant
            )
            overdue = max(
                0,
                (insights._now() - insights._parse(state["last_miss"])).total_seconds()
                / 86400
                - 1,
            )
            gap = int(state["clean_since"] == 0)
            priority = round(0.5 * error_rate + 0.3 * min(1, overdue) + 0.2 * gap, 4)
            out.append(
                {
                    "source": source,
                    "item": {
                        **public_item(item),
                        "item_version": evidence.version(item),
                    },
                    "skill_id": code,
                    "priority": priority,
                    "reason": "delayed_check_due"
                    if overdue > 0
                    else "repeated_skill_error",
                    "evidence_ids": state["evidence_ids"][-12:],
                    "policy_version": evidence.POLICY_VERSION,
                    "eligible_for_retention": overdue >= 0
                    and (
                        insights._now() - insights._parse(state["last_miss"])
                    ).total_seconds()
                    >= 86400,
                }
            )
    out.sort(
        key=lambda x: (
            -x["priority"],
            min(x["evidence_ids"]),
            json.dumps(x["source"], sort_keys=True),
        )
    )
    return {"items": out[:8]}
