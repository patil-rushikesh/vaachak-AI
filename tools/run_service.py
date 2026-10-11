#!/usr/bin/env python3
"""Single-instance API and optional worker on the same persistent Render disk."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def event(name, **fields):
    print(json.dumps({"event": name, **fields}), flush=True)


def supervise(commands, grace_seconds=25):
    """Stop the whole service if a child exits; let the platform restart it."""
    children = {}
    stopping = False

    def stop(signum, _frame):
        nonlocal stopping
        stopping = True
        event("service_stopping", signal=signum)

    previous = {s: signal.signal(s, stop) for s in (signal.SIGTERM, signal.SIGINT)}
    result = 0
    try:
        for name, command in commands.items():
            children[name] = subprocess.Popen(command, start_new_session=True)
            event("service_child_started", child=name, pid=children[name].pid)
        while not stopping:
            for name, process in children.items():
                code = process.poll()
                if code is not None:
                    event("service_child_exited", child=name, exit_code=code)
                    result = 1  # Even an unexpected successful exit loses a service.
                    stopping = True
                    break
            if not stopping:
                time.sleep(0.2)
    finally:
        for process in children.values():
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        deadline = time.monotonic() + grace_seconds
        for process in children.values():
            try:
                process.wait(timeout=max(0.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        for signum, handler in previous.items():
            signal.signal(signum, handler)
    return result


def main():
    sys.path.insert(0, str(ROOT / "classroom_web/server"))
    import ai
    import db
    import deployment

    ai.load_env_file()
    production = os.getenv("VAACHAK_ENV") == "production"
    deployment.allowed_origins(os.getenv("VAACHAK_CORS_ORIGINS", ""), production)
    if production and len(os.getenv("VAACHAK_TEACHER_INVITE", "")) < 24:
        raise ValueError("Set VAACHAK_TEACHER_INVITE to a random secret of at least 24 characters")
    port = int(os.getenv("PORT", "8000"))
    if not 1 <= port <= 65535:
        raise ValueError("PORT must be between 1 and 65535")
    # Complete migrations before either process can open the database.
    db.init()
    commands = {
        "api": [sys.executable, "-m", "uvicorn", "main:app", "--app-dir",
                str(ROOT / "classroom_web/server"), "--host", "0.0.0.0",
                "--port", str(port), "--workers", "1", "--no-access-log",
                "--no-proxy-headers"],
    }
    if os.getenv("VAACHAK_RUN_WORKER") == "1":
        commands["worker"] = [sys.executable, str(ROOT / "tools/learning_worker.py")]
    return supervise(commands)


if __name__ == "__main__":
    sys.exit(main())
