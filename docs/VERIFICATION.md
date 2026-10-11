> Historical reference: the web and Android frontends and their build tooling have been removed. See the root README for current setup.

# Verification record

Local verification on 2026-09-23, macOS ARM64, Flutter 3.47.5 / Dart 3.13.4, PostgreSQL 16.15.

## Phase 1 completed baseline

The following numbered totals record the completed Phase 1 baseline. Phase 2 changes and completed native runs are recorded separately below.

| Check | Result |
|---|---|
| Dart/Flutter formatting and analysis | Passed |
| Engine tests | 63 passed: evidence projection, unseen skills, timezone boundaries, available-content planning, graph validity, BKT goldens/invariants, planner, ladder/staircase, 40 grammar fixtures, HLC, alignment, replay, erasure, immutable payloads multiple teacher pins, assessment replay/sequence validation and erasure |
| Content tests | 5 passed: seed release rejection, review metadata, modality validation, reading schema/rubric bounds and reading-node/immutability checks |
| Store tests | 8 passed: SQLCipher 4 legacy-file compatibility, concurrent sequences, PIN lockout, minor consent, import idempotence/atomicity, erasure, encryption wrong-key reopen and consent-filtered queue |
| Pack tests | 2 passed: tier classification, signed installation, tampering/wrong-key rejection and safe paths |
| Sync tests | 4 passed: encrypted round trip, wrong key/pairing/tampering, shuffled/duplicate QR frames, fountain repair and malformed input |
| Explanation tests | 3 passed: immediate fallback, validated model result, child model disabling, malformed/unsafe output |
| Speech signal tests | 3 passed: silence/clipping/noise rejection, speech-shaped signal, clearing and buffer limits |
| Flutter session/controller tests | 27 passed: Riverpod session ownership, cancelled unlocks, profile isolation, durable retry, consent lockout, child-profile guards, content availability, durable practice/mastery update, revoked consent, encrypted assessment resume, retry/concurrency, stopping, atomic rollback, content changes modality gating, reading grading/quality/model checks, microphone revocation and numeric-evidence retry |
| Flutter widget tests | 12 passed: age/locale layouts at 200% text scale, native profile/PIN unlock and background locking, localized consent, invalid-content safe state, unconfigured teacher portal assessment resume/answer/unavailable-skill flow and reading consent refusal without scoring |
| Presentation theme unit test | 1 passed: age-specific sizes, touch targets and high contrast |
| Python pipeline tests | 7 passed: canonical format, draft release rejection, review round trip, signing verification immutable manifest, reading rubric/model validation and rubric-bound review |
| PostgreSQL migration | Applied successfully to clean dev/qa/prod schemas |
| SQL behavior tests | Passed: teacher roster isolation, cross-class denial, mutation grants, exactly-once ingestion, BKT parity, identity conflict, bound-device checks, voice rejection and irreversible erasure behavior |
| pgTAP | 12 passed: schemas/tables, RLS and privileges |
| Release teacher-web build | Passed |
| Android APK/AAB build, device integration, ASR/TTS model integration | Not run in the Phase 1 baseline; see Phase 2 status below |
| Reference-phone performance/energy | Not measured |
| Live Supabase auth and configured portal E2E | Not run: no project credentials/provisioned school |
| Local browser visual inspection | Blocked: browser could not connect to localhost despite successful local HTTP response |
| Educator, legal, manual accessibility review | Not performed |

No phone-performance or production-compliance claim follows from these tests. The bundled curriculum intentionally fails `pipeline.py validate --release` until content coverage and educator sign-off are complete.

Reproduce with `tools/check.py` and `tools/sql_check.py`. CI remains an executable definition rather than a completed remote CI run. Android execution status is recorded separately below. No production system was contacted or deployed.

Assessment increment: 96 Dart/Flutter tests and 5 Python tests passed. Database migration, SQL behavior and pgTAP results above are from the earlier baseline run; SQL was unchanged and was not rerun for this increment. See `ASSESSMENT.md` for implemented scope and remaining assessment requirements.

Reading increment: 106 Dart/Flutter tests and 7 Python tests passed, along with formatting, static analysis and the release web build. SQL remains unchanged from the baseline verification. Reading tests use synthetic signal/transcript fixtures; they do not establish microphone behavior, ASR accuracy or calibrated learning outcomes. See `READING_ASSESSMENT.md`.

Phase 1 completion: **128 Dart/Flutter tests and 7 Python tests passed**, along with formatting, static analysis, content structure validation and the release web build. SQL was unchanged; PostgreSQL and pgTAP results remain from the earlier baseline run. Actual SQLCipher 4 encryption and legacy encrypted-file compatibility were tested locally. Android/device checks, manual visual/accessibility review and curriculum approval remain release gates. See `PHASE_1.md` for the completed engineering checklist and scope boundaries.

## Phase 2 verification

The completed `tools/check.py` run passed **165 Dart/Flutter tests and 10 Python tests**, formatting, static analysis, content structure validation and the release teacher-web build. Dart/Flutter totals: engine 63, content 5, store 8, packs 13, sync 4, explanation 8, speech 18 and app 46. One opt-in real-model test was skipped in the ordinary suite because model paths were absent; separate actual-model runs are recorded below. The complete host-run log is `/tmp/vaachak-phase2-final-checks.log`.

New coverage includes signed pack resume/rollback/runtime-schema and file-set validation, actual token timing conversion, PCM chunk boundaries/cancellation, native worker lifecycle, shared model activation constraints, lazy explainer activation, six-second/cleanup fallback, child disablement and template-first validated UI replacement. Explanation-focused checks passed eight package tests, three lazy-runtime tests and two grammar widgets.

| Native acceptance item | Current status |
| --- | --- |
| Android SDK / ARM64 API 30 emulator | Installed; emulator boot verified |
| Android debug APK compilation and installation | Passed on the ARM64 API 30 emulator |
| Real encrypted profile/PIN/grammar/background-lock instrumentation | Passed on Android after correcting the test finder and using the valid platform lifecycle transition sequence |
| Real signed Whisper/Piper inference and numeric evidence | Passed on desktop and Android emulator; Android PCM playback/stop and SQLCipher evidence persistence exercised |
| Real signed Gemma 1B LiteRT-LM inference and validation/fallback | Passed on Android: native text generated; reviewed template retained because no validated model explanation was accepted |
| Physical microphone, playback and interruption validation | Not completed on reference phones |
| RAM/latency/thermal/energy acceptance | Not measured on reference phones |

Model weights and test signing material are kept outside the repository. The development Gemma file was checked against its published SHA-256 (`1325ae366d31950f137c9c357b9fa89448b176d76998180c08ceaca78bba98be`); that establishes artifact identity, not successful inference or model-quality acceptance. Test fixtures do not approve shipping content or school trust anchors. See `PHASE_2.md` for reproduction and scope.

The real desktop Whisper/Piper smoke rerun passed after native lifecycle fixes. Its selected tiny.en model does not expose the attention output needed for word timing, so `hasWordTiming` is false and hesitation timing remains unavailable for this fixture. The separate Android speech run also passed. Neither synthetic TTS-to-ASR run establishes real microphone accuracy.

Android speech acceptance passed using the real signed development fixture (`/tmp/vaachak-android-speech.log`): synthesized clip duration **2,589 ms**, reference-alignment accuracy **1.0**, `hasWordTiming: false`, and **one persisted answer** after the idempotent-save check. The run exercised native PCM playback/stop and encrypted evidence storage. The score describes this single synthesized fixture, not a human-speech benchmark or calibrated learner outcome.

Android Gemma acceptance passed (`/tmp/vaachak-android-gemma.log`): the actual authorized 1B LiteRT-LM model produced **22 characters in 3,856 ms** for the inference smoke request. The subsequent explanation flow reported `templateFirst: true`, `displayedSource: template` and `validatedModelAccepted: false`. This proves native inference and safe template retention; it does **not** demonstrate an accepted model-generated grammar explanation. Total cold test time was approximately 1 minute 55 seconds including signed-pack verification/installation; this is emulator test timing, not a phone inference benchmark.

The final Android offline UI rerun passed (`/tmp/vaachak-android-offline5.log`): actual encrypted profile creation, consent refusal/acceptance, PIN unlock, grammar template fallback, saved correction evidence and background route locking. The test uses the valid `inactive → hidden → paused` and `hidden → inactive → resumed` lifecycle transitions. Final static analysis was clean (`/tmp/vaachak-final-analysis.log`). All Phase 2 engineering/emulator acceptance checks are now recorded as passed; physical reference-device performance, human-microphone evaluation, supported word-timing models and production content/model approval remain release gates. Gemma native execution was demonstrated, while its grammar explanation correctly remained a template in the observed run.

The final normal (non-instrumentation) ARM64 debug APK was rebuilt, installed and cold-launched on the API 30 emulator after all integration checks. Android reported `Status: ok` and the app as the resumed activity; no AndroidRuntime errors were logged. Artifact: `apps/vaachak_app/build/app/outputs/flutter-apk/app-debug.apk`. This is a development build without production pack trust anchors or release signing.

## Phase 3 verification

The host suite passed **170 Dart/Flutter and 10 Python tests**, formatting, static analysis, content validation and release web compilation. PostgreSQL behavior checks, 12 pgTAP checks and the real PostgREST desktop integration passed. Android service integration, teacher approval/evidence/pin UI and learner consent/join/sync/revocation/erasure UI all passed. The final learner rerun passed after clearing a full disposable emulator overlay; its preceding build failure was disk exhaustion. Final analysis after the transfer batch selector was clean.

The supplied hosted Supabase project now contains both migrations. Each of dev/qa/prod has 29 tables with RLS enabled and 70 skill nodes; the expected seven Phase 3 RPCs were found. All three schemas are recognized by the Data API and reject anonymous class access with HTTP 401. SQL checks under the authenticated role returned zero visible classes without an assigned identity; joining execute permission was false for anon and true for authenticated. Hosted teacher provisioning/email OTP, optical QR scanning and cross-phone hotspot testing remain outstanding. See [Phase 3](PHASE_3.md) for logs, reproduction and limits.

Hosted `phase3.sql` and `security.sql` assertions subsequently passed with owner-authorized synthetic identities and rollback. Coverage includes enrollment/guardian approval, pairing scope, invalid-code rate limiting, cross-class denial, ingestion integrity, erasure and acknowledgement. Normal ARM64 APK and hosted-config release web builds passed; the APK installed and cold-launched successfully with no AndroidRuntime errors. No real email was sent or permanent test login provisioned.

## Phase 4 verification

`/tmp/phase4-full-checks3.log` passed **184 Dart/Flutter tests and 14 Python tests**, format checking, analysis, content structure validation and release web compilation. Totals: engine 64, content 5, store 11, packs 18, sync 8, explanation 8, speech 18, app 52. The two opt-in model/backend tests remain separately exercised harnesses, not included in the ordinary suite.

New coverage includes immediate/flexible update policy, deferred restart, recovery of accepted/downloaded updates, single-flight/disposal/failure handling; purpose-specific minor consent and persistent revocation/erasure; signed catalog installation, replay/expiry/tampering/version protection; catalog signing and production configuration checks. The regression suite caught an update inspection timer surviving widget disposal; cancellation was fixed, and both the full suite and the final 15-test update/widget rerun passed. Final analysis was clean (`/tmp/phase4-final-analysis.log`).

Android Phase 4 instrumentation passed twice; final log `/tmp/phase4-android-final.log`. It exercised real SQLCipher persistence, minor microphone consent refusal without evidence, withdrawal through the privacy UI, close/reopen, retained PIN access, queued core erasure, native installed-version lookup and actual Play-plugin failure on the sideloaded emulator build. Actual Store update completion is not demonstrated.

The current production gate intentionally fails (`verification/phase4-release-readiness.json`): production environment, CDN/trust anchors, privacy contact, Android release signing and curriculum approval are absent. This prevents interpreting engineering acceptance as production readiness. Phase 3's field checks remain deferred.

Final storage hardening reserves 500 MB beyond staging and installed bytes. The dedicated pre-download rejection check and complete pack suite passed (19 tests, aggregate Dart/Flutter count **185**). Emulator startup/idle memory evidence is in `verification/phase4-emulator-benchmark.json`: five Activity launches, median 1,245 ms, idle PSS 327,564 KiB. No AndroidRuntime errors were observed. This is a debug emulator result and is not reference-phone/model-loaded performance acceptance.

Phase 3 was reverified after Phase 4. Local SQL/pgTAP, desktop and three Android school flows, hosted security assertions and six anonymous API denials passed. A new fourth Android test passed native QR image decoding (100 events, three frames) and authenticated file transfer. See [the verification report](PHASE_3_VERIFICATION.md) for evidence and remaining real-email/physical-device checks.
