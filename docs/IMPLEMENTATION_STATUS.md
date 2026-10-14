# Current application implementation status

Reconciled against source on **15 October 2026**, baseline commit `10d27c6`. This document describes the current Expo/FastAPI application. Hosting and native acceptance below are recorded observations from **11 October 2026**, not new live-service checks on the documentation review date.

## What is delivered

The application supports English practice for students and independent learners, with instructor-managed courses, classrooms and feedback. The intended initial audience is adult college learners preparing for interviews, presentations, workplace and everyday communication; this remains a product hypothesis rather than completed audience research.

| Area | Implemented behavior | Source |
| --- | --- | --- |
| Frontend | One Expo SDK 57 / React Native / TypeScript application for Android, iOS and web; learner and instructor navigation | `apps/vaachak/src/app`, `apps/vaachak/src/features` |
| Accounts | Teacher, student and learner roles; email/password sessions; production teacher invitation; password change, reset-token handling, export and erasure | `classroom_web/server/main.py`, `operations.py`, `growth.py` |
| Learning | Six task kinds: choice, fill, listen, build, read and free response; courses, lessons, class assignments, history and retry comparison | `main.py`, `courses.py`; frontend `Player.tsx`, `Courses.tsx`, `Learning.tsx` |
| Personal practice | Four goals, starter/stretch preference, weekly goal, saved bounded sessions, task snapshots, drafts and another-session action | `growth.py`; frontend `Growth.tsx` |
| Review and teacher attention | Skill-specific evidence, delayed-success checks, due review, recommendation reasons, snooze/resolve and follow-up assignments | `insights.py`, `operations.py`, `evidence.py` |
| Speech and feedback | Server-side Groq transcription; transcript preview/correction; deterministic grading and AI-assisted coaching; provenance, uncertainty and unscored attempts | `ai.py`, `feedback.py`, `main.py`, `growth.py` |
| Teaching knowledge | Owner-scoped create/edit/review/publish/withdraw; versioned citations; published edits return to private drafts | `knowledge.py`, `main.py`; frontend `Knowledge.tsx` |
| AI content authoring | Synchronous drafts and persisted generation jobs with leases/recovery; human review before publication | `ai.py`, `generation_jobs.py`, `inline_worker.py`; frontend `Composer.tsx` |
| Conversation practice | Four scripted scenarios (everyday, interview, workplace, presentation); persisted turns, revision checks and bounded participation summaries | `growth.py`; frontend `Growth.tsx` |
| Optional reminders | Explicit permission request and scheduled native reminders; web/Expo Go report unavailable support | frontend `reminders.ts`, `reminders.web.ts` |
| Limited offline use | Up to 30 public text activities downloaded for seven days; local self-practice feedback; logout removes the download | frontend `Downloads.tsx`, backend `/api/practice-download` |
| Reliability | Submission UUIDs, task versions, recovery lookup, uniform errors, request IDs, structured logs, ownership checks and private audio access | `evidence.py`, `observability.py`, `audio_store.py` |

Source paths without a directory prefix in the table are relative to `classroom_web/server/`. The complete schema has **100 HTTP operations**; see [OpenAPI](../postman/openapi.json), [API list](../postman/API_LIST.txt) and [API guide](../classroom_web/API_CONTRACT.md).

## Architecture and deployment

- **Web:** https://vaachak-ai.vercel.app on Vercel.
- **API:** https://vaachak-api.onrender.com on Render Free; one instance and one Uvicorn worker, with `VAACHAK_RUN_WORKER=inline` waking persisted generation jobs on demand.
- **Database:** Neon PostgreSQL selected by `DATABASE_URL`; local SQLite remains supported.
- **Audio:** private S3-compatible object storage in the cloud; local files in local deployments. Recordings reach the API and, for transcription, Groq. Playback requires authorization.
- **Android:** signed standalone version 1.0.0, version code 2, built and emulator-smoke-tested against the hosted API. See [release evidence](verification/android-share-release-2026-10-11.json) and [download/install instructions](../deploy/backend/README.md#android-and-ios-distribution).
- **iOS:** Expo Go simulator journeys were checked. No signed native IPA was produced; the selected free distribution route is the hosted web app through Safari/Add to Home Screen.

See [architecture](ARCHITECTURE.md) and the [operator runbook](../deploy/backend/README.md). Free-host cold starts and provider quotas apply; this deployment does not promise an always-on SLA.

## What the current release does not establish

- No integrated on-device speech/LLM runtime, complete offline learning or cross-device event synchronization. Submission-ID reconciliation is not an offline answer/audio outbox.
- No deployed seven-skill BKT placement test or calibrated mastery probabilities. The current review policy uses attempt evidence and delayed-success rules.
- No acoustic phoneme scoring. Transcript agreement and task scores are not validated pronunciation or CEFR proficiency measurements.
- No generative multi-turn role-play. The four conversation scenarios use authored prompts.
- No embedded vector database or embedding-based retrieval. Teaching knowledge is selected by skill/domain and deterministic keyword matching, with source-ID/version validation.
- No guardian identity-verification workflow in the current account service; optional research consent is a different feature. No legal-compliance certification is claimed.
- No unlimited unique curriculum or unlimited provider calls. Continuous practice reuses a finite accessible pool and labels repetition.
- No completed human learning-efficacy, retention, accent-fairness or representative-device performance study. Synthetic test users and recordings are test fixtures.

## Remaining release and research work

1. Configure and verify SMTP if self-service reset email is required; deployed email recovery was unconfigured at the last acceptance check. Operator-assisted reset exists.
2. Establish external backup/retention scheduling, protected exports and a cloud restore drill. Cleanup and local backup tools alone do not establish a running schedule.
3. Complete signed-build microphone/interruption/notification checks, screen-reader acceptance and broader physical-device coverage. Existing physical Android tests used Expo Go; iOS simulator acceptance is not physical iPhone acceptance.
4. Review curriculum and run consented adult usability/speech evaluation with reproducible baselines. Separate measured engineering correctness from educational effectiveness.
5. Review outstanding build-tool dependency advisories and production monitoring/capacity before broader distribution. Historical audit results are not a current security certification.
6. Deliver the remaining generative-AI roadmap incrementally. G1/G2 feedback/knowledge is integrated; existing drafting and sessions cover parts of later work but do not complete G3–G7 acceptance.

## Documentation and evidence boundaries

Use [verification](VERIFICATION.md) for dated test evidence, [backend status](BACKEND_IMPLEMENTATION_STATUS.md) for service details, and [user-value status](USER_VALUE_IMPLEMENTATION_STATUS.md) for the product backlog. Original plans retain their original requirements and estimates; their baseline sections are not current status inventories.

`packages/` and `infra/supabase/` retain separate Dart/Flutter and Supabase implementations, including BKT, encrypted storage, packs and event sync. They are not imported into the deployed Expo application. [Legacy status](LEGACY_IMPLEMENTATION_STATUS.md) preserves their historical implementation and test record; features there must not be presented as current app integrations.
