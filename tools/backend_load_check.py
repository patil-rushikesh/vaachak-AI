#!/usr/bin/env python3
"""Isolated HTTP load/restart verification. Never uses developer credentials or data."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error

ROOT = Path(__file__).resolve().parents[1]


def request(base, path, token=None, data=None):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(
        base + path,
        body,
        headers={
            "Content-Type": "application/json",
            **({"Authorization": "Bearer " + token} if token else {}),
        },
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.load(r), (time.monotonic() - started) * 1000
    except urllib.error.HTTPError as e:
        return e.code, {}, (time.monotonic() - started) * 1000


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--seconds", type=int, default=900)
    p.add_argument("--users", type=int, default=20)
    p.add_argument("--output", default="docs/verification/backend-load.json")
    args = p.parse_args()
    folder = Path(tempfile.mkdtemp(prefix="vaachak_load_"))
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    env = {
        **os.environ,
        "PYTHONPATH": str(ROOT / "classroom_web/server"),
        "VAACHAK_DATA": str(folder / "data"),
        "GROQ_API_KEY": "",
        "VAACHAK_GROQ_KEY": "",
        "VAACHAK_WHISPER_MODEL": "",
        "VAACHAK_ENV": "test",
    }
    logfile = (folder / "requests.jsonl").open("w")
    cmd = [
        sys.executable,
        "-m",
        "uvicorn",
        "main:app",
        "--host",
        "127.0.0.1",
        "--port",
        str(port),
        "--no-access-log",
        "--log-level",
        "warning",
    ]
    server = subprocess.Popen(cmd, cwd=ROOT, env=env, stdout=logfile, stderr=logfile)
    base = f"http://127.0.0.1:{port}"
    try:
        for _ in range(100):
            try:
                if request(base, "/api/ready")[0] == 200:
                    break
            except OSError:
                time.sleep(0.1)
        tokens = []
        for i in range(args.users):
            status, result, _ = request(
                base,
                "/api/auth/register",
                data={
                    "name": f"Load {i}",
                    "email": f"load{i}@example.test",
                    "role": "learner",
                    "password": "load-test-password",
                },
            )
            assert status == 200, (status, result)
            tokens.append(result["token"])
        until = time.monotonic() + args.seconds

        def worker(token):
            reads = []
            writes = []
            statuses = {}
            i = 0
            while time.monotonic() < until:
                start = time.monotonic()
                if i % 5 == 0:
                    from urllib.parse import urlencode

                    payload = urlencode(
                        {
                            "set_id": "en-present-agreement",
                            "item_index": 0,
                            "transcript": "She goes to school.",
                            "client_uuid": f"load-{tokens.index(token)}-{i:08d}",
                        }
                    ).encode()
                    req = urllib.request.Request(
                        base + "/api/attempts",
                        payload,
                        headers={
                            "Content-Type": "application/x-www-form-urlencoded",
                            "Authorization": "Bearer " + token,
                        },
                    )
                    try:
                        with urllib.request.urlopen(req, timeout=30) as r:
                            status = r.status
                            r.read()
                    except urllib.error.HTTPError as e:
                        status = e.code
                    writes.append((time.monotonic() - start) * 1000)
                else:
                    status, _, elapsed = request(
                        base,
                        [
                            "/api/me/stats",
                            "/api/catalog",
                            "/api/me/attempts",
                            "/api/me/review",
                        ][i % 4],
                        token,
                    )
                    reads.append(elapsed)
                statuses[status] = statuses.get(status, 0) + 1
                i += 1
                time.sleep(max(0, 1 - (time.monotonic() - start)))
            return reads, writes, statuses

        with ThreadPoolExecutor(args.users) as pool:
            results = list(pool.map(worker, tokens))
        reads = []
        writes = []
        statuses = {}
        for r, w, counts in results:
            reads += r
            writes += w
            for code, n in counts.items():
                statuses[code] = statuses.get(code, 0) + n
        before = request(base, "/api/me/stats", tokens[0])[1]["attempts"]
        server.terminate()
        server.wait(timeout=15)
        server = subprocess.Popen(
            cmd, cwd=ROOT, env=env, stdout=logfile, stderr=logfile
        )
        for _ in range(100):
            try:
                if request(base, "/api/ready")[0] == 200:
                    break
            except OSError:
                time.sleep(0.1)
        after = request(base, "/api/me/stats", tokens[0])[1]["attempts"]

        def metrics(values):
            values = sorted(values)
            return {
                "requests": len(values),
                "p50_ms": round(statistics.median(values), 2),
                "p95_ms": round(
                    values[min(len(values) - 1, int(len(values) * 0.95))], 2
                ),
                "max_ms": round(max(values), 2),
            }

        total = sum(statuses.values())
        success = statuses.get(200, 0) / total
        report = {
            "duration_seconds": args.seconds,
            "concurrent_users": args.users,
            "workload": "80% reads, 20% typed deterministic-rules attempts; no provider calls",
            "status_counts": statuses,
            "success_fraction": success,
            "reads": metrics(reads),
            "writes": metrics(writes),
            "restart_preserved_attempts": before == after,
            "first_user_attempts": after,
            "request_log": str(folder / "requests.jsonl"),
            "passed": success >= 0.99
            and metrics(reads)["p95_ms"] < 1000
            and before == after,
        }
        target = ROOT / args.output
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
        if not report["passed"]:
            sys.exit(1)
    finally:
        server.terminate()
        server.wait(timeout=15)
        logfile.close()


if __name__ == "__main__":
    main()
