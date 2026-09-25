# Teacher workflows — captured 25 September 2026

This is the user's new feature set. The legacy Flutter implementation remains separate.
The teacher/student backend and responsive web interface are implemented. The main teacher/student workflow, audio uploads/playback, review and progress have passed targeted browser checks. Live microphone capture still needs permission/device preflight on the presentation browser; see [DEMO_GUIDE.md](DEMO_GUIDE.md).
Local audio storage is explicitly approved; cloud migration can follow.

## Requested product behavior

1. Teacher logs in to their own dashboard.
2. Classroom navigation groups students by school, class and postal PIN code. A separate join code is retained; neither field substitutes for teacher authorization.
3. Opening a student shows learning status, areas needing practice, tests taken and assigned problems solved. Define completed tests separately from individual attempts, and distinct solved problems separately from retries. No attempts means unassessed, not zero ability.
4. Problem library stores title, teacher ownership, problem type, reusable problem ID, content and reference assets.
5. Voice practice creation: teacher records a model sentence, supplies/confirms exact text and teaching notes, uploads audio, reviews its playback and analysis, then makes the practice available for assignment.
6. Quiz creation: synonym/antonym cards, matching choices, and sentence-meaning questions. Meaning responses can be correct paraphrases, partial understanding or incorrect; exact string matching is insufficient.
7. Assignment: select a class or individual learner, select one or more existing problems by ID or create new ones, then assign them. Capture immutable problem/reference versions and class recipient snapshots so later changes do not silently alter an assignment.
8. Student voice response: hear the teacher, read the same text, record an attempt, receive evidence-based feedback and track progress. Word matching, pace and comparable pauses are implemented; calibrated pronunciation/phoneme grading remains future work.
9. Pitch and expressive reading: preserve the uploaded waveform for reference and student recordings and let the teacher specify an intended expression (for example welcoming, curious or excited). Experimental pitch extraction and matching-word relative contour comparison are now implemented. Calibrated emphasis/prosody grading remains future work; the system does not infer the learner's internal mood or emotions from their voice.
10. Teacher-managed student password reset replaces the password and revokes existing student sessions while preserving assignments, recordings and learning history.
11. Saved reading/meaning submissions enter a durable local database queue. One analysis worker resumes pending work after a process restart without requiring the learner to submit again.

## Architecture recommendation

- Python/FastAPI service; PostgreSQL relational database. SQLite is the convenient local development/demo default.
- Audio files outside database rows. Local files now; private Supabase Storage or S3-compatible storage later. Database retains recording UUIDs, checksums, format and analysis evidence. The API URL stays stable when the file backend changes.
- Original upload retained byte-for-byte; canonical analysis/playback copy is mono 16 kHz 16-bit PCM WAV. Keep the original for future higher-sample-rate analysis. Do not trim pauses or time-stretch audio.
- Store source codec, sample rate and channel metadata when available. Browser capture requests no automatic gain, noise suppression or echo cancellation; devices may ignore unsupported requests. Original capture quality is the upper bound of later analysis; converting compressed audio to WAV cannot restore information already lost at capture.
- Pitch processing stores timestamped fundamental-frequency estimates, voiced flags, periodicity confidence and `algorithm_version: yin-cmndf-v1` separately from learning scores. A custom NumPy YIN-style estimator analyzes normalized audio at 20 ms intervals over 65–650 Hz. Public/stored display tracks have at most 1,000 representative frames and expose their actual sampling interval; immutable originals support later higher-resolution reanalysis. Confidence is periodicity strength, not a calibrated voicing probability. Compare speaker-centered relative contours across matching words, not raw pitch equality.
- Pending attempt rows form the durable local analysis queue. One worker processes them sequentially and automatically resumes saved pending work on startup. A file lock rejects a second worker sharing the data directory. This local design does not support multiple distributed API/analysis workers; shared queue claims, coordination and operational monitoring remain later deployment work.
- Current tables cover teachers/student sessions, classrooms, students, reusable problems/content, immutable reference recordings, assignments/items/recipient snapshots, attempts, teacher reviews and idempotency requests. The prototype models one teacher and one classroom per student; school identity is a classroom attribute. Multiple teachers, transfers and historical enrollments need an explicit later schema design.
- The responsive web interface includes teacher and student sign-in, classrooms, student provisioning/password reset, problem creation, assignments, practice, feedback and progress views. It supports browser microphone recording with user permission on localhost/HTTPS and file upload fallback. Pitch and waveform displays distinguish evidence from grades. Main browser workflows and mobile teacher navigation were checked; live microphone capture has not been exercised on this presentation setup.

## Speech comparison design

Separate evidence dimensions instead of one unexplained efficiency percentage:

- Text coverage: omitted, substituted, inserted and repeated words, with uncertainty when ASR is unreliable.
- Pronunciation: phoneme-level evidence from an appropriate acoustic model; transcription match is not a pronunciation score.
- Fluency: pace, repetitions and within-phrase hesitation, based on aligned timings.
- Phrasing: compare gaps at corresponding word boundaries, allowing different natural reading speeds. Punctuation suggests phrasing; it is not literally pronounced.
- Prosody: experimental relative pitch contours are implemented after centering each speaker on their own median. Word-aligned comparisons require reliable timestamps and at least three supported matching words. Stress scoring and a calibrated prosody grade are not implemented. Do not compare absolute pitch, voice identity or waveform similarity as correctness.
- Meaning: rubric-based semantic understanding independently of accent and pronunciation.

Teacher recordings are mentoring examples, not an infallible universal accent standard. Teacher reviews transcript and reference before assignment. Validate scores against human-rated learner audio, including the intended ages and accents, before presenting an overall accuracy number.

## Free local model/tool shortlist

Checked against primary sources on 25 September 2026. Local model execution has no per-request API fee; hardware and hosting still have costs. These are available tools/models, not evidence of validated child-speech assessment.

| Component | Use | Limitation |
| --- | --- | --- |
| [faster-whisper](https://github.com/SYSTRAN/faster-whisper) with base.en for this local prototype | Local transcription and estimated word times; CPU int8 | ASR can conceal mispronunciation; not a pronunciation grader |
| [WhisperX](https://github.com/m-bain/whisperX) | ASR plus word alignment | Alignment locates text in audio, not proof it was spoken correctly |
| [Montreal Forced Aligner](https://montreal-forced-aligner.readthedocs.io/en/latest/) | Word/phone alignment against known text | Needs language models/dictionaries; scoring still needs separate implementation |
| [wav2vec2-lv-60-espeak-cv-ft](https://huggingface.co/facebook/wav2vec2-lv-60-espeak-cv-ft) | Experimental phoneme recognition from 16 kHz audio | Not a ready calibrated pronunciation-assessment service |
| [Silero VAD](https://github.com/snakers4/silero-vad) | Speech/non-speech intervals for pause analysis | Does not judge meaningful pauses or punctuation |
| Custom NumPy YIN-style estimator; [librosa pYIN documentation](https://librosa.org/doc/0.11.0/generated/librosa.pyin.html) is a research reference | Implemented timestamped pitch/voicing evidence and speaker-centered comparison | This is not pYIN; periodicity confidence is not calibrated probability, and tones/music can look voiced |

Reference capture/storage, optional ASR, word-aligned student feedback and experimental pitch evidence are implemented. Next model work should validate against human-rated learner recordings before adding phoneme or prosody grades, rather than adding every model in the shortlist.

## Grok/Groq role

[xAI Grok](https://docs.x.ai/overview) and Groq use different credentials/endpoints and must be configured explicitly. Never paste a key into source or a chat. No provider key is needed for local recording storage, local ASR, pitch extraction or optional Ollama meaning suggestions. Meaning evaluation compares answers against teacher-provided alternatives and a rubric; AI suggestions remain teacher-reviewed by default. It must not invent acoustic scores from transcripts. Paid API usage is not part of the free local speech/pitch baseline.

## Implementation status

Implemented: teacher registration/login/logout; student provisioning/login and teacher-managed password reset; owner-scoped classrooms and rosters; all four problem types; stable IDs; immutable reference recordings; class/individual assignments with frozen content and recipients; idempotent student text/audio submissions; authenticated playback; automatic choice/matching scores; exact accepted meanings and optional AI suggestions; optional local reading analysis; experimental pitch/voicing tracks and teacher/student relative comparisons; a durable sequential database queue with restart resume; retryable failures; teacher reviews/history; student and teacher progress metrics; responsive teacher/student screens with browser recording, file fallback and evidence visualizations. Original voice files and source metadata remain unchanged.

Pending: final browser acceptance verification; validated phoneme/pronunciation and prosody grades; reliable automatic semantic partial-credit grading; cloud/private object storage and remote hosting; distributed job processing; versioned production migrations; teacher/self-service account recovery; complete retention/deletion tools; model calibration on real learner recordings. Emotion inference is not implemented. Reference selection at assignment time acts as the teacher's explicit choice; a separate editorial publishing/approval workflow is not implemented. AI meaning suggestions require teacher confirmation by default because native tests found high-confidence errors in the small local model. The latest development suite passed 175 tests; final verification is being rerun, and no final browser verification is claimed here.
