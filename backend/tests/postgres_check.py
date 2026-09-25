"""Run the API suite in an isolated PostgreSQL Docker container, then remove it."""
import json
import os
import secrets
import subprocess
import sys
import time


def main():
    name = "vaachak-test-" + secrets.token_hex(6)
    password = secrets.token_urlsafe(24)
    container_env = {**os.environ, "POSTGRES_PASSWORD": password}
    started = False
    try:
        subprocess.run([
            "docker", "run", "--detach", "--rm", "--name", name,
            "-e", "POSTGRES_PASSWORD", "-e", "POSTGRES_DB=vaachak_test",
            "-p", "127.0.0.1::5432", "postgres:16-alpine",
        ], env=container_env, check=True, stdout=subprocess.DEVNULL)
        started = True
        for _ in range(40):
            result = subprocess.run(["docker", "exec", name, "pg_isready", "-U", "postgres"], capture_output=True)
            if result.returncode == 0:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("Temporary PostgreSQL did not become ready")
        info = json.loads(subprocess.check_output(["docker", "inspect", name]))[0]
        port = info["NetworkSettings"]["Ports"]["5432/tcp"][0]["HostPort"]
        env = {**os.environ, "TEST_DATABASE_URL": f"postgresql+psycopg://postgres:{password}@127.0.0.1:{port}/vaachak_test"}
        return subprocess.run([sys.executable, "-m", "pytest", "-q", "--tb=short"], env=env).returncode
    finally:
        if started:
            subprocess.run(["docker", "rm", "--force", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    raise SystemExit(main())
