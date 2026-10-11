"""Reviewed teaching units for grounded coaching (G2).

A small base of short, skill-tagged explanations. The coach is given at most a few units and
must cite the ids it used; the server validates those ids against what it actually sent, so the
model cannot invent a source. Retrieval is deterministic keyword matching, so it runs on any
SQLite build (no FTS5 dependency) and can be replayed for a given attempt.
"""
from __future__ import annotations

import re
import uuid

import skills as skilldef
from evidence import now

_STOP = {"the", "a", "an", "to", "of", "is", "are", "and", "in", "on", "it", "you", "he",
         "she", "they", "we", "my", "your", "with", "for", "this", "that", "do", "does"}


def _words(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-z]+", (text or "").lower()) if w not in _STOP and len(w) > 2}


def create(conn, *, skill_code, title, body, example=None, level="A1", language="en",
           owner_id=None, visibility="public", status="approved") -> str:
    uid = uuid.uuid4().hex
    conn.execute(
        "INSERT INTO knowledge_units(id,skill_code,level,language,title,body,example,source,"
        "owner_id,visibility,status,version,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (uid, skilldef.normalise(skill_code), level, language, title.strip(), body.strip(),
         (example or "").strip() or None, "Teacher note" if owner_id else "Vaachak reviewed",
         owner_id, visibility, status, 1, now()))
    return uid


def _row(r) -> dict:
    return {"id": r["id"], "skill_code": r["skill_code"], "title": r["title"], "body": r["body"],
            "example": r["example"], "source": r["source"], "version": r["version"], "level": r["level"]}


def list_for_teacher(conn, owner_id: int) -> list[dict]:
    rows = conn.execute(
        "SELECT * FROM knowledge_units WHERE visibility='public' OR owner_id=? "
        "ORDER BY skill_code, title", (owner_id,)).fetchall()
    return [_row(r) for r in rows]


def retrieve(conn, skill_code, text: str = "", language: str = "en",
             owner_id: int | None = None, limit: int = 3) -> list[dict]:
    """Up to `limit` approved units for this skill, best keyword match first.

    owner_id None retrieves only public units (what a learner sees). A teacher may pass their
    own id to also see their private units. Teacher-private units never leak to other users.
    """
    code = skilldef.normalise(skill_code)
    domain = code.split(".")[0]
    rows = conn.execute(
        "SELECT * FROM knowledge_units WHERE status='approved' AND language=? "
        "AND (visibility='public' OR owner_id IS ?) AND (skill_code=? OR skill_code LIKE ?)",
        (language, owner_id, code, domain + ".%")).fetchall()
    if not rows:
        return []
    q = _words(text)

    def rank(r):
        overlap = len(q & _words(f"{r['title']} {r['body']} {r['example'] or ''}"))
        return (2 if r["skill_code"] == code else 0) + overlap

    return [_row(r) for r in sorted(rows, key=rank, reverse=True)[:limit]]
