import uuid
import json
import db
from datetime import datetime, timedelta, timezone


def key():
    return str(uuid.uuid4())


def start(client, h, **kw):
    return client.post(
        "/api/me/practice-sessions", headers=h, json={"client_uuid": key(), **kw}
    )


def test_profile_sessions_submission_resume_and_scope(client, world):
    h = world["a"]
    assert (
        client.get("/api/me/learning-profile", headers=h).json()["configured"] is False
    )
    assert (
        client.put(
            "/api/me/learning-profile",
            headers=h,
            json={"goal": "interview", "weekly_goal": 4},
        ).status_code
        == 200
    )
    token = key()
    body = {"client_uuid": token, "count": 2}
    a = client.post("/api/me/practice-sessions", headers=h, json=body)
    assert a.status_code == 200, a.text
    assert (
        client.post("/api/me/practice-sessions", headers=h, json=body).json()
        == a.json()
    )
    assert (
        client.post(
            "/api/me/practice-sessions", headers=h, json={**body, "count": 3}
        ).status_code
        == 409
    )
    assert (
        client.get("/api/me/practice-sessions/" + token, headers=world["b"]).status_code
        == 404
    )
    with db.connect() as conn:
        items = json.loads(
            conn.execute(
                "SELECT items FROM practice_sessions WHERE id=?", (token,)
            ).fetchone()[0]
        )
    for i, item in enumerate(items):
        data = {"practice_session_id": token, "item_index": i, "client_uuid": key()}
        if item["kind"] in ("choice", "fill", "listen"):
            data["choice"] = item["correct"]
        else:
            data["transcript"] = (
                item.get("text") or item.get("answer") or "I work on a college project."
            )
        response = client.post("/api/attempts", headers=h, data=data)
        assert response.status_code == 200, response.text
        assert response.json()["practice_session_id"] == token
        assert (
            client.post("/api/attempts", headers=h, data=data).json()["id"]
            == response.json()["id"]
        )
    result = client.get("/api/me/practice-sessions/" + token, headers=h).json()
    assert result["completed"] and result["position"] == 2
    assert client.get("/api/me/practice-sessions", headers=h).json() == []
    assert start(client, h).status_code == 200


def test_drafts_conflicts_owner_and_archives(client, world):
    k = key()
    url = "/api/teacher/drafts/" + k
    body = {"revision": 0, "payload": {"title": "Draft", "items": []}}
    assert client.put(url, headers=world["a"], json=body).status_code == 403
    assert client.put(url, headers=world["t"], json=body).json()["revision"] == 1
    assert client.put(url, headers=world["t"], json=body).status_code == 409
    assert len(client.get("/api/teacher/drafts", headers=world["t"]).json()) == 1
    assert client.get("/api/teacher/archives", headers=world["t"]).status_code == 200
    assert client.delete(url, headers=world["t"]).status_code == 200


def test_reports_events_and_conversation_idempotency(client, world):
    h = world["a"]
    assert (
        client.post(
            "/api/feedback-reports",
            headers=h,
            json={"category": "suggestion", "message": "More interview tasks"},
        ).status_code
        == 200
    )
    ev = {"id": key(), "name": "practice_started"}
    assert client.post("/api/events", headers=h, json=ev).status_code == 200
    with db.connect() as conn:
        assert conn.execute("SELECT count(*) FROM product_events").fetchone()[0] == 0
    client.put("/api/me/learning-profile", headers=h, json={"analytics": True})
    for _ in range(2):
        client.post("/api/events", headers=h, json=ev)
    with db.connect() as conn:
        assert conn.execute("SELECT count(*) FROM product_events").fetchone()[0] == 1
    c = key()
    state = client.post(
        "/api/conversations", headers=h, json={"id": c, "scenario": "interview"}
    ).json()
    assert client.get("/api/conversations/" + c, headers=world["b"]).status_code == 404
    for i in range(4):
        body = {
            "id": key(),
            "revision": state["revision"],
            "text": "I built a useful project.",
        }
        r = client.post("/api/conversations/" + c + "/turns", headers=h, json=body)
        assert r.status_code == 200, r.text
        state = r.json()
        assert (
            client.post(
                "/api/conversations/" + c + "/turns", headers=h, json=body
            ).json()
            == state
        )
    assert state["complete"] and state["summary"]
    client.put("/api/me/learning-profile", headers=h, json={"analytics": False})
    with db.connect() as conn:
        assert conn.execute("SELECT count(*) FROM product_events").fetchone()[0] == 0


def test_review_spacing_disputes_and_repetition(client, world):
    h = world["a"]
    session = start(client, h, count=1, mode="assessment").json()
    with db.connect() as conn:
        item = json.loads(
            conn.execute(
                "SELECT items FROM practice_sessions WHERE id=?", (session["id"],)
            ).fetchone()[0]
        )[0]
    data = {
        "practice_session_id": session["id"],
        "item_index": 0,
        "transcript": item.get("answer", ""),
    }
    if item["kind"] in ("choice", "fill"):
        data = {
            "practice_session_id": session["id"],
            "item_index": 0,
            "choice": item["correct"],
        }
    r = client.post("/api/attempts", headers=h, data=data)
    assert r.status_code == 200, r.text
    with db.connect() as conn:
        conn.execute(
            "UPDATE attempts SET created_at=? WHERE id=?",
            (
                (datetime.now(timezone.utc) - timedelta(days=2)).isoformat(),
                r.json()["id"],
            ),
        )
        conn.commit()
    assert client.get("/api/me/review-queue", headers=h).json()["due_count"] == 1
    client.patch(
        f"/api/attempts/{r.json()['id']}/dispute", headers=h, json={"disputed": True}
    )
    assert client.get("/api/me/review-queue", headers=h).json()["due_count"] == 0


def test_confirmed_transcript_provenance_and_access(client, world, monkeypatch):
    import feedback
    from pathlib import Path

    monkeypatch.setattr(feedback, "server_asr_available", lambda: True)
    monkeypatch.setattr(feedback, "transcribe_file", lambda *args: "I works in Pune.")
    audio = (
        Path(__file__).resolve().parents[2] / "postman/fixtures/silence.wav"
    ).read_bytes()
    k = key()
    r = client.post(
        "/api/transcriptions",
        headers=world["a"],
        data={"client_uuid": k},
        files={"audio": ("speech.wav", audio, "audio/wav")},
    )
    assert r.status_code == 200, r.text
    assert r.json()["transcript"] == "I works in Pune."
    assert client.get("/api/transcriptions/" + k, headers=world["b"]).status_code == 404
    a = client.post(
        "/api/attempts",
        headers=world["a"],
        data={
            "set_id": "en-present-agreement",
            "item_index": 0,
            "transcription_id": k,
            "transcript": "I work in Pune.",
            "client_uuid": key(),
        },
    )
    assert a.status_code == 200, a.text
    assert a.json()["transcript_origin"] == "learner_corrected_asr"
    assert a.json()["original_asr_transcript"] == "I works in Pune."
    assert a.json()["has_audio"]
    bad = key()
    r = client.post(
        "/api/attempts",
        headers=world["b"],
        data={
            "set_id": "en-present-agreement",
            "item_index": 0,
            "transcription_id": k,
            "transcript": "Hello",
            "client_uuid": bad,
        },
    )
    assert r.status_code == 422
    assert (
        client.get("/api/me/submissions/" + bad, headers=world["b"]).json()["status"]
        == "failed"
    )


def test_generation_jobs_are_private_bounded_and_review_required(
    client, world, monkeypatch
):
    import generation_jobs, ai

    body = {"client_uuid": key(), "topic": "Workplace English", "count": 1}
    assert client.post("/api/ai/jobs", headers=world["a"], json=body).status_code == 403
    r = client.post("/api/ai/jobs", headers=world["t"], json=body)
    assert r.status_code == 200, r.text
    assert client.post("/api/ai/jobs", headers=world["t"], json=body).json() == r.json()
    monkeypatch.setattr(ai, "configured", lambda: True)
    monkeypatch.setattr(
        ai,
        "generate_items",
        lambda *args: [{"kind": "read", "text": "We work together."}],
    )
    assert generation_jobs.work_once()
    r = client.get("/api/ai/jobs/" + body["client_uuid"], headers=world["t"]).json()
    assert r["status"] == "completed" and r["review_required"] and len(r["items"]) == 1
    assert len(client.get("/api/ai/jobs", headers=world["t"]).json()) == 1
    with db.connect() as conn:
        assert conn.execute("SELECT count(*) FROM lessons").fetchone()[0] == 0


def test_reset_request_does_not_enumerate_and_consumes_token(
    client, world, monkeypatch
):
    import growth

    sent = []
    monkeypatch.setenv("VAACHAK_SMTP_HOST", "smtp.example.invalid")
    monkeypatch.setenv("VAACHAK_SMTP_FROM", "support@example.invalid")
    monkeypatch.setattr(
        growth, "deliver_reset", lambda email, token: sent.append((email, token))
    )
    a = client.post("/api/auth/password-reset-request", json={"email": "asha@s.test"})
    b = client.post(
        "/api/auth/password-reset-request", json={"email": "missing@s.test"}
    )
    assert a.status_code == b.status_code == 200 and a.json() == b.json()
    assert len(sent) == 1
    r = client.post(
        "/api/auth/reset-password",
        json={"token": sent[0][1], "new_password": "New-password-123"},
    )
    assert r.status_code == 200, r.text
    assert (
        client.post(
            "/api/auth/reset-password",
            json={"token": sent[0][1], "new_password": "Other-password-123"},
        ).status_code
        == 400
    )


def test_session_draft_conflict_download_and_export(client, world):
    h = world["a"]
    s = start(client, h, count=1).json()
    url = "/api/me/practice-sessions/" + s["id"]
    payload = {"revision": s["revision"], "item_index": 0, "text": "My saved answer"}
    r = client.patch(url, headers=h, json=payload)
    assert r.status_code == 200, r.text
    assert client.get(url, headers=h).json()["draft"]["text"] == "My saved answer"
    assert client.patch(url, headers=h, json=payload).status_code == 409
    assert client.patch(url, headers=world["b"], json=payload).status_code == 404
    pack = client.get("/api/practice-download", headers=h)
    assert pack.status_code == 200 and pack.json()["items"]
    exported = client.get("/api/me/export", headers=h).json()
    assert exported["learning_data"]["practice_sessions"][0]["draft"]


def test_starting_check_excludes_due_open_speaking_tasks(client, world, monkeypatch):
    import growth

    monkeypatch.setattr(
        growth,
        "review_items",
        lambda *_: [
            {
                "due": True,
                "item": {"kind": "free", "prompt": "Describe a work project."},
            }
        ],
    )
    response = start(client, world["a"], mode="assessment", count=3)
    assert response.status_code == 200
    assert len(response.json()["items"]) == 3
    assert all(
        i["kind"] in ("choice", "fill", "build") for i in response.json()["items"]
    )
