# User-value implementation status

Updated 11 October 2026. This is an incremental implementation of USER_VALUE_IMPLEMENTATION_PLAN.md. The application has working additions, but **the eight milestones are not yet fully accepted and the release is not deployment-certified**. Automated checks do not replace educator review, observed usability testing, or the M.Tech pilot.

Current G1/G2 bug-fix evidence is in [the review fixes report](verification/G1_G2_REVIEW_FIXES.md). The known segmentation example, unscored progress handling, knowledge privacy, explicit publication, startup content installation and contract drift are corrected there; broader feedback calibration and milestone acceptance remain pending.

## Implemented and verified locally

- Expo Router route wrappers; existing feature screens retained; lint/type checking and web regression tests.
- Goal/difficulty/weekly preferences, optional analytics consent, guest practice with deterministic feedback.
- Persistent personal sessions, immutable task snapshots, session UUID idempotency, owned text/choice drafts with revision conflicts, completion and another-session actions.
- Public content selection with exact fingerprints, recent exposure counts and explicit purposeful revision when content repeats. “Continuous practice” means another bounded session is available; it does not promise infinite unique content or unlimited provider requests.
- Due-review selection derived from valid personal evidence with 1/3/7/14-day intervals. Disputes and immediate retries do not count as delayed success.
- Separate transcription upload/preview, optional correction and final evaluation. Original ASR text and corrected evidence provenance remain separate. Existing one-step clients continue to work.
- Private teacher drafts with autosave/manual save, revision conflicts and resume; archive listing/restoration.
- Persistent bounded teacher generation jobs with leases and recoverable interrupted work. Outputs require review and are never automatically published. Separate worker supplied in both Compose configurations.
- Selected public quiz download with seven-day expiry, local provisional feedback and logout cleanup. Native reminders request permission only on explicit enablement; Expo Go and web show unsupported guidance.
- Feedback helpfulness/report capture, opt-in allowlisted events, account export/erasure coverage for new resources, expired transcription cleanup.
- SMTP password-reset request with generic account response, hashed single-use expiring tokens and rate limits. SMTP is optional and unconfigured locally; operator recovery remains available.
- Three bounded scripted text conversation scenarios with owned sessions, revision checks and idempotent turns. Summaries describe participation, not measured proficiency.

Current G1/G2 release finalization: the teacher teaching-note lifecycle and learner source/basis details are integrated into the existing Expo app. Final verification: 181 backend tests, all 100 API operations with successful responses, 74 browser journeys, 21 frontend unit tests, Android teacher lifecycle and a live versioned-citation smoke check. See [current release details](verification/G1_G2_REVIEW_FIXES.md). This does not close the broader acceptance gaps below.

## Acceptance gaps by milestone

| Milestone | Remaining work before acceptance |
| --- | --- |
| M0 reliability | Signed staging builds; complete iOS/Android microphone, interruptions and accessibility runs; comprehensive unsaved-change guards/local fallback; stage flags; real SMTP delivery and safe reset deep links; scheduled retention/backup expiry and production restore drill. |
| M1 first value | Learner/trainer interviews; reviewed guest material and optional merge; explanation-language preference; calibrated starting-path recommendation; observed time-to-first-value measurement. |
| M2 fair feedback | Broader ASR segmentation and human rubric/transcription calibration beyond the corrected known cases; persisted versioned due-state beyond current derived queue; comparable longitudinal skill views; full audio edge-case/native evidence. |
| M3 continuous learning | Semantic near-duplicate detection; reviewed generation-to-pool workflow; richer transfer/exploration policy, skill adaptation, skip controls and capacity/cost checks. Existing pool is finite and revision is explicitly labeled. |
| M4 teaching | Four educator-reviewed full-week goal paths; conflict recovery UI/local fallback; report triage and content retirement workflow; improved invitation links and bulk assignment preview. |
| M5 return/offline | Private lesson/reference-audio download manifests; durable consent-aware audio outbox; app-kill/offline recovery beyond current submission reconciliation; reviewed localization; native reminder/DST and screen-reader testing. Public quiz download is not a full offline application. |
| M6 pilot/deployment | Report ownership/triage; consented human pilot; retention cohorts; shareable opt-in achievements; HTTPS hosting, signed release configuration, operational monitoring and mixed-traffic load testing. No pilot results are claimed. |
| M7 conversation | Saved-session discovery/resume UI; audio-confirmation input; hints/finish controls and reviewed focused summaries; interrupted-turn/native regression coverage. Current prompts are scripted, not AI dialogue. |

## Test evidence

The expanded 11 October page/control audit is recorded in [END_TO_END_TEST_REPORT.md](verification/END_TO_END_TEST_REPORT.md). Earlier counts below describe their original runs.

- Backend: **152 passed**, `verification/growth-backend-tests.xml`. Provider-dependent resource tests use controlled mocks; they do not prove live model quality or actual email delivery.
- Browser: **24 passed** across desktop and mobile web, `verification/frontend/growth-results.json`. Includes all six activity formats, teacher publishing, retry reconciliation, account errors, draft recovery, guest practice, goals, downloads and conversation.
- Frontend units: **19 passed**; type check passed; lint has **0 errors and 11 warnings**.
- API registry: **94 operations**, regenerated OpenAPI TypeScript types and Postman contract.
- Both Compose configurations validate. Rebuilt backend image passed `/api/ready` (schema 5, storage and media decoder available); its worker ran `--once` successfully. This does not establish production acceptance.
- Expo exports succeeded for Android, iOS and web; export success is not a signed native build.
- Additional browser offline check: 2 passed, `verification/frontend/offline-results.json`.
- Android native: emulator renders after enabling the ATD renderer; **3 Maestro smoke flows passed**: guest correction, authenticated goal/conversation, and classroom choice + typed-reading completion. Reports: `verification/frontend/android-guest.xml`, `android-learner.xml`, `android-practice.xml`. Screenshots accompany them. The authenticated flow restored a session; sign-in also returned HTTP 200 during the preceding native run. These are Expo Go checks, not signed-build or real microphone certification. Earlier iOS evidence predates these additions and is not a regression pass for them. The new iOS runtime run was stopped before completion when available disk fell below 1 GB; only the temporary simulator created for this run was removed.

- Physical Android (realme 15 5G, Android 16, Expo Go 57.0.9): guest correction, authenticated scripted conversation, and classroom choice passed. Actual microphone recording and playback worked. Speech upload exposed an Expo 57 multipart incompatibility; the native recorder now uploads binary data through Expo Blob instead of the unsupported legacy URI object. A second phone check exposed Android classifying an MP4 container as audio/mpeg; uploads now explicitly declare audio/mp4 and practice.m4a. Three regression checks cover binary content, MIME/filename, and missing/empty recordings. Transcription errors no longer trigger final-attempt reconciliation before an attempt is sent. Live speech upload and transcript preview now pass on the physical phone: the configured speech provider returned an unchanged transcript, and final submission persisted one recorded_confirmed attempt with server_asr_confirmed provenance and an audio/mp4 recording. Feedback rendered and the practice completion screen passed. Speech reports: `verification/frontend/physical-android-upload.xml`, `physical-android-finish.xml`, and `physical-android-speech.json`. **Open quality defect:** ASR wrote “everyday” for spoken “every day”; token alignment and AI grammar feedback penalized the transcription spacing (75% task score). This is not evidence of a pronunciation or learner grammar error. ASR-aware word-boundary handling and human calibration remain necessary. Sanitized reports: `verification/frontend/physical-android-guest.xml`, `physical-android-conversation.xml`, `physical-android-recording-ready.xml`. These checks do not certify a signed release.

## Local operation

Run the API as before. Start the additional worker against the **same** `VAACHAK_DATA` directory:

```sh
.venv313/bin/python tools/learning_worker.py
```

It loads the existing ignored `classroom_web/vaachak.env`, processes bounded jobs and logs only job identity, status, sanitized error code and elapsed time. `--once` processes at most one job for diagnostics. A stopped worker leaves queued jobs persistent; no progress should be claimed until it runs.

SMTP variables are documented in `classroom_web/vaachak.env.example` and `deploy/backend/.env.example`. Supply real values locally or through deployment secrets; do not commit credentials. STARTTLS is required. Email delivery currently uses an in-process background task, so durable delivery/retry remains a release gap.

`tools/backend_admin.py` handles cleanup/backup operations; schedule and verify these for the selected host. `tools/product_metrics.py` emits basic aggregate counts only, not retention or learning-efficacy claims.
