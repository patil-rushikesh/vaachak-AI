> Historical reference: the web and Android frontends and their build tooling have been removed. See the root README for current setup.

# Reviewed reading checks

Reading is now an assessment activity in the seven-skill overview. It shares the existing per-skill staircase, event replay, exact-rung selection, no-repeat IDs and transactional completion. The reading coach also loads passages from the content bank instead of keeping its own hardcoded text.

## Passage contract

Content packs may contain `passages.json`, covered by the pack's signed file manifest. Each entry contains:

- `id`, positive `version`, reading `nodeId`, `title`, `text`, `cefr`, `difficulty` (0–4) and `ageBands`.
- `targetWcpm`: a positive, finite educator-reviewed pace target, at most 300. Different age targets require age-specific passage entries.
- `assessmentModelIds`: exact signed speech-pack identities such as `school.asr@1.0.0`. Approved passages require at least one version. These versions must be evaluated with the rubric before an educator approves the passage.
- `reviewStatus`, `reviewer` and `reviewedAt`. Draft or incompletely approved passages cannot enter an assessment.

Text is bounded to 500 normalized words and 10,000 characters. The loader rejects non-reading nodes and duplicate passage identities. The pipeline's release coverage checks use passages for reading nodes. Review CSV export/import includes passage text, scoring target, model versions and eligibility together; a changed rubric invalidates an exported review.

The one bundled passage remains a **draft**. Its target is a development fixture, not a calibrated age norm; its model allowlist is empty. `ALLOW_DRAFT_CONTENT` permits it in the coach only. It never enables draft assessment scoring.

## Capture and scoring

The check requests microphone consent separately from core learning consent, including the existing guardian-witness reference for minors. A declined or unavailable microphone leaves the passage unanswered. A matching verified speech pack is required before capture. Coaching playback is hidden during assessment.

Audio stays in a bounded PCM memory buffer. Signal-quality gates reject silence, clipping and inadequate signal-to-noise ratio. Reading assessment additionally requires at least two seconds and a nonempty recognition result. Backgrounding or leaving the route invalidates pending capture/recognition; buffers are cleared and late results do not enter the assessment. Resources that finish opening after cancellation are disposed.

The versioned `wordAccuracyTimesPaceV1` policy computes:

`score = wordAccuracy × min(1, wordsCorrectPerMinute / targetWcpm)`

This is an ASR-derived word-accuracy and pace estimate. The reviewed model version and target are part of the assessment pool digest, along with the policy version and learner age band. Pack/rubric changes pause resume. The existing staircase counts scores of at least 0.7 as correct.

Only numeric score, accuracy, WCPM, correct-word count, duration, signal metrics, capture ID, model ID and policy ID accompany the standard item/run event fields. Recordings, recognized words and error hypotheses are excluded from assessment events. Per-node mastery uses the existing BKT fold on device and server.

## Saving and recovery

Scoring produces an immutable numeric result before audio is cleared. Saving rechecks both core and microphone consent. A failed write offers **Retry saving result**, retaining numeric evidence in memory. Retrying a committed capture does not count twice. The final answer and completion marker commit in one transaction.

An app restart resumes after the last committed passage. If a result never committed, the passage remains unanswered and must be recorded again; numeric evidence awaiting retry is not a durable spill queue.

## Verification and remaining gates

Synthetic tests cover accuracy/pace grading, silence/short/empty-input rejection, model-version gating, consent revocation, write failure and retry, encrypted database reopen, six-response completion and changed rubrics. The widget test verifies passage rendering, hidden coaching playback and declining consent without an answer. Content and Python tests cover schema constraints and rubric-bound review.

No real microphone, ASR model, Android build or reference-phone performance run was available. Production needs educator-approved coverage, evaluated speech models and device validation. The current ASR adapter lacks calibrated word confidence and word timings; phoneme-level pronunciation, prosody and comprehension are not established by this reading score. Listening, pronunciation and free-speaking assessment flows, age-band/final-staircase prior seeding and the complete initial-assessment timing target remain unfinished.
