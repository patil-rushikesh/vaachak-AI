# Backend deployment and operations

The supported target is one FastAPI instance on one Linux host, backed by persistent SQLite and private local audio storage. Do not horizontally replicate this deployment or place its database on a network filesystem. The existing Dart/Supabase components are separate and are not needed to run this service.

## Local development

Use Python 3.13 and install FFmpeg (`ffprobe` must be on PATH). Install `classroom_web/requirements-dev.txt`, then run `python classroom_web/run.py`. API documentation is at `/api/docs`, liveness/capability information at `/api/health`, and database/storage/media readiness at `/api/ready`. Readiness does not probe the paid AI provider on every request.

The server loads `classroom_web/vaachak.env` locally. Never commit that file. Docker does not copy it. A missing provider key allows deterministic text practice but does not provide speech transcription or AI drafting.

## Hosted deployment

1. Provision a Linux host with Docker Compose and persistent local storage. Point a DNS hostname to it and allow inbound 80/443. No host/domain has been provisioned by this change.
2. Copy `deploy/backend/.env.example` to `deploy/backend/.env`, restrict permissions to the operator, and configure `DOMAIN`, a long random `VAACHAK_TEACHER_INVITE`, and the server-side `GROQ_API_KEY`. Do not put these secrets into an APK or Postman export.
3. From this directory, run `docker compose up -d --build`. Caddy terminates HTTPS. The API port is not publicly published; only the proxy exposes ports. The data volume contains `/data/classroom.db` and `/data/audio`.
4. Verify `https://YOUR_DOMAIN/api/ready`, register a test instructor using `teacher_invite`, register a learner, join a class, submit practice and verify authenticated playback.
5. Connect the React Native release to this HTTPS base URL. A real phone cannot use the development computer's `localhost` address.

The provider model overrides are optional. Registration is instructor-invite controlled in production. Independent learner/student signup remains available with rate limiting; use host access restrictions if the cohort must be closed. This release uses authenticated operator-assisted recovery for the bounded cohort, not public self-service recovery email.

## Logs and error handling

`docker compose logs -f api` streams JSON request events. Docker rotates these logs at 10 MB, retaining five files. Each event records UTC time, request ID, HTTP method, route template, status, duration, response bytes, error code and exception type when relevant. Logs exclude request bodies, query strings, bearer tokens, raw transcripts and provider error bodies. API responses carry `X-Request-ID` so users can report a failure without exposing their answer.

All errors retain the legacy `detail` string and add:

```json
{"detail":"Task changed. Reload it before submitting.","error":{"code":"content_changed","message":"Task changed. Reload it before submitting.","request_id":"generated-request-id"}}
```

Validation errors include sanitized field locations/types, not submitted values. Unexpected exceptions return a generic 500. Database conflicts return 409; temporary storage failures return 503; quotas return 429 with `Retry-After`. Decode failures return 415, missing ASR configuration 503, and unusable provider transcription 502. A client must distinguish a rejected attempt from a successfully saved attempt with rules-based feedback.

Do not enable Uvicorn/proxy access logs containing full query URLs. Only trust proxy-forwarded addresses when the proxy/network boundary is explicitly configured. The built-in anonymous auth quota is conservative behind a shared proxy; tune `VAACHAK_AUTH_PER_MINUTE` to the cohort rather than trusting arbitrary forwarded headers.

## Submission recovery and content compatibility

Mobile clients should send a unique `client_uuid` for each logical attempt and the `item_version` returned with the task. Reuse the same UUID when reconciling the same input; an intentional learner retry gets a new UUID and `retry_of_attempt_id`.

- Same UUID and input after completion returns the existing attempt.
- Different input with the same UUID returns `idempotency_conflict`.
- A request already processing returns `submission_processing`. Poll `/api/me/submissions/{client_uuid}` with backoff.
- Failed submissions remain failed. Show the failure, then create a new logical submission only when the learner retries.
- Startup marks abandoned processing reservations `interrupted`; it does not silently award credit or duplicate provider work. The single-instance deployment is required for this behavior.
- Legacy clients without a UUID still work but cannot obtain retry deduplication guarantees.

Changed lessons increment their revision; old attempts retain their original task snapshot and no longer count toward replacement content. Ambiguous legacy attempts retain `legacy_unknown` provenance and are not automatically assigned trustworthy version metadata. Content with learner evidence cannot be hard-deleted through ordinary content APIs: archive it. Account erasure is a separate explicit action.

## Backup, restore and upgrade

Before deploying a new schema, run the old data backup before starting the new application. The backup command does not migrate the source database:

```sh
python tools/backend_admin.py backup /protected-backups/pre-upgrade
python tools/backend_admin.py migrate
```

Set `VAACHAK_DATA` to the correct data directory. Inside the container, the commands use `/app/tools/backend_admin.py` and `/data` automatically. Mount a protected external backup directory or copy completed backups outside the host. A backup left only inside a container is not durable.

The tool takes a SQLite writer lock while it snapshots through the backup API and copies audio. This briefly blocks writes. It writes a checksum manifest and restrictive file permissions. Schedule daily backups through the host's service scheduler; verify the destination and alert on a nonzero exit. Keep backups outside Git and restrict operator access.

Stop the application before restore. Restore to an empty directory:

```sh
python tools/backend_admin.py restore /protected-backups/pre-upgrade /new-empty-data
```

Verify the manifest, database integrity, record counts and representative authenticated audio playback before switching the service to the restored directory. The tool refuses a nonempty destination and verifies every restored manifest file. A backup is not an acceptable erasure workaround: define a retention period and reapply account-erasure records if restoring older backups containing erased users.

For rollback, prefer a code version compatible with the migrated schema. If that is impossible, stop the service and restore a pre-upgrade snapshot, explicitly accounting for later writes. Do not automatically downgrade tables. Current migration version: 1; migrations are additive and legacy evidence is marked unknown.

## Recovery, ownership and privacy

Authenticated host operators can issue a short-lived, single-use reset token after verifying the account holder through the institution's agreed process:

```sh
python tools/backend_admin.py issue-reset learner@example.edu --output /protected/reset-token.txt
```

The token is written to an exclusively created mode-0600 file, never printed. Deliver it privately to the verified owner, who submits it to `POST /api/auth/reset-password`. Delete the delivery file afterward. Reset/change password revokes all sessions. The CLI is not exposed as a remote admin endpoint.

`GET /api/me/export` provides owned account/content and attempt metadata; authenticated audio endpoints provide the actual files. `DELETE /api/me` requires the current password and removes learner records and associated audio. An instructor must transfer owned classes/courses first to avoid deleting other learners' evidence:

```sh
python tools/backend_admin.py transfer OLD_TEACHER_ID NEW_TEACHER_ID
```

Ownership transfer is an authenticated host operation and must be agreed with the receiving instructor. Research consent can be changed independently in preferences. Withdrawing it stops eligibility for future research exports; previously exported research data must be handled under the study's withdrawal procedure. The application does not automatically contact external researchers or erase their copies.

Run the retention job daily from the host scheduler:

```sh
python tools/backend_admin.py cleanup --audio-days 30
```

It removes attempt audio older than the configured retention period, expired sessions/reset tokens and orphan audio older than one day, while preserving task/result evidence. Teacher reference recordings persist until the instructor deletes them or the relevant account is erased. Explain the selected policy to participants; 30 days is a configurable project default, not a legal retention rule.

## Verification

```sh
python -m pytest classroom_web/tests -q --junitxml=docs/verification/backend-tests.xml
python tools/export_postman.py
python tools/build_postman_smoke.py
python tools/backend_load_check.py --seconds 900 --users 20
```

The load check creates an isolated server/database and uses deterministic text grading; its latency is not live-AI latency. The Postman collection is destructive only to its own synthetic test records but should run against a dedicated test environment. It covers successful operations, authorization checks, archive/delete guards and an intentionally invalid password-reset token. Pytest exercises a valid operator reset separately.

Opt-in live ASR verification requires a running configured backend and an explicitly supplied test recording:

```sh
python tools/backend_live_check.py --audio /path/to/synthetic-speaking.wav
```

This creates and erases a synthetic learner. Synthetic speech verifies integration, not human accent robustness. See `docs/BACKEND_IMPLEMENTATION_STATUS.md` for measured evidence and remaining external release gates.
