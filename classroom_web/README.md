# Vaachak Classroom API

FastAPI backend with SQLite storage and local audio files. No browser or Android frontend is included.

Use Python 3.13 and install FFmpeg so `ffprobe` is available.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python run.py
```

Run these commands from `classroom_web`. API docs: http://localhost:8000/api/docs. Use `--host 0.0.0.0` to listen on the network and `--port` to change the port. `--seed` resets the database and creates demo data.

On Windows, `start.bat` creates an environment and opens the API docs. It seeds demo data on first run. `start-fresh.bat` deletes local data after confirmation.

Copy `vaachak.env.example` to `vaachak.env` and configure the desired AI provider. Without AI configuration, rule-based feedback remains available; clients must supply transcripts when server transcription is unavailable. Data defaults to `data/`; override with `VAACHAK_DATA`.

See [API contract](API_CONTRACT.md) for endpoints and authentication. Run tests with `python -m pytest tests -q`.

For container deployment, logs, backup/restore and account recovery, see [the operator runbook](../deploy/backend/README.md). [Verification results](../docs/verification/backend-release-summary.json) distinguish local checks from external deployment gates.
