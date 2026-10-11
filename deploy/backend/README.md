# Release deployment and operations

The cloud target is one FastAPI instance on Render Free, Neon Postgres, and private Neon S3-compatible audio storage. Local Docker Compose still supports SQLite and local audio. Keep one API instance for the current submission-recovery lifecycle. The existing Dart/Supabase components are separate and are not needed to run this service.

## Render backend, Vercel web, and mobile release

This configuration packages the current G1/G2 release. Later generative-AI milestones remain separate. A checked-in deployment configuration is not evidence of a live deployment or a signed mobile binary.

### Render

1. Create a Neon Free project with Postgres 18 and a **private** `vaachak-audio` bucket. The current provisioned project is `wild-surf-71001769`, production branch `br-shy-bonus-b4v1hayw`, AWS Ohio. Keep all credentials out of Git.
2. Create a Render Blueprint from `main` and `render.yaml`. It selects **Free**, Ohio, and no persistent disk. Set `DATABASE_URL` to Neon's pooled connection string with TLS. Supply the bucket's `AWS_ENDPOINT_URL_S3`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_REGION`. Object keys remain private; authenticated API routes authorize every download.
3. Set `GROQ_API_KEY` as a Render secret, and `VAACHAK_CORS_ORIGINS` to exact Vercel/custom HTTPS origins. The Blueprint generates a private `VAACHAK_TEACHER_INVITE` for approved instructor registration. Never put these secrets in the frontend.
4. Wait for `/api/ready` to return 200. Migrations run transactionally on startup with a Postgres advisory lock; a fresh database receives the schema equivalent to SQLite versions 1–7. Built-in curriculum is installed idempotently. **Existing local accounts and recordings are not imported automatically.**
5. Keep **one instance, one Uvicorn worker, `VAACHAK_RUN_WORKER=inline`**. Enqueuing a draft wakes the in-process runner; it does not continuously poll an idle Neon database. Jobs are durable, leased, and recovered after expiry. Sleeping/restarting Render can delay jobs; this free deployment is suitable for a project demonstration, not an always-on SLA.
6. The frontend allows 90 seconds for ordinary requests and 150 seconds for speech/AI, accommodating Render cold starts. Requests are not automatically replayed: mutation retries retain the application's submission identity rules.

Render Free can discard all local files and sleep after inactivity. Only temporary ffmpeg/ASR/playback files use its filesystem. The API retains current upload caps (8 MB attempts, 20 MB teacher recordings). Monitor Neon storage/compute and Groq quotas; free hosting does not mean unlimited provider calls.

For cloud backups, use **Neon Backup & Restore / branches or `pg_dump`**, and export the private bucket separately. SQLite backup/restore commands below apply only to local deployments; the CLI rejects SQLite backup against Postgres. Free-tier recovery windows are short: keep independent operator-controlled exports. `backend_admin.py cleanup` supports both local and remote audio; run it from a trusted operator environment with cloud secrets, because Render Free has no shell or scheduled jobs. Do not point local test runners at the hosted production database.

### Vercel

1. Import the repository, choose branch `main`, and set **Root Directory to `apps/vaachak`**, Node.js 22, and framework preset **Other**. The checked-in `vercel.json` selects `npm ci`, `npm run build:release:web`, and output directory `dist`.
2. Set `EXPO_PUBLIC_API_URL` to the actual Render HTTPS origin, without `/api`, in every Vercel environment you intend to build. Never put provider keys or the instructor invitation in Vercel or an `EXPO_PUBLIC_*` variable.
3. Deploy, add the assigned production origin to Render's CORS list, and redeploy the API. Add individual preview origins only when necessary; do not allow all `*.vercel.app` sites.
4. Verify sign-in, direct reload of a nested route, class creation/joining, feedback/history, and recording/playback on the HTTPS site. Requests, including audio uploads, go directly to Render. The SPA fallback handles route reloads.

Release builds reject missing, HTTP, local/test, or path-suffixed API origins. The API origin is compiled into the client: changing it requires rebuilding web and mobile artifacts. The CI fixture URL is for compilation checks only and must never be distributed.

### Android and iOS distribution

The app is linked to the EAS project `@patilrushikesh/vaachak`. Its public project ID is committed in `apps/vaachak/app.json`; signing credentials remain in EAS. After the backend is reachable, run from `apps/vaachak`:

```sh
npx eas-cli@latest login
npx eas-cli@latest env:create --environment production --name EXPO_PUBLIC_API_URL --value https://YOUR-ACTUAL-API.onrender.com --visibility plaintext
npx eas-cli@latest build --platform android --profile apk
```

The `apk` profile creates a signed APK for direct Android installation. Preserve its signing key for future upgrades. The `production` profile creates an Android AAB for the Play Store instead. EAS manages incrementing release build numbers remotely. The package/bundle identifier is `com.vaachak.learning`; confirm ownership before creating store records.

Choose the actual iOS distribution route before building:

```sh
# Ad hoc IPA: register the physical iPhones/iPads first.
npx eas-cli@latest device:create
npx eas-cli@latest build --platform ios --profile preview

# App Store / TestFlight binary; upload separately after building.
npx eas-cli@latest build --platform ios --profile production

# Simulator-only build, which does not install on physical iPhones.
npx eas-cli@latest build --platform ios --profile ios-simulator
```

Physical-device iOS distribution requires Apple signing access and a paid Apple Developer membership. An ad hoc IPA installs only on devices included in its provisioning profile; use TestFlight for broader testing. An arbitrary IPA file is not installable by every iPhone user. Expo Go and simulator checks do not certify a signed release binary.

| Configuration | Location | Purpose |
| --- | --- | --- |
| `GROQ_API_KEY` | Render secret | AI feedback, transcription, and drafting |
| `VAACHAK_TEACHER_INVITE` | Render secret | Approved instructor signup |
| `VAACHAK_CORS_ORIGINS` | Render environment | Exact allowed HTTPS web origins |
| `VAACHAK_DATA`, `VAACHAK_RUN_WORKER`, `PORT` | Render Blueprint | Persistent storage and process configuration |
| `EXPO_PUBLIC_API_URL` | Vercel and EAS production environments | Public API origin compiled into clients |
| Android keystore / Apple signing credentials | EAS / Apple account | Installable mobile distribution |

AI remains subject to provider availability and configured quotas; unlimited existing practice does not imply unlimited paid generation. Replace provider credentials previously pasted into chat with a fresh key in Render before public launch.

### Hosted acceptance and operations

After deployment, verify readiness, allowed/rejected browser origins, instructor invitation, learner signup, all six task formats, real speech upload/transcription/playback, teacher review/publication, knowledge citations, unscored retries, account export/erasure, and password recovery. Redeploy and verify an account and recording survive. Run Postman smoke tests only against disposable staging records. Install signed Android/iOS builds and repeat microphone, session restoration, navigation, and network recovery checks.

Keep backups outside the application disk and rehearse restoration before storing real learner work. Render Cron jobs cannot mount this service's disk. Run the existing backup/retention commands inside the service using an operator-controlled schedule or authenticated shell/SSH, with an external backup destination. This repository does not provision that external destination or scheduler; an explicit operator schedule is needed until configured.

References: [Render Blueprint](https://render.com/docs/blueprint-spec), [persistent disks](https://render.com/docs/disks), [Expo web deployment](https://docs.expo.dev/guides/publishing-websites/), [Expo internal distribution](https://docs.expo.dev/build/internal-distribution/).

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

For rollback, prefer a code version compatible with the migrated schema. If that is impossible, stop the service and restore a pre-upgrade snapshot, explicitly accounting for later writes. Do not automatically downgrade tables. Current migration version: 7; migrations are additive and legacy evidence is marked unknown.

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
docker build -f deploy/backend/Dockerfile -t vaachak-backend:release .
python tools/release_container_check.py --report docs/verification/release-container.json
```

The load check creates an isolated server/database and uses deterministic text grading; its latency is not live-AI latency. The Postman collection is destructive only to its own synthetic test records but should run against a dedicated test environment. It covers successful operations, authorization checks, archive/delete guards and an intentionally invalid password-reset token. Pytest exercises a valid operator reset separately.

Opt-in live ASR verification requires a running configured backend and an explicitly supplied test recording:

```sh
python tools/backend_live_check.py --audio /path/to/synthetic-speaking.wav
```

This creates and erases a synthetic learner. Synthetic speech verifies integration, not human accent robustness. See `docs/BACKEND_IMPLEMENTATION_STATUS.md` for measured evidence and remaining external release gates.
