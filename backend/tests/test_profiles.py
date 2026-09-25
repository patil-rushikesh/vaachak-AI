"""Optional learning context, ownership, additive bootstrap and immutable audio snapshots."""
import io
import json
import os
import wave
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from uuid import uuid4

import numpy as np
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, delete, func, inspect, select
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from vaachak_backend.api import create_app
from vaachak_backend.db import Base, LoginSession, Problem, Recording, Teacher, new_id
from vaachak_backend.domain_models import Attempt, Classroom, Student, StudentProfile, TeacherProfile
from vaachak_backend.profile_service import PROFILE_FIELDS
from vaachak_backend.security import hash_password

PASSWORD = "profile test password"
PROFILE = {"country": "India", "state_region": "Maharashtra", "city": "Pune", "first_language": "Marathi", "target_accent": "British English"}


@pytest.fixture
def setup(tmp_path):
    app = create_app(database_url=os.getenv("TEST_DATABASE_URL") or f"sqlite:///{tmp_path / 'test.sqlite3'}", data_dir=tmp_path, analysis_worker=False)
    with app.state.session_factory() as session:
        for table in reversed(Base.metadata.sorted_tables):
            session.execute(delete(table))
        session.commit()
    with TestClient(app) as client:
        yield client, app, tmp_path


def register(client, email="teacher@example.test", profile=None):
    body = {"email": email, "password": PASSWORD}
    if profile is not None:
        body["learning_profile"] = profile
    response = client.post("/auth/register", json=body)
    assert response.status_code == 201, response.text
    return {"Authorization": "Bearer " + response.json()["access_token"]}, response.json()["user"]["id"]


def create_classroom_student(client, teacher, profile=None, name="learner"):
    room = client.post("/teacher/classrooms", headers=teacher, json={"school_name": "Test School", "name": "Class 6", "postal_code": "411001"})
    assert room.status_code == 201, room.text
    body = {"display_name": "Test Learner", "login_name": name, "password": PASSWORD}
    if profile is not None:
        body["learning_profile"] = profile
    response = client.post(f"/teacher/classrooms/{room.json()['id']}/students", headers=teacher, json=body)
    assert response.status_code == 201, response.text
    login = client.post("/auth/login", json={"identifier": name, "role": "student", "password": PASSWORD})
    assert login.status_code == 200, login.text
    return room.json(), response.json(), {"Authorization": "Bearer " + login.json()["access_token"]}


def patch(client, route, headers, profile):
    response = client.patch(route, headers=headers, json={"learning_profile": profile})
    assert response.status_code == 200, response.text
    return response.json()["learning_profile"]


def wav_bytes():
    samples = .2 * np.sin(np.arange(32000) * 2 * np.pi * 220 / 16000)
    stream = io.BytesIO()
    with wave.open(stream, "wb") as audio:
        audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        audio.writeframes((samples * 32767).astype("<i2").tobytes())
    return stream.getvalue()


def practice(client, teacher, student_id, kind="choice"):
    body = {"title": "Practice", "kind": kind, "expected_text": "This is my house."}
    if kind == "choice":
        body["payload"] = {"options": [{"id": "a", "text": "One"}, {"id": "b", "text": "Two"}], "correct_option_id": "a"}
    elif kind == "meaning":
        body["payload"] = {"accepted_answers": ["This home belongs to me"]}
    response = client.post("/teacher/problems", headers=teacher, json=body)
    assert response.status_code == 201, response.text
    problem = response.json()
    item = {"problem_id": problem["id"]}
    if kind == "read_aloud":
        audio = client.post(f"/problems/{problem['id']}/recordings", headers=teacher, files={"file": ("voice.wav", wav_bytes())})
        assert audio.status_code == 201, audio.text
        item["recording_id"] = audio.json()["id"]
        problem["reference"] = audio.json()
    assignment = client.post("/teacher/assignments", headers=teacher, json={"title": "Practice", "student_id": student_id, "problems": [item]})
    assert assignment.status_code == 201, assignment.text
    return problem, assignment.json()


def student_item(client, student, assignment):
    response = client.get(f"/student/assignments/{assignment['id']}", headers=student)
    assert response.status_code == 200, response.text
    return response.json()["problems"][0]


def test_signup_profiles_are_optional_trimmed_and_never_infer_accent(setup):
    client, app, _ = setup
    teacher, teacher_id = register(client, profile={key: f"  {value}  " for key, value in PROFILE.items()})
    profile = client.get("/teacher/profile", headers=teacher).json()["learning_profile"]
    assert {key: profile[key] for key in PROFILE_FIELDS} == PROFILE
    assert profile["provenance"] == "self_reported" and profile["entered_by"] == "self"
    assert profile["updated_at"]
    blank_teacher, blank_id = register(client, "blank@example.test")
    blank = client.get("/teacher/profile", headers=blank_teacher).json()["learning_profile"]
    assert {key: blank[key] for key in PROFILE_FIELDS} == dict.fromkeys(PROFILE_FIELDS, "")
    assert blank["provenance"] == "not_provided" and blank["entered_by"] is None
    _, learner, student = create_classroom_student(client, teacher, {"country": "India", "first_language": "Hindi"})
    assert learner["learning_profile"]["country"] == "India"
    assert learner["learning_profile"]["target_accent"] == ""
    assert learner["learning_profile"]["provenance"] == "teacher_entered"
    assert client.get("/student/profile", headers=student).json()["learning_profile"] == learner["learning_profile"]
    with app.state.session_factory() as session:
        assert session.get(TeacherProfile, teacher_id).city == "Pune"
        assert session.get(TeacherProfile, blank_id) is None
        assert session.get(StudentProfile, learner["id"]).target_accent == ""


def test_partial_updates_clear_explicit_values_and_noop_does_not_change_context(setup):
    client, _, _ = setup
    teacher, _ = register(client, profile=PROFILE)
    profile = patch(client, "/teacher/profile", teacher, {"city": "  Mumbai  ", "target_accent": ""})
    assert profile["city"] == "Mumbai" and profile["target_accent"] == ""
    assert profile["country"] == "India" and profile["first_language"] == "Marathi"
    assert patch(client, "/teacher/profile", teacher, {}) == profile
    room, learner, student = create_classroom_student(client, teacher, PROFILE)
    changed = patch(client, "/student/profile", student, {"city": "", "first_language": "ગુજરાતી"})
    assert changed["city"] == "" and changed["first_language"] == "ગુજરાતી"
    assert changed["state_region"] == "Maharashtra" and changed["provenance"] == "self_reported"
    teacher_edit = patch(client, f"/teacher/students/{learner['id']}/profile", teacher, {"target_accent": "General American"})
    assert teacher_edit["target_accent"] == "General American" and teacher_edit["entered_by"] == "teacher"
    assert teacher_edit["first_language"] == "ગુજરાતી"
    roster = client.get(f"/teacher/classrooms/{room['id']}", headers=teacher).json()
    assert roster["students"][0]["learning_profile"] == teacher_edit
    detail = client.get(f"/teacher/students/{learner['id']}", headers=teacher).json()
    assert detail["learning_profile"] == teacher_edit == detail["student"]["learning_profile"]


def test_profile_role_ownership_and_privacy(setup):
    client, _, _ = setup
    teacher, _ = register(client, profile=PROFILE)
    outsider, _ = register(client, "outsider@example.test")
    room, learner, student = create_classroom_student(client, teacher, PROFILE)
    for path in ["/teacher/profile", "/student/profile"]:
        assert client.get(path).status_code == 401
    assert client.get("/teacher/profile", headers=student).status_code == 403
    assert client.get("/student/profile", headers=teacher).status_code == 403
    assert client.patch("/teacher/profile", headers=student, json={"learning_profile": PROFILE}).status_code == 403
    assert client.patch("/student/profile", headers=teacher, json={"learning_profile": PROFILE}).status_code == 403
    route = f"/teacher/students/{learner['id']}/profile"
    assert client.patch(route, headers=outsider, json={"learning_profile": PROFILE}).status_code == 404
    assert client.patch(route, headers=student, json={"learning_profile": PROFILE}).status_code == 403
    assert client.get(f"/teacher/students/{learner['id']}", headers=outsider).status_code == 404
    assert client.get(f"/teacher/classrooms/{room['id']}", headers=outsider).status_code == 404
    assert client.get("/teacher/profile", headers=outsider).json()["learning_profile"]["city"] == ""
    assert "learning_profile" not in client.get("/auth/me", headers=student).json()


@pytest.mark.parametrize("profile", [None, [], {"country": None}, {"country": 123}, {"city": "x" * 101}, {"first_language": "bad\x00text"},
                                     {"target_accent": "bad\ud800text"}, {"latitude": 18.5}, {"provenance": "inferred"}])
def test_invalid_signup_profile_does_not_create_an_account(setup, profile):
    client, app, _ = setup
    response = client.post("/auth/register", content=json.dumps({"email": "invalid@example.test", "password": PASSWORD, "learning_profile": profile}),
                           headers={"Content-Type": "application/json"})
    assert response.status_code == 422, response.text
    with app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(Teacher)) == 0
        assert session.scalar(select(func.count()).select_from(TeacherProfile)) == 0
        assert session.scalar(select(func.count()).select_from(LoginSession)) == 0


def test_signup_profile_write_failure_rolls_back_account_and_session(setup, monkeypatch):
    from vaachak_backend import api
    client, app, _ = setup
    original = api.update_profile
    def fail_after_write(*args, **kwargs):
        original(*args, **kwargs)
        raise OperationalError("save optional profile", {}, RuntimeError("simulated database failure"))
    monkeypatch.setattr(api, "update_profile", fail_after_write)
    response = client.post("/auth/register", json={"email": "invalid@example.test", "password": PASSWORD, "learning_profile": PROFILE})
    assert response.status_code == 503
    with app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(Teacher)) == 0
        assert session.scalar(select(func.count()).select_from(TeacherProfile)) == 0
        assert session.scalar(select(func.count()).select_from(LoginSession)) == 0


def test_concurrent_partial_profile_updates_merge_on_blank_historical_account(setup, monkeypatch):
    from vaachak_backend import domain_api
    client, _, _ = setup
    teacher, _ = register(client)
    barrier, original = Barrier(2), domain_api.update_profile
    def synchronized(*args, **kwargs):
        barrier.wait(timeout=10)
        return original(*args, **kwargs)
    monkeypatch.setattr(domain_api, "update_profile", synchronized)
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(client.patch, "/teacher/profile", headers=teacher, json={"learning_profile": part})
                   for part in [{"country": "India"}, {"city": "Pune"}]]
        responses = [future.result(timeout=20) for future in futures]
    assert all(response.status_code == 200 for response in responses), [response.text for response in responses]
    profile = client.get("/teacher/profile", headers=teacher).json()["learning_profile"]
    assert profile["country"] == "India" and profile["city"] == "Pune"
    assert profile["target_accent"] == ""


def test_new_profile_tables_preserve_legacy_database_and_recordings(tmp_path):
    database = f"sqlite:///{tmp_path / 'legacy.sqlite3'}"
    engine = create_engine(database)
    legacy_tables = [table for table in Base.metadata.sorted_tables if table.name not in {"teacher_profiles", "student_profiles"}]
    Base.metadata.create_all(engine, tables=legacy_tables)
    before = {name: [column["name"] for column in inspect(engine).get_columns(name)] for name in inspect(engine).get_table_names()}
    with Session(engine) as session:
        teacher = Teacher(email="legacy@example.test", password_hash=hash_password(PASSWORD))
        session.add(teacher)
        session.flush()
        room = Classroom(teacher_id=teacher.id, school_name="Existing school", name="Existing class", postal_code="411001", join_code="LEGACY12")
        problem = Problem(teacher_id=teacher.id, title="Old reference", kind="read_aloud", expected_text="Old sentence", teaching_notes="")
        session.add_all([room, problem])
        session.flush()
        student = Student(teacher_id=teacher.id, classroom_id=room.id, display_name="Existing learner", login_name="legacy-learner", password_hash=hash_password(PASSWORD))
        recording = Recording(problem_id=problem.id, original_sha256="old-original", normalized_sha256="old-normalized", original_bytes=12, duration_seconds=1,
                              measurements={"measurement_version": "legacy", "duration_seconds": 1})
        session.add_all([student, recording])
        session.commit()
        teacher_id, student_id, problem_id, recording_id = teacher.id, student.id, problem.id, recording.id
    engine.dispose()
    app = create_app(database_url=database, data_dir=tmp_path, analysis_worker=False)
    with TestClient(app) as client:
        login = client.post("/auth/login", json={"email": "legacy@example.test", "password": PASSWORD})
        assert login.status_code == 200
        teacher_headers = {"Authorization": "Bearer " + login.json()["access_token"]}
        assert client.get("/teacher/profile", headers=teacher_headers).json()["learning_profile"]["provenance"] == "not_provided"
        old = client.get(f"/problems/{problem_id}/recordings", headers=teacher_headers).json()[0]
        assert old["id"] == recording_id and old["measurements"] == {"measurement_version": "legacy", "duration_seconds": 1}
        profile = client.get(f"/teacher/students/{student_id}", headers=teacher_headers).json()["learning_profile"]
        assert all(profile[field] == "" for field in PROFILE_FIELDS)
        patch(client, "/teacher/profile", teacher_headers, {"country": "India"})
        assert "learning_context" not in client.get(f"/problems/{problem_id}/recordings", headers=teacher_headers).json()[0]["measurements"]
        with app.state.session_factory() as session:
            after = inspect(session.bind)
            assert {name: [column["name"] for column in after.get_columns(name)] for name in before} == before
            assert {"teacher_profiles", "student_profiles"}.issubset(after.get_table_names())
            assert session.get(Teacher, teacher_id).email == "legacy@example.test"
            assert session.get(Student, student_id).display_name == "Existing learner"


def test_audio_learning_context_is_private_immutable_and_not_used_for_grading(setup, monkeypatch):
    client, app, directory = setup
    teacher, _ = register(client, profile={**PROFILE, "city": "Teacher town"})
    _, learner, student = create_classroom_student(client, teacher, {**PROFILE, "city": "Learner town", "target_accent": ""})
    analysis_calls = []
    def analyze(audio_path, expected_text, reference_path=None):
        analysis_calls.append((audio_path, expected_text, reference_path))
        return {"status": "completed", "score": .5, "feedback": "Experimental word match", "result": {
            "score_kind": "experimental_transcript_word_accuracy", "word_accuracy": .5, "word_coverage": .5,
            "alignment": [{"operation": "substitute", "expected": "house", "spoken": "horse"}],
            "pronunciation": {"status": "not_assessed", "score": None}, "pitch": {"status": "available", "score": None},
        }}
    monkeypatch.setattr("vaachak_backend.speech_service.analyze_reading", analyze)
    problem, assignment = practice(client, teacher, learner["id"], "read_aloud")
    reference = problem["reference"]
    reference_context = reference["measurements"]["learning_context"]
    assert reference_context["learning_profile"]["city"] == "Teacher town"
    assert reference_context["learning_profile"]["provenance"] == "self_reported"
    assert reference_context["recorded_at"]
    item = student_item(client, student, assignment)
    assert "Teacher town" not in json.dumps(item)
    assert client.get(f"/problems/{problem['id']}/recordings", headers=student).status_code == 403
    assert client.get(item["reference_audio_url"], headers=student).status_code == 200
    route = f"/student/assignments/{assignment['id']}/problems/{item['id']}/recordings"
    request_id, source = str(uuid4()), wav_bytes()
    uploaded = client.post(route, headers=student, data={"request_id": request_id}, files={"file": ("voice.wav", source)})
    assert uploaded.status_code == 201, uploaded.text
    attempt = client.get(f"/student/attempts/{uploaded.json()['id']}", headers=student).json()
    context = attempt["measurements"]["learning_context"]
    assert context["learning_profile"]["city"] == "Learner town"
    assert context["learning_profile"]["entered_by"] == "teacher"
    assert context["learning_profile"]["target_accent"] == ""
    assert context["recorded_at"]
    assert attempt["reference_audio_url"] == item["reference_audio_url"]
    assert (directory / "attempts" / attempt["id"] / "original").read_bytes() == source
    assert analysis_calls[0][1] == "This is my house."
    assert all("town" not in str(argument) for argument in analysis_calls[0])
    patch(client, "/teacher/profile", teacher, {"city": "Teacher moved"})
    patch(client, "/student/profile", student, {"city": "Learner moved", "target_accent": "General American"})
    replay = client.post(route, headers=student, data={"request_id": request_id}, files={"file": ("voice.wav", source)})
    assert replay.json()["id"] == attempt["id"]
    assert replay.json()["measurements"]["learning_context"] == context
    assert client.get(f"/problems/{problem['id']}/recordings", headers=teacher).json()[0]["measurements"]["learning_context"] == reference_context
    new_attempt = client.post(route, headers=student, data={"request_id": str(uuid4())}, files={"file": ("voice.wav", source)})
    assert new_attempt.status_code == 201
    new_context = new_attempt.json()["measurements"]["learning_context"]
    assert new_context["learning_profile"]["city"] == "Learner moved"
    assert new_context["learning_profile"]["target_accent"] == "General American"
    assert new_context["learning_profile"]["entered_by"] == "self"
    assert client.get(f"/student/attempts/{new_attempt.json()['id']}", headers=student).json()["score"] == .5
    # A teacher grade is separate from unmodified word-match evidence.
    reviewed = client.patch(f"/teacher/attempts/{attempt['id']}/review", headers=teacher, json={"score": .9, "feedback": "Teacher reviewed the audio."})
    assert reviewed.status_code == 200, reviewed.text
    value = client.get(f"/student/attempts/{attempt['id']}", headers=student).json()
    dimensions = {dimension["key"]: dimension for dimension in value["display_feedback"]["dimensions"]}
    assert value["score"] == .9 and value["result"]["word_accuracy"] == .5
    assert dimensions["word_match"]["score"] == .5
    assert dimensions["teacher_review"]["score"] == .9
    assert all(dimensions[key]["score"] is None for key in ["pitch", "pace", "pauses", "pronunciation"])


def test_practice_status_buckets_count_latest_attempt_once_per_assignment_item(setup, monkeypatch):
    client, app, _ = setup
    teacher, _ = register(client)
    _, learner, student = create_classroom_student(client, teacher)
    problem, first = practice(client, teacher, learner["id"])
    second = client.post("/teacher/assignments", headers=teacher, json={"title": "Practice again", "student_id": learner["id"], "problems": [{"problem_id": problem["id"]}]}).json()
    def buckets():
        overview = client.get("/student/overview", headers=student).json()
        value = overview["progress"]["current_practice_status"]
        assert sum(value[key] for key in ("graded", "pending", "needs_review", "not_started")) == value["total"]
        teacher_value = client.get(f"/teacher/students/{learner['id']}", headers=teacher).json()["progress"]["current_practice_status"]
        assert teacher_value == value
        return value
    assert buckets() == {"graded": 0, "pending": 0, "needs_review": 0, "not_started": 2, "total": 2}
    item = student_item(client, student, first)
    route = f"/student/assignments/{first['id']}/problems/{item['id']}/attempts"
    body = {"request_id": str(uuid4()), "answer": "a"}
    attempt = client.post(route, headers=student, json=body).json()
    assert client.post(route, headers=student, json=body).json()["id"] == attempt["id"]
    assert buckets() == {"graded": 1, "pending": 0, "needs_review": 0, "not_started": 1, "total": 2}
    second_item = student_item(client, student, second)
    second_route = f"/student/assignments/{second['id']}/problems/{second_item['id']}/attempts"
    assert client.post(second_route, headers=student, json={"request_id": str(uuid4()), "answer": "a"}).status_code == 201
    assert buckets()["graded"] == 2
    _, meaning = practice(client, teacher, learner["id"], "meaning")
    meaning_item = student_item(client, student, meaning)
    meaning_route = f"/student/assignments/{meaning['id']}/problems/{meaning_item['id']}/attempts"
    monkeypatch.setattr("vaachak_backend.speech_service.evaluate_meaning", lambda *args: {"status": "completed", "score": 1, "feedback": "Correct", "result": {}})
    assert client.post(meaning_route, headers=student, json={"request_id": str(uuid4()), "answer": "This home belongs to me"}).status_code == 201
    assert buckets() == {"graded": 3, "pending": 0, "needs_review": 0, "not_started": 0, "total": 3}
    monkeypatch.setattr("vaachak_backend.domain_api._run_analysis", lambda *args: None)
    pending = client.post(meaning_route, headers=student, json={"request_id": str(uuid4()), "answer": "A different explanation"}).json()
    assert buckets() == {"graded": 2, "pending": 1, "needs_review": 0, "not_started": 0, "total": 3}
    with app.state.session_factory() as session:
        session.get(Attempt, pending["id"]).status = "failed"
        session.commit()
    assert buckets() == {"graded": 2, "pending": 0, "needs_review": 1, "not_started": 0, "total": 3}
    assert client.patch(f"/teacher/attempts/{pending['id']}/review", headers=teacher, json={"score": .8, "feedback": "Meaning understood."}).status_code == 200
    assert buckets() == {"graded": 3, "pending": 0, "needs_review": 0, "not_started": 0, "total": 3}


def test_unreviewed_semantic_suggestions_do_not_leak_through_display_feedback(setup, monkeypatch):
    client, _, _ = setup
    teacher, _ = register(client)
    _, learner, student = create_classroom_student(client, teacher)
    _, assignment = practice(client, teacher, learner["id"], "meaning")
    item = student_item(client, student, assignment)
    monkeypatch.setattr("vaachak_backend.speech_service.evaluate_meaning", lambda *args: {
        "status": "needs_review", "score": None, "feedback": "Your teacher will review this answer.",
        "result": {"method": "ai_semantic_review", "suggested_score": .12345, "classification": "incorrect",
                   "explanation": "PRIVATE MODEL SUGGESTION", "confidence": .99}})
    attempt = client.post(f"/student/assignments/{assignment['id']}/problems/{item['id']}/attempts", headers=student,
                          json={"request_id": str(uuid4()), "answer": "It is my home"}).json()
    student_view = client.get(f"/student/attempts/{attempt['id']}", headers=student).json()
    assert student_view["score"] is None and "display_feedback" in student_view
    assert "PRIVATE MODEL SUGGESTION" not in json.dumps(student_view)
    assert "0.12345" not in json.dumps(student_view)
    assert all(dimension["score"] is None for dimension in student_view["display_feedback"]["dimensions"])
    teacher_view = client.get(f"/teacher/students/{learner['id']}", headers=teacher).json()["attempts"][0]
    assert teacher_view["result"]["suggested_score"] == .12345
    assert "PRIVATE MODEL SUGGESTION" not in json.dumps(teacher_view["display_feedback"])
