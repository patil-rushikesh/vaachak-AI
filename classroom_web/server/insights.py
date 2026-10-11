"""Turning attempt history into two things people can act on.

For the teacher: a queue of "this student needs you, and here is the one thing to do".
A dashboard that only tells you how things are gets ignored, so every row here carries a
reason, the evidence behind it, and a single action.

For the learner: which skills to practise next, and when a past mistake should come back.

Everything is derived from the attempts table. There is no separate progress state to drift
out of sync, and a teacher changing the thresholds never needs a migration.
"""
from __future__ import annotations

import json
import sqlite3
from collections import defaultdict
from datetime import datetime, timedelta, timezone

import skills

# How long before silence counts as "gone quiet".
INACTIVE_DAYS = 7
# A skill is "stuck" after this many misses with no recent success.
STUCK_MISSES = 3
# Finished the work but this far below is the quiet struggler nobody notices.
PROFICIENT = 60
# A learner with fewer attempts than this, while classmates work, is hanging back.
QUIET_ATTEMPTS = 3
# A drop of this many points between the last few answers and the ones before it.
DECLINE_POINTS = 10

# Leitner boxes: how long a task waits before coming back, moving up a box each time it is
# answered well and dropping to the first box when it is not. The first box is 0 days, so a
# mistake can be retried straight away while the learner still remembers making it.
BOX_DAYS = [0, 1, 2, 4, 8, 16]
PASS_SCORE = 80


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _parse(ts: str | None) -> datetime | None:
    if not ts:
        return None
    try:
        d = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def _days_since(ts: str | None) -> float | None:
    d = _parse(ts)
    return None if d is None else (_now() - d).total_seconds() / 86400


# ----------------------------------------------------------------------------- per-learner skills
def skill_counts(conn: sqlite3.Connection, user_id: int, where: str = "", args: tuple = ()) -> dict[str, dict]:
    """How often each skill went wrong, and whether it has gone right since.

    Accent-only features are left out entirely: they are not mistakes and must never appear
    as something a learner has to fix.
    """
    rows = conn.execute(
        f"SELECT created_at, score, result FROM attempts WHERE user_id=? {where} ORDER BY created_at",
        (user_id, *args)).fetchall()
    out: dict[str, dict] = {}
    for r in rows:
        try:
            res = json.loads(r["result"])
        except (TypeError, ValueError):
            continue
        for g in res.get("grammar", []):
            code = skills.normalise(g.get("skill"))
            if skills.is_accent_only(code):
                continue
            s = out.setdefault(code, {"code": code, "misses": 0, "last_miss": None, "clean_since": 0})
            s["misses"] += 1
            s["last_miss"] = r["created_at"]
            s["clean_since"] = 0
        # a clean, good answer counts as evidence the learner is getting past earlier slips
        if r["score"] >= PASS_SCORE and not res.get("grammar"):
            for s in out.values():
                s["clean_since"] += 1
    for code, s in out.items():
        s.update(skills.describe(code))
        s["stuck"] = s["misses"] >= STUCK_MISSES and s["clean_since"] < 2
    return out


def weak_skills(conn, user_id: int, where: str = "", args: tuple = (), limit: int = 4) -> list[dict]:
    counts = skill_counts(conn, user_id, where, args)
    ranked = sorted(counts.values(), key=lambda s: (-s["misses"], s["code"]))
    return ranked[:limit]


# ----------------------------------------------------------------------------- spaced review
def due_for_review(conn: sqlite3.Connection, user_id: int, limit: int = 8) -> list[dict]:
    """Past mistakes that are due to come back, using Leitner boxes.

    Each task sits in a box. Answer it well and it moves up, so it returns later; get it wrong
    and it drops to box 1 and returns tomorrow. A task answered well from the last box is done.
    """
    rows = conn.execute(
        "SELECT lesson_id, assignment_id, set_id, item_index, score, created_at, kind, target "
        "FROM attempts WHERE user_id=? ORDER BY created_at", (user_id,)).fetchall()
    tasks: dict[tuple, dict] = {}
    for r in rows:
        key = (r["lesson_id"], r["assignment_id"], r["set_id"], r["item_index"])
        t = tasks.setdefault(key, {"box": 0, "last": None, "score": 0, "kind": r["kind"], "target": r["target"]})
        if r["score"] >= PASS_SCORE:
            # A good answer always moves past the retry box, so it is not asked again today.
            t["box"] = min(max(t["box"] + 1, 2), len(BOX_DAYS))
        else:
            t["box"] = 1
        t["last"], t["score"] = r["created_at"], r["score"]

    due = []
    for key, t in tasks.items():
        if t["box"] >= len(BOX_DAYS) and t["score"] >= PASS_SCORE:
            continue  # learned: it has survived the longest interval
        waited = _days_since(t["last"])
        if waited is None:
            continue
        wait_for = BOX_DAYS[max(t["box"] - 1, 0)]
        if waited >= wait_for:
            lesson_id, assignment_id, set_id, item_index = key
            src = ({"lesson_id": lesson_id} if lesson_id else
                   {"assignment_id": assignment_id} if assignment_id else
                   {"set_id": set_id} if set_id else None)
            if src:
                due.append({"source": {**src, "item_index": item_index}, "last_score": t["score"],
                            "box": t["box"], "overdue_days": round(waited - wait_for, 1)})
    due.sort(key=lambda d: (d["last_score"], -d["overdue_days"]))
    return due[:limit]


# ----------------------------------------------------------------------------- teacher attention queue
def _recent_scores(conn, user_id: int, class_id: int, n: int = 6) -> list[int]:
    rows = conn.execute(
        "SELECT score FROM attempts WHERE user_id=? AND (assignment_id IN (SELECT id FROM assignments WHERE class_id=?) "
        "OR lesson_id IN (SELECT l.id FROM lessons l JOIN class_courses cc ON cc.course_id=l.course_id WHERE cc.class_id=?)) "
        "ORDER BY created_at DESC LIMIT ?", (user_id, class_id, class_id, n * 2)).fetchall()
    return [r["score"] for r in rows]


def attention(conn: sqlite3.Connection, class_id: int, teacher_id: int) -> list[dict]:
    """Who needs the teacher, why, and the one thing to do about it.

    Ordered worst first. Rows the teacher has marked unhelpful never come back.
    """
    dismissed = {(r["student_id"], r["reason"]) for r in conn.execute(
        "SELECT student_id, reason FROM insight_dismissals WHERE class_id=?", (class_id,))}
    where = ("AND (assignment_id IN (SELECT id FROM assignments WHERE class_id=?) "
             "OR lesson_id IN (SELECT l.id FROM lessons l JOIN class_courses cc ON cc.course_id=l.course_id WHERE cc.class_id=?))")
    roster = conn.execute(
        "SELECT u.id, u.name FROM enrollments e JOIN users u ON u.id=e.student_id WHERE e.class_id=? ORDER BY u.name",
        (class_id,)).fetchall()
    class_attempts = [
        conn.execute(f"SELECT count(*) n FROM attempts WHERE user_id=? {where}", (u["id"], class_id, class_id)).fetchone()["n"]
        for u in roster
    ]
    busiest = max(class_attempts) if class_attempts else 0

    rows: list[dict] = []
    for u, n_attempts in zip(roster, class_attempts):
        last = conn.execute(
            f"SELECT max(created_at) t FROM attempts WHERE user_id=? {where}", (u["id"], class_id, class_id)).fetchone()["t"]
        quiet_days = _days_since(last)
        scores = _recent_scores(conn, u["id"], class_id)
        base = {"student_id": u["id"], "name": u["name"], "last_active": last, "attempts": n_attempts}

        def add(reason, why, action, label, detail=None, severity=0):
            if (u["id"], reason) in dismissed:
                return
            rows.append({**base, "reason": reason, "why": why, "action": action,
                         "action_label": label, "detail": detail or {}, "severity": severity})

        if n_attempts == 0:
            add("never_started", "Has not answered anything yet", "assign",
                "Give them a short task", severity=4)
        elif quiet_days is not None and quiet_days >= INACTIVE_DAYS:
            add("inactive", f"Nothing for {int(quiet_days)} days", "assign",
                "Give them a short task", {"days": int(quiet_days)}, severity=3)
        elif busiest >= QUIET_ATTEMPTS * 2 and n_attempts < QUIET_ATTEMPTS:
            add("quiet", f"Only {n_attempts} answer{'s' if n_attempts != 1 else ''} while the class has done much more",
                "assign", "Give them a short task", {"attempts": n_attempts}, severity=2)

        stuck = [s for s in skill_counts(conn, u["id"], where, (class_id, class_id)).values() if s["stuck"]]
        stuck.sort(key=lambda s: -s["misses"])
        if stuck:
            s = stuck[0]
            add("stuck_skill", f"Keeps getting “{s['label']}” wrong ({s['misses']} times)", "practise",
                f"Set practice on {s['label'].lower()}", {"skill": s["code"], "label": s["label"]}, severity=3)

        if len(scores) >= 6:
            recent, before = scores[:3], scores[3:6]
            drop = sum(before) / 3 - sum(recent) / 3
            if drop >= DECLINE_POINTS:
                add("declining", f"Scores falling: {round(sum(before) / 3)} down to {round(sum(recent) / 3)}",
                    "review", "Look at their answers", {"drop": round(drop)}, severity=2)

        if scores and n_attempts >= QUIET_ATTEMPTS:
            avg = round(sum(scores) / len(scores))
            if avg < PROFICIENT:
                add("below_proficient", f"Doing the work but averaging {avg}", "review",
                    "Look at their answers", {"avg": avg}, severity=3)

    rows.sort(key=lambda r: (-r["severity"], r["name"]))
    return rows


def class_skill_grid(conn: sqlite3.Connection, class_id: int, top: int = 6) -> dict:
    """Which skills this class gets wrong most, and who is affected by each."""
    where = ("AND (assignment_id IN (SELECT id FROM assignments WHERE class_id=?) "
             "OR lesson_id IN (SELECT l.id FROM lessons l JOIN class_courses cc ON cc.course_id=l.course_id WHERE cc.class_id=?))")
    roster = conn.execute(
        "SELECT u.id, u.name FROM enrollments e JOIN users u ON u.id=e.student_id WHERE e.class_id=? ORDER BY u.name",
        (class_id,)).fetchall()
    per_student: dict[int, dict[str, int]] = {}
    totals: dict[str, int] = defaultdict(int)
    for u in roster:
        counts = skill_counts(conn, u["id"], where, (class_id, class_id))
        per_student[u["id"]] = {c: s["misses"] for c, s in counts.items()}
        for c, s in counts.items():
            totals[c] += s["misses"]
    ranked = sorted(totals.items(), key=lambda kv: -kv[1])[:top]
    codes = [c for c, _ in ranked]
    return {
        "skills": [{**skills.describe(c), "total": totals[c],
                    "students": sum(1 for u in roster if per_student[u["id"]].get(c))} for c in codes],
        "rows": [{"student_id": u["id"], "name": u["name"],
                  "counts": [per_student[u["id"]].get(c, 0) for c in codes]} for u in roster],
    }
