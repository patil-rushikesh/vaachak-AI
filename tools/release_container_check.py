#!/usr/bin/env python3
"""Exercise the release image on a disposable volume; never uses production data."""

import argparse
import json
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request
import uuid


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True).strip()


def run(image):
    name = "vaachak-release-test-" + uuid.uuid4().hex[:10]
    volume = name + "-data"
    origin = "https://release-check.vercel.app"
    invite = "synthetic-release-invitation-482"
    checks = {}
    base = ""

    def request(path, method="GET", body=None, token=None, request_origin=origin):
        headers = {"Origin": request_origin, "Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(base + path, method=method, headers=headers,
            data=json.dumps(body).encode() if body is not None else None)
        try:
            response = urllib.request.urlopen(req, timeout=10)
        except urllib.error.HTTPError as error:
            response = error
        return response.status, response.headers, json.load(response)

    def start():
        nonlocal base
        docker("run", "-d", "--name", name, "-p", "127.0.0.1::10000",
            "-v", volume + ":/data", "-e", "PORT=10000",
            "-e", "VAACHAK_ENV=production", "-e", "VAACHAK_RUN_WORKER=1",
            "-e", "VAACHAK_CORS_ORIGINS=" + origin,
            "-e", "VAACHAK_TEACHER_INVITE=" + invite,
            "-e", "GROQ_API_KEY=", "-e", "VAACHAK_GROQ_KEY=", image)
        base = "http://" + docker("port", name, "10000/tcp")
        for _ in range(60):
            try:
                status, _, data = request("/api/ready")
                if status == 200 and data["ok"]:
                    return data
            except (OSError, ValueError):
                pass
            time.sleep(0.5)
        raise AssertionError("Release container did not become ready")

    docker("volume", "create", volume)
    try:
        # Simulate a fresh host disk mounted over the image-owned directory.
        docker("run", "--rm", "-v", volume + ":/data", "--entrypoint", "python", image,
            "-c", "import os; os.chown('/data',0,0); os.chmod('/data',0o755)")
        ready = start()
        checks["ready_on_dynamic_port"] = ready["ok"]
        checks["schema_version"] = ready["schema_version"]
        status = docker("exec", name, "cat", "/proc/1/status")
        assert "Uid:\t10001\t10001\t10001\t10001" in status
        checks["root_owned_disk_initialized_and_privileges_dropped"] = True
        # Inspect PID 1, because docker exec does not inherit entrypoint env changes.
        docker("exec", "--user", "10001", name, "python", "-c",
            "from pathlib import Path; env=Path('/proc/1/environ').read_bytes().split(b'\\0'); assert b'HOME=/home/vaachak' in env")
        checks["non_root_home_supports_postgres_tls"] = True
        body = {"name": "Release teacher", "email": "release-check@example.invalid",
            "password": "Synthetic-Release-482!", "role": "teacher"}
        assert request("/api/auth/register", "POST", body)[0] == 403
        body["teacher_invite"] = invite
        code, headers, registered = request("/api/auth/register", "POST", body)
        assert code == 200, registered
        assert headers["access-control-allow-origin"] == origin
        token = registered["token"]
        checks["production_instructor_invitation"] = True
        code, _, preferences = request("/api/me/preferences", "PATCH", {
            "timezone": "Asia/Calcutta", "research_consent": False}, token)
        assert code == 200, preferences
        checks["device_timezone_alias_supported_in_slim_image"] = True
        code, headers, error = request("/api/me")
        assert code == 401
        assert headers["x-request-id"] == error["error"]["request_id"]
        assert headers["access-control-allow-origin"] == origin
        assert request("/api/me", token=token)[0] == 200
        assert "access-control-allow-origin" not in request("/api/health", request_origin="https://untrusted.vercel.app")[1]
        checks["cors_authentication_and_structured_errors"] = True
        job_id = str(uuid.uuid4())
        code, _, job = request("/api/ai/jobs", "POST", {
            "client_uuid": job_id, "topic": "Everyday greetings", "count": 1,
            "level": "A1", "kinds": ["read"]}, token)
        assert code == 200, job
        for _ in range(30):
            _, _, job = request("/api/ai/jobs/" + job_id, token=token)
            if job["status"] == "failed":
                break
            time.sleep(0.5)
        assert job["status"] == "failed" and job["error_code"] == "generation_unavailable", job
        checks["colocated_worker_consumes_job_and_handles_missing_provider"] = True
        docker("exec", "--user", "10001", name, "python", "-c",
            "from pathlib import Path; Path('/data/audio/release-marker').write_text('persistent')")
        docker("stop", "-t", "30", name)
        assert docker("inspect", "-f", "{{.State.ExitCode}}", name) == "0"
        checks["graceful_platform_shutdown"] = True
        docker("rm", name)
        start()
        assert request("/api/me", token=token)[0] == 200
        assert request("/api/ai/jobs/" + job_id, token=token)[2]["status"] == "failed"
        assert docker("exec", name, "cat", "/data/audio/release-marker") == "persistent"
        checks["database_sessions_jobs_and_audio_survive_replacement"] = True
        logs = docker("logs", name)
        events = [json.loads(line) for line in logs.splitlines() if line.startswith("{")]
        worker = next(e["pid"] for e in events if e.get("event") == "service_child_started" and e["child"] == "worker")
        docker("exec", name, "python", "-c", f"import os,signal; os.kill({worker},signal.SIGKILL)")
        for _ in range(60):
            if docker("inspect", "-f", "{{.State.Running}}", name) == "false":
                break
            time.sleep(0.5)
        assert docker("inspect", "-f", "{{.State.ExitCode}}", name) == "1"
        checks["worker_failure_stops_service_for_platform_restart"] = True
        return checks
    finally:
        subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["docker", "volume", "rm", volume], stdout=subprocess.DEVNULL, check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", default="vaachak-backend:release")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    report = run(args.image)
    serialized = json.dumps(report, indent=2) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(serialized)
    print(serialized)
