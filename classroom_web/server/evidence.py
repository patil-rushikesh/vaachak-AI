"""Attempt evidence, transactional submission identities and shared access checks."""

import hashlib
import json
import time
from datetime import datetime, timezone
from fastapi import HTTPException

RUBRIC_VERSION = "task-feedback-v1"
POLICY_VERSION = "skill-review-v1"
CLASS_SCOPE = """AND (assignment_id IN (SELECT id FROM assignments WHERE class_id=?)
 OR lesson_id IN (SELECT l.id FROM lessons l JOIN class_courses cc ON cc.course_id=l.course_id WHERE cc.class_id=?))"""


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def version(item):
    return digest(item)[:24]


def public_versioned(items):
    from items import public_item

    return [{**public_item(i), "item_version": version(i)} for i in items]


def limit(conn, bucket, maximum, seconds=60):
    window = int(time.time()) // seconds
    conn.execute(
        "INSERT INTO rate_limits VALUES(?,?,1) ON CONFLICT(bucket,window) DO UPDATE SET count=count+1",
        (bucket, window),
    )
    count = conn.execute(
        "SELECT count FROM rate_limits WHERE bucket=? AND window=?", (bucket, window)
    ).fetchone()[0]
    conn.commit()
    if count > maximum:
        raise HTTPException(
            429,
            "Request limit reached. Try again later.",
            headers={"Retry-After": str(seconds)},
        )


def claim(conn, user_id, key, payload_hash):
    """Commit reservation before provider I/O. A crash never creates a second attempt."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        old = conn.execute(
            "SELECT * FROM submissions WHERE user_id=? AND client_uuid=?",
            (user_id, key),
        ).fetchone()
        if old:
            if old["request_hash"] != payload_hash:
                raise HTTPException(
                    409,
                    {
                        "code": "idempotency_conflict",
                        "message": "Submission ID was already used with different input.",
                    },
                )
            if old["status"] == "completed":
                conn.commit()
                return old["attempt_id"]
            raise HTTPException(
                409,
                {
                    "code": "submission_" + old["status"],
                    "message": "Submission already exists. Check its status before creating a new submission.",
                },
            )
        conn.execute(
            "INSERT INTO submissions(user_id,client_uuid,request_hash,status,created_at,updated_at) VALUES(?,?,?,?,?,?)",
            (user_id, key, payload_hash, "processing", now(), now()),
        )
        conn.commit()
        return None
    except Exception:
        conn.rollback()
        raise


def accessible_attempt(conn, user, attempt_id):
    a = conn.execute("SELECT * FROM attempts WHERE id=?", (attempt_id,)).fetchone()
    allowed = a is not None and a["user_id"] == user["id"]
    if a and user["role"] == "teacher":
        if a["assignment_id"]:
            allowed = bool(
                conn.execute(
                    """SELECT 1 FROM assignments a JOIN classes c ON c.id=a.class_id
                JOIN enrollments e ON e.class_id=c.id AND e.student_id=? WHERE a.id=? AND c.teacher_id=?""",
                    (a["user_id"], a["assignment_id"], user["id"]),
                ).fetchone()
            )
        elif a["lesson_id"]:
            allowed = bool(
                conn.execute(
                    """SELECT 1 FROM lessons l JOIN class_courses cc ON cc.course_id=l.course_id
                JOIN classes c ON c.id=cc.class_id JOIN enrollments e ON e.class_id=c.id
                WHERE l.id=? AND c.teacher_id=? AND e.student_id=?""",
                    (a["lesson_id"], user["id"], a["user_id"]),
                ).fetchone()
            )
    if not allowed:
        raise HTTPException(404, "Attempt not found.")
    return a


def attempt_json(a):
    result = json.loads(a["result"])
    if result.get("evaluation_status") == "unscored":
        # Also sanitize historical G1 rows which persisted numeric zero and corrective tips.
        result.update(score=None, accuracy=None, grammar=[], words=[], extra_words=[],
                      strengths=[], next_line="", evidence_eligible=False,
                      verdict="This answer has not been scored.",
                      tips=["Check the transcript, record again, or type your answer."])
    return {
        "id": a["id"],
        "transcript": a["transcript"],
        **result,
        "created_at": a["created_at"],
        "assignment_id": a["assignment_id"],
        "lesson_id": a["lesson_id"],
        "set_id": a["set_id"],
        "practice_session_id": a["practice_session_id"],
        "item_index": a["item_index"],
        "content_version": a["content_version"],
        "item_snapshot": json.loads(a["item_snapshot"]),
        "input_mode": a["input_mode"],
        "transcript_origin": a["transcript_origin"],
        "rubric_version": a["rubric_version"],
        "retry_of_attempt_id": a["retry_of_attempt_id"],
        "disputed": bool(a["disputed"]),
        "skill_ids": json.loads(a["skill_ids"]),
        "has_audio": bool(a["audio_file"]),
    }


def protect_delete(conn, condition, args):
    if conn.execute(
        "SELECT 1 FROM attempts WHERE " + condition + " LIMIT 1", args
    ).fetchone():
        raise HTTPException(
            409,
            {
                "code": "history_exists",
                "message": "This content has learner evidence. Archive it instead of deleting it.",
            },
        )


def recover_interrupted(conn):
    conn.execute("UPDATE transcriptions SET status='interrupted' WHERE status='processing'")
    # Supported deployment is one application instance. Startup marks abandoned claims explicitly.
    conn.execute(
        "UPDATE submissions SET status='interrupted',error_code='server_restarted',updated_at=? WHERE status='processing'",
        (now(),),
    )
    conn.commit()
