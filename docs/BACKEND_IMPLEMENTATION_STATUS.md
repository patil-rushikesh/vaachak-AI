# Backend milestone implementation and verification

Implementation date: 11 October 2026. This report concerns the FastAPI backend only. It preserves the existing service, SQLite store, task types, classroom/course routes and Groq/rules integration. React Native screens and academic human-participant evaluation are outside this backend implementation.

Current G1/G2 release finalization and frontend integration are tracked in [G1/G2 release verification](verification/G1_G2_REVIEW_FIXES.md). Its current schema and 100-operation inventory supersede counts in older verification runs below.

## Implemented milestone coverage

| Milestone | Backend delivery |
|---|---|
| M1 contracts and integrity | Pinned runtime dependencies including httpx; versioned additive migration; typed success/error contracts; idempotent submission reservations; immutable per-attempt task snapshots; lesson revisions; input/transcript/rubric/model provenance |
| M2 mobile support | Paginated attempt history/detail; linked retries; submission status lookup; transcript disputes; authorized audio; consistent teacher evidence across assignments and courses; version-aware task responses |
| M3 review and intervention | Skill-specific delayed-success evidence; immediate retries excluded from retention advancement; explainable priority/reasons/evidence IDs; different-task recommendations from accessible skill-tagged material; snooze/resolve/reopen and follow-up assignment evidence; preferences/local-day statistics |
| M3 lifecycle | Class/course/lesson/assignment archival and restore; historical-evidence deletion guards; assignment metadata editing; recording deletion; password change/reset; account export/erasure; instructor ownership transfer |
| M4 operations | JSON request logs for every endpoint; request IDs; uniform sanitized errors; quotas; decoded media validation; bounded provider fallbacks; readiness; non-root container; HTTPS Compose configuration; backup/restore checksums; cleanup/operator tools; CI and updated Postman artifacts |

Existing routes remain available. Intentional compatibility changes: query-string bearer tokens are rejected; uploaded audio must be decodable and correctly labeled; hard deletion of content with attempts returns 409; modified lessons do not retain completion from old content; unrelated successes no longer clear skill flags. Legacy attempt provenance remains unknown rather than invented.

## Verification artifacts

- `verification/backend-tests.xml`: backend regression and new milestone acceptance results.
- `verification/backend-endpoint-coverage.json`: actual method/route/status coverage recorded from HTTP requests during tests.
- `verification/backend-newman.xml`: ordered HTTP workflow against the Docker container with AI disabled.
- `verification/backend-newman-live.xml`: the same workflow against the configured local AI backend.
- `verification/backend-live-speech.json`: audio-only transcription and feedback using an explicitly identified synthetic recording.
- `verification/backend-load.json`: isolated concurrent HTTP workload, latency distribution and restart persistence.
- `verification/backend-release-summary.json`: final machine-readable summary, including limitations.

These artifacts are generated evidence, not promises of universal performance. The request log path in the load report identifies the local detailed JSONL trace; it is not a portable dependency.

## Measured verification results

- 143 Python backend tests passed; no failures/errors. One Starlette TestClient/httpx deprecation warning remains.
- All 71 application operations received successful-response coverage in the recorded HTTP tests.
- Docker HTTP workflow: 88 requests and 95 assertions, no failures.
- Live-provider workflow: 88 requests and 96 assertions, no failures; audio-only synthetic ASR also succeeded.
- Fifteen-minute isolated workload: 20 concurrent users, 17,900 requests, zero HTTP failures; ordinary read p95 448.36 ms. A two-minute follow-up also passed with 2,400 requests.
- Container build, persisted-account restart, checksum-verified restore and database integrity checks passed.
- Synthetic policy replay passed five designed invariants versus two for the original heuristic. This is correctness evidence, not a learning-efficacy or real-user recommendation claim; see `verification/review-policy-evaluation.json`.

## Supported deployment and limits

The target is one application instance, a persistent local SQLite/audio volume, and a bounded academic cohort. Idempotency applies when clients supply a submission UUID. Startup marks interrupted operations explicitly; automatic durable background execution is not claimed. Review weights are an inspectable project hypothesis, not a validated learning model. Skill-tagged tasks are supplied/reviewed by teachers; untagged catalog activities remain usable but do not establish a skill-specific success.

The report does not claim a completed human study, measured learning benefit, acoustic pronunciation scoring, full offline operation, or integrated historical Supabase features. Some success contracts intentionally retain additive extension fields for compatibility; generated clients should use the documented task discriminators and validate optional fields.

## External release gates

1. Provision the deployment host/domain and install real deployment secrets. The container and Compose artifacts are provided; local tests do not prove a public HTTPS deployment exists.
2. Configure daily backup/cleanup scheduling and the institution's protected off-host backup destination. Exercise restore on that deployment host and document retention/erasure handling for older backups.
3. Review the initial task skill labels/content and conduct the planned consented human speech/usability evaluation. Synthetic audio and replay fixtures are not substitutes.
4. Connect and test the eventual Android release against the hosted API. Mobile permissions, actual microphone/device behavior and APK signing are frontend release work.

The operator runbook is `deploy/backend/README.md`. Previously existing local data was backed up before application migration; the final release summary records the backup location without exposing credentials.
