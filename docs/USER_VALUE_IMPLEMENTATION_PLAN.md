# Vaachak: user value, retention and continuous learning implementation plan

> Status reconciliation — 15 October 2026: this is the original planning document, not a current feature inventory. Read [implementation status](IMPLEMENTATION_STATUS.md), [architecture](ARCHITECTURE.md) and [dated verification](VERIFICATION.md) first. Hosted Render/Neon/Vercel deployment and a signed Android APK are delivered. G1/G2 feedback and teaching knowledge are integrated; remaining roadmap acceptance and human evaluation are separate. Historical statements below such as “not implemented” describe the planning baseline.

Date: 11 October 2026. Status: proposed implementation backlog, not a completion report.

This plan extends `REACT_NATIVE_PRODUCT_PLAN.md` and the existing M.Tech project. Preserve the FastAPI service, SQLite data, six task types, attempt evidence, review policy, course/class workflows and isolated Expo app. Deliver improvements incrementally; do not replace the product. All new API names and tables below are proposed contracts until implemented and verified.

## 1. Product outcome and scope

The first audience is adult college students preparing for interviews, presentations and everyday workplace English. Teachers and placement trainers are the initial distribution partners. This is a product hypothesis to validate with interviews, not completed audience research.

The intended experience is: choose a practical goal → get one useful result → understand the next step → practise and retry → return for spaced revision → see credible improvement → continue into new situations without reaching a dead end.

“Continuous learning” means no curriculum-imposed finish line or compulsory daily stopping point. Learners can continue with reviewed practice, revision, deeper challenges and new scenarios. It does not mean infinite novel content, unlimited AI calls, guaranteed provider availability or unlimited storage. Disclose actual limits before they interrupt a session; preserve available low-cost practice when provider capacity is exhausted.

Success takes priority over feature count: reliable submissions, useful corrections, understandable next steps and voluntary return. Avoid unsupported accent, pronunciation or certified proficiency claims. Retain the existing distinction between task performance and demonstrated delayed skill evidence.

## 2. Verified starting point

| Area | Existing implementation | Remaining work |
|---|---|---|
| App | `apps/vaachak`: learner/teacher navigation, shared controls, responsive web, native recording | Release builds, Android visual checks, device/accessibility validation, navigation/deep-link alignment |
| Practice | `Player.tsx`, six task formats, typed/audio answers, feedback, retries | Guided first use, session resume, pre-evaluation transcript review, more useful feedback structure |
| Evidence | `evidence.py`, `insights.py`, history, delayed-success evidence, recommendations | Persisted review scheduling, goal mapping, clearer progress narratives and diagnostics |
| Teachers | `Classes.tsx`, `Composer.tsx`, `Courses.tsx`, reviewed AI drafts and follow-ups | Durable drafts, safer editing, archived-content discovery, simpler onboarding |
| Reliability | Submission UUIDs, immutable snapshots, pending-ID recovery, request logs and errors | Durable unsent/session state, new-workflow idempotency, async generation recovery |
| Lifecycle | Password change/reset backend, export/erasure, archive/restore routes | Self-service reset delivery, complete lifecycle UI and backup/retention policy execution |
| Operations | Containers, readiness, quotas, backup tooling, API artifacts | Real HTTPS deployment, scheduling, capacity/cost monitoring and signed mobile releases |

Recorded baseline: 143 backend tests, 12 frontend unit tests, 18 browser tests; 71 API operations checked. iOS Expo Go practice was verified; native signed builds and Android UI validation remain outstanding. These are historical verification results, not new test runs for this planning task. Consult the backend and frontend status reports for limitations.

Repository alignment issue: `apps/vaachak/AGENTS.md` requires Expo Router, while the current app uses React Navigation directly. Also, package scripts have no lint command. Resolve these in M0 with an incremental route-wrapper migration preserving feature components and a configured lint check. Read SDK-matched documentation before touching Expo APIs; do not hand-edit generated native directories.

## 3. Milestones and release order

Effort below is a planning range in engineer-weeks for one full-time engineer, excluding waiting for store accounts, content review and participant recruitment. Re-estimate after M0; approximately 19–29 engineer-weeks for the full scope. This is not a delivery-date commitment.

| Milestone | Effort | Depends on | Release gate |
|---|---:|---|---|
| M0 Reliability and device baseline | 2–3 | Existing app | Signed internal builds; critical journeys pass on iOS, Android and web |
| M1 First value, goals and measurement | 2–3 | M0 | New learner completes useful practice without teacher setup |
| M2 Trustworthy feedback and progress | 3–4 | M1 | Reviewed transcript/evidence semantics and feedback acceptance pass |
| M3 Continuous adaptive practice | 3–5 | M1, M2 | End-of-course continuation, deduplication and provider-outage tests pass |
| M4 Teacher productivity and content depth | 2–3 | M0; needed before broad M3 rollout | Durable drafts, reviewed goal paths and intervention workflow pass |
| M5 Return experience and low-connectivity support | 3–5 | M2, M3 | Resume, revision, reminders and bounded offline workflows pass |
| M6 Pilot, growth and operational release | 2–3 plus 4–6 calendar weeks observation | M0–M5 | Pilot findings resolved and operational release checklist signed off |
| M7 Guided conversation extension | 2–3 | M2, M3; after pilot stability | Reviewed scenarios, turn recovery, budgets and summary evidence pass |

M4 content preparation can start during M1 without blocking core engineering. Release a controlled pilot after M0–M4; use it to refine M5. M7 is part of this backlog but should not delay a sound M.Tech core submission. Broad acquisition follows reliability and useful-content evidence, not merely feature completion.

## 4. Detailed implementation backlog

### M0 — Complete and protect the existing experience

1. Build signed internal iOS and Android packages against a staging HTTPS API. Resolve Android disk capacity without deleting unrelated user data. Verify real microphone capture, denial/revocation, playback, backgrounding, interruption and lower-memory devices.
2. Keep the app folder isolated. Introduce route wrappers under `src/app/` following repository rules, reuse existing feature components and migrate navigation incrementally. Test back navigation, browser refresh and authenticated deep links. Add lint to local scripts and CI.
3. Add unsaved-change guards immediately. Persist session position and draft text with user ownership, expiry and a schema version. Audio retention must be explicit: opt-in draft retention, encrypted private storage where supported, bounded duration/size and reliable cleanup. Never place recordings in SecureStore or analytics.
4. Add archive filters/listing and restoration screens for courses, lessons, classes and assignments, reusing current restore and evidence deletion guards.
5. Finish password recovery: generic request response, single-use hashed expiring tokens, rate limits, configured delivery, safe deep links and invalid/expired token UX. Retain operator recovery for the bounded institutional deployment until delivery is configured. Test account enumeration resistance and token reuse.
6. Expose understandable recording retention controls and account export/erasure. Define default retention, cleanup jobs, active-draft exclusions and backup expiry. Deletion removes active data; backup handling must be disclosed accurately.
7. Extend existing structured request logs to new endpoints. Record request/trace ID, endpoint, status, duration and sanitized error code. Add job IDs and provider latency to background work; never log bearer tokens, raw speech, transcripts or passwords.

Acceptance: authentication, join, practice, recovery, teacher publishing, export/deletion and restore pass on all supported platforms; no cross-account cache/draft leakage; no duplicate attempt after response loss; no unsaved-work loss without a warning. Introduce stage-level flags so new behavior can be disabled while old data remains readable.

### M1 — First useful result, goals and audience understanding

1. Interview an initial 8–12 learners and 3–5 trainers across the chosen audience. Observe task completion; identify device/connectivity, language and confidence barriers. Treat findings as qualitative discovery, not representative market research.
2. Add a short goal picker: interview, workplace conversation, college presentation or everyday English. Ask optional explanation language and flexible weekly practice preference; allow later changes.
3. Provide a reviewed guest sample using local deterministic tasks before sign-up. Do not issue anonymous unlimited AI access. Offer optional sign-up after feedback; retain only non-sensitive guest progress and merge it once with explicit user choice. Clear guest data after expiry.
4. Add a skippable short starting assessment with varied reviewed tasks and a low-confidence/provisional result. Suggest a starting path; users can override it. Do not equate this small test to certified CEFR placement or voice-based proficiency.
5. Give Today one primary next action with purpose, estimated duration and a visible “Choose something else” option. Keep teacher onboarding separate: create class → invite learners → publish first reviewed activity.
6. Instrument first-value events from the outset, with the privacy rules in section 8. Add an accessible feedback/report entry point.

Acceptance: an unfamiliar learner can reach a useful sample result in a target of three minutes during observed testing; onboarding can be skipped/resumed; changing goals preserves history; no teacher invitation or course setup is required for learner first value. The three-minute target is a usability goal to measure, not a proven result.

### M2 — Fair feedback, assessment and credible progress

1. Rework feedback into: what worked, one priority correction, a concrete improved example and one retry action. Validate provider output against a typed schema; show a clear limited-feedback fallback when AI is unavailable.
2. Split new audio submissions into capture/upload → ASR preview → optional transcript correction → evaluation. Preserve the original ASR transcript, corrected transcript and origin separately. Reuse current attempt snapshots, versions and submission UUIDs on final evaluation.
3. Keep the current one-step submission route for compatibility. Add a proposed authorized transcription resource with expiry, ownership checks and idempotent creation. A confirmed transcript is learner-corrected text evidence; it must not be reported as independently recognized speech or acoustic proficiency. Never mutate old scored attempts when a transcript changes.
4. Retain post-result dispute controls. Disputed or otherwise invalid evidence must not advance skill estimates. Test the policy for both dispute and reversal, preserving an audit trail.
5. Add progress views based on comparable task/skill evidence: first versus later attempt, recurring errors, separate immediate retry from delayed transfer, and visible insufficient-evidence states. Avoid aggregating unlike rubric scores into a misleading proficiency number.
6. Persist due-review state derived from valid evidence. Start with a transparent versioned spacing policy, deterministic clock tests and bounded intervals. Immediate retries do not postpone due review as if durable learning occurred.
7. Calibrate the initial assessment and feedback rubric on reviewed examples. Conduct a consented human check of usefulness and transcription fairness before changing score semantics.

Acceptance: users understand the correction and can act on it; transcription edits are visibly distinguished; outdated task versions, duplicate submissions, disputes and retry chains preserve evidence integrity. Tests cover provider timeout, invalid output, silence, wrong-language input and inaccessible audio.

### M3 — Continuous adaptive learning without a curriculum dead end

1. Add a “Keep practising” action after every session and course completion. It offers another manageable batch, revision, a different scenario or a harder/easier challenge. Users can stop freely; daily goals never impose a hard stop.
2. Build a server-side next-session selector using goal, chosen difficulty, due review, valid skill evidence, accessible content and recent item history. Return short explainable reasons. Preserve class/course access and prerequisite rules; personal practice cannot expose private teacher material.
3. Prefer reviewed pool items first. Define target mixes of revision, transfer and exploration as versioned policy settings rather than hard-coded learning claims. Users can override topic/difficulty and skip an unsuitable activity without a penalty.
4. Add content fingerprints and exposure history. Avoid exact and near-duplicate items within a configurable recent window; do not count a paraphrase as independent skill evidence. If the pool is exhausted, offer clearly labeled purposeful revision or another topic rather than pretend it is novel.
5. Grow the pool through teacher-reviewed generation. Reuse the existing six-kind validators and `/api/ai/items` pipeline, but queue draft generation and review before publication. Controlled variations of approved templates can be introduced only with checked answers/distractors and versioned provenance. Never publish unchecked model output simply to maintain an endless feed.
6. Use bounded asynchronous generation jobs with persistent state, deduplication keys, retry limits, deadline, model/prompt provenance and a review queue. Do not generate on every Next tap. Reserve jobs transactionally and recover abandoned leases after restart.
7. Separate inference budgets from learning access. Reuse current quotas; add per-user/job concurrency caps, provider circuit breaking and global cost budgets. On quota/provider failure, offer reviewed deterministic activities, downloaded material or revision, explaining which AI/speech features are temporarily unavailable.
8. Reuse the existing submission pipeline for new sessions. Proposed personal practice items need an owned, authorized source type and immutable snapshot resolution; do not overload teacher assignment IDs or catalog IDs. Update attempt source validation, contracts and migrations together.

Acceptance: a learner finishing all accessible course content still receives a valid next option; repeated Next requests do not duplicate sessions or trigger uncontrolled generation; repeated answers do not inflate progress; pool exhaustion is honest; provider failure never yields invented feedback. Run a long synthetic sequence across small/large pools and restart mid-generation, measuring novelty, repetition, access correctness and cost.

### M4 — Teachers, content quality and useful classroom outcomes

1. Add server-backed teacher drafts with autosave status, schema validation, optimistic revision checks and explicit conflict recovery. Keep a local text fallback where appropriate; published lessons retain separate immutable revisions.
2. Seed four reviewed goal paths, each with beginner/intermediate entry options, prerequisites and a complete initial practice week. Set item-count targets from actual path design; do not bulk-generate hundreds of unchecked exercises.
3. Add a content checklist: clear objective, correct answer/rubric, useful explanation, language level, bias/stereotype review, skill label and realistic context. Provide report → triage → revise → retire/version workflow.
4. Simplify class invitation with shareable codes/links, preview and rotation. Explain instructor visibility before a learner joins.
5. Improve attention views around an actionable next step and workload prioritization. Reuse snooze/resolve/reopen and targeted follow-up; show later evidence, not automatic “resolved” claims after assignment creation.
6. Add bulk assignment preview with selection confirmation, accessible learner counts and authorization checks. Avoid unsolicited messaging to students.

Acceptance: closing/reopening the editor recovers drafts; concurrent edits cannot silently overwrite; unpublished content stays private; archived/restored material respects history; instructors can assign and inspect a follow-up without navigating through unrelated screens.

### M5 — Comfortable return, accessibility and limited connectivity

1. Create a weekly plan with optional reminders, timezone/quiet hours, pause and immediate opt-out. Request notification permission only after the learner chooses reminders. Use local reminders initially; introduce push delivery only with token lifecycle, scheduling and retry support.
2. Reward useful milestones without competitive pressure: completed real-life situations, returned practice and demonstrated delayed success. Offer forgiving streaks and never delete earned evidence after missed days.
3. Download explicitly selected reviewed lessons and reference audio with size estimates, revision manifests and storage limits. Separate “available offline” activities from those needing ASR/AI. Do not download an unbounded content pool.
4. Add a durable offline outbox only after session recovery is stable. States: draft → queued → uploading → awaiting result → completed/needs attention. Preserve UUIDs, ownership, task versions and order. Reconcile before replay; stop on expired auth, conflict, revoked access or changed tasks. Never silently upload a recording after consent is withdrawn.
5. Provide provisional deterministic offline feedback where supported; label it and avoid double-counting when synchronized. Provider-evaluated work remains pending until online.
6. Add localized interface strings and reviewed explanation translations for one pilot-selected language first. Keep the English practice objective clear; use human review for educational explanations.
7. Verify screen readers, font scaling, contrast, keyboard use, reduced motion, captions/transcripts and touch targets. Offer typed alternatives while clearly distinguishing what they measure. Extend empty, loading, offline and error states consistently.

Acceptance: resume after app kill, reconnect and token expiry do not lose or duplicate work; shared devices isolate cached data; logout/erasure cleans private drafts and downloaded private content; reminder disablement is immediate; DST/timezone changes do not cause notification bursts.

### M6 — Satisfaction, responsible growth and deployment

1. Add one-tap “Was this helpful?” and categorized issue reporting from feedback/lessons, with optional comment and contact permission. Link reports to content/version and request ID without attaching recordings by default. Provide operator triage and a visible acknowledgment.
2. Launch an initial 20–30 learner pilot with 3–5 teachers, recruitment and consent separate from product analytics. Observe first use and interview both returners and people who stop. Small cohort findings remain exploratory.
3. Compare retention by activation, goal, content availability and device category. Investigate dissatisfaction before increasing reminder frequency. Revisit the M.Tech study protocol for research claims and institutional approval where applicable.
4. Add useful acquisition surfaces after pilot stability: public reviewed samples, clear goal-specific landing content, teacher invitations and opt-in shareable achievements. Never share recordings, names or performance publicly by default. No fabricated testimonials or guaranteed fluency claims.
5. Deploy HTTPS staging then production; configure provider secrets, backups, restore drills, retention jobs, alerts and support procedures. Signed builds must use production endpoints with no debug credentials. Run dependency/security checks and document unresolved risk.
6. Stay with a single-instance SQLite deployment for the measured academic cohort. Before wider promotion, load-test actual mixed traffic including audio, generation and content writes. Migrate to a server database/shared media store and a dedicated queue only when measured capacity and deployment topology require it; SQLite files must not be shared casually across replicas.

Acceptance: release health dashboards, rollback instructions, quota/cost alarms and tested restore exist; critical user reports have an owner; public promotion is gated on pilot issues and operational capacity.

### M7 — Guided real-life conversation

Start with three reviewed text/turn-based scenarios: interview introduction, asking for clarification at work and presenting a project. Allow audio input through the same transcription-confirmation flow. Add short follow-up questions, hints, a visible finish action and a focused summary.

Persist session/turn IDs, scenario/rubric versions and idempotent turn submission. Bound turns, context size, latency and inference budget; longer learning continues through a fresh session. Keep conversational memory scoped to that session unless the user explicitly saves a preference. Provide reviewed fallback prompts on provider failure.

Summaries must distinguish conversation participation from formally evaluated task evidence. Do not automatically feed model impressions into skill mastery; define reviewed mappings and validate them first. Test interrupted turns, retry duplication, irrelevant input, unsafe/inappropriate generated content and expired access. Streaming/real-time voice is a later optimization, not required for this milestone.

## 5. Proposed implementation boundaries

| Existing area | Incremental additions |
|---|---|
| `apps/vaachak/src/features` | Onboarding, goals, assessment, continuous practice, transcript confirmation, draft recovery, feedback reports, downloads and conversation features |
| `apps/vaachak/src/app` | Thin Expo Router route wrappers; shared feature components stay outside routes |
| `src/api`, providers, shared controls | Generated contracts, typed errors, durable-state abstraction, auth isolation, queue state, localization and accessible status components |
| `classroom_web/server/operations.py` | Existing lifecycle extensions: reset request, archive discovery, preferences and privacy |
| `evidence.py`, `insights.py`, `feedback.py` | Versioned review policy, explicit transcript origins, comparable progress and feedback schema |
| New backend modules | Goals/assessment, sessions/review scheduling, transcription staging, draft management, generation jobs, reporting/metrics; keep `main.py` focused on composition |
| `migrations.py`, contracts, tests | Ordered additive migrations, typed new contracts, source validation, authorization and regression coverage |
| Deployment/CI | Worker process when introduced, readiness/cost metrics, scheduler, signed-build gates, browser/native checks |

Do not rewrite old migrations or infer missing legacy skill/provenance values. Add a migration runner that applies ordered versions, test upgrading real schema snapshots and preserve current data. Before rollout take a verified backup. Prefer forward-compatible readers and feature rollback; destructive schema rollback requires a tested restore plan.

## 6. Proposed API and data contracts

Routes below use the existing `/api` prefix. Reuse existing preferences, attempts, submission status, course, class and lifecycle routes where adequate; do not create duplicate endpoints simply to match this table.

| Capability | Proposed contract | Durable state / important invariant |
|---|---|---|
| Goals and assessment | `GET/PUT /me/learning-profile`; `POST /assessments`; `POST /assessments/{id}/complete` | Goal selections, assessment/version/result; owned and idempotent completion |
| Next practice/resume | `POST /me/practice-sessions`; `GET/PATCH /me/practice-sessions/{id}` | Session revision, item snapshots, cursor and reasons; optimistic concurrency and UUID |
| Due revision | `GET /me/review-queue` | Per-skill/item schedule with policy version; recomputable from valid evidence |
| Transcript preview | `POST /transcriptions`; `GET /transcriptions/{id}`; final attempt references ID and optional corrected text | Private expiring upload, original ASR and edit provenance; no double evaluation |
| Draft autosave | `POST /teacher/drafts`; `GET/PATCH/DELETE /teacher/drafts/{id}` | Owner, draft type, payload, revision, expiry; conflict response rather than overwrite |
| Reset delivery | `POST /auth/password-reset-request`; reuse reset completion | Generic acknowledgment; bounded delivery attempts and single-use token |
| Archive discovery | Existing list endpoints accept authorized archive filter | Existing archive state; same ownership/access rules |
| Generation jobs | Teacher/operator enqueue/status routes; learner session selector consumes approved pool | Job lease, attempts, budget, failure reason, review state and deduplication key |
| Reports/analytics | `POST /feedback-reports`; bounded `POST /events` | Report workflow; allowlisted minimal events with deletion/retention policy |
| Offline manifests | Authorized lesson download manifest endpoint | Version/checksum/size; access expiry and synchronization rules |
| Conversation | `POST /conversations`; `POST /conversations/{id}/turns`; complete/read routes | Ordered turns, budgets, rubric/version, ownership and idempotency |

Additional tables are introduced only per milestone: learning profiles/goals, assessment sessions, practice sessions/items, exposure history, review schedule, transcription resources, drafts, generation jobs/reviewed pool, reports and minimal events, conversation sessions/turns. Reuse existing items, attempts, courses and skills where possible. Index owner/status/due-time queries. Define retention and cascade behavior before each migration.

Every endpoint requires explicit auth/role checks, constrained payloads, pagination where applicable, stable error codes, request IDs, and log redaction. Expensive mutations need idempotency, budgets and restart semantics. Update OpenAPI, operation registry, generated types, Postman collection and examples in the same change.

## 7. Testing and release gates

- Preserve baseline backend, contract, unit and browser checks. Add tests for behavior and failure boundaries rather than component implementation details.
- Contract/migration: old client compatibility, legacy data upgrades, rollback/restore, source authorization and unknown extension fields.
- Learning policy: deterministic clocks; delayed versus immediate retries; disputed/corrected transcripts; evidence scarcity; repeated/near-duplicate content; goal changes and exposure history.
- Resilience: offline transitions, killed client/worker, response loss, simultaneous requests, expired login, stale item revisions, provider 429/5xx, malformed feedback and quota exhaustion.
- Media/privacy: silence, invalid/oversized audio, interruptions, storage cleanup, permission denial, account switching, erasure and absent sensitive log/event payloads.
- Native: internal signed builds on iOS/Android plus real-device microphone checks. Web mobile emulation is not Android native evidence. Include screen reader and large-text/manual acceptance.
- Performance: measure API and end-to-end feedback latency separately; test mixed production-like workloads at expected concurrency. Set SLOs from staging measurements and show progress/cancel/recovery during long operations. Never reuse prior read-load results as proof of ASR/generation capacity.
- Release each milestone behind a flag to a small cohort, inspect errors and feedback, then expand. Keep evidence in `docs/verification/` with no secrets or personal speech.

## 8. Measurement and pilot decision rules

Primary outcome: weekly learners completing at least one useful practice-and-feedback cycle. Supporting measures are activation, feedback helpfulness, successful submission rate, D7/D30 return, completion of delayed revision, teacher follow-up completion, crash-free sessions and provider cost per useful cycle.

Define activation as first valid practice plus feedback viewed; guest samples and authenticated activation are separate funnels. Define D7/D30 return windows before analysis, state denominators and report cohort sizes. Exclude synthetic tests and staff. Do not use time spent alone as a learning metric.

Collect only allowlisted events such as onboarding_completed, practice_started, feedback_viewed, retry_completed, review_completed and report_submitted. Never include raw audio, transcripts, answers, tokens or contact details. Use pseudonymous IDs, coarse device categories, bounded retention and access controls. Separate optional product analytics from research consent; honor deletion and explain necessary operational logging separately.

Provisional pilot goals: at least 80% of observed participants finish first practice without help, at least 80% of feedback ratings are useful, and at least 99% of supported submissions complete or offer a recoverable outcome. These are decision targets, not measured promises. Establish baseline retention before choosing a D7/D30 improvement target; report uncertainty and qualitative explanations in a small cohort. Any severe privacy/data-loss defect blocks rollout regardless of averages.

## 9. Immediate execution queue

1. M0: resolve native testing capacity, create internal builds, align routing/lint and verify platform parity.
2. M0: ship unsaved-change guards/session recovery and archive discovery; specify reset delivery and retention configuration.
3. M1: interview the initial audience, finalize the first goal path and implement goal-based onboarding plus reviewed guest sample.
4. M1/M2: add minimal event/report capture, structured feedback and transcript-confirmation contracts.
5. M4: begin content review and durable draft work alongside the learner foundation.
6. M2/M3: implement persisted review scheduling and the first continuous session selector using reviewed material only.
7. M3/M5: introduce bounded generation/review jobs, offline downloads and opt-in reminders after recovery invariants pass.
8. M6/M7: run the pilot, fix observed friction, then expand acquisition and guided conversation.

No implementation is claimed by this document. Completion means working code, appropriate tests, accessible UX, updated contracts/runbooks, observed user acceptance and deployable artifacts—not merely adding endpoints or screens.
