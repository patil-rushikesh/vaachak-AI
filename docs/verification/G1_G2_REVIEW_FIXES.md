> Documentation reconciliation, 15 October 2026: Later release evidence supersedes the then-pending hosting/signing/push statements below: see [current verification](../VERIFICATION.md) and [Android release](android-share-release-2026-10-11.json). This document retains its original run counts and observations.

# G1 and G2 review fixes

Date: 11 October 2026. Scope: the current G1/G2 feedback and teaching-knowledge release, including the seven findings from review at commit `1b34394`.

## Current release finalized and frontend integrated

This release preserves the existing backend and Expo application. Future G3–G7 generative-AI milestones remain separate. Current local release acceptance is complete; production deployment and academic human evaluation are not implied.

### Backend behavior

- Typed knowledge units expose `can_manage`; ownership remains enforced on every mutation.
- Create trims and validates content, rejects unknown skills and whitespace-only text, and supports owner-scoped UUID retry protection. A lost create response does not create duplicate notes.
- Version-checked editing returns content to a private draft, increments its version and clears approval. Stale edits return 409 without overwriting newer content.
- Review, publication and withdrawal are explicit actions. Withdrawn notes cannot enter retrieval; editing creates a new draft for review. Existing attempt citations retain their original title/source/version.
- Grounded feedback carries the version of each cited note. Focused legacy catalog sets use curated coaching context when their items lack skill tags. This context never changes assessed skills, content versions or reading scores. Explicit item skill tags take precedence; unrelated general sets remain ungrounded.
- Existing privacy, unscored progress, migration, starter-content, error-envelope and request-log fixes remain covered. New routes inherit sanitized errors and structured request IDs.
- Postman, OpenAPI, frontend operation registry and generated TypeScript contracts match **100 API operations**. New routes: `PUT /api/teacher/knowledge/{unit_id}` and `POST /api/teacher/knowledge/{unit_id}/withdraw`.

### Frontend delivery

Teachers use **Library → Teaching notes** to write an explanation and optional example, choose a skill/level, search their notes or the shared library, inspect a note, edit, review, publish and withdraw. Lifecycle states and public visibility are explained before action. Other teachers' notes and starter content have no owner controls. Failed saves retain editor text, duplicate create retries are safe, and stale edits give a refresh/recovery path.

Learners open **Why this feedback?** on current or historical attempts to inspect the grading basis and versioned teaching-note citations. Optional next-line suggestions are clearly unscored practice. Uncertain attempts retain neutral feedback and retry without artificial failure or completion.

### Final verification

| Check | Result |
| --- | --- |
| Full backend suite | **181 passed**; one existing Starlette/httpx deprecation warning |
| API HTTP coverage | **100/100 operations exercised, 100/100 with successful responses** in `backend-endpoint-coverage.json` |
| Frontend unit tests | **21 passed** |
| Desktop and mobile-web journeys | **74 passed**, no skips, failures or flaky retries |
| Android native | Teacher sign-in → create → review → publish → withdraw passed in Expo Go 57 on the disposable ATD emulator; session restoration/library/detail navigation also passed |
| iOS native follow-up | iPhone 16 / iOS 26.2 / Expo Go 57.0.9: guest and citation assertions passed in Maestro; teacher lifecycle, learner retry/completion, preferences and session restoration passed through direct native UI checks. Full unattended automation remains pending; see below |
| Visual inspection | Android library and note detail inspected after enabling the ATD renderer; header and controls render without the previous extra header gap |
| TypeScript and API contract | Passed; registry checked against freshly imported backend schema |
| Lint | Zero errors, 11 pre-existing warnings |
| Platform exports | Android, iOS and web passed |
| Backend Docker | Final image built; readiness returned schema 7 with storage/media decoder ready; worker `--once` exited successfully |
| Live AI smoke | Synthetic built-in grammar reading returned HTTP 200, AI feedback and **one versioned citation** using the configured provider |

Artifacts: [backend run](current-release-backend.log), [browser results](frontend/current-release-browser.json), [Android flow](frontend/current-release-android.log), [library screenshot](frontend/current-release-teaching-notes-library.png), [note detail screenshot](frontend/current-release-teaching-note-detail.png), and [live smoke](current-release-live-smoke.json).

The browser citation-display check simulates provider-derived fields while using real registration, submission and attempt retrieval. Backend citation validation is independently tested, and the separate live smoke confirms one actual provider response. This is not a broad human quality or ASR calibration study. The Android run uses an ATD without a software keyboard. The iOS follow-up below adds runtime checks with a software keyboard; neither run certifies real microphone behavior, signed release builds, SMTP delivery or production hosting.

The first live smoke revealed missing coaching context on untagged legacy catalog items; that integration gap was fixed and a full-suite regression added before the successful final smoke. No user database was reset. Changes are local and have not been pushed.

### iOS runtime follow-up — 11 October 2026

Tested the current working tree on a new **iPhone 16 simulator, iOS 26.2**, using **Expo Go 57.0.9**, Xcode 27 and Maestro 2.11.0. An isolated API used port 8008 and a disposable database; Metro used port 8097. No existing user database was modified. The app was left running with those local services for inspection.

Cache cleanup removed regenerable npm/npx, pip, Homebrew and obsolete Expo downloads, plus unreachable uv cache entries. `uv cache prune --force` reported 13.7 GiB of logical cached files removed; shared files mean this is not equivalent to physical disk space reclaimed. Free disk space rose from about 1.6 GiB to over 7 GiB after simulator installation. Project source, installed environments and other simulators were preserved.

The initial Metro `--localhost` process listened only on IPv6 while Expo advertised an IPv4 bundle URL. Starting Metro with `REACT_NATIVE_PACKAGER_HOSTNAME=127.0.0.1 --lan` resolved the development connection. No application code change was needed.

| Journey | Observed result | Method |
| --- | --- | --- |
| Guest sample | Incorrect choice correction, correct polite request, return to sign-in | Passing Maestro flow |
| Teacher knowledge | Sign-in, draft creation, review confirmation, publication confirmation, published state, withdrawal confirmation and private withdrawn state | Native UI interaction plus HTTP/database evidence |
| Learner assignment | Class navigation, correct choice, feedback basis, next task and typed fallback when speech is unavailable | Native UI interaction |
| Uncertain answer | `Zzz` displays “Not scored”, does not allow completion, and offers retry | Native UI plus API: null score/accuracy and `evaluation_status=unscored` |
| Retry and completion | Correct typed retry scores 100, links to the unscored attempt, and completes the two-task practice | Native UI plus persisted retry relation |
| Progress | Journal retains the unscored attempt; scored count is 3 and average is 92% for the three scored attempts | Native UI plus persisted attempts |
| Grounded feedback | A real provider-generated historical attempt displays the starter source and Version 1 | Native navigation followed by passing Maestro citation assertion |
| Preferences | Device timezone saves as Asia/Kolkata and returns a success message | Native UI plus API readback |
| Session restoration | Terminate Expo Go, reopen the project, return to the signed-in learner home without entering credentials | Native screenshot and authenticated `/api/me` response |

The captured HTTP log contains **94 requests: 93 HTTP 200, one HTTP 401, zero 5xx**. The 401 was caused by malformed synthetic input during an early automation attempt, and the app displayed its error message and support reference. Subsequent sign-ins succeeded. No application runtime exception appeared in Metro. TypeScript passed; lint reported zero errors and the same 11 existing warnings. The new disposable iOS seeding script also ran successfully.

**Automation limits:** long Maestro teacher/learner flows encountered keyboard focus, an iOS password-save prompt, and scrolling/hit-target failures. These are not recorded as clean unattended passes. The corresponding product journeys were completed through native accessibility interaction and checked against backend state. Only the two passing, bounded Maestro checks are retained as iOS test files. A stable unattended full iOS suite remains pending.

The deterministic API disabled speech/AI for the assignment run. A separate live provider call created the historical citation fixture in the same disposable database before UI testing. This verifies citation display and typed fallback, not iOS microphone recording or ASR quality. Signed standalone builds, physical iPhone testing, and every-page/every-button iOS coverage remain outside this run.

Evidence: [structured results](frontend/current-release-ios-results.json), [sanitized HTTP log](frontend/current-release-ios-http.json), [guest runner](frontend/current-release-ios-guest.log), [citation runner](frontend/current-release-ios-citation.log), [published note](frontend/current-release-ios-teaching-published.png), [unscored answer](frontend/current-release-ios-unscored.png), [completion](frontend/current-release-ios-completed.png), [citation](frontend/current-release-ios-citation.png), and [restored session](frontend/current-release-ios-restored-session.png). Reproduction is documented in the [app README](../../apps/vaachak/README.md).

## Earlier review-fix run

The following sections preserve the original seven-finding validation before the release-finalization work above.

## Corrected behavior

| Finding | Correction | Regression evidence |
| --- | --- | --- |
| Private notes became retrievable after owner deletion | Explicit published-public or approved-owner filtering; account deletion removes owned notes through a database trigger; upgrade removes orphaned private notes | Owner erasure, ownerless private retrieval, export and migration tests |
| Unscored attempts still affected grades and completion | Null public score/accuracy, neutral feedback, shared `scored_attempts` progress view, preserved history, session completion repair | Statistics/history, skill review, personal session and course completion tests; browser retry journey |
| AI reintroduced a segmentation correction | Perfect readings differing only by explicit segmentation equivalents bypass model judgment; contradictory model corrections fall back to rule feedback | Mocked false corrections for perfect and partially matched readings |
| Arbitrary boundary removal accepted different phrases | Explicit `everyday/every day` and `login/log in` reading equivalents replace blanket concatenation | Positive equivalents and counterexamples including `a nice man/an ice man` |
| Notes became public without recorded approval | Draft creation, version-checked owner review, then explicit publication; reviewer/time recorded | Ownership, stale versions, unreviewed publication, idempotency and listing isolation |
| Existing installations lacked starter knowledge | Versioned stable-ID starter units installed during database initialization; separate non-destructive installer | Repeat startup preserves users and teacher drafts; eight starter units available |
| API checks passed stale artifacts | Import current backend OpenAPI before comparing the saved schema and registry; regenerated Postman, registry and TypeScript declarations | Stale artifacts rejected before regeneration; 98 operations match afterward |

## Validation

- Backend suite: **177 passed**, including 13 targeted review regressions.
- Frontend units: **21 passed**.
- Desktop and mobile-width browser journeys: **68 passed**, including the real API unscored → retry → correct answer → journal flow on both layouts.
- TypeScript: passed. Lint: zero errors and 11 existing warnings.
- Web export: passed.
- API contract check: **98 operations**, compared with freshly imported backend OpenAPI. This includes the new review and publish routes.
- Demo seed smoke check: passed in an isolated database. No user database was reset.
- Upgrade regression: preserves historical attempts, quarantines old auto-approved teacher notes, removes orphaned private notes, and reopens sessions prematurely completed by unscored attempts. Repeated migration is safe.

AI error scenarios use controlled provider responses; this run does not claim new live-provider quality calibration. Browser tests use an isolated local API with AI disabled. Physical Android/iOS testing and signed-build release acceptance were not rerun here. These fixes do not complete every milestone in the generative AI plan.

## Upgrade and compatibility

Restart the API to apply migration 7 and install the starter content. The CLI alternative from the repository root is:

```sh
VAACHAK_DATA=/path/to/existing/data .venv313/bin/python tools/install_knowledge.py
```

Use the same data directory as the service. Do not use demo `--seed` to upgrade a real installation.

Previously auto-approved teacher notes return to draft because they lack explicit review provenance. The owner calls `/api/teacher/knowledge/{unit_id}/review` with the current version, then `/publish` to make the note public. This records the author's explicit review; it is not independent peer review.

Clients must accept null scores for unscored attempts. The React Native/web client now shows “Not scored,” preserves retry, and does not show a completion button for an unscored task. Genuine scored zeroes still display as zero. The legacy database score column remains numeric for compatibility; progress consumers must read `scored_attempts`, and history consumers must use `evidence.attempt_json` rather than displaying that storage value directly.

## Reproduction

```sh
# Repository root
.venv313/bin/python -m pytest classroom_web/tests -q
.venv313/bin/python tools/export_postman.py

# apps/vaachak
npm run typecheck
npm run lint
npm test
npm run api:check
npm run build:web
# With an isolated API and web server, as described in the app README:
npx playwright test journeys comprehensive controls knowledge
```
