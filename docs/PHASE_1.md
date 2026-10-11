> Historical reference: the web and Android frontends and their build tooling have been removed. See the root README for current setup.

# Phase 1 — Core engine, persistence and learner UI

The **engineering checklist from the user's pasted four-phase roadmap is implemented and locally verified**. This is not a production-release certification. The separate prototype schedule in `VaachakAI.md` has a broader scope; its complete seven-skill experience and deployment gates are not implied by this milestone.

## Acceptance checklist

| Original Phase 1 requirement | Implementation and evidence |
| --- | --- |
| 60–80-node acyclic skill graph | 70 nodes, seven skills, prerequisites, difficulty/age metadata; missing-node and cycle rejection tests |
| Binary and graded BKT | Pure Dart posterior-mixture updates, per-node parameters, golden values and probability-invariant tests |
| Explainable top-five path | Mastery, relevance, recency, blocking and teacher weights; prerequisite gating, at most two nodes per skill; content availability applied before selection; localized one-sentence reasons |
| 40 grammar patterns and templates | Data-driven rules and 40 positive/negative fixtures; reviewed templates only in production; bundled draft material remains an educator-review gate |
| Drift + SQLCipher | Actual SQLCipher Community binaries selected by sqlite3's `source: sqlcipher` build hook; checked SQLCipher 4 runtime, v4 compatibility, memory wiping, WAL, full synchronous writes and integrity checks |
| Encrypted local PIN profiles | Random 256-bit database secret in secure storage; salted 210,000-round PBKDF2 PIN hashing, persistent lockout, guardian requirement for child profiles, no replacement key generated over an existing database |
| Append-only event log and replay | ULIDs, device sequence, HLC, transactions, immutable events, deduplication, replay-derived snapshots, export and irreversible erasure tombstones |
| Riverpod offline workflows | Provider-owned encrypted store and roster; notifier-owned active session; unlock, profile switching, progress notifications and lock; late PIN results cancelled after lock |
| Age-band theme system | Child: larger text/buttons and one-column simplified view; student: responsive study grid; adult: denser evidence and work-oriented framing; high-contrast palettes and 48–60 dp button minimums |
| Localized PIN selection and onboarding | English/Hindi profile picker, consent, age labels, PIN dialog/errors and creation form; UI locale follows the unlocked profile; picker preference saved locally |
| Learner dashboard | Seven independent skill summaries, unassessed state, evidence counts, weakest observed nodes, recommended activities, recent attempt scores and seven-day activity counts using the device's current time-zone offset |
| Durable learner practice | Every step gets a stable command ID; same-command retries count once; conflicting replies rejected; consent and unlocked state rechecked inside the transaction; cache-write failures cannot turn a committed answer into a second observation |
| Locking and navigation | Explicit lock, five-minute idle lock, background lock and consent-refresh lock; keyboard/pointer activity includes pushed learner routes; route stack cleared on lock |

## Important implementation choices

The earlier SQLite3MultipleCiphers compatibility backend has been replaced by SQLCipher Community. A preserved synthetic encrypted fixture proves that the new backend opens and extends the earlier v4-compatible database format. Wrong-key rejection and plaintext-absence checks still pass. No existing learner database is deleted or reset to perform this change. The native bootstrap checks SQLCipher using its [documented runtime PRAGMA](https://www.zetetic.net/sqlcipher/sqlcipher-api/#cipher_version).

The dashboard labels attempt counts as evidence. They are not calibrated statistical confidence intervals, and unobserved skills do not become fabricated weaknesses. Weekly counts exclude future-dated evidence; event replay retains deterministic HLC ordering.

Content titles, English exercises and educator-authored explanations remain English learning material. Phase 1 navigation, dashboard explanations, profile/PIN/consent forms, practice controls and grammar-coach chrome support English and Hindi. Full localization of later assessment, speech, pack, update and teacher screens remains broader-roadmap work.

## Verification and remaining release gates

See `VERIFICATION.md` for the executed suite. Phase 1 additions exercise provider progress notifications, offline PIN unlock, cancelled unlocks, profile isolation, consent withdrawal, save retries, legacy database compatibility, all three age layouts in both languages at 200% text size, high-contrast text colors, and the real app's profile → practice → background-lock flow with a temporary encrypted store.

These local tests do not replace Android compilation/instrumentation, secure-storage checks on a physical phone, TalkBack/manual visual review, native resource benchmarks, educator approval or legal review. The bundled curriculum is deliberately still draft and cannot pass the release content gate. No model assets, live school backend or release signing credentials were fabricated.

Listening, pronunciation and free-speaking assessments, assessment-based prior initialization, full initial-assessment onboarding, model evaluation, sync/pairing UI and production hardening are still tracked in `IMPLEMENTATION_STATUS.md`. They are not marked complete by this Phase 1 foundation milestone.
