"""Role boundaries and account creation contracts."""
import os

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete, select

from vaachak_backend.api import create_app
from vaachak_backend.db import Base, LoginSession, StudentSession, Teacher
from vaachak_backend.domain_models import Classroom, Student
from vaachak_backend.security import hash_password


@pytest.fixture
def client(tmp_path):
    app = create_app(database_url=os.getenv("TEST_DATABASE_URL") or f"sqlite:///{tmp_path / 'test.sqlite3'}", data_dir=tmp_path, analysis_worker=False)
    with app.state.session_factory() as session:
        for table in reversed(Base.metadata.sorted_tables):
            session.execute(delete(table))
        session.commit()
    with TestClient(app) as client:
        yield client, app


def test_registration_normalization_duplicate_and_session_secrecy(client):
    client, app = client
    payload = {"email": " Teacher@Example.test ", "password": "correct teacher password"}
    response = client.post("/auth/register", json=payload)
    assert response.status_code == 201, response.text
    token = response.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    assert response.json()["user"]["role"] == "teacher"
    assert client.get("/auth/me", headers=headers).json()["display_name"] == "teacher@example.test"
    assert client.post("/auth/register", json=payload).status_code == 409
    assert client.post("/auth/register", json={"email": "bad", "password": "x" * 12}).status_code == 422
    assert client.post("/auth/register", json={"email": "new@example.test", "password": "short"}).status_code == 422
    assert client.post("/auth/login", json={"identifier": "TEACHER@example.test", "password": payload["password"], "role": "teacher"}).status_code == 200
    assert client.post("/auth/login", json={"identifier": "teacher@example.test", "password": "wrong", "role": "teacher"}).status_code == 401
    with app.state.session_factory() as session:
        teacher = session.scalar(select(Teacher))
        login = session.scalar(select(LoginSession))
        assert teacher.password_hash != payload["password"]
        assert login.token_hash != token


def test_student_auth_role_boundary_expiry_and_logout(client):
    client, app = client
    registered = client.post("/auth/register", json={"email": "teacher@example.test", "password": "correct teacher password"}).json()
    teacher_id = registered["user"]["id"]
    with app.state.session_factory() as session:
        room = Classroom(teacher_id=teacher_id, name="Class 6", school_name="Test School", postal_code="411001", join_code="ABC123XY")
        session.add(room)
        session.flush()
        student = Student(teacher_id=teacher_id, classroom_id=room.id, display_name="Test Student",
                          login_name="test-student", password_hash=hash_password("student password"))
        session.add(student)
        session.commit()
    response = client.post("/auth/login", json={"identifier": "TEST-STUDENT", "password": "student password", "role": "student"})
    assert response.status_code == 200, response.text
    headers = {"Authorization": f"Bearer {response.json()['access_token']}"}
    assert client.get("/auth/me", headers=headers).json()["role"] == "student"
    assert client.get("/problems", headers=headers).status_code == 403
    assert client.get("/teacher/classrooms", headers=headers).status_code == 403
    teacher_headers = {"Authorization": f"Bearer {registered['access_token']}"}
    assert client.get("/student/assignments", headers=teacher_headers).status_code == 403
    assert client.post("/auth/login", json={"identifier": "test-student", "password": "student password", "role": "teacher"}).status_code == 401
    assert client.post("/auth/logout", headers=headers).status_code == 204
    assert client.get("/auth/me", headers=headers).status_code == 401
    response = client.post("/auth/login", json={"identifier": "test-student", "password": "student password", "role": "student"})
    with app.state.session_factory() as session:
        row = session.scalar(select(StudentSession))
        row.expires_at = 0
        session.commit()
    assert client.get("/auth/me", headers={"Authorization": f"Bearer {response.json()['access_token']}"}).status_code == 401


def test_validation_does_not_echo_password_or_nonfinite_input(client):
    client, _ = client
    response = client.post('/auth/register', json={'email': 'test@example.test', 'password': 'secret'})
    assert response.status_code == 422
    assert 'secret' not in response.text
    auth = client.post('/auth/register', json={'email': 'teacher@example.test', 'password': 'correct teacher password'}).json()
    headers = {'Authorization': f"Bearer {auth['access_token']}"}
    response = client.patch('/teacher/attempts/00000000-0000-0000-0000-000000000000/review',
                            content='{"score":NaN,"feedback":"Invalid score"}',
                            headers={**headers, 'Content-Type': 'application/json'})
    assert response.status_code == 422
    assert response.json()['detail'][0]['loc'] == ['body', 'score']
    assert response.headers['cache-control'] == 'no-store'


def test_private_responses_and_errors_are_not_cached(client):
    client, _ = client
    for path in ['/auth/me', '/teacher/classrooms', '/student/overview']:
        response = client.get(path)
        assert response.status_code == 401
        assert response.headers['cache-control'] == 'no-store'
        assert response.headers['x-content-type-options'] == 'nosniff'


def test_expired_sessions_are_pruned_when_signing_in(client):
    client, app = client
    payload = {'email': 'teacher@example.test', 'password': 'correct teacher password'}
    client.post('/auth/register', json=payload)
    with app.state.session_factory() as session:
        stale = session.scalar(select(LoginSession))
        stale.expires_at = 0
        stale_hash = stale.token_hash
        session.commit()
    response = client.post('/auth/login', json=payload)
    assert response.status_code == 200
    with app.state.session_factory() as session:
        assert session.get(LoginSession, stale_hash) is None


def test_database_outage_returns_retryable_error_without_sensitive_sql(client, monkeypatch):
    from sqlalchemy.exc import OperationalError
    from sqlalchemy.orm import Session
    client, _ = client

    def unavailable(self):
        raise OperationalError('secret SQL statement', {'password': 'do-not-expose'}, Exception('private host'))

    with monkeypatch.context() as patch:
        patch.setattr(Session, 'commit', unavailable)
        response = client.post('/auth/register', json={'email': 'teacher@example.test', 'password': 'correct teacher password'})
    assert response.status_code == 503
    assert 'do-not-expose' not in response.text and 'secret SQL' not in response.text
    assert response.headers['cache-control'] == 'no-store'


@pytest.mark.parametrize('invalid', ['nul\x00character', 'unpaired\ud800surrogate'])
def test_invalid_unicode_is_rejected_before_hashing_or_database(client, invalid):
    client, _ = client
    # Use escaped JSON because an HTTP client's own UTF-8 encoder rightly rejects surrogates.
    import json
    for path, body in [('/auth/register', {'email': 'unicode@example.test', 'password': invalid}),
                       ('/auth/login', {'identifier': invalid, 'password': 'correct password'})]:
        response = client.post(path, content=json.dumps(body), headers={'Content-Type': 'application/json'})
        assert response.status_code == 422
        assert response.json()['detail'][0]['msg'].endswith('Text must not contain NUL or invalid Unicode characters')
