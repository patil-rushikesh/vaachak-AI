# Vaachak Classroom API

FastAPI backend with SQLite storage and local audio files. The cross-platform Expo frontend is maintained separately in `../apps/vaachak`.

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

## Starter knowledge and upgrades

Database initialization installs the versioned starter curriculum idempotently. Existing users,
attempts, courses and teacher notes are preserved. To initialize/upgrade explicitly without demo
seeding, run `.venv313/bin/python tools/install_knowledge.py` from the repository root, using the
same `VAACHAK_DATA` as the API. Do not use `--seed` to upgrade an existing installation: it resets data.

Migration 7 quarantines previously auto-approved teacher notes as drafts; review and publish them
through the knowledge endpoints before public coaching uses them. Owner erasure removes all owned
notes, and orphaned private notes are excluded from retrieval. Unscored attempts remain available
in history with null scores but do not contribute to progress. The legacy numeric database column
is retained for compatibility; new progress readers must use the `scored_attempts` view.
