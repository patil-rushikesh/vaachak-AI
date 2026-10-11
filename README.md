# VaachakAI backend and libraries

The web and Android frontends have been removed. This repository retains the classroom API, reusable learning libraries, curriculum data, and Supabase infrastructure.

## Run the classroom API

Use Python 3.10 or newer.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r classroom_web/requirements-dev.txt -r tools/content_pipeline/requirements.txt
.venv/bin/python classroom_web/run.py
```

API documentation is at http://localhost:8000/api/docs. The root URL and `/static` do not serve an application. Optional `--seed` resets the local database and loads demo accounts; use only with disposable data. See [API contract](classroom_web/API_CONTRACT.md) and [server setup](classroom_web/README.md).

## Repository layout

- `classroom_web/server`: FastAPI, SQLite, AI feedback, courses, and classroom endpoints.
- `classroom_web/tests`: API and backend tests.
- `packages`: reusable Dart learning, content, storage, speech, explanation, sync, and pack libraries. Speech and explanation adapters still require Flutter dependencies.
- `content`: shared curriculum JSON used by libraries and content tooling.
- `infra/supabase`: migrations, configuration, and database tests.
- `tools`: content pipelines, library checks, and database verification utilities.
- `docs`: historical implementation and architecture records; app build and UI instructions in these records are no longer applicable.

## Checks

```sh
.venv/bin/python -m pytest classroom_web/tests -q
.venv/bin/python -m unittest discover -s tools/content_pipeline -v
.venv/bin/python tools/content_pipeline/pipeline.py validate content
FLUTTER=/path/to/flutter/bin/flutter .venv/bin/python tools/check.py
```

The complete check script uses Flutter 3.47.5 / Dart 3.13.4 for the retained libraries. Database checks run separately with `python3 tools/sql_check.py --bootstrap` against a configured test PostgreSQL instance.

## API reference and Postman

The [complete API list](postman/API_LIST.txt) contains all 71 classroom operations and their access requirements. Import [the Postman collection](postman/VaachakAI.postman_collection.json), set collection variables `base_url`, `email`, `password`, `name`, and `role`, then run Register or Login. The token and created resource IDs are saved automatically. Switch credentials and log in again when changing between teacher and learner actions. Select local files for multipart uploads. Requests are a reference, not an ordered bulk-run workflow.

[OpenAPI snapshot](postman/openapi.json). Regenerate these files with your backend Python environment: `python tools/export_postman.py`. Supabase deployment-generated APIs are separate from the classroom API.

### Run every classroom endpoint locally

Start the API with `.venv313/bin/python classroom_web/run.py` (or your configured Python environment). Import `postman/VaachakAI.local-tests.postman_collection.json` into Postman and run all requests in order with one iteration. The collection creates unique synthetic accounts, saves tokens/IDs, exercises all 71 operations, and checks role restrictions, history-deletion guards and lifecycle behavior. Run against a dedicated test database: it erases its synthetic learner and recording, while its instructor and authored content remain.

Command-line equivalent:

```sh
python tools/build_postman_smoke.py
npx --yes newman run postman/VaachakAI.local-tests.postman_collection.json --reporters cli,junit --reporter-junit-export postman/local-test-results.xml
```

Audio uploads use `postman/fixtures/silence.wav`, a synthetic fixture. Regenerating the test collection sets its absolute upload path for your checkout. The tests verify upload/download, not speech transcription. When no AI key is configured, the AI drafting test verifies the expected HTTP 503; live model generation remains unverified.

Postman desktop restricts file access to its working directory. The tested desktop requests use `/Users/admin/Postman/files/vaachak-api-tests/silence.wav`. Copy the synthetic fixture into your configured Postman working directory and regenerate with `python tools/build_postman_smoke.py --audio-file /absolute/path/to/silence.wav` before importing on another machine.

If you reselect upload files in Postman, enable the form-data Content-Type column and set each file field to `audio/wav`; Postman may otherwise choose an unsupported default MIME type.


## Enhanced backend deployment

The backend now includes durable submission identities, versioned evidence, explainable review,
instructor follow-up, account lifecycle operations, structured logs and uniform errors.
See [implementation and test status](docs/BACKEND_IMPLEMENTATION_STATUS.md) and the
[deployment/operator runbook](deploy/backend/README.md). The supported release runtime is
Python 3.13 with FFmpeg. Container/HTTPS configuration is in `deploy/backend`.

## React Native application

The new iOS, Android and web application lives in [`apps/vaachak`](apps/vaachak/README.md), with learner/teacher journeys, API integration, isolated dependencies, automated tests and a Dockerized web deployment. See its README for local startup, verification evidence and remaining release gates.
