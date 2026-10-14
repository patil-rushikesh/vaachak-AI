> Historical Flutter/Dart/Supabase record, retained on 15 October 2026. Statements below describe that implementation and its original verification dates, not the current Expo/FastAPI release. Some referenced app paths no longer exist. See [current implementation](IMPLEMENTATION_STATUS.md) and [current architecture](ARCHITECTURE.md).

> Historical reference: the web and Android frontends and their build tooling have been removed. See the root README for current setup.

# Implementation status and release gates

The codebase contains working implementations across all requested package boundaries. **The requested end-to-end production platform is not complete.** Tests establish the behaviors they cover; they do not establish the specification's complete functionality or non-functional targets.

## Phase 1 foundation milestone

The engineering checklist for **Phase 1: Core Engine, Persistence & Learner UI** in the pasted roadmap is implemented and locally verified. See `PHASE_1.md` for the requirement-by-requirement evidence and scope. This does not complete the broader prototype schedule or remove the external release gates below.

## Phase 2 on-device AI milestone

The speech, signed model-pack and local explanation workflows are implemented. The host suite passed 165 Dart/Flutter and 10 Python tests; Android build/installation and real desktop/Android Whisper/Piper integration passed. Android Gemma native inference/template-first fallback and offline profile/PIN/grammar/background-lock instrumentation also passed. Phase 2 engineering and emulator checks are complete. See `PHASE_2.md` for the checklist, reproducible native tests and remaining release gates. Emulator acceptance does not establish physical-phone performance, real microphone accuracy or production model approval.

## Phase 3 school synchronization milestone

Class joining, consent-aware foreground synchronization, teacher approval/evidence/interventions and encrypted offline transfers are wired into the app. Real PostgreSQL/PostgREST service checks passed on desktop and Android; learner and teacher Android UI tests passed. Both migrations and protected API schemas are deployed to the supplied Supabase project; hosted synthetic SQL checks passed; real school/account onboarding and OTP acceptance remain. See `PHASE_3.md` for evidence and limits.

## Phase 4 updates and privacy hardening milestone

Recoverable Play update flows, explicit flexible-update restart, signed/expiring CDN catalog discovery, replay protection, overlapping pack trust keys, actual installed-version compatibility, purpose-specific consent withdrawal and a fail-closed release preparation gate are implemented. The host suite plus final storage-reserve regression passed 185 Dart/Flutter and 14 Python tests; native Phase 4 consent/persistence/erasure/update-fallback acceptance passed. See `PHASE_4.md`. Actual Play delivery, production school configuration/content approval and physical-phone acceptance remain release gates. Phase 3 was reverified after Phase 4; real inbox and physical-device checks remain. See `PHASE_3_VERIFICATION.md`.

## Implemented

- 70-node acyclic graph spanning seven skills; prerequisites, five difficulty rungs, BKT binary/graded updates, ranking and one-sentence factors, skill-diversity limits, multi-teacher pin precedence, staircase and ladder algorithms.
- 40 conservative grammar pattern rules with positive/negative fixtures. A narrow regex taxonomy is implemented; the broader POS/lemma tagger described in the design is not.
- Weighted phonetic-fallback word alignment, omissions/substitutions/repetitions/hesitations from provided timestamps, WCPM, one chosen correction. The current ASR adapter does not fabricate missing confidence or word times.
- Drift with actual SQLCipher Community encryption and verified compatibility with the earlier v4-format database, 210,000-iteration salted PBKDF2 PIN hashes, lockout, device-scoped sequences, HLC, ULIDs, immutable events, snapshots derived from replay, atomic imports, export and erasure tombstones.
- Learner profile creation/unlock, separate minor flag, witnessed-consent reference, localized English/Hindi onboarding, dashboard and practice controls, distinct child/student/adult layouts, high-contrast palettes, duplicate-safe saved practice attempts, grammar templates, learner export/erase, background/inactivity locking.
- Riverpod-owned encrypted-store, roster and active-session state; stale-unlock cancellation, profile isolation, consent-refresh locking, evidence-based weaknesses and recent progress, and content-aware top-five selection.
- Resumable reviewed-choice assessment checks for vocabulary, grammar and sentence formation; seven-skill availability screen, exact-rung selection, six/eight-item stopping, transactional completion, idempotent retries and question-pool change detection. See `ASSESSMENT.md`.
- Reviewed passage schema, signed-pack loading and rubric-bound educator review; read-aloud assessment using approved model versions, word accuracy/pace scoring, microphone consent recheck, numeric-only evidence and safe save retry. See `READING_ASSESSMENT.md`.
- In-memory PCM capture and clearing, sherpa ASR and Piper-compatible VITS TTS adapter, background worker, quality gates, capped recording and text fallback after failure; native memory-only playback.
- Signed pack folder/CDN installation, native device tiers, capability refresh, resumable file streams with checked HTTP Range responses, exact signed file sets, runtime-schema validation, digest verification, atomic activation and verified rollback, installed content-bank loading and runtime model configuration.
- Verified Tier A Gemma/LiteRT-LM activation wired into the grammar coach as explicit optional local rewording; strict JSON/length/corrected-form checks, safety screening, reviewed practice-only output, template-first six-second fallback, child disablement, lifecycle cancellation and idle disposal. Speech and explanation share a resource lease.
- Encrypted `.vbundle` codec and file utilities, systematic fountain QR encoder/decoder, bounded LAN receiver, HTTPS event sender and consent-filtered retrying sync queue.
- Supabase dev/qa/prod tables, monthly partitions, identity registry, least-privilege policies, ingestion with authoritative consent checks, deterministic BKT fold, teacher interventions, evidence-based insight queries, export, erasure and maintenance SQL.
- Teacher portal email OTP flow, RLS-backed class/learner queries, observed mastery, evidence drill-down and approve/reject/pin/assign controls. Backend provisioning is required.
- Play update service (flexible routine updates; immediate for explicit migration policy or Play priority >=4), release-signing enforcement, dependency lockfile, CI, unit/contract/widget/SQL/pgTAP checks, Android integration test and benchmark helper.

## Engineering still required before the roadmap is complete

1. **Full assessment and curriculum:** the app now orchestrates resumable reviewed-choice checks for three skills plus a read-aloud reading-check flow, with all seven shown independently. The complete seven-skill, 20-minute initial assessment still requires listening/pronunciation/free-speaking modalities, evaluated reading models and rubrics, age-band/final-level prior seeding and mandatory onboarding gating. Practice and coaching remain independently available. Listening, free speaking, picture vocabulary and phoneme-model activities are not implemented as complete learner journeys. The bundled reading passage remains draft and disabled in production; reviewed passages and exact approved model versions are now supported by the schema/loader and assessment flow.
2. **Content production:** 15 draft questions and one draft passage do not replace the required 1,500 items, 300 passages, 2,000 vocabulary assets and 150 listening clips. All 40 rule explanations also need educator review, richer adversarial fixtures, and stronger linguistic matching.
3. **School deployment and field validation:** the Phase 3 app flows are implemented and tested against real local PostgreSQL/PostgREST. Hosted configuration and account provisioning, physical camera QR scanning and transfers between separate phones remain deployment/field checks. Foreground sync runs on resume and every 60 seconds; OS background scheduling is not implemented.
4. **Speech validation:** development-only signed model fixtures and native smoke harnesses now exist outside the repository. Desktop and Android Whisper/Piper inference passed with the synthetic speech fixture, including Android playback/stop and encrypted numeric evidence. This does not establish real microphone accuracy. Actual supported token intervals are merged into words, with ambiguous or missing timings left untimed. No real recorded speech corpus is bundled. Contextual biasing, calibrated confidence, full number expansion, a pronunciation lexicon/G2P, frequency/taxonomy correction weighting and phoneme-level pronunciation remain incomplete. Shipping model compatibility and speech quality need Android/reference-phone evaluation.
5. **Explanation evaluation:** learner UI, verified explainer activation and shared runtime arbitration are connected. An authorized signed Gemma 1B fixture produced actual text on Android. Its explanation request retained the reviewed template; no validated model-generated grammar explanation was accepted in that run. Model quality, licensing/distribution review and representative-device performance remain release gates. No claim of hallucination-proof validation is made.
6. **Reliability:** storage failures report that an attempt was not saved and allow retry. An automatic bounded memory spill queue, crash-resume orchestration for activities beyond the new assessment checks, nightly encrypted backups/corruption recovery, schema-upgrade fixtures, remote unlink and consent evidence correction still need work. Purpose-specific withdrawal UI is implemented.
7. **Security and operations:** TLS certificate/SPKI pinning and rotation, production school release keys, audit retention enforcement, access auditing, observability and authenticated diagnostics remain required. Pairing keys, signed offline teacher interventions, rate-limited joining and erasure acknowledgements are implemented. Guardian reference entry is not cryptographic identity verification; offline revocations take effect on refresh or cache expiry.
8. **Scale and performance:** no phone RAM, ASR/TTS latency, thermal, battery, cold-start or 500-event ingestion benchmark has passed. Full-history server replay is a correctness baseline and must be optimized with tested checkpoints/compaction. The 1M learner claim is not established.
9. **Accessibility and localization:** no TalkBack/manual contrast audit has been completed. Phase 1 UI now covers English/Hindi onboarding, dashboard, practice and grammar-coach controls, with distinct age layouts tested at 200% text size. Full localization of later assessment, speech, teacher, pack, update and error screens remains required.

## External gates

- Android SDK and an ARM64 API 30 emulator are installed. APK compilation/installation and native speech/playback/encrypted-evidence integration passed. Gemma native inference/safe fallback and the complete offline profile/PIN/grammar/background-lock test passed; physical reference-phone acceptance remains outstanding.
- Shipping ASR, TTS and optional Gemma model approval, applicable licensing/distribution review, per-model calibration and a consented evaluation corpus. Development-only fixtures do not satisfy these release gates.
- Educator approval and adequate content coverage. The release validator deliberately fails for the bundled drafts.
- Supabase project/client configuration, school records, authenticated device bindings, guardian verification and purpose-scoped consent provisioning.
- Release signing keys and school pack trust anchors, plus an approved rotation process.
- Legal review of the deploying organization's DPDP obligations and consent process. This implementation is not a legal compliance certification.

## Verification evidence

The final check results are recorded in `docs/VERIFICATION.md`. The teacher web build can be compiled without live credentials. The local HTTP server was reachable with HTTP tools, but the available in-app browser timed out on the localhost preview; visual browser QA was not completed. Widget tests cover safe initial/error states, all six age/language dashboard combinations at 200% text size, consent refusal and offline profile-to-practice-to-lock navigation. CI was authored locally and has not run on a remote GitHub repository.
