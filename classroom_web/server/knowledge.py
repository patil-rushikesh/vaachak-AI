"""Reviewed teaching units for grounded coaching (G2).

A small base of short, skill-tagged explanations. The coach is given at most a few units and
must cite the ids it used; the server validates those ids against what it actually sent, so the
model cannot invent a source. Retrieval is deterministic keyword matching, so it runs on any
SQLite build (no FTS5 dependency) and can be replayed for a given attempt.
"""
from __future__ import annotations

import re
import uuid
from fastapi import HTTPException

import skills as skilldef
from evidence import now

_STOP = {"the", "a", "an", "to", "of", "is", "are", "and", "in", "on", "it", "you", "he",
         "she", "they", "we", "my", "your", "with", "for", "this", "that", "do", "does"}

# Curated coaching context for the focused legacy sets, whose items predate skill tags.
# These are retrieval hints only, never evidence that a reading assesses grammar or acoustics.
CATALOG_COACHING_SKILLS = {
    "en-present-agreement": ["MORPH.AGREEMENT"],
    "en-th-sounds": ["PHON.TH"],
    "en-w-v": ["PHON.VW"],
}


def for_practice(conn, item: dict, *, set_id: str | None = None, text: str = "") -> list[dict]:
    codes = item.get("skill_ids") or CATALOG_COACHING_SKILLS.get(set_id, [])
    found = {}
    for code in codes[:4]:
        for unit in retrieve(conn, code, text=text, limit=3):
            found.setdefault(unit["id"], unit)
    return list(found.values())[:3]


def _words(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-z]+", (text or "").lower()) if w not in _STOP and len(w) > 2}


def create(conn, *, skill_code, title, body, example=None, level="A1", language="en",
           owner_id=None, visibility="private", status="draft", client_uuid=None) -> str:
    uid = (uuid.uuid5(uuid.NAMESPACE_URL, f"vaachak:note:{owner_id}:{client_uuid}").hex
           if client_uuid else uuid.uuid4().hex)
    if client_uuid:
        existing = conn.execute("SELECT * FROM knowledge_units WHERE id=?", (uid,)).fetchone()
        if existing:
            expected = (skilldef.normalise(skill_code), title.strip(), body.strip(),
                        (example or "").strip() or None, level, language, owner_id)
            actual = tuple(existing[k] for k in ("skill_code", "title", "body", "example", "level", "language", "owner_id"))
            if actual != expected:
                raise HTTPException(409, "This save was already used for a different note. Refresh your teaching notes.")
            return uid
    conn.execute(
        "INSERT INTO knowledge_units(id,skill_code,level,language,title,body,example,source,"
        "owner_id,visibility,status,version,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (uid, skilldef.normalise(skill_code), level, language, title.strip(), body.strip(),
         (example or "").strip() or None, "Teacher note" if owner_id else "Vaachak reviewed",
         owner_id, visibility, status, 1, now()))
    return uid


def _row(r, viewer_id=None) -> dict:
    return {"id": r["id"], "skill_code": r["skill_code"], "title": r["title"], "body": r["body"],
            "example": r["example"], "source": r["source"], "version": r["version"], "level": r["level"],
            "language": r["language"], "visibility": r["visibility"], "status": r["status"],
            "reviewed_by": r["reviewed_by"], "reviewed_at": r["reviewed_at"],
            "published_at": r["published_at"],
            "can_manage": viewer_id is not None and r["owner_id"] == viewer_id}


def transition(conn, unit_id: str, owner_id: int, action: str, version: int) -> dict:
    """Explicit owner review and publication; repeated requests are safe."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        row = conn.execute("SELECT * FROM knowledge_units WHERE id=? AND owner_id=?",
                           (unit_id, owner_id)).fetchone()
        if not row:
            raise HTTPException(404, "Teaching note not found.")
        if row["version"] != version:
            raise HTTPException(409, "The note changed. Read it again before reviewing.")
        if action == "review":
            if row["status"] not in ("draft", "approved", "published"):
                raise HTTPException(409, "Edit this withdrawn note before reviewing it again.")
            if row["status"] == "draft":
                conn.execute("UPDATE knowledge_units SET status='approved',reviewed_by=?,reviewed_at=? WHERE id=?",
                             (owner_id, now(), unit_id))
        elif action == "publish":
            if row["status"] not in ("approved", "published") or not row["reviewed_at"]:
                raise HTTPException(409, "Review this note before publishing it.")
            if row["status"] != "published":
                conn.execute("UPDATE knowledge_units SET status='published',visibility='public',published_at=? WHERE id=?",
                             (now(), unit_id))
        elif action == "withdraw":
            if row["status"] != "withdrawn":
                conn.execute("UPDATE knowledge_units SET status='withdrawn',visibility='private' WHERE id=?", (unit_id,))
        else:
            raise ValueError("Unknown knowledge transition")
        result = _row(conn.execute("SELECT * FROM knowledge_units WHERE id=?", (unit_id,)).fetchone(), owner_id)
        conn.commit()
        return result
    except Exception:
        conn.rollback()
        raise


def list_for_teacher(conn, owner_id: int) -> list[dict]:
    rows = conn.execute(
        "SELECT * FROM knowledge_units WHERE (visibility='public' AND status='published') OR owner_id=? "
        "ORDER BY skill_code, title", (owner_id,)).fetchall()
    return [_row(r, owner_id) for r in rows]


def update(conn, unit_id: str, owner_id: int, version: int, values: dict) -> dict:
    """An edit is a new private draft; old reviews never apply to changed content."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        row = conn.execute("SELECT * FROM knowledge_units WHERE id=? AND owner_id=?", (unit_id, owner_id)).fetchone()
        if not row:
            raise HTTPException(404, "Teaching note not found.")
        if row["version"] != version:
            raise HTTPException(409, "The note changed. Refresh your teaching notes before editing.")
        conn.execute(
            "UPDATE knowledge_units SET skill_code=?,title=?,body=?,example=?,level=?,language=?,"
            "version=version+1,status='draft',visibility='private',reviewed_by=NULL,reviewed_at=NULL,published_at=NULL WHERE id=?",
            (values["skill_code"], values["title"], values["body"], values.get("example") or None,
             values["level"], values["language"], unit_id))
        result = _row(conn.execute("SELECT * FROM knowledge_units WHERE id=?", (unit_id,)).fetchone(), owner_id)
        conn.commit()
        return result
    except Exception:
        conn.rollback()
        raise


def retrieve(conn, skill_code, text: str = "", language: str = "en",
             owner_id: int | None = None, limit: int = 3) -> list[dict]:
    """Up to `limit` approved units for this skill, best keyword match first.

    owner_id None retrieves only public units (what a learner sees). A teacher may pass their
    own id to also see their private units. Teacher-private units never leak to other users.
    """
    code = skilldef.normalise(skill_code)
    domain = code.split(".")[0]
    rows = conn.execute(
        "SELECT * FROM knowledge_units WHERE language=? "
        "AND ((visibility='public' AND status='published') OR (owner_id=? AND status='approved')) "
        "AND (skill_code=? OR skill_code LIKE ?)",
        (language, owner_id, code, domain + ".%")).fetchall()
    if not rows:
        return []
    q = _words(text)

    def rank(r):
        overlap = len(q & _words(f"{r['title']} {r['body']} {r['example'] or ''}"))
        return (2 if r["skill_code"] == code else 0) + overlap

    return [_row(r) for r in sorted(rows, key=rank, reverse=True)[:limit]]
