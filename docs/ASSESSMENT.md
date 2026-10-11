> Historical reference: the web and Android frontends and their build tooling have been removed. See the root README for current setup.

# Resumable assessment checks

The learner dashboard opens **Start or resume skill checks**. The overview shows all seven skills independently. Vocabulary, grammar and sentence formation currently support reviewed choice questions. Reading supports reviewed passages and approved speech-pack versions through the read-aloud route; see `READING_ASSESSMENT.md`. Listening, pronunciation and speaking remain unavailable.

The bundled 15 draft questions and one draft passage cannot start an assessment, including in `ALLOW_DRAFT_CONTENT` builds. An installed, reviewed bank must contain questions at the middle difficulty (rung 2, displayed as level 3). Tests use synthetic approved fixtures only; no bundled material was marked educator-approved.

## State and selection

`SkillAssessment.fold` reconstructs each skill's latest run from learner-scoped events, deduplicated by ID and ordered by HLC/ID. Erasure dominates the history. The run belongs to the device that created it. Imported history can be displayed, but continuing on another device requires a new run so two devices cannot append competing steps to the same run.

`AssessmentStarted` records protocol 1, skill, age band, initial difficulty and a SHA-256 digest of the eligible question pool. Selection is deterministic: exact requested difficulty, stable item-ID order, newest approved version per ID, no repeated question IDs. The eligible pool respects both node and item age bands. Changes to question wording, scoring, versions, eligibility or pool membership invalidate resume; the screen explains how to restore the original pack or start a new check. Incomplete histories are retained when a new run starts.

Each answer records run ID, zero-based ordinal, skill, item ID/version, node, difficulty, selected option and score. The staircase moves up for scores at least 0.7 and down otherwise, bounded to rungs 0–4. It ends at eight answers, or from answer six when the last four responses alternate. Missing questions pause the check without changing its difficulty or reporting completion.

## Durability and retry

The controller reads history, rechecks core consent, validates the displayed run/question and appends inside one database transaction. The final answer and `AssessmentCompleted` marker commit together. Repeating the same run/ordinal/item/choice is a no-op; a conflicting answer is rejected. Completion is derived from answers, never trusted from the marker alone.

The screen advances only after the write and history refresh succeed. If refresh fails after commit, Retry replays the original command safely. Reopening the encrypted database restores the next unanswered step. No audio or free-form learner response is added to assessment events.

## Remaining assessment work

Text checks and the reading-check flow are implemented, but the complete initial assessment specified in §6.1 still requires reviewed curriculum coverage, evaluated speech models, listening/pronunciation/free-speaking activity schemas and the remaining three learner flows. Assessment answers currently update the same per-node BKT fold on device and server; calibrated age-band/final-staircase prior seeding is not implemented. Practice is still accessible independently; a mandatory seven-skill onboarding gate and the under-20-minute device benchmark remain future work. Assessment UI copy is currently English.

Tests cover encrypted restart, exact-rung exhaustion, six/eight stopping, non-repetition, duplicate/concurrent submission, rollback on a failed completion write, changed packs, stale runs, consent revocation, unsupported modalities, foreign items, event ordering, invalid sequences and erasure.
