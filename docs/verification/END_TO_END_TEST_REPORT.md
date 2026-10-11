# End-to-end page and control audit — 11 October 2026

## Scope and evidence

Subsequent G1/G2 code fixes and their current verification are recorded in [G1 and G2 review fixes](G1_G2_REVIEW_FIXES.md). The audit below retains its original scope and limitations.

This audit expands the previous smoke tests into learner and teacher page/control journeys. It exercises the actual API and persistent database except where a test explicitly injects a failure or a synthetic ASR preview. Synthetic accounts and disposable classes/courses keep destructive checks away from user data.

Final combined browser result: **66 / 66 passed** across desktop Chrome and mobile web. Two additional re-recording regressions passed after extending that scenario. Backend: **152 passed** in `full-backend-tests.xml`. Frontend units: **19 passed**, TypeScript passed, ESLint **0 errors / 11 existing warnings**. Live AI generation and its queue worker: **1 desktop journey passed**, recorded in `frontend/live-provider-test.log`.

The source inventory contains **191 control declarations**: 129 literal labels and 62 dynamic/shared declarations. `frontend/full-control-audit.json` records 125 literal labels actually interacted with in passing browser tests, linked to their test names. The remaining four (Topic, Draft three tasks, Queue AI draft, Check queued draft) are covered by the separate passing live-provider journey. A label hit is not a claim that every conditional state, content instance, accessibility mode or platform combination is certified. Course Progress is a display-only route; it is asserted by tests even though the click-only route audit does not list it.

## Page and control coverage

| Page / area | Verified interactions and outcomes |
| --- | --- |
| Welcome, sign-in, registration, recovery | Guest sample through all questions and restart; independent registration; all role selectors and teacher invite field; invalid credentials; recovery-service unavailable message; invalid reset token; return to sign-in. |
| Learner Today | Practice/class entry, enrolled-course See all, growth entry and progress destinations. |
| Practice and courses | Search match/no match; public practice; enroll/leave; sequential locked lesson; lesson completion and repeat entry. |
| Player | All six task types; correct/incorrect responses; selected-word removal; speech/typed mode switching; synthetic microphone recording/re-recording; playback/pause; transcript editor; helpful/unhelpful feedback; retry and completion destinations. |
| Submission recovery | Lost response reconciled without duplicate; unsent attempt becomes editable; pending ID survives reload and sign-in; readable request failure; injected malformed response reaches the rendering boundary and its recovery control. |
| Review, Progress, Attempt | Review evidence link and task completion; attempt cards; first/follow-up comparison links; newest/older history pagination; real-phone recorded evidence playback, dispute and restoration. |
| Growth | All four learning goals, both difficulties, weekly-day choices, consent, reminder hour, unsupported-reminder guidance/pause, starting check, answer draft/resume, subsequent sessions, due revision, product feedback, four-turn conversation, status reload and restart. |
| Downloads | Download, refresh, wrong/correct provisional answers, next item, removal and offline use within the active web session. This is not full offline-app certification. |
| Settings | Invalid timezone, device timezone, save, research consent, data export, wrong/correct password change, logout/login, deletion cancellation and permanent deletion of a synthetic account. |
| Teacher Today, Classes, Class | First-class action; create/open; rotate joining code; learner join and removal; assignment rename/archive/restore/delete; course assign/unassign; class archive/restore. |
| Insights and Student | Class insights; evidence and learner links; personal follow-up entry; attention snooze cancellation/confirmation, resolve and follow-up journal. |
| Library, Course, Course Progress | Create/edit course; visibility; sequential order; unit rename/reorder/delete confirmation; lesson reorder/edit/save/archive/restore/delete; publish/unpublish; course progress; archive/restore/delete. |
| Composer | All six editors; options add/remove/correct-answer selection; explanation; every skill selector toggled on/off; approval switches; reference selection/None; draft saving/resume; publishing; uncertain-save return action. Live synchronous and queued AI generation both preserve the human approval gate. |
| Recordings and Saved work | Synthetic browser voice-reference save/play/pause/delete; deletion cancellation; empty library; draft resume and archived-resource restoration. Saved work is the teacher branch of Growth. |

## Physical Android verification

Device: realme 15 5G, Android 16, Expo Go 57.0.9, USB connection to the isolated local API. Sanitized JUnit reports omit the device identifier. These six additional flows passed:

- `frontend/physical-android-teacher-core.xml`: teacher insights, learner evidence, classroom, draft save, course progress, lesson editor and save.
- `frontend/physical-android-teacher-finish.xml`: voice-reference library, account and saved work.
- `frontend/physical-android-learner-login.xml`: switch from teacher to the learner account.
- `frontend/physical-android-learner-pages.xml`: journal, practice search, preferences, export/share, download/remove and reminder handling.
- `frontend/physical-android-reminders.xml`: explicit Expo Go limitation and reminder pause feedback.
- `frontend/physical-android-evidence.xml`: saved real recording playback/pause, transcript dispute/restore and signed-in state after stopping/reopening the app.

Earlier same-day physical speech reports (`physical-android-upload.xml`, `physical-android-finish.xml`, `physical-android-speech.json`) establish real microphone upload, live transcription, confirmed recorded submission and completion. The transcript-edit browser case deliberately uses a controlled ASR response; it does not claim synthetic microphone noise is real speech.

Reusable phone flows are in `apps/vaachak/tests/native/physical-*.yaml`. They document starting-state prerequisites and use environment variables for credentials/Expo URL. The teacher course/class fixture names are synthetic. Raw Maestro logs and screenshots remain outside the repository because they can contain test credentials or phone notification details.

## Defects fixed during this audit

1. Attempt comparison/follow-up buttons called a navigation method that did not exist. Both now use the application navigation adapter and pass regression journeys.
2. Course lesson order was mistakenly used as a task cursor. One-task lessons could crash immediately. Only personal practice sessions now restore a validated cursor; lessons start at task zero. Three unit regressions cover this distinction and cursor bounds.
3. Stray JSX space expressions directly inside native layout containers caused Android text-rendering errors. Removed them from Learning, Player, Courses and Composer; an AST regression test checks this class of error.
4. A lesson response could arrive after a user started typing and overwrite the new title. The editor now shows loading content until hydration finishes. A delayed-response browser regression verifies the edit/save path.
5. Decorative icons leaked into button accessible names and busy buttons lost their names. Shared buttons now expose their actual title explicitly as the accessible label.

## Test-environment corrections

Earlier runs are not counted as final passes. They exposed stale test selectors, off-screen phone controls, ambiguous hidden-screen text, synthetic-account rate limiting and two ENOSPC artifact-write failures. The final functional browser server uses a separate disposable data directory, disabled AI, and `VAACHAK_AUTH_PER_MINUTE=1000` to accommodate rapid account setup. Normal app/server settings were not changed. The temporary final functional server and web proxy were stopped after verification; the phone application services were left running. Backend rate-limit tests still run with their own test configuration. Large browser traces were disabled to reduce disk pressure; failed screenshots and concise reports remain enabled.

## Remaining limits and release blockers

- This is not proof of every possible combination of content, permission state, device and failure timing. The complete physical-phone control matrix, TalkBack/VoiceOver, denied/revoked microphone permission, phone-call/audio interruptions, background/kill during upload and long-duration soak tests remain to be certified.
- Current release changes have not received a complete iOS regression run. The Mac ran short of disk space during this work. Prior iOS screenshots predate these additions.
- Expo Go cannot verify installed-build local notification scheduling/delivery. Signed Android/iOS builds and notification/timezone/DST checks are still required.
- SMTP is unconfigured locally. The unavailable/error path passes; actual reset-email delivery, token link handling and production recovery are not certified.
- **Known feedback-quality defect remains:** live ASR wrote “everyday” for spoken “every day”, and scoring/grammar feedback penalized that spacing. This must not be interpreted as a learner pronunciation error. ASR-aware scoring and human calibration are still needed.
- Continuous practice draws from a finite pool and explicitly includes revision. These tests do not establish infinite unique content, learning efficacy or retention.
- HTTPS staging, production credentials, signed releases, production restore/load tests and real-device iOS validation are not established by local E2E passes.

## Reproduction

From the repository root, start an isolated functional API (do not point it at production data):

```sh
VAACHAK_DATA=/tmp/vaachak-final-functional VAACHAK_AUTH_PER_MINUTE=1000 PYTHONPATH=classroom_web/server GROQ_API_KEY= VAACHAK_GROQ_KEY= .venv313/bin/python -m uvicorn main:app --host 127.0.0.1 --port 8006 --no-access-log
```

From `apps/vaachak`, export web and serve it in a second terminal:

```sh
EXPO_PUBLIC_API_URL= npm run build:web
PORT=8095 API_PORT=8006 node scripts/serve.mjs
```

Run verification:

```sh
E2E_BASE_URL=http://127.0.0.1:8095 E2E_NO_TRACE=1 E2E_REPORT=test-results-final/results.json npx playwright test journeys comprehensive controls --output=test-results-final
node scripts/audit-controls.mjs
node scripts/summarize-e2e.mjs test-results-final/results.json
npm run typecheck
npm run lint
npm test
```

Live provider testing additionally requires an AI-enabled isolated API and its worker. Run `provider.spec.ts` with `E2E_LIVE_PROVIDER=1` and the matching `E2E_BASE_URL`. It makes actual provider requests; its result is kept separate from deterministic functional coverage.

## Header-spacing follow-up — 11 October 2026

The shared page header now uses Expo Router's exported `Header` with `headerStatusBarHeight={0}`. The outer application SafeAreaView already provides system-bar spacing; the nested header must not add it again. Page titles and standard back navigation remain in place. The SDK 57 supported import is `expo-router/react-navigation` ([Expo migration reference](https://docs.expo.dev/router/migrate/sdk-55-to-56/)). No additional dependency is retained.

Validation: TypeScript passed; lint 0 errors / 11 existing warnings; web export passed; four desktop/mobile navigation journeys passed. The mobile-web screenshot `frontend/header-spacing-web.png` was visually inspected. The final physical Android screenshot could not be verified because the phone returned a black screen; an unlock request is pending. Earlier native flow passes do not establish the final header's visual result.
