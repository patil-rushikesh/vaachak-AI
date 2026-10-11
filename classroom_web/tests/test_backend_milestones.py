"""Acceptance tests for the additive backend milestones, including failure and recovery."""

import json
import logging
import sqlite3
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))

import pytest
import ai
import db
import evidence
import feedback
import insights
from conftest import make_user
from test_courses import build_course, QUIZ, READ

WAV = (
    Path(__file__).resolve().parents[2] / "postman/fixtures/silence.wav"
).read_bytes()


def post(client, headers, **data):
    return client.post(
        "/api/attempts",
        headers=headers,
        data={
            "set_id": "en-present-agreement",
            "item_index": 0,
            "transcript": "She goes to school.",
            **data,
        },
    )


def test_submission_replay_conflict_and_owner_scope(client, world):
    first = post(client, world["a"], client_uuid="request-0001")
    second = post(client, world["a"], client_uuid="request-0001")
    assert first.status_code == second.status_code == 200
    assert first.json()["id"] == second.json()["id"]
    assert (
        post(
            client, world["a"], client_uuid="request-0001", transcript="Different"
        ).status_code
        == 409
    )
    state = client.get("/api/me/submissions/request-0001", headers=world["a"]).json()
    assert state["status"] == "completed" and state["attempt_id"] == first.json()["id"]
    assert (
        client.get("/api/me/submissions/request-0001", headers=world["b"]).status_code
        == 404
    )


def test_concurrent_duplicate_has_one_attempt(client, world, monkeypatch):
    started = threading.Event()
    release = threading.Event()
    original = feedback.analyse_full

    def slow(*a, **kw):
        started.set()
        assert release.wait(5)
        return original(*a, **kw)

    monkeypatch.setattr(feedback, "analyse_full", slow)
    with ThreadPoolExecutor(2) as pool:
        first = pool.submit(post, client, world["a"], client_uuid="parallel-0001")
        assert started.wait(5)
        second = post(client, world["a"], client_uuid="parallel-0001")
        release.set()
        assert (
            second.status_code == 409
            and second.json()["error"]["code"] == "submission_processing"
        )
        assert first.result().status_code == 200
    with db.connect() as conn:
        assert conn.execute("SELECT count(*) FROM attempts").fetchone()[0] == 1


def test_content_versions_snapshot_and_delete_guard(client, world):
    cid, l1, l2 = build_course(client, world["t"])
    item = client.get(f"/api/lessons/{l1}", headers=world["a"]).json()["items"][0]
    first = client.post(
        "/api/attempts",
        headers=world["a"],
        data={
            "lesson_id": l1,
            "item_index": 0,
            "choice": 1,
            "item_version": item["item_version"],
        },
    ).json()
    assert (
        client.put(
            f"/api/lessons/{l1}",
            headers=world["t"],
            json={"title": "New", "items": [READ]},
        ).status_code
        == 200
    )
    state = client.get(f"/api/courses/{cid}", headers=world["a"]).json()["units"][0][
        "lessons"
    ][0]
    assert state["done_items"] == 0
    old = client.get(f"/api/attempts/{first['id']}", headers=world["a"]).json()
    assert old["item_snapshot"]["kind"] == "choice"
    stale = client.post(
        "/api/attempts",
        headers=world["a"],
        data={
            "lesson_id": l1,
            "item_index": 0,
            "transcript": "Good morning",
            "item_version": item["item_version"],
        },
    )
    assert stale.status_code == 409
    assert client.delete(f"/api/courses/{cid}", headers=world["t"]).status_code == 409
    assert (
        client.patch(
            f"/api/courses/{cid}/archive", headers=world["t"], json={"archived": True}
        ).status_code
        == 200
    )
    assert client.get(f"/api/courses/{cid}", headers=world["a"]).status_code == 404
    assert (
        client.get(f"/api/attempts/{first['id']}", headers=world["a"]).status_code
        == 200
    )


def test_history_retry_dispute_and_pagination(client, world):
    a = post(client, world["a"]).json()
    b = post(client, world["a"], retry_of_attempt_id=a["id"]).json()
    assert b["input_mode"] == "typed" and b["transcript_origin"] == "client_text"
    assert client.get(f"/api/attempts/{a['id']}", headers=world["a"]).json()[
        "retries"
    ] == [b["id"]]
    assert client.get(f"/api/attempts/{a['id']}", headers=world["b"]).status_code == 404
    assert post(client, world["b"], retry_of_attempt_id=a["id"]).status_code == 422
    page = client.get("/api/me/attempts?limit=1", headers=world["a"]).json()
    assert page["items"][0]["id"] == b["id"] and page["next_cursor"] == b["id"]
    assert (
        client.get(f"/api/me/attempts?cursor={b['id']}", headers=world["a"]).json()[
            "items"
        ][0]["id"]
        == a["id"]
    )
    client.patch(
        f"/api/attempts/{b['id']}/dispute", headers=world["a"], json={"disputed": True}
    )
    assert client.get("/api/me/stats", headers=world["a"]).json()["attempts"] == 1


def test_teacher_course_evidence_and_membership(client, world):
    cid, l1, _ = build_course(client, world["t"])
    classid = world["cls"]["id"]
    client.post(
        f"/api/classes/{classid}/courses", headers=world["t"], json={"course_id": cid}
    )
    attempt = client.post(
        "/api/attempts",
        headers=world["a"],
        data={"lesson_id": l1, "item_index": 0, "choice": 0},
    ).json()
    uid = client.get("/api/me", headers=world["a"]).json()["id"]
    detail = client.get(f"/api/classes/{classid}/students/{uid}", headers=world["t"])
    assert detail.status_code == 200, detail.text
    assert detail.json()["recent"][0]["id"] == attempt["id"]
    assert detail.json()["stats"]["attempts"] == 1
    assert (
        client.get(f"/api/attempts/{attempt['id']}", headers=world["t"]).status_code
        == 200
    )
    client.delete(f"/api/classes/{classid}/students/{uid}", headers=world["t"])
    assert (
        client.get(f"/api/attempts/{attempt['id']}", headers=world["t"]).status_code
        == 404
    )


def test_skill_requires_relevant_delayed_different_task(client, world):
    uid = client.get("/api/me", headers=world["a"]).json()["id"]
    with db.connect() as conn:
        for i in range(3):
            conn.execute(
                """INSERT INTO attempts(user_id,item_index,kind,transcript,score,result,item_snapshot,input_mode,created_at)
                VALUES(?,0,'free','x',0,?,'{"prompt":"first"}','typed',?)""",
                (
                    uid,
                    json.dumps({"grammar": [{"skill": "MORPH.AGREEMENT"}]}),
                    (datetime.now(timezone.utc) - timedelta(days=5 - i)).isoformat(),
                ),
            )
        for i in range(2):
            conn.execute(
                """INSERT INTO attempts(user_id,item_index,kind,transcript,score,result,item_snapshot,input_mode,created_at)
                VALUES(?,0,'free','x',100,?,'{"prompt":"other"}','typed',?)""",
                (
                    uid,
                    json.dumps({"grammar": [], "assessed_skills": ["MORPH.AGREEMENT"]}),
                    (datetime.now(timezone.utc) - timedelta(days=2 - i)).isoformat(),
                ),
            )
        conn.commit()
        state = insights.skill_counts(conn, uid)["MORPH.AGREEMENT"]
        assert state["clean_since"] == 2 and not state["stuck"]
        assert insights.weak_skills(conn, uid) == []


def test_immediate_repeats_do_not_advance_retention(client, world):
    for _ in range(8):
        post(client, world["a"])
    with db.connect() as conn:
        conn.execute("UPDATE attempts SET created_at=datetime('now','-2 days')")
        conn.commit()
        due = insights.due_for_review(
            conn, client.get("/api/me", headers=world["a"]).json()["id"]
        )
    assert len(due) == 1 and due[0]["box"] == 2


def test_insight_snooze_resolve_and_followup(client, world):
    cid = world["cls"]["id"]
    uid = client.get("/api/me", headers=world["a"]).json()["id"]
    url = f"/api/classes/{cid}/attention/actions"
    assert (
        client.post(
            url,
            headers=world["a"],
            json={"student_id": uid, "reason": "never_started", "status": "resolved"},
        ).status_code
        == 403
    )
    assert (
        client.post(
            url,
            headers=world["t"],
            json={"student_id": uid, "reason": "never_started", "status": "snoozed"},
        ).status_code
        == 422
    )
    a = client.post(
        f"/api/classes/{cid}/assignments",
        headers=world["t"],
        json={"title": "Follow-up", "student_id": uid, "items": [QUIZ]},
    ).json()
    r = client.post(
        url,
        headers=world["t"],
        json={
            "student_id": uid,
            "reason": "never_started",
            "status": "snoozed",
            "snooze_until": (
                datetime.now(timezone.utc) + timedelta(days=1)
            ).isoformat(),
            "assignment_id": a["id"],
        },
    )
    assert r.status_code == 200, r.text
    assert all(
        row["student_id"] != uid
        for row in client.get(
            f"/api/classes/{cid}/attention", headers=world["t"]
        ).json()["rows"]
    )
    client.post(
        "/api/attempts",
        headers=world["a"],
        data={"assignment_id": a["id"], "item_index": 0, "choice": 1},
    )
    assert client.get(url, headers=world["t"]).json()["items"][0]["follow_up_attempts"]


def test_preferences_timezone_and_privacy(client, world):
    assert (
        client.patch(
            "/api/me/preferences", headers=world["a"], json={"timezone": "No/Such"}
        ).status_code
        == 422
    )
    assert (
        client.patch(
            "/api/me/preferences",
            headers=world["a"],
            json={
                "timezone": "Asia/Kolkata",
                "language": "mr",
                "research_consent": True,
            },
        ).status_code
        == 200
    )
    data = client.get("/api/me/export", headers=world["a"]).json()
    assert (
        data["profile"]["timezone"] == "Asia/Kolkata"
        and "pw_hash" not in data["profile"]
    )
    assert data["privacy_events"][0]["action"] == "research_granted"
    assert (
        client.patch(
            "/api/me/preferences", headers=world["a"], json={"research_consent": False}
        ).status_code
        == 200
    )


def test_password_change_revokes_all_sessions(client, world):
    r = client.post(
        "/api/me/password",
        headers=world["a"],
        json={
            "current_password": "password-123",
            "new_password": "updated-password-123",
        },
    )
    assert r.status_code == 200
    assert client.get("/api/me", headers=world["a"]).status_code == 401
    assert (
        client.post(
            "/api/auth/login",
            json={"email": "asha@s.test", "password": "updated-password-123"},
        ).status_code
        == 200
    )


def test_operator_reset_is_single_use(client, world, tmp_path):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
    import backend_admin

    target = tmp_path / "reset.txt"
    backend_admin.issue_reset("asha@s.test", target)
    token = target.read_text().strip()
    data = {"token": token, "new_password": "reset-password-123"}
    assert target.stat().st_mode & 0o777 == 0o600
    assert client.post("/api/auth/reset-password", json=data).status_code == 200
    assert client.post("/api/auth/reset-password", json=data).status_code == 400
    assert client.get("/api/me", headers=world["a"]).status_code == 401


def test_delete_account_removes_audio_and_sessions(client, world):
    r = client.post(
        "/api/attempts",
        headers=world["a"],
        data={"set_id": "en-present-agreement", "item_index": 0, "transcript": "hello"},
        files={"audio": ("a.wav", WAV, "audio/wav")},
    )
    assert r.status_code == 200, r.text
    with db.connect() as conn:
        filename = conn.execute(
            "SELECT audio_file FROM attempts WHERE id=?", (r.json()["id"],)
        ).fetchone()[0]
    assert (db.data_dir() / "audio" / filename).exists()
    assert (
        client.request(
            "DELETE", "/api/me", headers=world["a"], json={"password": "password-123"}
        ).status_code
        == 200
    )
    assert not (db.data_dir() / "audio" / filename).exists()
    assert client.get("/api/me", headers=world["a"]).status_code == 401
    assert (
        client.request(
            "DELETE", "/api/me", headers=world["t"], json={"password": "password-123"}
        ).status_code
        == 409
    )


def test_restart_marks_inflight_submission(client, world):
    uid = client.get("/api/me", headers=world["a"]).json()["id"]
    with db.connect() as conn:
        evidence.claim(conn, uid, "restart-001", "hash")
        evidence.recover_interrupted(conn)
    assert (
        client.get("/api/me/submissions/restart-001", headers=world["a"]).json()[
            "status"
        ]
        == "interrupted"
    )


def test_provider_failure_and_audio_cleanup(client, world, monkeypatch):
    monkeypatch.setattr(feedback, "server_asr_available", lambda: True)
    monkeypatch.setattr(feedback, "transcribe_file", lambda *a: "")
    before = set((db.data_dir() / "audio").iterdir())
    r = client.post(
        "/api/attempts",
        headers=world["a"],
        data={
            "set_id": "en-present-agreement",
            "item_index": 0,
            "client_uuid": "fail-asr-001",
        },
        files={"audio": ("a.wav", WAV, "audio/wav")},
    )
    assert r.status_code == 502 and r.json()["error"]["code"] == "transcription_failed"
    assert set((db.data_dir() / "audio").iterdir()) == before
    assert (
        client.get("/api/me/submissions/fail-asr-001", headers=world["a"]).json()[
            "status"
        ]
        == "failed"
    )


def test_request_logs_and_errors_do_not_leak(client, world, monkeypatch, caplog):
    caplog.set_level(logging.INFO, logger="vaachak.requests")

    def broken(*a, **k):
        raise RuntimeError("secret-password-do-not-log")

    monkeypatch.setattr(feedback, "analyse_full", broken)
    response = post(client, world["a"], transcript="private-learner-transcript")
    assert response.status_code == 500
    assert response.json()["error"]["request_id"] == response.headers["x-request-id"]
    assert "secret-password" not in response.text + caplog.text
    assert "private-learner-transcript" not in caplog.text
    event = json.loads(caplog.records[-1].message)
    assert event["route"] == "/api/attempts" and event["status"] == 500
    validation = client.post(
        "/api/auth/register", json={"password": "private-password"}
    )
    assert validation.status_code == 422 and "private-password" not in validation.text
    missing = client.get("/not-a-route?token=secret-query")
    assert missing.status_code == 404 and "secret-query" not in caplog.text


def test_migrations_idempotent_backup_restore(client, world, tmp_path):
    import backend_admin

    post(client, world["a"])
    db.init()
    db.init()
    backup = backend_admin.backup(tmp_path / "backup")
    restored = backend_admin.restore(backup, tmp_path / "restored")
    with sqlite3.connect(restored / "classroom.db") as conn:
        assert conn.execute("SELECT count(*) FROM attempts").fetchone()[0] == 1
        assert [r[0] for r in conn.execute("SELECT version FROM schema_migrations ORDER BY version")] == [1, 2, 3, 4, 5, 6, 7]
    (backup / "classroom.db").write_bytes(b"corrupted")
    with pytest.raises(ValueError):
        backend_admin.restore(backup, tmp_path / "bad")


def test_invitation_and_quotas(client, world, monkeypatch):
    monkeypatch.setenv("VAACHAK_ENV", "production")
    monkeypatch.setenv("VAACHAK_TEACHER_INVITE", "instructor-invite")
    body = {
        "name": "T",
        "email": "new@t.test",
        "password": "password-123",
        "role": "teacher",
    }
    assert client.post("/api/auth/register", json=body).status_code == 403
    assert (
        client.post(
            "/api/auth/register", json={**body, "teacher_invite": "instructor-invite"}
        ).status_code
        == 200
    )
    monkeypatch.setenv("VAACHAK_ATTEMPTS_PER_MINUTE", "1")
    assert post(client, world["a"]).status_code == 200
    assert post(client, world["a"]).status_code == 429


def test_every_json_endpoint_has_success_and_error_contract(client):
    schema = client.get("/api/openapi.json").json()
    for path, methods in schema["paths"].items():
        for method, op in methods.items():
            if method not in ["get", "post", "put", "patch", "delete"]:
                continue
            if not path.endswith("/audio"):
                assert op["responses"]["200"]["content"]["application/json"][
                    "schema"
                ], path
            assert op["responses"]["422"]["content"]["application/json"]["schema"], path


def test_recommendation_uses_same_skill_other_task(client, world):
    items = [
        {
            "kind": "free",
            "prompt": "Describe your brother.",
            "skill_ids": ["MORPH.AGREEMENT"],
        },
        {
            "kind": "free",
            "prompt": "Describe your sister.",
            "skill_ids": ["MORPH.AGREEMENT"],
        },
    ]
    a = client.post(
        f"/api/classes/{world['cls']['id']}/assignments",
        headers=world["t"],
        json={"title": "Agreement", "items": items},
    ).json()
    client.post(
        "/api/attempts",
        headers=world["a"],
        data={
            "assignment_id": a["id"],
            "item_index": 0,
            "transcript": "he go to school",
        },
    )
    r = client.get("/api/me/recommendations", headers=world["a"])
    assert r.status_code == 200, r.text
    assert any(
        i["source"].get("assignment_id") == a["id"] and i["source"]["item_index"] == 1
        for i in r.json()["items"]
    )


@pytest.mark.parametrize("resource", ["classes", "courses", "assignments", "lessons"])
def test_archive_restore_and_owner_checks(client, world, resource):
    cid, lid, _ = build_course(client, world["t"])
    aid = client.post(
        f"/api/classes/{world['cls']['id']}/assignments",
        headers=world["t"],
        json={"title": "A", "items": [QUIZ]},
    ).json()["id"]
    rid = {
        "classes": world["cls"]["id"],
        "courses": cid,
        "assignments": aid,
        "lessons": lid,
    }[resource]
    url = f"/api/{resource}/{rid}/archive"
    other = make_user(client, "teacher", "Other", "another@example.test")
    assert client.patch(url, headers=other, json={"archived": True}).status_code == 404
    assert (
        client.patch(url, headers=world["t"], json={"archived": True}).status_code
        == 200
    )
    assert (
        client.patch(url, headers=world["t"], json={"archived": False}).status_code
        == 200
    )


def test_assignment_edit_recording_delete_and_ready(client, world):
    assert client.get("/api/ready").status_code == 200
    rec = client.post(
        "/api/recordings",
        headers=world["t"],
        data={"title": "Intro", "duration_ms": 1000},
        files={"file": ("x.wav", WAV, "audio/wav")},
    ).json()
    assignment = client.post(
        f"/api/classes/{world['cls']['id']}/assignments",
        headers=world["t"],
        json={"title": "Practice", "items": [QUIZ], "recording_id": rec["id"]},
    ).json()
    url = f"/api/assignments/{assignment['id']}"
    assert (
        client.patch(
            url,
            headers=world["t"],
            json={"title": "Revised", "due_at": "2026-12-01T10:00:00+05:30"},
        ).status_code
        == 200
    )
    assert (
        client.patch(
            url, headers=world["t"], json={"due_at": "2026-12-01T10:00:00"}
        ).status_code
        == 422
    )
    assert client.get(url, headers=world["a"]).json()["title"] == "Revised"
    assert (
        client.delete(f"/api/recordings/{rec['id']}", headers=world["t"]).status_code
        == 200
    )
    assert (
        client.get(f"/api/recordings/{rec['id']}/audio", headers=world["t"]).status_code
        == 404
    )
    assert client.get(url, headers=world["a"]).json()["recording_id"] is None


def test_asr_provenance(client, world, monkeypatch):
    monkeypatch.setattr(feedback, "server_asr_available", lambda: True)
    monkeypatch.setattr(feedback, "transcribe_file", lambda *a: "She goes to school.")
    response = client.post(
        "/api/attempts",
        headers=world["a"],
        data={"set_id": "en-present-agreement", "item_index": 0},
        files={"audio": ("x.wav", WAV, "audio/wav")},
    )
    assert response.status_code == 200, response.text
    assert (
        response.json()["input_mode"] == "recorded"
        and response.json()["transcript_origin"] == "server_asr"
    )


def test_legacy_migration_does_not_invent_provenance(client, world):
    with db.connect() as conn:
        conn.execute(
            "INSERT INTO attempts(user_id,item_index,kind,transcript,score,result) VALUES(2,0,'read','legacy',50,'{}')"
        )
        conn.commit()
        a = conn.execute("SELECT * FROM attempts").fetchone()
        assert a["input_mode"] == "legacy_unknown" and a["content_version"] == 0


def test_local_day_streak_uses_preferences(client, world, monkeypatch):
    a = post(client, world["a"]).json()
    client.patch(
        "/api/me/preferences", headers=world["a"], json={"timezone": "Asia/Kolkata"}
    )
    with db.connect() as conn:
        stamp = (datetime.now(timezone.utc) - timedelta(days=1)).replace(
            hour=20, minute=0, second=0, microsecond=0
        )
        conn.execute(
            "UPDATE attempts SET created_at=? WHERE id=?", (stamp.isoformat(), a["id"])
        )
        conn.commit()
    days = client.get("/api/me/stats", headers=world["a"]).json()["days"]
    # The evidence belongs to October 11 in India, irrespective of UTC date.
    assert any(
        d["day"] == (stamp + timedelta(hours=5, minutes=30)).date().isoformat()
        and d["attempts"] == 1
        for d in days
    )


def test_remaining_route_lifecycles(client, world, monkeypatch):
    assert client.get("/api/health").json()["ok"]
    assert client.get("/api/recordings", headers=world["t"]).status_code == 200
    assert client.get("/api/me/preferences", headers=world["a"]).status_code == 200
    cid, l1, l2 = build_course(client, world["t"])
    course = client.get(f"/api/courses/{cid}", headers=world["t"]).json()
    uid = course["units"][0]["id"]
    assert (
        client.patch(
            f"/api/units/{uid}", headers=world["t"], json={"title": "Renamed"}
        ).status_code
        == 200
    )
    assert (
        client.post(
            f"/api/units/{uid}/move", headers=world["t"], json={"direction": "up"}
        ).status_code
        == 200
    )
    assert (
        client.delete(f"/api/courses/{cid}/enroll", headers=world["a"]).status_code
        == 200
    )
    assert client.delete(f"/api/units/{uid}", headers=world["t"]).status_code == 200
    assert client.delete(f"/api/courses/{cid}", headers=world["t"]).status_code == 200
    a = client.post(
        f"/api/classes/{world['cls']['id']}/assignments",
        headers=world["t"],
        json={"title": "Disposable", "items": [QUIZ]},
    ).json()
    assert (
        client.delete(f"/api/assignments/{a['id']}", headers=world["t"]).status_code
        == 200
    )
    monkeypatch.setattr(ai, "configured", lambda: True)
    monkeypatch.setattr(ai, "generate_items", lambda *a: [QUIZ])
    assert (
        client.post(
            "/api/ai/items", headers=world["t"], json={"topic": "Agreement"}
        ).status_code
        == 200
    )
    assert client.post("/api/auth/logout", headers=world["a"]).status_code == 200
    assert client.get("/api/me", headers=world["a"]).status_code == 401


def test_large_body_and_rate_error_contract(client):
    r = client.post(
        "/api/auth/login",
        content=b"x",
        headers={
            "Content-Length": str(23 * 1024 * 1024),
            "Content-Type": "application/json",
        },
    )
    assert r.status_code == 413 and r.json()["error"]["code"] == "payload_too_large"
    r = client.post(
        "/api/auth/login",
        content=(b"x" * 1024 * 1024 for _ in range(23)),
        headers={"Content-Type": "application/json"},
    )
    assert r.status_code == 413, r.text


def test_archived_class_revokes_private_course_and_recording(client, world):
    cid, l1, _ = build_course(client, world["t"], visibility="classes")
    clid = world["cls"]["id"]
    client.post(
        f"/api/classes/{clid}/courses", headers=world["t"], json={"course_id": cid}
    )
    rec = client.post(
        "/api/recordings",
        headers=world["t"],
        data={"title": "Only this class", "duration_ms": 1000},
        files={"file": ("a.wav", WAV, "audio/wav")},
    ).json()
    client.post(
        f"/api/classes/{clid}/assignments",
        headers=world["t"],
        json={"title": "Audio", "items": [QUIZ], "recording_id": rec["id"]},
    )
    assert client.get(f"/api/courses/{cid}", headers=world["a"]).status_code == 200
    assert (
        client.get(f"/api/recordings/{rec['id']}/audio", headers=world["a"]).status_code
        == 200
    )
    client.patch(
        f"/api/classes/{clid}/archive", headers=world["t"], json={"archived": True}
    )
    assert client.get(f"/api/courses/{cid}", headers=world["a"]).status_code == 404
    assert (
        client.get(f"/api/recordings/{rec['id']}/audio", headers=world["a"]).status_code
        == 404
    )


def test_completed_submission_replays_after_content_replacement(client, world):
    cid, lid, _ = build_course(client, world["t"])
    item = client.get(f"/api/lessons/{lid}", headers=world["a"]).json()["items"][0]
    data = {
        "lesson_id": lid,
        "item_index": 0,
        "choice": 1,
        "item_version": item["item_version"],
        "client_uuid": "immutable-replay-001",
    }
    first = client.post("/api/attempts", headers=world["a"], data=data)
    assert first.status_code == 200
    client.put(
        f"/api/lessons/{lid}",
        headers=world["t"],
        json={"title": "Replacement", "items": [READ]},
    )
    second = client.post("/api/attempts", headers=world["a"], data=data)
    assert second.status_code == 200 and second.json()["id"] == first.json()["id"]


def test_new_skill_miss_resets_delayed_evidence_clock(client, world):
    uid = client.get("/api/me", headers=world["a"]).json()["id"]
    with db.connect() as conn:
        events = [
            (6, 0, "first"),
            (5, 100, "other"),
            (4, 100, "other"),
            (0.1, 0, "first"),
            (0.05, 100, "other"),
        ]
        for days, score, task in events:
            value = {
                "grammar": [{"skill": "MORPH.AGREEMENT"}] if not score else [],
                "assessed_skills": ["MORPH.AGREEMENT"],
            }
            conn.execute(
                """INSERT INTO attempts(user_id,item_index,kind,transcript,score,result,item_snapshot,input_mode,created_at)
                VALUES(?,0,'free','x',?,?,?,'typed',?)""",
                (
                    uid,
                    score,
                    json.dumps(value),
                    json.dumps({"prompt": task}),
                    (datetime.now(timezone.utc) - timedelta(days=days)).isoformat(),
                ),
            )
        conn.commit()
        assert insights.skill_counts(conn, uid)["MORPH.AGREEMENT"]["clean_since"] == 0
