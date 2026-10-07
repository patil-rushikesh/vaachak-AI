import os
import sys
import tempfile
from pathlib import Path

os.environ["VAACHAK_DATA"] = tempfile.mkdtemp(prefix="vaachak_test_")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "server"))

import pytest
from fastapi.testclient import TestClient

import db
import main


@pytest.fixture()
def client():
    for f in db.data_dir().glob("classroom.db*"):
        f.unlink()
    main._failures.clear()
    with TestClient(main.app) as c:
        yield c


def make_user(client, role, name, email):
    r = client.post("/api/auth/register", json={"name": name, "email": email, "password": "password-123", "role": role})
    assert r.status_code == 200, r.text
    return {"Authorization": "Bearer " + r.json()["token"]}


@pytest.fixture()
def world(client):
    t = make_user(client, "teacher", "Ms Rao", "rao@t.test")
    a = make_user(client, "student", "Asha", "asha@s.test")
    b = make_user(client, "student", "Bala", "bala@s.test")
    cls = client.post("/api/classes", headers=t, json={"name": "Std 5 A", "standard": "5", "section": "A", "pincode": "411001", "state": "Maharashtra", "district": "Pune", "language": "en", "academic_year": "2026-27"}).json()
    for h in (a, b):
        assert client.post("/api/classes/join", headers=h, json={"code": cls["code"]}).status_code == 200
    return {"t": t, "a": a, "b": b, "cls": cls}
