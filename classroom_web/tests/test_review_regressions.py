"""Regression coverage for the G1/G2 code review: fairness, privacy and lifecycle."""
import json
import sqlite3
import uuid

import pytest
import ai
import db
import evidence
import feedback
import knowledge
from conftest import make_user


def note(client, headers, visibility="private"):
    r = client.post("/api/teacher/knowledge", headers=headers, json={
        "skill_code": "MORPH.AGREEMENT", "title": "Review fixture",
        "body": "Use she goes in the simple present.", "visibility": visibility,
    })
    assert r.status_code == 200, r.text
    return r.json()


def retrieved_ids():
    with db.connect() as conn:
        return {u["id"] for u in knowledge.retrieve(conn, "MORPH.AGREEMENT", limit=50)}


def test_knowledge_requires_owned_versioned_review_then_publication(client, world):
    n = note(client, world["t"], "public")
    assert n["status"] == "draft" and n["id"] not in retrieved_ids()
    base = f"/api/teacher/knowledge/{n['id']}"
    other = make_user(client, "teacher", "Other", "other-review@example.test")
    for action in ("review", "publish"):
        assert client.post(base + "/" + action, headers=other, json={"version": 1}).status_code == 404
        assert client.post(base + "/" + action, headers=world["a"], json={"version": 1}).status_code == 403
    assert client.post(base + "/publish", headers=world["t"], json={"version": 1}).status_code == 409
    assert client.post(base + "/review", headers=world["t"], json={"version": 2}).status_code == 409
    reviewed = client.post(base + "/review", headers=world["t"], json={"version": 1})
    assert reviewed.status_code == 200 and reviewed.json()["reviewed_by"]
    assert reviewed.json()["reviewed_at"] and n["id"] not in retrieved_ids()
    for _ in range(2):
        published = client.post(base + "/publish", headers=world["t"], json={"version": 1})
        assert published.status_code == 200 and published.json()["published_at"]
    assert n["id"] in retrieved_ids()
    # A draft is not exposed through another teacher's listing either.
    draft = note(client, world["t"], "public")
    listed = client.get("/api/teacher/knowledge", headers=other).json()["units"]
    assert draft["id"] not in {r["id"] for r in listed}


def test_erasure_removes_private_and_public_owned_notes(client):
    teacher = make_user(client, "teacher", "Owner", "erase-knowledge@example.test")
    private = note(client, teacher)
    public = note(client, teacher, "public")
    for n in (private, public):
        assert client.post(f"/api/teacher/knowledge/{n['id']}/review", headers=teacher, json={"version": 1}).status_code == 200
    assert client.post(f"/api/teacher/knowledge/{public['id']}/publish", headers=teacher, json={"version": 1}).status_code == 200
    exported = client.get("/api/me/export", headers=teacher).json()
    assert {r["id"] for r in exported["owned_content"]["knowledge_units"]} == {private["id"], public["id"]}
    assert client.request("DELETE", "/api/me", headers=teacher, json={"password": "password-123"}).status_code == 200
    assert not {private["id"], public["id"]} & retrieved_ids()
    with db.connect() as conn:
        assert not conn.execute("SELECT 1 FROM knowledge_units WHERE id IN (?,?)", (private["id"], public["id"])).fetchall()


def test_ownerless_private_note_is_never_public(client):
    with db.connect() as conn:
        uid = knowledge.create(conn, skill_code="MORPH.AGREEMENT", title="Orphan",
                               body="Private", visibility="private", status="approved")
        conn.commit()
        assert uid not in {r["id"] for r in knowledge.retrieve(conn, "MORPH.AGREEMENT", limit=50)}


def test_startup_installs_content_idempotently_without_touching_users(client, world):
    n = note(client, world["t"])
    with db.connect() as conn:
        before = [tuple(r) for r in conn.execute("SELECT * FROM users ORDER BY id")]
        conn.execute("DELETE FROM knowledge_units WHERE id LIKE 'builtin-%'")
        conn.commit()
    db.init()
    db.init()
    with db.connect() as conn:
        assert before == [tuple(r) for r in conn.execute("SELECT * FROM users ORDER BY id")]
        assert conn.execute("SELECT count(*) FROM knowledge_units WHERE id LIKE 'builtin-%'").fetchone()[0] == 8
        assert conn.execute("SELECT status FROM knowledge_units WHERE id=?", (n["id"],)).fetchone()[0] == "draft"


@pytest.mark.parametrize("target,heard", [
    ("This is a nice man", "This is an ice man"),
    ("I enjoy ice cream", "I enjoy I scream"),
])
def test_different_phrases_are_not_perfect_readings(target, heard):
    r = feedback.analyse("read", target, heard)
    assert r["score"] is None or r["score"] < 100


def test_model_cannot_reintroduce_boundary_correction(monkeypatch):
    monkeypatch.setattr(ai, "configured", lambda: True)
    monkeypatch.setattr(ai, "coach", lambda *a, **k: {
        "score": 75, "verdict": "Use two words instead of everyday.", "strengths": [],
        "grammar": [{"said": "everyday", "fix": "every day", "why": "Use two words.", "skill": "LEX.CHOICE"}],
        "next_line": "Try again.",
    })
    r = feedback.analyse_full("read", "I study every day", "I study everyday")
    assert r["score"] == 100 and r["grammar"] == [] and r["source"] == "rules"
    assert "two words" not in json.dumps(r)


def test_unscored_does_not_call_ai(monkeypatch):
    monkeypatch.setattr(ai, "configured", lambda: True)
    def unexpected(*args, **kwargs):
        pytest.fail("Uncertain transcript must not be coached as a learner error")
    monkeypatch.setattr(ai, "coach", unexpected)
    r = feedback.analyse_full("read", "She goes to school", "zzz")
    assert r["score"] is None and not r["evidence_eligible"]


def test_unscored_preserves_history_without_affecting_scores_or_review(client, world):
    h = world["a"]
    data = {"set_id": "en-present-agreement", "item_index": 0, "transcript": "She goes to school."}
    assert client.post("/api/attempts", headers=h, data=data).status_code == 200
    before = client.get("/api/me/stats", headers=h).json()
    bad = client.post("/api/attempts", headers=h, data={**data, "transcript": "zzz", "client_uuid": "unscored-review-1"})
    assert bad.status_code == 200 and bad.json()["score"] is None
    assert bad.json()["evaluation_status"] == "unscored"
    after = client.get("/api/me/stats", headers=h).json()
    assert after == before
    # Stored older G1 rows are sanitized on read as well.
    with db.connect() as conn:
        row = conn.execute("SELECT * FROM attempts WHERE id=?", (bad.json()["id"],)).fetchone()
        legacy = json.loads(row["result"])
        legacy.update(score=0, accuracy=0, grammar=[{"skill": "PHON.WORD"}], tips=["You failed."])
        conn.execute("UPDATE attempts SET result=? WHERE id=?", (json.dumps(legacy), row["id"]))
        conn.commit()
    historical = client.get(f"/api/attempts/{bad.json()['id']}", headers=h).json()
    assert historical["score"] is None and historical["grammar"] == []
    assert "You failed" not in json.dumps(historical)
    import insights
    with db.connect() as conn:
        user = conn.execute("SELECT id FROM users WHERE email='asha@s.test'").fetchone()[0]
        assert insights.skill_counts(conn, user) == {}
        assert insights.due_for_review(conn, user) == []


def test_unscored_personal_session_is_not_completed_or_scheduled(client, world):
    key = str(uuid.uuid4())
    h = world["a"]
    assert client.post("/api/me/practice-sessions", headers=h, json={"client_uuid": key, "count": 1}).status_code == 200
    with db.connect() as conn:
        conn.execute("UPDATE practice_sessions SET items=? WHERE id=?", (json.dumps([{"kind": "read", "text": "I like tea."}]), key))
        conn.commit()
    bad = client.post("/api/attempts", headers=h, data={"practice_session_id": key, "item_index": 0, "transcript": "zzz"})
    assert bad.status_code == 200 and bad.json()["score"] is None
    state = client.get(f"/api/me/practice-sessions/{key}", headers=h).json()
    assert state["position"] == 0 and not state["completed"]
    assert client.get("/api/me/review-queue", headers=h).json()["items"] == []


def test_upgrade_quarantines_unreviewed_notes_and_preserves_history(monkeypatch):
    import migrations
    import growth_migrations as gm
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(db.SCHEMA)
    migrations.migrate(conn)
    all_migrations = gm.MIGRATIONS
    monkeypatch.setattr(gm, "MIGRATIONS", [m for m in all_migrations if m[0] <= 6])
    gm.migrate(conn)
    owner = conn.execute("INSERT INTO users(role,name,email,pw_hash) VALUES('teacher','Fixture','fixture@test','test')").lastrowid
    conn.execute("INSERT INTO knowledge_units(id,skill_code,title,body,owner_id,visibility,created_at) VALUES('legacy','MORPH.AGREEMENT','Note','Text',?,'public','2026-01-01')", (owner,))
    conn.execute("INSERT INTO knowledge_units(id,skill_code,title,body,visibility,created_at) VALUES('orphan','MORPH.AGREEMENT','Note','Private','private','2026-01-01')")
    conn.execute("INSERT INTO practice_sessions(id,user_id,request_hash,title,items,reason,position,completed,created_at) VALUES('old-session',?,'hash','Old session',?,'fixture',1,1,'2026-01-01')",
                 (owner, json.dumps([{"kind": "read", "text": "Hello."}])))
    conn.execute("INSERT INTO attempts(user_id,practice_session_id,item_index,kind,transcript,score,result) VALUES(?,'old-session',0,'read','zzz',0,?)",
                 (owner, json.dumps({"evaluation_status": "unscored", "score": 0})))
    conn.commit()
    monkeypatch.setattr(gm, "MIGRATIONS", all_migrations)
    gm.migrate(conn)
    gm.migrate(conn)
    assert conn.execute("SELECT status FROM knowledge_units WHERE id='legacy'").fetchone()[0] == "draft"
    assert conn.execute("SELECT 1 FROM knowledge_units WHERE id='orphan'").fetchone() is None
    assert conn.execute("SELECT count(*) FROM users").fetchone()[0] == 1
    state = conn.execute("SELECT position,completed,revision FROM practice_sessions WHERE id='old-session'").fetchone()
    assert tuple(state) == (0, 0, 2)
    assert conn.execute("SELECT count(*) FROM attempts").fetchone()[0] == 1
    assert conn.execute("SELECT count(*) FROM scored_attempts").fetchone()[0] == 0
    conn.execute("DELETE FROM users WHERE id=?", (owner,))
    assert conn.execute("SELECT count(*) FROM knowledge_units").fetchone()[0] == 0
    conn.close()


def test_partial_reading_rejects_ai_segmentation_correction(monkeypatch):
    monkeypatch.setattr(ai, "configured", lambda: True)
    monkeypatch.setattr(ai, "coach", lambda *a, **k: {
        "score": 60, "verdict": "Everyday is wrong.", "strengths": [],
        "grammar": [{"said": "everyday", "fix": "every day", "why": "Wrong spacing", "skill": "LEX.CHOICE"}],
        "next_line": "Try again.",
    })
    r = feedback.analyse_full("read", "I study every day after school", "I study everyday before school")
    assert r["score"] < 100 and r["source"] == "rules"
    assert "Wrong spacing" not in json.dumps(r)


def test_uncertain_course_attempt_does_not_complete_a_lesson(client, world):
    from test_courses import build_course
    cid, _, lesson = build_course(client, world["t"], sequential=False)
    h = world["a"]
    right = client.post("/api/attempts", headers=h, data={"lesson_id": lesson, "item_index": 0, "choice": 0})
    assert right.status_code == 200
    bad = client.post("/api/attempts", headers=h, data={"lesson_id": lesson, "item_index": 1, "transcript": "zzz"})
    assert bad.status_code == 200 and bad.json()["score"] is None
    shown = client.get(f"/api/lessons/{lesson}", headers=h).json()
    assert shown["best"] == {"0": 100}
    from courses import best_by_lesson, lesson_state
    with db.connect() as conn:
        user = conn.execute("SELECT id FROM users WHERE email='asha@s.test'").fetchone()[0]
        row = conn.execute("SELECT * FROM lessons WHERE id=?", (lesson,)).fetchone()
        state = lesson_state(row, best_by_lesson(conn, user, cid)[lesson])
        assert not state["complete"] and state["done_items"] == 1 and state["avg"] == 100
