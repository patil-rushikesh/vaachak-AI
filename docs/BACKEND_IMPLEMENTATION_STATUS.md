# Current backend implementation and verification

Source reconciled **15 October 2026**, baseline `10d27c6`. Scope: the FastAPI service used by the Expo application. See [application status](IMPLEMENTATION_STATUS.md) and [architecture](ARCHITECTURE.md) for frontend and retained-library boundaries.

## Implemented service

| Area | Delivery |
| --- | --- |
| Contract and integrity | 100 OpenAPI operations; typed response/error contracts; UUID submission reservations, task snapshots/revisions, retry linkage and input/transcript/model/rubric provenance |
| Practice | All six exercise kinds; catalog, assignments, course enrolment/completion, preferences, personal sessions, drafts, public downloads and four scripted conversation scenarios |
| Feedback | Groq transcription and coaching, deterministic grading/fallback, transcript preview/confirmation, disputes, explicit unscored results excluded from scored progress |
| Knowledge | Versioned starter installation; owned note create/edit/review/publish/withdraw; private/public retrieval boundaries; versioned source citations |
| Review and teaching | Skill-specific delayed-success evidence; immediate retries excluded from retention advancement; reasons/evidence IDs; snooze/resolve/reopen; targeted follow-up and journals |
| Authoring jobs | Persistent generation queue, leases, bounded retry/recovery; review before publication; request-woken inline runner or separate local worker |
| Lifecycle | Archive discovery/restore and guarded hard deletion; password change/reset, export/erasure, instructor ownership transfer and retention tools |
| Runtime | SQLite locally or PostgreSQL through `DATABASE_URL`; local or private S3-compatible audio; schema 7; structured logs/request IDs, sanitized errors, CORS, quotas, media validation and non-root container |

Implementation: `classroom_web/server/{main,courses,growth,feedback,ai,knowledge,evidence,insights,operations,generation_jobs,inline_worker,db,postgres,audio_store,observability}.py`.

## Hosted deployment

Recorded 11 October 2026: Render Free API, Neon PostgreSQL/private audio and Vercel frontend passed the [hosted smoke run](verification/hosted-release-2026-10-11.json). A [signed Android APK](verification/android-share-release-2026-10-11.json) was subsequently tested against that API. These are completed engineering milestones, not pending provisioning tasks.

Keep one API instance/Uvicorn worker with `VAACHAK_RUN_WORKER=inline` on Render. Separate Compose worker configuration remains available locally. Startup submission reconciliation and the current operating topology are not a multi-instance scaling guarantee. Jobs survive in the database, but host sleep/restarts can delay execution.

## Verification evidence

- Both [SQLite](verification/backend-endpoint-coverage.json) and [PostgreSQL](verification/backend-endpoint-coverage-postgres.json) reports record 100/100 operations exercised successfully.
- The retained [backend JUnit](verification/backend-tests.xml) records 193 tests, zero failures/errors/skips. This is the artifact's own run, not a claim that every later command produced that count.
- [G1/G2 verification](verification/G1_G2_REVIEW_FIXES.md) records an earlier 181-test backend run plus frontend/native integration and live citation smoke.
- [Cloud container checks](verification/neon-release-container.json) cover schema 7, non-root execution, jobs and external persistence across replacement.
- [Original backend summary](verification/backend-release-summary.json) preserves the earlier 143-test/71-operation milestone and its deterministic load test (20 concurrent users, 17,900 requests). Its then-pending hosting and operation count are historical, and its latency is not live-AI performance.
- [Review-policy evaluation](verification/review-policy-evaluation.json) checks five synthetic invariants; it does not establish learner improvement or human-rated accuracy.

See the [verification index](VERIFICATION.md). No full backend test rerun or live hosting check is implied by this documentation reconciliation.

## Remaining operations and research acceptance

1. Configure and verify real SMTP/reset delivery if required. The deployed configuration last reported email recovery unavailable; operator-issued reset tokens already work.
2. Configure external backup/cleanup scheduling and protected cloud exports; rehearse restore and document erasure handling for backups. SQLite backup commands are not Neon/bucket backup commands.
3. Review content and evaluate real human speech, feedback usefulness and delayed learning outcomes. Scores are task-specific; transcript matching is not acoustic pronunciation scoring.
4. Complete provider capacity/cost, mixed live-AI workload, monitoring and broader signed-device acceptance before a larger rollout.
5. Complete remaining G3–G7 acceptance separately. Existing drafting/session primitives do not establish full adaptive generation or responsive AI dialogue.

Current FastAPI does not integrate the retained Dart BKT/event-sync runtime, Supabase RLS policies or verified-guardian workflow. Research consent alone does not provide child onboarding authorization or legal-compliance certification. Follow the [operator runbook](../deploy/backend/README.md).
