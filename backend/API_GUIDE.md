# Vachak backend integration guide

Base URL for this machine: `http://127.0.0.1:8000`. The implemented teacher/student web interface is at `/`; interactive request documentation is at `/docs`, and OpenAPI at `/openapi.json`. The API also works independently of the interface. Final browser acceptance testing is in progress.

## Authentication

1. Teacher: `POST /auth/register` with `{"email":"teacher@example.test","password":"a-long-private-password"}`. Password length is 12–256 characters.
2. Sign in: `POST /auth/login` with `{"identifier":"teacher@example.test","password":"...","role":"teacher"}`. Students use their teacher-provisioned username and `role:"student"`.
3. Save `access_token` securely on the client. Send `Authorization: Bearer TOKEN` on private requests. Tokens expire after 8 hours; `/auth/me` returns the identity/role, and `POST /auth/logout` revokes the token.

Teachers can access only their own students/content; students can access only their assigned work and own attempts. Knowledge of an ID, postal PIN or classroom join code grants no access. Student self-enrollment is not implemented.

## Teacher creates and assigns practice

| Operation | Route | Body / behavior |
| --- | --- | --- |
| Create classroom | `POST /teacher/classrooms` | `{school_name,name,postal_code}` |
| List classrooms | `GET /teacher/classrooms` | Includes student counts and a separate join code |
| Classroom roster | `GET /teacher/classrooms/{id}` | Classroom and enrolled students |
| Provision student | `POST /teacher/classrooms/{id}/students` | `{display_name,login_name,password}`; globally unique lowercase username, password 8–256 characters |
| Reset student password | `PATCH /teacher/students/{id}/password` | `{password:"new-private-password"}`; 8–256 characters, returns 204; owning teacher only, revokes all student sessions and preserves learning records |
| Create problem | `POST /teacher/problems` | `{title,kind,expected_text,teaching_notes?,payload}`; formats below |
| List / inspect problem | `GET /teacher/problems`, `GET /teacher/problems/{id}` | Teacher receives full content and answer keys |
| Upload reference | `POST /problems/{problem_id}/recordings` | Multipart field `file`; read-aloud only |
| List references | `GET /problems/{problem_id}/recordings` | Immutable recording IDs, metadata, experimental `measurements.pitch` evidence for newly uploaded references, and private playback URLs |
| Assign | `POST /teacher/assignments` | See example below |
| List / inspect assignments | `GET /teacher/assignments`, `GET /teacher/assignments/{id}` | Recipients, attempts and completion evidence |
| Review attempt | `PATCH /teacher/attempts/{id}/review` | `{score:0.75,feedback:"..."}`; score 0–1, feedback required |
| Student progress | `GET /teacher/students/{id}` | Status, attempts, saved evidence, reviews and skill summaries |
| Dashboard | `GET /teacher/overview` | Counts, recent activity and review queue |

Problem examples (all also require `title`):

```json
{"kind":"read_aloud","expected_text":"Okay, this is my house.","teaching_notes":"Pause after Okay.","payload":{"expression":"Welcoming"}}
```

```json
{"kind":"choice","expected_text":"Choose a synonym for happy.","payload":{"options":[{"id":"a","text":"Joyful"},{"id":"b","text":"Sad"}],"correct_option_id":"a","skill":"synonym"}}
```

```json
{"kind":"matching","expected_text":"Match the opposites.","payload":{"pairs":[{"id":"hot","left":"Hot","right":"Cold"},{"id":"early","left":"Early","right":"Late"}],"skill":"antonym"}}
```

```json
{"kind":"meaning","expected_text":"What does 'lend me a hand' mean?","payload":{"accepted_answers":["Please help me"],"rubric":"Understand that the speaker asks for help."}}
```

Choice/matching allow 2–12 cards with unique IDs/text. `skill` is `synonym`, `antonym` or `vocabulary`. Meaning requires 1–20 accepted answers. Complete size constraints are in `/docs` and the API validators.

Assignment example:

```json
{
  "request_id": "GENERATE-A-UUID",
  "title": "Today's English practice",
  "classroom_id": "CLASSROOM-UUID",
  "problems": [
    {"problem_id":"READING-PROBLEM-UUID","recording_id":"REFERENCE-UUID"},
    {"problem_id":"CHOICE-PROBLEM-UUID"}
  ]
}
```

Use exactly one of `classroom_id` or `student_id`. Read-aloud requires a stored reference belonging to that problem. Assignments freeze the selected content, references and current recipients. Students added to the class later need a new assignment. An assignment has 1–50 distinct problems. Supplying a UUID `request_id` prevents duplicate assignments on retries; reusing it with changed content returns 409.

## Student completes assigned work

- `GET /student/overview` and `GET /student/assignments` show the student's work and progress.
- `GET /student/assignments/{id}` returns problem items, prior attempts and reference playback URLs. **Each returned problem's `id` is an assignment-item UUID. Use that `id` in submission routes.** Its `problem_id` identifies the reusable library problem.
- Student responses exclude answer keys, accepted meanings and private rubrics. Matching cards have independently generated IDs and shuffled right-side order; submit the IDs returned for that assignment.
- For choice, matching or meaning: `POST /student/assignments/{assignment_id}/problems/{item_id}/attempts` with `{"request_id":"UUID","answer":...}`. Choice answer is an option ID; matching is `{left_id:right_id}` with every card matched once; meaning is nonempty text up to 5000 characters.
- For reading: `POST /student/assignments/{assignment_id}/problems/{item_id}/recordings`, multipart fields `file` and `request_id`.
- Keep the same request UUID and identical payload when retrying after a lost connection. A new deliberate attempt needs a new UUID. Upload retries are compared using the original audio checksum.
- Poll `GET /student/attempts/{id}` while status is `pending`. `POST /student/attempts/{id}/retry-analysis` retries `failed` or `needs_review` reading/meaning analysis without creating another attempt. Teacher-reviewed or completed attempts cannot be reanalyzed.
- Private reference/attempt audio URLs require the same bearer header. Fetch as an authenticated blob before setting an HTML audio source; never place tokens in query strings.

## Assessment and progress meaning

| Status | Meaning |
| --- | --- |
| `pending` | Submission is stored in the durable local queue; analysis is waiting or running, and resumes after process restart |
| `completed` | Deterministic/experimental analysis or teacher review completed |
| `needs_review` | Saved work needs teacher judgment; unavailable/busy/uncertain models do not create fake grades |
| `failed` | Analysis or its output failed validation; original answer/audio is retained and can be retried |

Choice uses the answer key. Matching awards the fraction of correct pairs. Exact teacher-accepted meanings are matched automatically; other meanings can receive AI suggestions visible only to the teacher. Students receive the teacher-confirmed feedback and score after review. Teacher feedback/score takes precedence over late analysis, and review history is retained separately from automatic evidence.

Reading scores are **experimental transcript word-match estimates**, with pace and comparable pause evidence. Experimental pitch contours are separate evidence and never alter the score. No pronunciation, pitch, emotion or language-proficiency grade is produced. A teacher review can replace the displayed practice score; preserve the distinction between that judgment and the original automatic measurements.

### Pitch evidence contract

New teacher reference uploads include `recording.measurements.pitch`; student analysis includes `attempt.result.pitch`. Older reference recordings can be analyzed during student/reference comparison. Pitch extraction uses a custom NumPy YIN-style estimator (`algorithm_version: "yin-cmndf-v1"`), not librosa pYIN. [The pYIN documentation](https://librosa.org/doc/0.11.0/generated/librosa.pyin.html) is a research reference for the separation of fundamental frequency, voicing and confidence.

| Field | Meaning |
| --- | --- |
| `status` | `available`, `insufficient_evidence`, or `unavailable`; absence of evidence is not a poor learner grade |
| `experimental`, `score` | `true` and `null`; pitch is not included in the practice score |
| `frequency_range_hz` | Supported analysis range, currently 65–650 Hz |
| `frame_hop_seconds` | Internal analysis step, currently 0.02 seconds |
| `track_step_seconds` | Actual spacing of representative public frames; may be larger than the analysis step |
| `frames` | At most 1,000 records containing `time_seconds`, `f0_hz` or null, `voiced`, `confidence`, and `relative_semitones` or null |
| `confidence_kind` | `periodicity_not_probability`; do not display this as calibrated voicing probability or learner accuracy |
| `summary` | `median_f0_hz`, `voiced_fraction`, approximate `voiced_seconds`, and `range_semitones` (95th–5th percentile spread) |
| `analyzed_frame_count`, `display_frame_count` | Full analysis count and bounded public/stored track count |
| `reference_comparison` | Student results may contain matching-word comparisons of speaker-centered relative pitch |

Relative semitones are measured around each recording's own median, so naturally higher or lower voices are not penalized. `reference_comparison.points` contains `word`, `expected_word_index`, `student_semitones`, `reference_semitones` and `difference_semitones`; `median_absolute_difference_semitones` is an experimental difference measurement, **not an accuracy percentage**. Comparison requires reliable ASR timing and at least three matching words with supported voiced samples. It may be unavailable even when the individual pitch track is available.

Plot each frame's actual timestamp and break the line at unvoiced/null values. Do not interpolate speech pitch across silence. Periodic music/noise, breathy or irregular voices, octave errors and frequencies outside the supported range can affect evidence. The system does not infer mood or emotion. Raw audio is retained unchanged for future reanalysis.

`submitted_problems` counts distinct assignment items with any saved attempt. The latest attempt governs each item's current status. `completed_count`/`completed_problems`/`reviewed_problems` count items whose latest attempt is completed; `solved_problems` requires a completed score of at least 0.7. `attempts` includes retries with new UUIDs, but repeated requests with the same UUID count once. `completed_assignments` requires every item to be completed. Averages exclude unassessed items; no attempts means unassessed, not zero ability. Scores across exercise kinds are practice summaries, not a calibrated common ability scale.

## Files and failure handling

Accepted decoding formats: WAV, MP3, M4A, WebM, Ogg, FLAC and AIFF. Maximum file 20 MiB, total request 22 MiB, duration 0.5–120 seconds. Empty, corrupt, silent, very quiet or out-of-range files are rejected and cleaned up. Source bytes/checksums/format metadata are retained separately from 16 kHz mono PCM16 analysis WAVs; speed, pitch and pauses are not deliberately modified.

| HTTP status | Client action |
| --- | --- |
| 401 | Sign in again; clear only the session associated with that request |
| 403 | Current role cannot use this route |
| 404 | Resource is absent or not accessible to this account |
| 409 | Resolve duplicate names, changed idempotent content, unavailable reference or invalid analysis state |
| 413 / 422 | Correct file size or validation errors; no valid submission was accepted |
| 429 | Login throttled; wait five minutes before retrying |
| 503 | Dependency temporarily unavailable; retry with the original request ID where supported |
| 507 | Server storage is full; free storage before retrying |

Errors have `detail` as a message or validation-error list. Private responses use `Cache-Control: no-store`.

The durable local queue uses pending database attempts as work records and one sequential model worker. A new submission wakes the worker; startup also discovers pending attempts, including interrupted work. A file lock rejects a second worker on the same data directory. The API remains available while queued analysis runs. Failed or reviewable attempts can use the retry endpoint; completed and teacher-reviewed evidence remains protected from late analysis.

Run one application process per database/data directory. Distributed workers, teacher/self-service account recovery, remote TLS deployment, full deletion/retention flows and versioned production migrations remain subsequent work. Teacher-managed student password reset is implemented and does not delete learning history.
