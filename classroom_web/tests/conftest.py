import os
import sys
import tempfile
from pathlib import Path

if os.getenv("VAACHAK_TEST_DATABASE_URL"):
    os.environ["DATABASE_URL"] = os.environ["VAACHAK_TEST_DATABASE_URL"]
else:
    os.environ.pop("DATABASE_URL", None)

os.environ["VAACHAK_DATA"] = tempfile.mkdtemp(prefix="vaachak_test_")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "server"))

import pytest
from fastapi.testclient import TestClient

import db
import main


@pytest.fixture(autouse=True)
def isolate_local_ai_configuration(monkeypatch):
    # Keep regression tests deterministic even when vaachak.env enables live AI.
    # Empty values also prevent load_env_file from importing developer credentials.
    monkeypatch.setenv("GROQ_API_KEY", "")
    monkeypatch.setenv("VAACHAK_GROQ_KEY", "")
    monkeypatch.setenv("VAACHAK_WHISPER_MODEL", "")


@pytest.fixture(autouse=True)
def isolated_postgres_database():
    url = os.getenv("VAACHAK_TEST_DATABASE_URL")
    if url:
        from urllib.parse import urlsplit
        parsed = urlsplit(url)
        if parsed.hostname not in ("127.0.0.1", "localhost") or not parsed.path.endswith("_test"):
            pytest.fail("Database reset is restricted to a local disposable *_test database")
        import psycopg
        with psycopg.connect(url, autocommit=True) as conn:
            conn.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public")


@pytest.fixture()
def client():
    for f in db.data_dir().glob("classroom.db*"):
        f.unlink()
    main._failures.clear()
    with TestClient(main.app) as c:
        yield c


def make_user(client, role, name, email):
    r = client.post(
        "/api/auth/register",
        json={"name": name, "email": email, "password": "password-123", "role": role},
    )
    assert r.status_code == 200, r.text
    return {"Authorization": "Bearer " + r.json()["token"]}


@pytest.fixture()
def world(client):
    t = make_user(client, "teacher", "Ms Rao", "rao@t.test")
    a = make_user(client, "student", "Asha", "asha@s.test")
    b = make_user(client, "student", "Bala", "bala@s.test")
    cls = client.post(
        "/api/classes",
        headers=t,
        json={
            "name": "Std 5 A",
            "standard": "5",
            "section": "A",
            "pincode": "411001",
            "state": "Maharashtra",
            "district": "Pune",
            "language": "en",
            "academic_year": "2026-27",
        },
    ).json()
    for h in (a, b):
        assert (
            client.post(
                "/api/classes/join", headers=h, json={"code": cls["code"]}
            ).status_code
            == 200
        )
    return {"t": t, "a": a, "b": b, "cls": cls}


@pytest.fixture(scope="session", autouse=True)
def endpoint_coverage_report():
    """Persist method/route/status evidence from actual requests in this test session."""
    import json
    import logging
    from collections import defaultdict

    records = defaultdict(lambda: defaultdict(int))

    class Coverage(logging.Handler):
        def emit(self, record):
            try:
                event = json.loads(record.getMessage())
                if event.get("event") == "http_request":
                    records[(event["method"], event["route"])][
                        str(event["status"])
                    ] += 1
            except (ValueError, KeyError):
                pass

    handler = Coverage()
    logger = logging.getLogger("vaachak.requests")
    logger.addHandler(handler)
    yield
    logger.removeHandler(handler)
    operations = []
    for path, methods in main.app.openapi()["paths"].items():
        for method in methods:
            if method in ("get", "post", "put", "patch", "delete"):
                statuses = dict(records.get((method.upper(), path), {}))
                operations.append(
                    {
                        "method": method.upper(),
                        "path": path,
                        "statuses": statuses,
                        "covered": bool(statuses),
                        "successful_response_tested": any(
                            int(s) < 300 for s in statuses
                        ),
                    }
                )
    root = Path(__file__).resolve().parents[2]
    target = root / "docs/verification" / ("backend-endpoint-coverage-postgres.json" if os.getenv("VAACHAK_TEST_DATABASE_URL") else "backend-endpoint-coverage.json")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps(
            {
                "operations": len(operations),
                "covered": sum(o["covered"] for o in operations),
                "successful": sum(o["successful_response_tested"] for o in operations),
                "items": operations,
            },
            indent=2,
        )
        + "\n"
    )
