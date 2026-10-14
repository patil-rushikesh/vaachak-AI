# Current verification index

Documentation reconciled 15 October 2026 against source baseline `10d27c6`. Reports below retain their original execution date, environment and scope. This documentation update does not rerun the browser/native/hosting suites or certify learning outcomes.

| Evidence | Recorded result and boundary |
| --- | --- |
| [SQLite operation coverage](verification/backend-endpoint-coverage.json) | 100/100 API operations covered with successful responses |
| [PostgreSQL operation coverage](verification/backend-endpoint-coverage-postgres.json) | 100/100 API operations covered with successful responses; separate database run |
| [Backend JUnit](verification/backend-tests.xml) | Stored artifact reports 193 tests, zero failures/errors/skips; do not replace this count with totals from another run |
| [G1/G2 verification](verification/G1_G2_REVIEW_FIXES.md) | Its earlier run recorded 181 backend tests, 21 frontend units and 74 browser journeys; knowledge lifecycle/citation integration and unscored handling |
| [Hosted acceptance](verification/hosted-release-2026-10-11.json) | Render/Neon/Vercel auth, authorization, private audio, live provider smoke and restart persistence |
| [Cloud container acceptance](verification/neon-release-container.json) | Schema 7, dynamic port, non-root runtime, worker and external persistence/replacement checks |
| [Signed Android release](verification/android-share-release-2026-10-11.json) | Version 1.0.0/code 2; signature checked, installed on emulator; guest/hosted learner/session smoke; 41 frontend unit tests in release verification |
| [Physical Android audit](verification/END_TO_END_TEST_REPORT.md) | Expo Go phone page/control journeys and actual microphone/transcription/playback; predates signed-release smoke |
| [iOS runtime](verification/frontend/current-release-ios-results.json) | Expo Go simulator guest/citation automation plus directly operated teacher/learner journeys; no standalone IPA or physical iPhone certification |
| [Review-policy fixture](verification/review-policy-evaluation.json) | Enhanced policy matches five designed synthetic cases versus two for baseline; not human recommendation accuracy |

Test totals from different dates overlap and must not be summed. Older reports may describe then-open defects or deployment gates; later scoped evidence supersedes those statements, not the historical result itself. The known “everyday/every day” segmentation case is corrected in G1/G2; broad speech fairness remains unevaluated.

## Reproduce safely

From the repository root, use a Python environment with backend dependencies:

```sh
GROQ_API_KEY='' VAACHAK_GROQ_KEY='' .venv313/bin/python -m pytest classroom_web/tests -q
```

The test fixtures select temporary SQLite storage unless an explicitly configured local disposable PostgreSQL test database is supplied. Never run database-reset suites against hosted learner data. Endpoint tests write their coverage artifact; retain run/date context when updating it.

From `apps/vaachak`:

```sh
npm run api:check
npm run typecheck
npm run lint
npm test
```

For browser/native/Compose prerequisites use the [app README](../apps/vaachak/README.md). For live ASR, use an explicitly authorized test recording and configured provider; deterministic tests do not prove model quality. Raw runners can contain synthetic credentials; publish only sanitized evidence.

## Outstanding acceptance

Representative human speech and learning evaluation, full signed-build permission/interruption/notification coverage, accessibility acceptance, physical iPhone testing, real recovery-email delivery, cloud restore scheduling/drill and production capacity remain distinct tasks. Passing endpoint coverage is not every possible endpoint input or every possible UI state.

[Legacy verification](LEGACY_VERIFICATION.md) preserves the Dart/Flutter/Supabase runs, including native offline model experiments. Those results are not Expo application acceptance.
