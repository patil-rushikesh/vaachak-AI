"""Release acceptance: safe retries, editable reviewed content, withdrawal and roles."""
import uuid

import db
import knowledge
from conftest import make_user


def payload(**overrides):
    return dict(skill_code="MORPH.AGREEMENT", title="Use she goes",
                body="In the simple present, use she goes and he likes.", **overrides)


def test_retry_safe_creation_and_trimmed_validation(client, world):
    data = payload(client_uuid=str(uuid.uuid4()))
    first = client.post("/api/teacher/knowledge", headers=world["t"], json=data)
    second = client.post("/api/teacher/knowledge", headers=world["t"], json=data)
    assert first.status_code == second.status_code == 200
    assert first.json() == second.json()
    assert first.json()["can_manage"] is True
    changed = {**data, "body": "Another explanation"}
    assert client.post("/api/teacher/knowledge", headers=world["t"], json=changed).status_code == 409
    other = make_user(client, "teacher", "Another owner", "note-owner@example.test")
    assert client.post("/api/teacher/knowledge", headers=other, json=data).json()["id"] != first.json()["id"]
    for field in ("title", "body", "skill_code"):
        invalid = client.post("/api/teacher/knowledge", headers=world["t"], json={**data, field: "   "})
        assert invalid.status_code == 422
        assert invalid.json()["error"]["request_id"]


def test_edit_invalidates_review_and_withdraw_removes_from_retrieval(client, world):
    h = world["t"]
    created = client.post("/api/teacher/knowledge", headers=h, json=payload()).json()
    path = f"/api/teacher/knowledge/{created['id']}"
    other = make_user(client, "teacher", "Other", "note-other@example.test")
    changed = {**payload(), "body": "Use she likes tea.", "version": 1}
    for method, suffix, data in (("PUT", "", changed), ("POST", "/withdraw", {"version": 1})):
        assert client.request(method, path + suffix, headers=other, json=data).status_code == 404
        assert client.request(method, path + suffix, headers=world["a"], json=data).status_code == 403
        assert client.request(method, path + suffix, json=data).status_code == 401
    for action in ("review", "publish"):
        assert client.post(path + "/" + action, headers=h, json={"version": 1}).status_code == 200
    shared = client.get("/api/teacher/knowledge", headers=other).json()["units"]
    assert next(u for u in shared if u["id"] == created["id"])["can_manage"] is False
    edited = client.put(path, headers=h, json=changed)
    assert edited.status_code == 200
    assert edited.json()["version"] == 2
    assert edited.json()["status"] == "draft" and edited.json()["visibility"] == "private"
    assert edited.json()["reviewed_at"] is None and edited.json()["published_at"] is None
    assert client.put(path, headers=h, json=changed).status_code == 409
    for action in ("review", "publish", "withdraw"):
        assert client.post(path + "/" + action, headers=h, json={"version": 1}).status_code == 409
    assert client.post(path + "/publish", headers=h, json={"version": 2}).status_code == 409
    for action in ("review", "publish", "withdraw", "withdraw"):
        assert client.post(path + "/" + action, headers=h, json={"version": 2}).status_code == 200
    with db.connect() as conn:
        owner = conn.execute("SELECT owner_id FROM knowledge_units WHERE id=?", (created["id"],)).fetchone()[0]
        for viewer in (None, owner):
            assert created["id"] not in {r["id"] for r in knowledge.retrieve(conn, "MORPH.AGREEMENT", owner_id=viewer, limit=100)}
    assert client.post(path + "/review", headers=h, json={"version": 2}).status_code == 409
    assert client.post(path + "/publish", headers=h, json={"version": 2}).status_code == 409
    assert client.put(path, headers=h, json={**changed, "version": 2}).json()["status"] == "draft"


def test_knowledge_starter_units_cannot_be_edited(client, world):
    units = client.get("/api/teacher/knowledge", headers=world["t"]).json()["units"]
    starter = next(u for u in units if u["id"].startswith("builtin-"))
    assert not starter["can_manage"]
    assert client.put(f"/api/teacher/knowledge/{starter['id']}", headers=world["t"], json=payload(version=1)).status_code == 404


def test_catalog_coaching_uses_notes_without_inventing_assessed_skills(client, world, monkeypatch):
    import ai
    seen = {}
    monkeypatch.setattr(ai, "configured", lambda: True)
    def coach(*args, **kwargs):
        units = kwargs["knowledge"]
        seen["units"] = units
        return {"score": 80, "verdict": "Check the verb ending.", "grammar": [], "strengths": [],
                "next_line": "Try he likes music.", "source_ids": [units[0]["id"]]}
    monkeypatch.setattr(ai, "coach", coach)
    r = client.post("/api/attempts", headers=world["a"], data={"set_id": "en-present-agreement", "item_index": 0, "transcript": "She go to school."})
    assert r.status_code == 200, r.text
    result = r.json()
    assert seen["units"][0]["skill_code"] == "MORPH.AGREEMENT"
    assert result["sources"][0]["version"] == seen["units"][0]["version"]
    assert result["skill_ids"] == [] and result["assessed_skills"] == []
    assert client.get(f"/api/attempts/{result['id']}", headers=world["a"]).json()["sources"] == result["sources"]
    with db.connect() as conn:
        assert knowledge.for_practice(conn, {"kind": "free"}, set_id="en-talk") == []
        units = knowledge.for_practice(conn, {"skill_ids": ["SYN.ARTICLE", "SYN.PREPOSITION"]}, set_id="en-present-agreement")
        assert 0 < len(units) <= 3
        assert all(u["skill_code"].startswith("SYN.") for u in units)
