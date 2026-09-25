"""End-to-end classroom permissions, frozen assignments, attempts and review evidence."""
import io
import os
import wave
from uuid import uuid4

import numpy as np
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete, select

from vaachak_backend.api import create_app
from vaachak_backend.db import Base, Problem
from vaachak_backend.domain_api import _run_analysis, recover_interrupted_attempts
from vaachak_backend.domain_models import AssignmentRequest, Attempt, AttemptReview, ProblemContent, Student

PASSWORD = "student test password"


def auth(response):
    assert response.status_code in (200, 201), response.text
    return {"Authorization": "Bearer " + response.json()["access_token"]}


def create(client, route, headers, body):
    response = client.post(route, headers=headers, json=body)
    assert response.status_code == 201, response.text
    return response.json()


def audio_bytes(frequency=220):
    times = np.arange(32000) / 16000
    samples = .2 * np.sin(2 * np.pi * frequency * times)
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes((samples * 32767).astype("<i2").tobytes())
    return buffer.getvalue()


@pytest.fixture
def domain(tmp_path):
    app = create_app(database_url=os.getenv("TEST_DATABASE_URL") or f"sqlite:///{tmp_path / 'test.sqlite3'}", data_dir=tmp_path, analysis_worker=False)
    with app.state.session_factory() as session:
        for table in reversed(Base.metadata.sorted_tables):
            session.execute(delete(table))
        session.commit()
    with TestClient(app) as client:
        teacher = auth(client.post("/auth/register", json={"email": "teacher@example.test", "password": PASSWORD}))
        outsider = auth(client.post("/auth/register", json={"email": "other@example.test", "password": PASSWORD}))
        room = create(client, "/teacher/classrooms", teacher, {"school_name": "Test School", "name": "Class 6", "postal_code": "411001"})
        student = create(client, f"/teacher/classrooms/{room['id']}/students", teacher,
                         {"display_name": "Asha", "login_name": "ASHA.6", "password": PASSWORD})
        second = create(client, f"/teacher/classrooms/{room['id']}/students", teacher,
                        {"display_name": "Ravi", "login_name": "ravi.6", "password": PASSWORD})
        student_auth = auth(client.post("/auth/login", json={"identifier": "asha.6", "password": PASSWORD, "role": "student"}))
        second_auth = auth(client.post("/auth/login", json={"identifier": "ravi.6", "password": PASSWORD, "role": "student"}))
        yield {"app": app, "client": client, "teacher": teacher, "outsider": outsider, "room": room,
               "student": student, "student_auth": student_auth, "second": second, "second_auth": second_auth, "directory": tmp_path}


def choice(d):
    return create(d["client"], "/teacher/problems", d["teacher"], {
        "title": "Synonyms", "kind": "choice", "expected_text": "Choose a synonym for happy.",
        "payload": {"options": [{"id": "correct", "text": "Joyful"}, {"id": "wrong", "text": "Sad"}],
                    "correct_option_id": "correct", "skill": "synonym"}})


def assign(d, problems, to_class=False):
    return create(d["client"], "/teacher/assignments", d["teacher"], {
        "title": "Practice one", "classroom_id" if to_class else "student_id": d["room"]["id"] if to_class else d["student"]["id"],
        "problems": problems})


def items(d, assignment):
    response = d["client"].get(f"/student/assignments/{assignment['id']}", headers=d["student_auth"])
    assert response.status_code == 200, response.text
    return response.json()["problems"]


def submit(d, assignment, item, answer, request_id=None):
    return d["client"].post(f"/student/assignments/{assignment['id']}/problems/{item['id']}/attempts",
                           headers=d["student_auth"], json={"request_id": request_id or str(uuid4()), "answer": answer})


def test_classrooms_and_students_are_owned_unique_and_private(domain):
    d = domain
    client = d["client"]
    detail = client.get(f"/teacher/classrooms/{d['room']['id']}", headers=d["teacher"]).json()
    assert detail["student_count"] == 2
    assert detail["postal_code"] == "411001" and detail["join_code"] != detail["postal_code"]
    assert detail["students"][0]["login_name"] == "asha.6"
    assert "password" not in str(detail)
    assert client.get(f"/teacher/classrooms/{d['room']['id']}", headers=d["outsider"]).status_code == 404
    assert client.get(f"/teacher/students/{d['student']['id']}", headers=d["outsider"]).status_code == 404
    assert client.post(f"/teacher/classrooms/{d['room']['id']}/students", headers=d["outsider"],
                       json={"display_name": "No", "login_name": "noo", "password": PASSWORD}).status_code == 404
    assert client.post(f"/teacher/classrooms/{d['room']['id']}/students", headers=d["teacher"],
                       json={"display_name": "Duplicate", "login_name": "ASHA.6", "password": PASSWORD}).status_code == 409
    assert client.post("/teacher/classrooms", headers=d["teacher"], json={"school_name": "Test School", "name": "Class 6", "postal_code": "411001"}).status_code == 409
    create(client, f"/teacher/classrooms/{d['room']['id']}/students", d["teacher"],
           {"display_name": "  Password spaces  ", "login_name": " SPACES ", "password": " spaced password "})
    assert client.post("/auth/login", json={"identifier": "spaces", "password": " spaced password ", "role": "student"}).status_code == 200
    assert client.post("/auth/login", json={"identifier": "spaces", "password": "spaced password", "role": "student"}).status_code == 401
    with d["app"].state.session_factory() as session:
        assert PASSWORD not in session.get(Student, d["student"]["id"]).password_hash


def test_choice_frozen_assignment_idempotency_and_actual_progress(domain):
    d = domain
    problem = choice(d)
    assignment = assign(d, [{"problem_id": problem["id"]}], to_class=True)
    item = items(d, assignment)[0]
    assert "correct_option_id" not in item["payload"]
    assert item["id"] != problem["id"]
    with d["app"].state.session_factory() as session:
        session.get(Problem, problem["id"]).expected_text = "Edited later"
        session.get(ProblemContent, problem["id"]).payload = {"options": [], "correct_option_id": "wrong"}
        session.commit()
    assert items(d, assignment)[0]["expected_text"] == "Choose a synonym for happy."
    request_id = str(uuid4())
    first = submit(d, assignment, item, "correct", request_id)
    assert first.status_code == 201, first.text
    assert first.json()["score"] == 1
    assert submit(d, assignment, item, "correct", request_id).json()["id"] == first.json()["id"]
    assert submit(d, assignment, item, "wrong", request_id).status_code == 409
    assert submit(d, assignment, item, "unknown").status_code == 422
    assert submit(d, assignment, item, "wrong").json()["score"] == 0
    overview = d["client"].get("/student/overview", headers=d["student_auth"]).json()
    assert overview["counts"]["attempts"] == 2
    assert overview["counts"]["submitted_problems"] == 1
    assert overview["counts"]["solved_problems"] == 0
    assert overview["counts"]["completed_assignments"] == 1
    assert overview["progress"]["average_score"] == 0
    assert overview["progress"]["weaknesses"][0]["skill"] == "synonym"
    teacher = d["client"].get("/teacher/overview", headers=d["teacher"]).json()
    assert teacher["counts"]["attempts"] == 2 and teacher["counts"]["students"] == 2
    detail = d["client"].get(f"/teacher/assignments/{assignment['id']}", headers=d["teacher"]).json()
    assert len(detail["recipients"]) == 2
    asha = next(s for s in detail["recipients"] if s["id"] == d["student"]["id"])
    assert asha["completed_count"] == 1 and asha["attempt_count"] == 2
    assert d["client"].get(f"/student/attempts/{first.json()['id']}", headers=d["second_auth"]).status_code == 404


def test_assignment_target_validation_idempotency_and_frozen_roster(domain):
    d = domain
    problem = choice(d)
    body = {"title": "Practice", "classroom_id": d["room"]["id"], "problems": [{"problem_id": problem["id"]}], "request_id": str(uuid4())}
    assignment = create(d["client"], "/teacher/assignments", d["teacher"], body)
    assert create(d["client"], "/teacher/assignments", d["teacher"], body)["id"] == assignment["id"]
    assert d["client"].post("/teacher/assignments", headers=d["teacher"], json={**body, "title": "Different"}).status_code == 409
    create(d["client"], f"/teacher/classrooms/{d['room']['id']}/students", d["teacher"],
           {"display_name": "Later", "login_name": "later.6", "password": PASSWORD})
    later_auth = auth(d["client"].post("/auth/login", json={"identifier": "later.6", "password": PASSWORD, "role": "student"}))
    assert d["client"].get("/student/assignments", headers=later_auth).json() == []
    assert d["client"].get(f"/student/assignments/{assignment['id']}", headers=later_auth).status_code == 404
    bad = {"title": "Invalid", "problems": [{"problem_id": problem["id"]}]}
    assert d["client"].post("/teacher/assignments", headers=d["teacher"], json=bad).status_code == 422
    assert d["client"].post("/teacher/assignments", headers=d["teacher"], json={**bad, "classroom_id": d["room"]["id"], "student_id": d["student"]["id"]}).status_code == 422
    assert d["client"].post("/teacher/assignments", headers=d["outsider"], json={**bad, "student_id": d["student"]["id"]}).status_code == 404
    only = assign(d, [{"problem_id": problem["id"]}])
    assert d["client"].get(f"/student/assignments/{only['id']}", headers=d["second_auth"]).status_code == 404
    with d["app"].state.session_factory() as session:
        assert len(list(session.scalars(select(AssignmentRequest)))) == 1


def test_matching_has_independent_ids_and_no_pair_mapping(domain):
    d = domain
    problem = create(d["client"], "/teacher/problems", d["teacher"], {"title": "Opposites", "kind": "matching", "expected_text": "Match opposites",
                     "payload": {"pairs": [{"id": "a", "left": "Hot", "right": "Cold"}, {"id": "b", "left": "Big", "right": "Small"}], "skill": "antonym"}})
    assignment = assign(d, [{"problem_id": problem["id"]}])
    item = items(d, assignment)[0]
    payload = item["payload"]
    assert set(payload) == {"left", "right", "skill"}
    assert {x["id"] for x in payload["left"]}.isdisjoint({x["id"] for x in payload["right"]})
    right = {card["text"]: card["id"] for card in payload["right"]}
    answers = {card["id"]: right[{"Hot": "Cold", "Big": "Small"}[card["text"]]] for card in payload["left"]}
    response = submit(d, assignment, item, answers)
    assert response.status_code == 201, response.text
    assert response.json()["score"] == 1 and "matching_answers" not in str(response.json())
    assert submit(d, assignment, item, {}).status_code == 422
    assert submit(d, assignment, item, {key: list(right.values())[0] for key in answers}).status_code == 422


@pytest.mark.parametrize("kind,payload", [
    ("choice", {"options": [{"id": "x", "text": "A"}, {"id": "x", "text": "B"}], "correct_option_id": "x"}),
    ("choice", {"options": [{"id": "x", "text": "A"}, {"id": "y", "text": "B"}], "correct_option_id": []}),
    ("choice", {"options": [{"id": "x", "text": "A"}, {"id": "y", "text": "B"}], "correct_option_id": "x", "skill": []}),
    ("matching", {"pairs": [{"id": "x", "left": "A", "right": "B"}]}),
    ("meaning", {"accepted_answers": [""]}),
    ("read_aloud", {"unexpected": "hidden"}),
])
def test_invalid_problem_structures_rejected(domain, kind, payload):
    response = domain["client"].post("/teacher/problems", headers=domain["teacher"],
                                     json={"title": "Bad", "kind": kind, "expected_text": "Prompt", "payload": payload})
    assert response.status_code == 422, response.text


def test_meaning_failure_retry_and_review_wins(domain, monkeypatch):
    d = domain
    problem = create(d["client"], "/teacher/problems", d["teacher"], {"title": "Meaning", "kind": "meaning", "expected_text": "Break a leg",
                     "payload": {"accepted_answers": ["Good luck"], "rubric": "Private teacher criteria"}})
    assignment = assign(d, [{"problem_id": problem["id"]}])
    item = items(d, assignment)[0]
    assert item["payload"] == {}
    monkeypatch.setattr("vaachak_backend.speech_service.evaluate_meaning", lambda *args: {"status": "completed", "score": 1, "feedback": "Correct meaning", "result": {}})
    attempt_id = submit(d, assignment, item, "Good luck").json()["id"]
    assert d["client"].get(f"/student/attempts/{attempt_id}", headers=d["student_auth"]).json()["score"] == 1
    def fail(*args):
        raise RuntimeError("provider unavailable")
    monkeypatch.setattr("vaachak_backend.speech_service.evaluate_meaning", fail)
    failed_id = submit(d, assignment, item, "Related meaning").json()["id"]
    failed = d["client"].get(f"/student/attempts/{failed_id}", headers=d["student_auth"]).json()
    assert failed["status"] == "failed" and failed["score"] is None
    monkeypatch.setattr("vaachak_backend.speech_service.evaluate_meaning", lambda *args: {"status": "needs_review", "score": None, "feedback": "Review needed", "result": {}})
    assert d["client"].post(f"/student/attempts/{failed_id}/retry-analysis", headers=d["student_auth"]).status_code == 202
    assert d["client"].get(f"/student/attempts/{failed_id}", headers=d["student_auth"]).json()["status"] == "needs_review"
    assert d["client"].get("/student/overview", headers=d["student_auth"]).json()["counts"]["solved_problems"] == 0
    assert d["client"].patch(f"/teacher/attempts/{failed_id}/review", headers=d["outsider"], json={"score": .8, "feedback": "Okay"}).status_code == 404
    review = d["client"].patch(f"/teacher/attempts/{failed_id}/review", headers=d["teacher"], json={"score": .8, "feedback": "You understand the phrase."})
    assert review.status_code == 200 and review.json()["score"] == .8
    assert review.json()["result"]["teacher_review"]["feedback"] == "You understand the phrase."
    assert d["client"].post(f"/student/attempts/{failed_id}/retry-analysis", headers=d["student_auth"]).status_code == 409
    _run_analysis(d["app"].state.session_factory, d["directory"], failed_id)
    with d["app"].state.session_factory() as session:
        assert session.get(Attempt, failed_id).score == .8
        assert len(list(session.scalars(select(AttemptReview)))) == 1
    def review_while_analyzing(*args):
        with d["app"].state.session_factory() as session:
            attempt = session.get(Attempt, attempt_id)
            attempt.reviewed_at = "reviewed during analysis"
            attempt.score, attempt.status, attempt.feedback = .65, "completed", "Teacher decision"
            session.commit()
        return {"status": "completed", "score": 0, "feedback": "Late result", "result": {}}
    with d["app"].state.session_factory() as session:
        session.get(Attempt, attempt_id).status = "pending"
        session.commit()
    monkeypatch.setattr("vaachak_backend.speech_service.evaluate_meaning", review_while_analyzing)
    _run_analysis(d["app"].state.session_factory, d["directory"], attempt_id)
    assert d["client"].get(f"/student/attempts/{attempt_id}", headers=d["student_auth"]).json()["score"] == .65


def test_audio_preserved_authorized_idempotent_and_failure_cleanup(domain, monkeypatch):
    d = domain
    problem = create(d["client"], "/teacher/problems", d["teacher"], {"title": "My house", "kind": "read_aloud", "expected_text": "This is my house.", "payload": {"expression": "happy"}})
    assert d["client"].post("/teacher/assignments", headers=d["teacher"], json={"title": "Incomplete", "student_id": d["student"]["id"], "problems": [{"problem_id": problem["id"]}]}).status_code == 422
    reference = d["client"].post(f"/problems/{problem['id']}/recordings", headers=d["teacher"], files={"file": ("voice.wav", audio_bytes())})
    assert reference.status_code == 201, reference.text
    assignment = assign(d, [{"problem_id": problem["id"], "recording_id": reference.json()["id"]}])
    item = items(d, assignment)[0]
    assert d["client"].get(item["reference_audio_url"], headers=d["student_auth"]).status_code == 200
    assert d["client"].get(item["reference_audio_url"], headers=d["second_auth"]).status_code == 404
    assert submit(d, assignment, item, "Words").status_code == 422
    monkeypatch.setattr("vaachak_backend.speech_service.analyze_reading", lambda *args: {"status": "needs_review", "score": None, "feedback": "Model unavailable; teacher review", "result": {"pitch": {"status": "not_assessed"}}})
    route = f"/student/assignments/{assignment['id']}/problems/{item['id']}/recordings"
    request_id = str(uuid4())
    source = audio_bytes(330)
    response = d["client"].post(route, headers=d["student_auth"], data={"request_id": request_id}, files={"file": ("../../escape.wav", source)})
    assert response.status_code == 201, response.text
    attempt = response.json()
    assert (d["directory"] / "attempts" / attempt["id"] / "original").read_bytes() == source
    for role in ["student_auth", "teacher"]:
        assert d["client"].get(attempt["audio_url"], headers=d[role]).status_code == 200
    for role in ["second_auth", "outsider"]:
        assert d["client"].get(attempt["audio_url"], headers=d[role]).status_code == 404
    assert d["client"].post(route, headers=d["student_auth"], data={"request_id": request_id}, files={"file": ("changed.wav", source)}).json()["id"] == attempt["id"]
    assert d["client"].post(route, headers=d["student_auth"], data={"request_id": request_id}, files={"file": ("voice.wav", audio_bytes(440))}).status_code == 409
    assert d["client"].post(route, headers=d["student_auth"], data={"request_id": str(uuid4())}, files={"file": ("voice.wav", b"not audio")}).status_code == 422
    assert len(list((d["directory"] / "attempts").iterdir())) == 1
    with d["app"].state.session_factory() as session:
        assert len(list(session.scalars(select(Attempt)))) == 1


def test_restart_recovery_retains_evidence(domain):
    d = domain
    problem = choice(d)
    assignment = assign(d, [{"problem_id": problem["id"]}])
    attempt = submit(d, assignment, items(d, assignment)[0], "correct").json()
    with d["app"].state.session_factory() as session:
        session.get(Attempt, attempt["id"]).status = "pending"
        session.commit()
    recover_interrupted_attempts(d["app"].state.session_factory)
    with d["app"].state.session_factory() as session:
        row = session.get(Attempt, attempt["id"])
        assert row.status == "failed" and row.answer == "correct" and row.id == attempt["id"]


def test_unreviewed_semantic_suggestions_are_teacher_only(domain, monkeypatch):
    d = domain
    problem = create(d["client"], "/teacher/problems", d["teacher"], {"title": "Meaning", "kind": "meaning", "expected_text": "The house is tiny.",
                     "payload": {"accepted_answers": ["The house is small"], "rubric": "Small size"}})
    assignment = assign(d, [{"problem_id": problem["id"]}])
    monkeypatch.setattr("vaachak_backend.speech_service.evaluate_meaning", lambda *args: {
        "status": "needs_review", "score": None, "feedback": "Your teacher will review this answer.",
        "result": {"method": "ai_semantic_review", "suggested_score": .9, "classification": "correct", "explanation": "Tentative model opinion", "confidence": .9}})
    attempt = submit(d, assignment, items(d, assignment)[0], "It is a small home").json()
    student_view = d["client"].get(f"/student/attempts/{attempt['id']}", headers=d["student_auth"]).json()
    assert student_view["score"] is None
    assignment_view = d["client"].get("/student/assignments", headers=d["student_auth"]).json()[0]
    assert assignment_view["completed_count"] == 0 and assignment_view["submitted_count"] == 1
    assert not {"suggested_score", "classification", "explanation", "confidence"}.intersection(student_view["result"])
    teacher_view = d["client"].get(f"/teacher/students/{d['student']['id']}", headers=d["teacher"]).json()
    assert teacher_view["attempts"][0]["result"]["suggested_score"] == .9
    assert d["client"].get("/student/overview", headers=d["student_auth"]).json()["counts"]["solved_problems"] == 0


def test_submission_rejects_other_assignment_and_audio_database_failure_cleans(domain, monkeypatch):
    from sqlalchemy.orm import Session
    d = domain
    problem = choice(d)
    first = assign(d, [{"problem_id": problem["id"]}])
    second = assign(d, [{"problem_id": problem["id"]}])
    assert submit(d, second, items(d, first)[0], "correct").status_code == 404
    voice = create(d["client"], "/teacher/problems", d["teacher"], {"title": "Reading", "expected_text": "Hello world", "kind": "read_aloud"})
    recording = d["client"].post(f"/problems/{voice['id']}/recordings", headers=d["teacher"], files={"file": ("voice.wav", audio_bytes())}).json()
    assignment = assign(d, [{"problem_id": voice["id"], "recording_id": recording["id"]}])
    item = items(d, assignment)[0]
    def fail_commit(self):
        raise RuntimeError("Simulated database outage")
    with monkeypatch.context() as patch:
        patch.setattr(Session, "commit", fail_commit)
        response = d["client"].post(f"/student/assignments/{assignment['id']}/problems/{item['id']}/recordings", headers=d["student_auth"],
                                   data={"request_id": str(uuid4())}, files={"file": ("voice.wav", audio_bytes())})
    assert response.status_code == 503
    assert list((d["directory"] / "attempts").iterdir()) == []
    with d["app"].state.session_factory() as session:
        assert list(session.scalars(select(Attempt))) == []


def test_latest_pending_or_failed_attempt_does_not_reuse_an_older_grade(domain, monkeypatch):
    d = domain
    problem = create(d["client"], "/teacher/problems", d["teacher"], {"title": "Meaning", "kind": "meaning", "expected_text": "A small house",
                     "payload": {"accepted_answers": ["A tiny home"], "rubric": "Small size"}})
    assignment = assign(d, [{"problem_id": problem["id"]}])
    item = items(d, assignment)[0]
    monkeypatch.setattr("vaachak_backend.speech_service.evaluate_meaning", lambda *args: {"status": "completed", "score": 1, "feedback": "Correct", "result": {}})
    submit(d, assignment, item, "A tiny home")
    monkeypatch.setattr("vaachak_backend.domain_api._run_analysis", lambda *args: None)
    newest = submit(d, assignment, item, "Another answer").json()
    def check_counts(status):
        response = d["client"].get("/student/overview", headers=d["student_auth"])
        assert response.status_code == 200, response.text
        value = response.json()
        assert value["counts"]["submitted_problems"] == 1
        assert value["counts"]["completed_problems"] == 0
        assert value["progress"]["completed_problems"] == value["progress"]["reviewed_problems"] == 0
        assert value["counts"]["solved_problems"] == 0
        assert value["counts"]["completed_assignments"] == 0
        assert value["progress"]["average_score"] is None
        assert value["progress"][f"{status}_problems"] == 1
        assert value["progress"]["skills"][0]["attempt_count"] == 2
    check_counts("pending")
    with d["app"].state.session_factory() as session:
        session.get(Attempt, newest["id"]).status = "failed"
        session.commit()
    check_counts("failed")


@pytest.mark.parametrize("outcome", [
    {"status": "completed", "score": 1, "feedback": "Bad evidence", "result": None},
    {"status": "completed", "score": 1, "feedback": "Bad evidence", "result": {"bad": float("nan")}},
    {"status": "completed", "score": None, "feedback": "Bad grade", "result": {}},
    {"status": "needs_review", "score": .7, "feedback": "Premature grade", "result": {}},
])
def test_invalid_model_outcome_is_saved_as_retryable_failure(domain, monkeypatch, outcome):
    d = domain
    problem = create(d["client"], "/teacher/problems", d["teacher"], {"title": "Meaning", "kind": "meaning", "expected_text": "A tiny home",
                     "payload": {"accepted_answers": ["A small house"]}})
    assignment = assign(d, [{"problem_id": problem["id"]}])
    monkeypatch.setattr("vaachak_backend.speech_service.evaluate_meaning", lambda *args: outcome)
    attempt_id = submit(d, assignment, items(d, assignment)[0], "A small house").json()["id"]
    response = d["client"].get(f"/student/attempts/{attempt_id}", headers=d["student_auth"])
    assert response.status_code == 200, response.text
    assert response.json()["status"] == "failed" and response.json()["score"] is None


def test_concurrent_assignment_retry_creates_exactly_one_assignment(domain, monkeypatch):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Barrier
    from vaachak_backend import domain_api
    from vaachak_backend.domain_models import Assignment, AssignmentItem, AssignmentRecipient
    d = domain
    problem = choice(d)
    body = {"title": "Concurrent assignment", "classroom_id": d["room"]["id"], "problems": [{"problem_id": problem["id"]}], "request_id": str(uuid4())}
    barrier, original = Barrier(2), domain_api._make_snapshot
    def snapshot(*args):
        value = original(*args)
        barrier.wait(timeout=10)
        return value
    monkeypatch.setattr(domain_api, "_make_snapshot", snapshot)
    with ThreadPoolExecutor(max_workers=2) as workers:
        futures = [workers.submit(d["client"].post, "/teacher/assignments", headers=d["teacher"], json=body) for _ in range(2)]
        responses = [future.result(timeout=20) for future in futures]
    assert [r.status_code for r in responses] == [201, 201], [r.text for r in responses]
    assert responses[0].json()["id"] == responses[1].json()["id"]
    with d["app"].state.session_factory() as session:
        assert len(list(session.scalars(select(Assignment)))) == 1
        assert len(list(session.scalars(select(AssignmentItem)))) == 1
        assert len(list(session.scalars(select(AssignmentRecipient)))) == 2
        assert len(list(session.scalars(select(AssignmentRequest)))) == 1


@pytest.mark.parametrize("changed_answer", [False, True])
def test_concurrent_attempt_requests_are_idempotent_or_conflict(domain, monkeypatch, changed_answer):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Barrier
    from vaachak_backend import domain_api
    d = domain
    problem = choice(d)
    assignment = assign(d, [{"problem_id": problem["id"]}])
    item = items(d, assignment)[0]
    barrier, original = Barrier(2), domain_api._check_retry
    def check(*args):
        existing = original(*args)
        if existing is None:
            barrier.wait(timeout=10)
        return existing
    monkeypatch.setattr(domain_api, "_check_retry", check)
    request_id = str(uuid4())
    with ThreadPoolExecutor(max_workers=2) as workers:
        futures = [workers.submit(submit, d, assignment, item, answer, request_id)
                   for answer in ["correct", "wrong" if changed_answer else "correct"]]
        responses = [future.result(timeout=20) for future in futures]
    assert sorted(r.status_code for r in responses) == ([201, 409] if changed_answer else [201, 201]), [r.text for r in responses]
    with d["app"].state.session_factory() as session:
        saved = list(session.scalars(select(Attempt)))
        assert len(saved) == 1
        assert saved[0].answer in {"correct", "wrong"}
    if not changed_answer:
        assert responses[0].json()["id"] == responses[1].json()["id"]


def test_concurrent_audio_retry_leaves_one_attempt_and_one_recording(domain, monkeypatch):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Barrier
    from vaachak_backend import domain_api
    d = domain
    problem = create(d["client"], "/teacher/problems", d["teacher"], {"title": "Read", "kind": "read_aloud", "expected_text": "This is a test"})
    recording = d["client"].post(f"/problems/{problem['id']}/recordings", headers=d["teacher"], files={"file": ("voice.wav", audio_bytes())}).json()
    assignment = assign(d, [{"problem_id": problem["id"], "recording_id": recording["id"]}])
    item = items(d, assignment)[0]
    barrier, original = Barrier(2), domain_api.normalize
    def normalize(*args):
        value = original(*args)
        barrier.wait(timeout=10)
        return value
    monkeypatch.setattr(domain_api, "normalize", normalize)
    monkeypatch.setattr(domain_api, "_run_analysis", lambda *args: None)
    route = f"/student/assignments/{assignment['id']}/problems/{item['id']}/recordings"
    request_id, source = str(uuid4()), audio_bytes()
    with ThreadPoolExecutor(max_workers=2) as workers:
        futures = [workers.submit(d["client"].post, route, headers=d["student_auth"], data={"request_id": request_id}, files={"file": ("voice.wav", source)}) for _ in range(2)]
        responses = [future.result(timeout=20) for future in futures]
    assert [r.status_code for r in responses] == [201, 201], [r.text for r in responses]
    assert responses[0].json()["id"] == responses[1].json()["id"]
    assert len(list((d["directory"] / "attempts").iterdir())) == 1
    with d["app"].state.session_factory() as session:
        assert len(list(session.scalars(select(Attempt)))) == 1


def test_invalid_null_bodies_and_boolean_review_score_rejected(domain):
    d = domain
    for route in ["/teacher/classrooms", "/teacher/problems", "/teacher/assignments"]:
        for body in [None, [], {"title": None}]:
            response = d["client"].post(route, headers=d["teacher"], json=body)
            assert response.status_code == 422, response.text
    problem = choice(d)
    assignment = assign(d, [{"problem_id": problem["id"]}])
    item = items(d, assignment)[0]
    for answer in [None, {}, [], 1, True]:
        assert submit(d, assignment, item, answer).status_code == 422
    attempt = submit(d, assignment, item, "correct").json()
    for score in [True, False, "1", None, -1, 2]:
        response = d["client"].patch(f"/teacher/attempts/{attempt['id']}/review", headers=d["teacher"], json={"score": score, "feedback": "Test"})
        assert response.status_code == 422, response.text


def test_reference_must_belong_to_problem_and_missing_reference_is_explicit(domain):
    d = domain
    first = create(d["client"], "/teacher/problems", d["teacher"], {"title": "First", "kind": "read_aloud", "expected_text": "First sentence"})
    second = create(d["client"], "/teacher/problems", d["teacher"], {"title": "Second", "kind": "read_aloud", "expected_text": "Second sentence"})
    recording = d["client"].post(f"/problems/{first['id']}/recordings", headers=d["teacher"], files={"file": ("voice.wav", audio_bytes())}).json()
    body = {"title": "Wrong reference", "student_id": d["student"]["id"], "problems": [{"problem_id": second["id"], "recording_id": recording["id"]}]}
    assert d["client"].post("/teacher/assignments", headers=d["teacher"], json=body).status_code == 422
    assignment = assign(d, [{"problem_id": first["id"], "recording_id": recording["id"]}])
    item = items(d, assignment)[0]
    (d["directory"] / "recordings" / recording["id"] / "reference.wav").unlink()
    assert d["client"].get(item["reference_audio_url"], headers=d["student_auth"]).status_code == 503
    body["problems"][0]["problem_id"] = first["id"]
    assert d["client"].post("/teacher/assignments", headers=d["teacher"], json=body).status_code == 409


@pytest.mark.parametrize("bad_text", ["bad\x00text", "bad\ud800text"])
def test_nonportable_database_text_is_rejected_before_storage(domain, bad_text):
    import json
    d = domain
    body = {"title": "Meaning", "kind": "meaning", "expected_text": "A small home", "payload": {"accepted_answers": [bad_text]}}
    response = d["client"].post("/teacher/problems", headers={**d["teacher"], "Content-Type": "application/json"}, content=json.dumps(body))
    assert response.status_code == 422, response.text
    assert bad_text not in response.text
    response = d["client"].post(f"/teacher/classrooms/{d['room']['id']}/students", headers={**d["teacher"], "Content-Type": "application/json"},
                               content=json.dumps({"display_name": bad_text, "login_name": "bad-text", "password": PASSWORD}))
    assert response.status_code == 422, response.text
    assert d["client"].get("/teacher/problems", headers=d["teacher"]).json() == []


def test_review_preserves_analysis_that_commits_after_review_read(domain, monkeypatch):
    from sqlalchemy.orm import Session
    from sqlalchemy.sql.dml import Update
    d = domain
    problem = create(d["client"], "/teacher/problems", d["teacher"], {"title": "Meaning", "kind": "meaning", "expected_text": "Tiny house",
                     "payload": {"accepted_answers": ["Small home"]}})
    assignment = assign(d, [{"problem_id": problem["id"]}])
    monkeypatch.setattr("vaachak_backend.domain_api._run_analysis", lambda *args: None)
    attempt_id = submit(d, assignment, items(d, assignment)[0], "Small home").json()["id"]
    execute = Session.execute
    injected = False
    def inject_analysis(self, statement, *args, **kwargs):
        nonlocal injected
        if not injected and isinstance(statement, Update) and statement.table.name == "student_attempts" and "reviewed_at" in statement.compile().params:
            injected = True
            with d["app"].state.session_factory() as session:
                row = session.get(Attempt, attempt_id)
                row.status, row.score, row.feedback = "completed", .6, "Automatic suggestion"
                row.analyzed_at = "2026-09-25T22:00:00+00:00"
                row.result = {"model_evidence": {"retained": True}}
                session.commit()
        return execute(self, statement, *args, **kwargs)
    monkeypatch.setattr(Session, "execute", inject_analysis)
    response = d["client"].patch(f"/teacher/attempts/{attempt_id}/review", headers=d["teacher"], json={"score": .9, "feedback": "Teacher judgment"})
    assert injected
    assert response.status_code == 200, response.text
    result = response.json()
    assert result["score"] == .9 and result["feedback"] == "Teacher judgment"
    assert result["result"]["model_evidence"]["retained"] is True
    assert result["result"]["automatic_score"] == .6
    assert result["result"]["automatic_feedback"] == "Automatic suggestion"
    with d["app"].state.session_factory() as session:
        assert len(list(session.scalars(select(AttemptReview)))) == 1


def test_teacher_password_reset_revokes_sessions_and_preserves_learning(domain):
    d = domain
    problem = choice(d)
    assignment = assign(d, [{"problem_id": problem["id"]}])
    attempt = submit(d, assignment, items(d, assignment)[0], "correct").json()
    assert attempt["answer_display"] == "Joyful"
    route = f"/teacher/students/{d['student']['id']}/password"
    new_password = " new student password "
    assert d["client"].patch(route, headers=d["outsider"], json={"password": new_password}).status_code == 404
    assert d["client"].patch(route, headers=d["student_auth"], json={"password": new_password}).status_code == 403
    for bad in [{"password": "short"}, {"password": None}, {"password": new_password, "display_name": "Changed"}]:
        assert d["client"].patch(route, headers=d["teacher"], json=bad).status_code == 422
    assert d["client"].get("/auth/me", headers=d["student_auth"]).status_code == 200
    assert d["client"].patch(route, headers=d["teacher"], json={"password": new_password}).status_code == 204
    assert d["client"].get("/auth/me", headers=d["student_auth"]).status_code == 401
    assert d["client"].get("/auth/me", headers=d["second_auth"]).status_code == 200
    assert d["client"].post("/auth/login", json={"identifier": "asha.6", "password": PASSWORD, "role": "student"}).status_code == 401
    login = d["client"].post("/auth/login", json={"identifier": "asha.6", "password": new_password, "role": "student"})
    assert login.status_code == 200, login.text
    assert login.json()["user"]["id"] == d["student"]["id"]
    new_auth = auth(login)
    saved = d["client"].get(f"/student/attempts/{attempt['id']}", headers=new_auth)
    assert saved.status_code == 200 and saved.json()["score"] == 1
    assert d["client"].get("/student/assignments", headers=new_auth).json()[0]["id"] == assignment["id"]


def test_old_password_login_cannot_recreate_session_after_reset(domain, monkeypatch):
    from vaachak_backend import api
    from vaachak_backend.db import StudentSession
    d = domain
    original = api.verify_password
    reset_performed = False
    def reset_after_verification(password, encoded):
        nonlocal reset_performed
        valid = original(password, encoded)
        if valid and not reset_performed:
            reset_performed = True
            response = d["client"].patch(f"/teacher/students/{d['student']['id']}/password", headers=d["teacher"], json={"password": "replacement password"})
            assert response.status_code == 204, response.text
        return valid
    monkeypatch.setattr(api, "verify_password", reset_after_verification)
    response = d["client"].post("/auth/login", json={"identifier": "asha.6", "password": PASSWORD, "role": "student"})
    assert reset_performed and response.status_code == 401, response.text
    with d["app"].state.session_factory() as session:
        assert list(session.scalars(select(StudentSession).where(StudentSession.student_id == d["student"]["id"]))) == []


def test_queue_resumes_saved_jobs_sequentially_after_interruption(domain, monkeypatch):
    from threading import Event, Lock
    from vaachak_backend import domain_api
    from vaachak_backend.job_service import AnalysisQueue
    d = domain
    problem = create(d["client"], "/teacher/problems", d["teacher"], {"title": "Meaning", "kind": "meaning", "expected_text": "Small home",
                     "payload": {"accepted_answers": ["Tiny house"]}})
    assignment = assign(d, [{"problem_id": problem["id"]}])
    item = items(d, assignment)[0]
    monkeypatch.setattr(domain_api, "_run_analysis", lambda *args: None)
    identifiers = [submit(d, assignment, item, answer).json()["id"] for answer in ["Tiny house", "Another answer"]]
    started, release = Event(), Event()
    def interrupted(*args):
        started.set()
        release.wait(10)
        # Simulate process shutdown before any result is persisted.
    monkeypatch.setattr(domain_api, "_run_analysis", interrupted)
    first = AnalysisQueue(d["app"].state.session_factory, d["directory"], poll_seconds=.02)
    first.start()
    try:
        assert started.wait(5)
        assert first.stop(timeout=.01) is False
        blocked = AnalysisQueue(d["app"].state.session_factory, d["directory"])
        with pytest.raises(RuntimeError, match="Another analysis worker"):
            blocked.start()
    finally:
        release.set()
        assert first.stop(timeout=5)
    with d["app"].state.session_factory() as session:
        assert all(session.get(Attempt, identifier).status == "pending" for identifier in identifiers)
    monkeypatch.setattr("vaachak_backend.speech_service.evaluate_meaning", lambda *args: {"status": "completed", "score": 1, "feedback": "Assessed", "result": {}})
    finished, guard = Event(), Lock()
    processed, active = [], 0
    def analyze(factory, directory, identifier):
        nonlocal active
        with guard:
            active += 1
            assert active == 1
        _run_analysis(factory, directory, identifier)
        with guard:
            processed.append(identifier)
            active -= 1
            if len(processed) == 2:
                finished.set()
    monkeypatch.setattr(domain_api, "_run_analysis", analyze)
    resumed = AnalysisQueue(d["app"].state.session_factory, d["directory"], poll_seconds=.02)
    resumed.start()
    try:
        assert finished.wait(10)
        assert processed == identifiers
        with d["app"].state.session_factory() as session:
            assert all(session.get(Attempt, identifier).status == "completed" for identifier in identifiers)
            assert len(list(session.scalars(select(Attempt)))) == 2
    finally:
        assert resumed.stop(timeout=5)


def test_live_queue_submission_wakes_worker_without_request_thread_analysis(domain, monkeypatch):
    from threading import Event
    from vaachak_backend import domain_api
    from vaachak_backend.job_service import AnalysisQueue
    d = domain
    problem = create(d["client"], "/teacher/problems", d["teacher"], {"title": "Meaning", "kind": "meaning", "expected_text": "Small house",
                     "payload": {"accepted_answers": ["Tiny home"]}})
    assignment = assign(d, [{"problem_id": problem["id"]}])
    item = items(d, assignment)[0]
    entered, release, finished = Event(), Event(), Event()
    def analyze(factory, directory, identifier):
        entered.set()
        release.wait(10)
        _run_analysis(factory, directory, identifier)
        finished.set()
    monkeypatch.setattr(domain_api, "_run_analysis", analyze)
    monkeypatch.setattr("vaachak_backend.speech_service.evaluate_meaning", lambda *args: {"status": "completed", "score": 1, "feedback": "Correct", "result": {}})
    queue = AnalysisQueue(d["app"].state.session_factory, d["directory"], poll_seconds=30)
    d["app"].state.analysis_queue = queue
    queue.start()
    try:
        # The HTTP request must finish while model analysis is blocked.
        response = submit(d, assignment, item, "Tiny home")
        assert response.status_code == 201 and response.json()["status"] == "pending"
        assert entered.wait(5)
        release.set()
        assert finished.wait(5)
        assert d["client"].get(f"/student/attempts/{response.json()['id']}", headers=d["student_auth"]).json()["status"] == "completed"
    finally:
        release.set()
        assert queue.stop(timeout=5)
        del d["app"].state.analysis_queue
