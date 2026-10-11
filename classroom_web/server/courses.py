"""Courses: teacher-built, ordered units and lessons that learners work through.

A course has units; a unit has lessons; a lesson has teaching text, an optional voice note and tasks
(see items.py). Learners reach a course by enrolling in a public one, or because their teacher
assigned it to their class. A lesson is finished when every task has been answered at least once;
stars show how well. With sequential courses, a lesson opens when the one before it is finished.
"""

from __future__ import annotations

import json
import sqlite3
from typing import Literal

import contracts
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

import evidence
import insights
from items import ItemIn, clean_item, public_item

# main.py imports this module only after defining these, so the circular import is safe.
from main import (
    SETS,
    current_user,
    get_db,
    learner_only,
    need_assignment,
    need_class,
    now_iso,
    summarize,
    teacher_only,
)

router = APIRouter(prefix="/api", responses=contracts.ERRORS)
MAX_LESSON_ITEMS = 30


# ----------------------------------------------------------------------------- models
class CourseIn(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    summary: str | None = Field(default=None, max_length=600)
    level: str = Field(default="A1", pattern=r"^(A1|A2|B1|B2|C1|C2)$")
    visibility: Literal["public", "classes"] = "public"
    sequential: bool = True


class CoursePatch(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=120)
    summary: str | None = Field(default=None, max_length=600)
    level: str | None = Field(default=None, pattern=r"^(A1|A2|B1|B2|C1|C2)$")
    visibility: Literal["public", "classes"] | None = None
    sequential: bool | None = None


class TitleIn(BaseModel):
    title: str = Field(min_length=1, max_length=120)


class LessonIn(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    intro: str | None = Field(default=None, max_length=2000)
    recording_id: int | None = None
    items: list[ItemIn] = Field(default_factory=list, max_length=MAX_LESSON_ITEMS)


class MoveIn(BaseModel):
    direction: Literal["up", "down"]


class PublishIn(BaseModel):
    published: bool


class ClassCourseIn(BaseModel):
    course_id: int


# ----------------------------------------------------------------------------- lookups
def own_course(conn, user, course_id: int) -> sqlite3.Row:
    c = conn.execute(
        "SELECT * FROM courses WHERE id=? AND teacher_id=?", (course_id, user["id"])
    ).fetchone()
    if not c:
        raise HTTPException(404, "Course not found.")
    return c


def learner_reach(conn, user, course: sqlite3.Row) -> str | None:
    """How a learner may use a published course: 'class', 'public', or None."""
    if course["status"] != "published" or course["archived"]:
        return None
    if conn.execute(
        "SELECT 1 FROM class_courses cc JOIN enrollments e ON e.class_id=cc.class_id JOIN classes c ON c.id=cc.class_id WHERE cc.course_id=? AND e.student_id=? AND c.archived=0",
        (course["id"], user["id"]),
    ).fetchone():
        return "class"
    return "public" if course["visibility"] == "public" else None


def visible_course(conn, user, course_id: int) -> tuple[sqlite3.Row, str]:
    """Return (course, 'owner'|'learner') or raise 404 without revealing that it exists."""
    c = conn.execute("SELECT * FROM courses WHERE id=?", (course_id,)).fetchone()
    if c and user["role"] == "teacher":
        if c["teacher_id"] == user["id"]:
            return c, "owner"
    elif c and learner_reach(conn, user, c):
        return c, "learner"
    raise HTTPException(404, "Course not found.")


def flat_lessons(conn, course_id: int) -> list[sqlite3.Row]:
    return conn.execute(
        "SELECT l.*, u.title unit_title, u.position upos FROM lessons l JOIN units u ON u.id=l.unit_id "
        "WHERE l.course_id=? AND l.archived=0 ORDER BY u.position, u.id, l.position, l.id",
        (course_id,),
    ).fetchall()


def best_by_lesson(conn, user_id: int, course_id: int) -> dict[int, dict[int, int]]:
    out: dict[int, dict[int, int]] = {}
    for r in conn.execute(
        "SELECT a.lesson_id, a.item_index, max(a.score) s FROM attempts a JOIN lessons l ON l.id=a.lesson_id "
        "WHERE a.user_id=? AND l.course_id=? AND a.content_version=l.revision AND a.disputed=0 GROUP BY a.lesson_id, a.item_index",
        (user_id, course_id),
    ):
        out.setdefault(r["lesson_id"], {})[r["item_index"]] = r["s"]
    return out


def lesson_state(lesson: sqlite3.Row, best: dict[int, int]) -> dict:
    n = len(json.loads(lesson["items"]))
    got = {i: s for i, s in best.items() if i < n}
    avg = round(sum(got.values()) / len(got)) if got else None
    done = n > 0 and len(got) == n
    stars = 0 if not done else 3 if avg >= 90 else 2 if avg >= 70 else 1
    return {
        "item_count": n,
        "done_items": len(got),
        "complete": done,
        "avg": avg,
        "stars": stars,
    }


def learner_course_view(conn, course: sqlite3.Row, user_id: int) -> dict:
    """Units with per-lesson status for one learner: done | open | locked."""
    lessons = flat_lessons(conn, course["id"])
    best = best_by_lesson(conn, user_id, course["id"])
    blocked = False
    units: dict[int, dict] = {}
    done = 0
    scores: list[int] = []
    next_id = None
    for l in lessons:
        st = lesson_state(l, best.get(l["id"], {}))
        locked = bool(course["sequential"]) and blocked
        status = "done" if st["complete"] else "locked" if locked else "open"
        if status == "open" and next_id is None and st["item_count"]:
            next_id = l["id"]
        if not st["complete"] and st["item_count"]:
            blocked = True
        done += st["complete"]
        if st["avg"] is not None:
            scores.append(st["avg"])
        u = units.setdefault(
            l["unit_id"], {"id": l["unit_id"], "title": l["unit_title"], "lessons": []}
        )
        u["lessons"].append(
            {
                "id": l["id"],
                "title": l["title"],
                "status": status,
                "stars": st["stars"],
                "item_count": st["item_count"],
                "done_items": st["done_items"],
                "avg": st["avg"],
                "has_recording": l["recording_id"] is not None,
            }
        )
    total = len([l for l in lessons if json.loads(l["items"])])
    return {
        "units": list(units.values()),
        "progress": {
            "lessons_done": done,
            "lessons_total": total,
            "percent": round(100 * done / total) if total else 0,
            "avg": round(sum(scores) / len(scores)) if scores else None,
            "next_lesson_id": next_id,
        },
    }


def course_summary(conn, c: sqlite3.Row) -> dict:
    n_units = conn.execute(
        "SELECT count(*) n FROM units WHERE course_id=?", (c["id"],)
    ).fetchone()["n"]
    n_les = conn.execute(
        "SELECT count(*) n FROM lessons WHERE course_id=?", (c["id"],)
    ).fetchone()["n"]
    t = conn.execute("SELECT name FROM users WHERE id=?", (c["teacher_id"],)).fetchone()
    return {
        "id": c["id"],
        "title": c["title"],
        "summary": c["summary"],
        "level": c["level"],
        "language": c["language"],
        "status": c["status"],
        "visibility": c["visibility"],
        "sequential": bool(c["sequential"]),
        "units": n_units,
        "lessons": n_les,
        "teacher": t["name"] if t else "",
    }


def audience_ids(conn, course_id: int) -> list[int]:
    rows = conn.execute(
        "SELECT user_id id FROM course_enrollments WHERE course_id=? UNION "
        "SELECT e.student_id FROM class_courses cc JOIN enrollments e ON e.class_id=cc.class_id WHERE cc.course_id=?",
        (course_id, course_id),
    ).fetchall()
    return [r["id"] for r in rows]


# ----------------------------------------------------------------------------- courses
@router.post("/courses", response_model=contracts.Course)
def create_course(
    body: CourseIn,
    user=Depends(teacher_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    cur = conn.execute(
        "INSERT INTO courses(teacher_id,title,summary,level,visibility,sequential) VALUES(?,?,?,?,?,?)",
        (
            user["id"],
            body.title.strip(),
            (body.summary or "").strip() or None,
            body.level,
            body.visibility,
            int(body.sequential),
        ),
    )
    conn.commit()
    return course_summary(
        conn,
        conn.execute("SELECT * FROM courses WHERE id=?", (cur.lastrowid,)).fetchone(),
    )


@router.get("/courses", response_model=contracts.CourseList)
def list_courses(
    q: str = "", user=Depends(current_user), conn: sqlite3.Connection = Depends(get_db)
):
    needle = q.strip().lower()

    def match(c) -> bool:
        return (
            not needle
            or needle in c["title"].lower()
            or needle in (c["summary"] or "").lower()
            or needle in c["level"].lower()
        )

    if user["role"] == "teacher":
        rows = [
            c
            for c in conn.execute(
                "SELECT * FROM courses WHERE teacher_id=? AND archived=0 ORDER BY updated_at DESC, id DESC",
                (user["id"],),
            )
            if match(c)
        ]
        out = []
        for c in rows:
            s = course_summary(conn, c)
            s["learners"] = len(audience_ids(conn, c["id"]))
            out.append(s)
        return {"mine": out, "available": []}
    mine_ids = {
        r["course_id"]
        for r in conn.execute(
            "SELECT course_id FROM course_enrollments WHERE user_id=?", (user["id"],)
        )
    }
    mine_ids |= {
        r["course_id"]
        for r in conn.execute(
            "SELECT cc.course_id FROM class_courses cc JOIN enrollments e ON e.class_id=cc.class_id WHERE e.student_id=?",
            (user["id"],),
        )
    }
    mine, avail = [], []
    for c in conn.execute(
        "SELECT * FROM courses WHERE status='published' AND archived=0 ORDER BY id DESC"
    ):
        if c["id"] in mine_ids and learner_reach(conn, user, c):
            s = course_summary(conn, c)
            s["progress"] = learner_course_view(conn, c, user["id"])["progress"]
            if match(c):
                mine.append(s)
        elif c["visibility"] == "public" and match(c):
            avail.append(course_summary(conn, c))
    return {"mine": mine, "available": avail}


@router.get("/courses/{course_id}", response_model=contracts.Course)
def get_course(
    course_id: int,
    user=Depends(current_user),
    conn: sqlite3.Connection = Depends(get_db),
):
    c, mode = visible_course(conn, user, course_id)
    out = course_summary(conn, c)
    out["mode"] = mode
    if mode == "owner":
        units = []
        for u in conn.execute(
            "SELECT * FROM units WHERE course_id=? ORDER BY position, id", (course_id,)
        ):
            ls = [
                {
                    "id": l["id"],
                    "title": l["title"],
                    "item_count": len(json.loads(l["items"])),
                    "has_recording": l["recording_id"] is not None,
                }
                for l in conn.execute(
                    "SELECT * FROM lessons WHERE unit_id=? ORDER BY position, id",
                    (u["id"],),
                )
            ]
            units.append({"id": u["id"], "title": u["title"], "lessons": ls})
        out["units"] = units
        out["classes"] = [
            dict(r)
            for r in conn.execute(
                "SELECT c.id, c.name FROM class_courses cc JOIN classes c ON c.id=cc.class_id WHERE cc.course_id=? ORDER BY c.name",
                (course_id,),
            )
        ]
        return out
    view = learner_course_view(conn, c, user["id"])
    out.update(view)
    out["enrolled"] = bool(
        conn.execute(
            "SELECT 1 FROM course_enrollments WHERE course_id=? AND user_id=?",
            (course_id, user["id"]),
        ).fetchone()
    )
    out["via_class"] = learner_reach(conn, user, c) == "class"
    return out


@router.patch("/courses/{course_id}", response_model=contracts.Course)
def patch_course(
    course_id: int,
    body: CoursePatch,
    user=Depends(teacher_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    own_course(conn, user, course_id)
    data = body.model_dump(exclude_none=True)
    if "sequential" in data:
        data["sequential"] = int(data["sequential"])
    if data:
        sets = ",".join(f"{k}=?" for k in data)
        conn.execute(
            f"UPDATE courses SET {sets}, updated_at=? WHERE id=?",
            (*data.values(), now_iso(), course_id),
        )
        conn.commit()
    return course_summary(
        conn, conn.execute("SELECT * FROM courses WHERE id=?", (course_id,)).fetchone()
    )


@router.delete("/courses/{course_id}", response_model=contracts.Ok)
def delete_course(
    course_id: int,
    user=Depends(teacher_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    own_course(conn, user, course_id)
    evidence.protect_delete(
        conn, "lesson_id IN (SELECT id FROM lessons WHERE course_id=?)", (course_id,)
    )
    conn.execute("DELETE FROM courses WHERE id=?", (course_id,))
    conn.commit()
    return {"ok": True}


@router.post("/courses/{course_id}/publish", response_model=contracts.Course)
def publish_course(
    course_id: int,
    body: PublishIn,
    user=Depends(teacher_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    own_course(conn, user, course_id)
    if body.published:
        lessons = flat_lessons(conn, course_id)
        if not lessons:
            raise HTTPException(422, "Add at least one lesson before publishing.")
        for l in lessons:
            if not json.loads(l["items"]):
                raise HTTPException(
                    422,
                    f"Lesson “{l['title']}” has no tasks yet. Add a task or delete the lesson.",
                )
    conn.execute(
        "UPDATE courses SET status=?, updated_at=? WHERE id=?",
        ("published" if body.published else "draft", now_iso(), course_id),
    )
    conn.commit()
    return course_summary(
        conn, conn.execute("SELECT * FROM courses WHERE id=?", (course_id,)).fetchone()
    )


# ----------------------------------------------------------------------------- units and lessons (authoring)
def next_position(conn, table: str, col: str, parent: int) -> int:
    row = conn.execute(
        f"SELECT coalesce(max(position),0)+1 p FROM {table} WHERE {col}=?", (parent,)
    ).fetchone()
    return row["p"]


def own_unit(conn, user, unit_id: int) -> sqlite3.Row:
    u = conn.execute(
        "SELECT u.* FROM units u JOIN courses c ON c.id=u.course_id WHERE u.id=? AND c.teacher_id=?",
        (unit_id, user["id"]),
    ).fetchone()
    if not u:
        raise HTTPException(404, "Unit not found.")
    return u


def own_lesson(conn, user, lesson_id: int) -> sqlite3.Row:
    l = conn.execute(
        "SELECT l.* FROM lessons l JOIN courses c ON c.id=l.course_id WHERE l.id=? AND c.teacher_id=?",
        (lesson_id, user["id"]),
    ).fetchone()
    if not l or l["archived"]:
        raise HTTPException(404, "Lesson not found.")
    return l


def touch(conn, course_id: int) -> None:
    conn.execute("UPDATE courses SET updated_at=? WHERE id=?", (now_iso(), course_id))


def swap(
    conn, table: str, row_id: int, siblings_sql: str, args: tuple, direction: str
) -> None:
    rows = conn.execute(siblings_sql, args).fetchall()
    ids = [r["id"] for r in rows]
    i = ids.index(row_id)
    j = i - 1 if direction == "up" else i + 1
    if 0 <= j < len(ids):
        ids[i], ids[j] = ids[j], ids[i]
        for pos, rid in enumerate(
            ids, start=1
        ):  # renumber so positions stay unique and gap-free
            conn.execute(f"UPDATE {table} SET position=? WHERE id=?", (pos, rid))


@router.post("/courses/{course_id}/units", response_model=contracts.Unit)
def add_unit(
    course_id: int,
    body: TitleIn,
    user=Depends(teacher_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    own_course(conn, user, course_id)
    cur = conn.execute(
        "INSERT INTO units(course_id,position,title) VALUES(?,?,?)",
        (
            course_id,
            next_position(conn, "units", "course_id", course_id),
            body.title.strip(),
        ),
    )
    touch(conn, course_id)
    conn.commit()
    return {"id": cur.lastrowid, "title": body.title.strip(), "lessons": []}


@router.patch("/units/{unit_id}", response_model=contracts.Ok)
def rename_unit(
    unit_id: int,
    body: TitleIn,
    user=Depends(teacher_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    u = own_unit(conn, user, unit_id)
    conn.execute("UPDATE units SET title=? WHERE id=?", (body.title.strip(), unit_id))
    touch(conn, u["course_id"])
    conn.commit()
    return {"ok": True}


@router.delete("/units/{unit_id}", response_model=contracts.Ok)
def delete_unit(
    unit_id: int, user=Depends(teacher_only), conn: sqlite3.Connection = Depends(get_db)
):
    u = own_unit(conn, user, unit_id)
    evidence.protect_delete(
        conn, "lesson_id IN (SELECT id FROM lessons WHERE unit_id=?)", (unit_id,)
    )
    conn.execute("DELETE FROM units WHERE id=?", (unit_id,))
    touch(conn, u["course_id"])
    conn.commit()
    return {"ok": True}


@router.post("/units/{unit_id}/move", response_model=contracts.Ok)
def move_unit(
    unit_id: int,
    body: MoveIn,
    user=Depends(teacher_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    u = own_unit(conn, user, unit_id)
    swap(
        conn,
        "units",
        unit_id,
        "SELECT id FROM units WHERE course_id=? ORDER BY position, id",
        (u["course_id"],),
        body.direction,
    )
    touch(conn, u["course_id"])
    conn.commit()
    return {"ok": True}


def _check_recording(conn, user, recording_id: int | None) -> None:
    if (
        recording_id
        and not conn.execute(
            "SELECT 1 FROM recordings WHERE id=? AND teacher_id=?",
            (recording_id, user["id"]),
        ).fetchone()
    ):
        raise HTTPException(422, "Recording not found.")


@router.post("/units/{unit_id}/lessons", response_model=contracts.LessonWrite)
def add_lesson(
    unit_id: int,
    body: LessonIn,
    user=Depends(teacher_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    u = own_unit(conn, user, unit_id)
    _check_recording(conn, user, body.recording_id)
    items = [clean_item(i) for i in body.items]
    cur = conn.execute(
        "INSERT INTO lessons(unit_id,course_id,position,title,intro,recording_id,items) VALUES(?,?,?,?,?,?,?)",
        (
            unit_id,
            u["course_id"],
            next_position(conn, "lessons", "unit_id", unit_id),
            body.title.strip(),
            (body.intro or "").strip() or None,
            body.recording_id,
            json.dumps(items),
        ),
    )
    touch(conn, u["course_id"])
    conn.commit()
    return {"id": cur.lastrowid, "title": body.title.strip(), "item_count": len(items)}


@router.put("/lessons/{lesson_id}", response_model=contracts.LessonWrite)
def save_lesson(
    lesson_id: int,
    body: LessonIn,
    user=Depends(teacher_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    l = own_lesson(conn, user, lesson_id)
    _check_recording(conn, user, body.recording_id)
    items = [clean_item(i) for i in body.items]
    conn.execute(
        "UPDATE lessons SET title=?, intro=?, recording_id=?, items=?, revision=revision+? WHERE id=?",
        (
            body.title.strip(),
            (body.intro or "").strip() or None,
            body.recording_id,
            json.dumps(items),
            int(items != json.loads(l["items"])),
            lesson_id,
        ),
    )
    touch(conn, l["course_id"])
    conn.commit()
    return {"id": lesson_id, "item_count": len(items)}


@router.delete("/lessons/{lesson_id}", response_model=contracts.Ok)
def delete_lesson(
    lesson_id: int,
    user=Depends(teacher_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    l = own_lesson(conn, user, lesson_id)
    evidence.protect_delete(conn, "lesson_id=?", (lesson_id,))
    conn.execute("DELETE FROM lessons WHERE id=?", (lesson_id,))
    touch(conn, l["course_id"])
    conn.commit()
    return {"ok": True}


@router.post("/lessons/{lesson_id}/move", response_model=contracts.Ok)
def move_lesson(
    lesson_id: int,
    body: MoveIn,
    user=Depends(teacher_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    l = own_lesson(conn, user, lesson_id)
    swap(
        conn,
        "lessons",
        lesson_id,
        "SELECT id FROM lessons WHERE unit_id=? ORDER BY position, id",
        (l["unit_id"],),
        body.direction,
    )
    touch(conn, l["course_id"])
    conn.commit()
    return {"ok": True}


# ----------------------------------------------------------------------------- lessons (reading)
def lesson_access(conn, user, lesson_id: int) -> tuple[sqlite3.Row, sqlite3.Row, str]:
    l = conn.execute("SELECT * FROM lessons WHERE id=?", (lesson_id,)).fetchone()
    if not l or l["archived"]:
        raise HTTPException(404, "Lesson not found.")
    c, mode = visible_course(conn, user, l["course_id"])
    if mode == "learner":
        view = learner_course_view(conn, c, user["id"])
        status = next(
            (
                x["status"]
                for u in view["units"]
                for x in u["lessons"]
                if x["id"] == lesson_id
            ),
            "locked",
        )
        if status == "locked":
            raise HTTPException(403, "Finish the lesson before this one first.")
    return l, c, mode


def lesson_items_for_learner(conn, user, lesson_id: int) -> list[dict]:
    """Used by the attempts route: the lesson's full items, only if this learner may work on it."""
    l, _, mode = lesson_access(conn, user, lesson_id)
    if mode != "learner":
        raise HTTPException(403, "Only learners can answer lesson tasks.")
    return json.loads(l["items"])


@router.get("/lessons/{lesson_id}", response_model=contracts.Lesson)
def get_lesson(
    lesson_id: int,
    user=Depends(current_user),
    conn: sqlite3.Connection = Depends(get_db),
):
    l, c, mode = lesson_access(conn, user, lesson_id)
    items = json.loads(l["items"])
    flat = flat_lessons(conn, c["id"])
    ids = [x["id"] for x in flat]
    pos = ids.index(lesson_id)
    out = {
        "id": l["id"],
        "title": l["title"],
        "intro": l["intro"],
        "recording_id": l["recording_id"],
        "unit_title": conn.execute(
            "SELECT title FROM units WHERE id=?", (l["unit_id"],)
        ).fetchone()["title"],
        "course": {"id": c["id"], "title": c["title"]},
        "position": pos + 1,
        "lesson_total": len(ids),
        "next_lesson_id": ids[pos + 1] if pos + 1 < len(ids) else None,
        "mode": mode,
    }
    if mode == "owner":
        out["items"] = items
    else:
        out["items"] = evidence.public_versioned(items)
        best = best_by_lesson(conn, user["id"], c["id"]).get(lesson_id, {})
        out["best"] = {str(k): v for k, v in best.items()}
    return out


def can_hear_lesson_recording(conn, user, recording_id: int) -> bool:
    rows = conn.execute(
        "SELECT id FROM lessons WHERE recording_id=? AND archived=0", (recording_id,)
    ).fetchall()
    for r in rows:
        try:
            lesson_access(conn, user, r["id"])
            return True
        except HTTPException:
            continue
    return False


# ----------------------------------------------------------------------------- learners: enrol, class courses
@router.post("/courses/{course_id}/enroll", response_model=contracts.Ok)
def enroll(
    course_id: int,
    user=Depends(learner_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    c = conn.execute("SELECT * FROM courses WHERE id=?", (course_id,)).fetchone()
    if not c or not learner_reach(conn, user, c):
        raise HTTPException(404, "Course not found.")
    conn.execute(
        "INSERT OR IGNORE INTO course_enrollments(course_id,user_id) VALUES(?,?)",
        (course_id, user["id"]),
    )
    conn.commit()
    return {"ok": True}


@router.delete("/courses/{course_id}/enroll", response_model=contracts.Ok)
def leave(
    course_id: int,
    user=Depends(learner_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    conn.execute(
        "DELETE FROM course_enrollments WHERE course_id=? AND user_id=?",
        (course_id, user["id"]),
    )
    conn.commit()
    return {"ok": True}


@router.post("/classes/{class_id}/courses", response_model=contracts.Ok)
def assign_course(
    class_id: int,
    body: ClassCourseIn,
    user=Depends(teacher_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    need_class(conn, user, class_id)
    c = own_course(conn, user, body.course_id)
    if c["status"] != "published":
        raise HTTPException(422, "Publish the course before giving it to a class.")
    conn.execute(
        "INSERT OR IGNORE INTO class_courses(class_id,course_id) VALUES(?,?)",
        (class_id, body.course_id),
    )
    conn.commit()
    return {"ok": True}


@router.delete("/classes/{class_id}/courses/{course_id}", response_model=contracts.Ok)
def unassign_course(
    class_id: int,
    course_id: int,
    user=Depends(teacher_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    need_class(conn, user, class_id)
    conn.execute(
        "DELETE FROM class_courses WHERE class_id=? AND course_id=?",
        (class_id, course_id),
    )
    conn.commit()
    return {"ok": True}


@router.get("/classes/{class_id}/courses", response_model=list[contracts.Course])
def class_courses(
    class_id: int,
    user=Depends(current_user),
    conn: sqlite3.Connection = Depends(get_db),
):
    need_class(conn, user, class_id)
    out = []
    for c in conn.execute(
        "SELECT c.* FROM class_courses cc JOIN courses c ON c.id=cc.course_id WHERE cc.class_id=? ORDER BY cc.assigned_at DESC",
        (class_id,),
    ):
        s = course_summary(conn, c)
        if user["role"] == "teacher":
            ids = [
                r["student_id"]
                for r in conn.execute(
                    "SELECT student_id FROM enrollments WHERE class_id=?", (class_id,)
                )
            ]
            pcts = [learner_course_view(conn, c, i)["progress"]["percent"] for i in ids]
            s["class_percent"] = round(sum(pcts) / len(pcts)) if pcts else None
        else:
            s["progress"] = learner_course_view(conn, c, user["id"])["progress"]
        out.append(s)
    return out


# ----------------------------------------------------------------------------- teacher: progress
@router.get("/courses/{course_id}/progress", response_model=contracts.Progress)
def course_progress(
    course_id: int,
    user=Depends(teacher_only),
    conn: sqlite3.Connection = Depends(get_db),
):
    c = own_course(conn, user, course_id)
    lessons = [l for l in flat_lessons(conn, course_id) if json.loads(l["items"])]
    people = []
    funnel = {
        l["id"]: {
            "id": l["id"],
            "title": l["title"],
            "completed": 0,
            "avg_sum": 0,
            "avg_n": 0,
        }
        for l in lessons
    }
    for uid in audience_ids(conn, course_id):
        u = conn.execute(
            "SELECT id,name,email FROM users WHERE id=?", (uid,)
        ).fetchone()
        if not u:
            continue
        view = learner_course_view(conn, c, uid)
        for unit in view["units"]:
            for ls in unit["lessons"]:
                f = funnel.get(ls["id"])
                if f and ls["status"] == "done":
                    f["completed"] += 1
                if f and ls["avg"] is not None:
                    f["avg_sum"] += ls["avg"]
                    f["avg_n"] += 1
        stats = summarize(
            conn,
            uid,
            "AND lesson_id IN (SELECT id FROM lessons WHERE course_id=?)",
            (course_id,),
        )
        classes = [
            r["name"]
            for r in conn.execute(
                "SELECT cl.name FROM class_courses cc JOIN classes cl ON cl.id=cc.class_id JOIN enrollments e ON e.class_id=cl.id "
                "WHERE cc.course_id=? AND e.student_id=?",
                (course_id, uid),
            )
        ]
        people.append(
            {
                "id": uid,
                "name": u["name"],
                "email": u["email"],
                "classes": classes,
                **view["progress"],
                "last_active": stats["last_active"],
                "attempts": stats["attempts"],
                "needs_help": stats["recent_avg"] is not None
                and stats["recent_avg"] < 60,
            }
        )
    people.sort(key=lambda p: p["name"])
    return {
        "course": course_summary(conn, c),
        "learners": people,
        "lessons": [
            {
                "id": f["id"],
                "title": f["title"],
                "completed": f["completed"],
                "avg": round(f["avg_sum"] / f["avg_n"]) if f["avg_n"] else None,
            }
            for f in funnel.values()
        ],
    }


# ----------------------------------------------------------------------------- personalised review
@router.get("/me/review", response_model=contracts.Review)
def review(user=Depends(learner_only), conn: sqlite3.Connection = Depends(get_db)):
    """Past mistakes that are due to come back, oldest and weakest first.

    Scheduling is Leitner: a task returns after 1, 2, 4, 8 then 16 days, moving up a box each
    time it is answered well and dropping back to the first box when it is not. A task that
    survives the longest gap is treated as learned and stops appearing.
    """
    out: list[dict] = []
    for d in insights.due_for_review(conn, user["id"], limit=20):
        src = d["source"]
        item = None
        try:
            if src.get("lesson_id"):
                l, _, _ = lesson_access(conn, user, src["lesson_id"])
                item = json.loads(l["items"])[src["item_index"]]
            elif src.get("set_id") and src["set_id"] in SETS:
                item = SETS[src["set_id"]]["items"][src["item_index"]]
            elif src.get("assignment_id"):
                row = need_assignment(conn, user, src["assignment_id"])
                item = json.loads(row["items"])[src["item_index"]]
        except (HTTPException, IndexError, TypeError, KeyError):
            continue
        if item is not None:
            out.append(
                {
                    **public_item(item),
                    "source": src,
                    "last_score": d["last_score"],
                    "box": d["box"],
                    "item_version": evidence.version(item),
                    "reason": d.get("reason"),
                    "evidence_ids": d.get("evidence_ids", []),
                    "priority": d.get("priority"),
                    "policy_version": evidence.POLICY_VERSION,
                }
            )
        if len(out) >= 8:
            break
    return {
        "items": out,
        "title": "Your review",
        "weak_skills": insights.weak_skills(conn, user["id"]),
    }
