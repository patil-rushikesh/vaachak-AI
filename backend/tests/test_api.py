import io
import os
import subprocess
import wave

import numpy as np
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete, select

from vaachak_backend.api import create_app
from vaachak_backend.db import Base, LoginSession, Recording, Teacher
from vaachak_backend.security import hash_password


def wav_bytes(seconds=2, silent=False, rate=22050, channels=1):
    times = np.arange(int(seconds * rate)) / rate
    samples = 0.2 * np.sin(2 * np.pi * 220 * times)
    samples[(times >= 0.7) & (times < 1.1)] = 0
    if silent:
        samples[:] = 0
    samples = np.repeat(samples[:, None], channels, axis=1)
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as audio:
        audio.setnchannels(channels)
        audio.setsampwidth(2)
        audio.setframerate(rate)
        audio.writeframes((samples * 32767).astype("<i2").tobytes())
    return buffer.getvalue()


@pytest.fixture
def setup(tmp_path):
    # TEST_DATABASE_URL must point to an isolated disposable database: tables are cleared.
    app = create_app(database_url=os.getenv("TEST_DATABASE_URL") or f"sqlite:///{tmp_path / 'test.sqlite3'}", data_dir=tmp_path, analysis_worker=False)
    with app.state.session_factory() as session:
        for table in reversed(Base.metadata.sorted_tables):
            session.execute(delete(table))
        session.add_all([
            Teacher(email="one@example.test", password_hash=hash_password("example-password-1")),
            Teacher(email="two@example.test", password_hash=hash_password("example-password-2")),
        ])
        session.commit()
    with TestClient(app) as client:
        token = client.post("/auth/login", json={"email": "one@example.test", "password": "example-password-1"}).json()["access_token"]
        headers = {"Authorization": f"Bearer {token}"}
        yield app, client, headers, tmp_path


def create_problem(client, headers):
    response = client.post("/problems", headers=headers, json={
        "title": "My house", "expected_text": "Okay, this is my house.",
        "teaching_notes": "Brief pause after Okay. Emphasize house.",
    })
    assert response.status_code == 201, response.text
    return response.json()["id"]


def test_reference_lifecycle_and_owner_isolation(setup):
    app, client, headers, directory = setup
    problem = create_problem(client, headers)
    source = wav_bytes(channels=2)
    response = client.post(f"/problems/{problem}/recordings", headers=headers,
                           files={"file": ("../../outside.wav", source, "audio/wav")})
    assert response.status_code == 201, response.text
    recording = response.json()
    assert recording["duration_seconds"] == pytest.approx(2, abs=0.001)
    assert recording["measurements"]["pronunciation_score"] is None
    assert recording["measurements"]["preservation"]["pitch_analysis"] == "yin-cmndf-v1"
    assert recording["measurements"]["pitch"]["score"] is None
    assert recording["measurements"]["pitch"]["summary"]["median_f0_hz"] == pytest.approx(220, abs=3)
    assert int(recording["measurements"]["source_media"]["sample_rate"]) == 22050
    assert recording["measurements"]["source_media"]["channels"] == 2
    assert any(gap["end"] - gap["start"] >= 0.3 for gap in recording["measurements"]["low_energy_intervals"])
    assert (directory / "recordings" / recording["id"] / "original").read_bytes() == source
    playback = client.get(recording["playback_url"], headers=headers)
    assert playback.status_code == 200
    with wave.open(io.BytesIO(playback.content)) as audio:
        assert (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) == (16000, 1, 2)
    assert client.get(f"/recordings/{recording['id']}/analyses", headers=headers).json() == []
    assert len(client.get(f"/problems/{problem}/recordings", headers=headers).json()) == 1
    other_token = client.post("/auth/login", json={"email": "two@example.test", "password": "example-password-2"}).json()["access_token"]
    other = {"Authorization": f"Bearer {other_token}"}
    assert client.get("/problems", headers=other).json() == []
    for path in [f"/problems/{problem}", f"/problems/{problem}/recordings",
                 recording["playback_url"], f"/recordings/{recording['id']}/analyses"]:
        assert client.get(path, headers=other).status_code == 404
    assert client.post(f"/problems/{problem}/recordings", headers=other,
                       files={"file": ("audio.wav", source)}).status_code == 404
    assert client.get(recording["playback_url"]).status_code == 401
    # Reopening the app preserves tokens, problem metadata and audio.
    second = create_app(database_url=os.getenv("TEST_DATABASE_URL") or f"sqlite:///{directory / 'test.sqlite3'}", data_dir=directory, analysis_worker=False)
    with TestClient(second) as reopened:
        assert reopened.get(f"/problems/{problem}", headers=headers).json()["teaching_notes"].startswith("Brief pause")
        assert reopened.get(recording["playback_url"], headers=headers).content == playback.content


@pytest.mark.parametrize("source", [b"", b"not an audio file", wav_bytes(silent=True), wav_bytes(seconds=0.1), wav_bytes(seconds=121), wav_bytes()[:44144]],
                         ids=["empty", "invalid", "silent", "too-short", "too-long", "truncated-waveform"])
def test_rejected_audio_leaves_no_record_or_file(setup, source):
    app, client, headers, directory = setup
    problem = create_problem(client, headers)
    response = client.post(f"/problems/{problem}/recordings", headers=headers,
                           files={"file": ("audio.wav", source)})
    assert response.status_code == 422, response.text
    with app.state.session_factory() as session:
        assert session.scalar(select(Recording)) is None
    assert list((directory / "recordings").iterdir()) == []


def test_upload_size_limit(setup, monkeypatch):
    _, client, headers, directory = setup
    monkeypatch.setattr("vaachak_backend.api.MAX_BYTES", 100)
    problem = create_problem(client, headers)
    assert client.post(f"/problems/{problem}/recordings", headers=headers,
                       files={"file": ("audio.wav", wav_bytes())}).status_code == 413
    assert list((directory / "recordings").iterdir()) == []


def test_auth_expiry_logout_and_validation(setup):
    app, client, headers, _ = setup
    assert client.get("/problems").status_code == 401
    assert client.post("/problems", headers=headers, json={"title": "  ", "expected_text": "x"}).status_code == 422
    assert client.post("/problems", headers=headers, json={"title": "x", "expected_text": "  "}).status_code == 422
    assert client.get("/problems?limit=1000", headers=headers).status_code == 422
    assert client.get("/problems/not-a-uuid", headers=headers).status_code == 422
    assert client.post("/auth/logout", headers=headers).status_code == 204
    assert client.get("/problems", headers=headers).status_code == 401
    response = client.post("/auth/login", json={"email": "one@example.test", "password": "example-password-1"})
    with app.state.session_factory() as session:
        login = session.scalar(select(LoginSession))
        login.expires_at = 0
        session.commit()
    assert client.get("/problems", headers={"Authorization": f"Bearer {response.json()['access_token']}"}).status_code == 401


def test_login_throttle(setup):
    _, client, _, _ = setup
    for _ in range(5):
        assert client.post("/auth/login", json={"email": "unknown@example.test", "password": "wrong"}).status_code == 401
    assert client.post("/auth/login", json={"email": "unknown@example.test", "password": "wrong"}).status_code == 429


def test_browser_webm_audio(setup):
    _, client, headers, directory = setup
    source = directory / "browser-source.wav"
    source.write_bytes(wav_bytes())
    webm = directory / "browser.webm"
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(source),
                    "-c:a", "libopus", str(webm)], check=True, timeout=30)
    problem = create_problem(client, headers)
    response = client.post(f"/problems/{problem}/recordings", headers=headers,
                           files={"file": ("recording.webm", webm.read_bytes(), "audio/webm")})
    assert response.status_code == 201, response.text
    assert response.json()["duration_seconds"] == pytest.approx(2, abs=0.02)


def test_database_failure_cleans_uploaded_files(setup, monkeypatch):
    from sqlalchemy.orm import Session
    app, client, headers, directory = setup
    problem = create_problem(client, headers)

    def fail_commit(self):
        raise RuntimeError("Simulated storage failure")

    with monkeypatch.context() as patch:
        patch.setattr(Session, "commit", fail_commit)
        response = client.post(f"/problems/{problem}/recordings", headers=headers,
                               files={"file": ("audio.wav", wav_bytes())})
    assert response.status_code == 503
    assert list((directory / "recordings").iterdir()) == []
    with app.state.session_factory() as session:
        assert session.scalar(select(Recording)) is None


def test_full_disk_during_audio_processing_cleans_files_and_reports_capacity(setup, monkeypatch):
    import errno
    app, client, headers, directory = setup
    problem = create_problem(client, headers)

    def full_disk(*args):
        raise OSError(errno.ENOSPC, 'No space left on private path')

    monkeypatch.setattr('vaachak_backend.api.normalize', full_disk)
    response = client.post(f'/problems/{problem}/recordings', headers=headers,
                           files={'file': ('audio.wav', wav_bytes())})
    assert response.status_code == 507
    assert 'private path' not in response.text
    assert list((directory / 'recordings').iterdir()) == []
    with app.state.session_factory() as session:
        assert session.scalar(select(Recording)) is None
