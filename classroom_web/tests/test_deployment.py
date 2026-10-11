"""Browser deployment and same-disk service lifecycle regression tests."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

import deployment
import observability

ORIGIN = "https://vaachak-test.vercel.app"
ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("origin", ["*", "https://*.vercel.app", "http://app.test", "https://app.test/api", "https://user:password@app.test", "https://app.test?key=value", "https://app.test#fragment", "https://app.test:wrong"])
def test_production_rejects_invalid_browser_origins(origin):
    with pytest.raises(ValueError):
        deployment.allowed_origins(origin, production=True)


def test_origin_list_trims_deduplicates_and_allows_local_development():
    assert deployment.allowed_origins(f" {ORIGIN}/, {ORIGIN}, ", True) == [ORIGIN]
    assert deployment.allowed_origins("http://localhost:8090") == ["http://localhost:8090"]
    assert deployment.allowed_origins("") == []


def test_cors_preflight_bearer_errors_and_request_ids(monkeypatch):
    monkeypatch.setenv("VAACHAK_CORS_ORIGINS", ORIGIN)
    monkeypatch.setenv("VAACHAK_ENV", "production")
    app = FastAPI()

    @app.get("/protected")
    def protected():
        raise HTTPException(401, "Sign in again")

    @app.get("/broken")
    def broken():
        raise RuntimeError("private internal error")

    observability.install(app)
    deployment.install(app)
    with TestClient(app) as client:
        preflight = client.options("/protected", headers={
            "Origin": ORIGIN, "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "authorization,content-type",
        })
        assert preflight.status_code == 200
        assert preflight.headers["access-control-allow-origin"] == ORIGIN
        assert "authorization" in preflight.headers["access-control-allow-headers"].lower()
        for route, status in [("/protected", 401), ("/broken", 500)]:
            response = client.get(route, headers={"Origin": ORIGIN})
            assert response.status_code == status
            assert response.headers["access-control-allow-origin"] == ORIGIN
            assert "X-Request-ID" in response.headers["access-control-expose-headers"]
            assert response.headers["x-request-id"] == response.json()["error"]["request_id"]
            assert "private internal error" not in response.text
        rejected = client.options("/protected", headers={
            "Origin": "https://untrusted.vercel.app",
            "Access-Control-Request-Method": "POST",
        })
        assert rejected.status_code == 400
        assert "access-control-allow-origin" not in rejected.headers


@pytest.mark.parametrize("crash", [True, False])
def test_supervisor_stops_sibling_on_failure_or_platform_shutdown(crash):
    # Real child processes verify signal forwarding and reaping, without a DB.
    sleeper = [sys.executable, "-c", "import time; time.sleep(30)"]
    commands = {"api": sleeper, "worker": sleeper}
    if crash:
        commands["worker"] = [sys.executable, "-c", "raise SystemExit(7)"]
    code = (
        f"import sys; sys.path.insert(0, {str(ROOT / 'tools')!r}); "
        f"from run_service import supervise; sys.exit(supervise({commands!r}, grace_seconds=1))"
    )
    process = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True)
    pids = []
    try:
        for _ in range(2):
            event = json.loads(process.stdout.readline())
            assert event["event"] == "service_child_started"
            pids.append(event["pid"])
        if not crash:
            process.send_signal(signal.SIGTERM)
        output, _ = process.communicate(timeout=10)
        assert process.returncode == (1 if crash else 0), output
        for pid in pids:
            with pytest.raises(ProcessLookupError):
                os.kill(pid, 0)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


def test_shutdown_signal_during_log_write_is_not_reentrant():
    # Deterministically reproduce SIGTERM arriving inside a startup log write.
    code = f"""
import sys, signal
sys.path.insert(0, {str(ROOT / 'tools')!r})
import run_service
original = run_service.event
writing = False
pids = []
def interrupted_event(name, **fields):
    global writing
    assert not writing, 'Signal handler re-entered logging'
    writing = True
    try:
        if name == 'service_child_started':
            pids.append(fields['pid'])
            signal.raise_signal(signal.SIGTERM)
        original(name, **fields)
    finally:
        writing = False
run_service.event = interrupted_event
result = run_service.supervise({{'api': [sys.executable, '-c', 'import time; time.sleep(30)']}}, grace_seconds=1)
import os
for pid in pids:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError('Child was not reaped')
sys.exit(result)
"""
    result = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert 'service_stopping' in result.stdout
