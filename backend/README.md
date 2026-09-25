# Vachak AI — Teacher and student backend

A FastAPI backend and responsive web interface for teacher/student workflows, private recording storage and optional local AI. The teacher and student screens are implemented under `frontend/`. See [DEMO_GUIDE.md](DEMO_GUIDE.md) for the presentation walkthrough and existing demo accounts. Existing Flutter code elsewhere in this repository remains separate.

## Run on this machine

```sh
cd /Users/admin/genai/backend
uv sync --extra test --extra speech
./run_demo.sh
```

Open the [teacher/student web app](http://127.0.0.1:8000/) or [interactive API documentation](http://127.0.0.1:8000/docs). Python 3.11/3.12, uv and FFmpeg are required. `run_demo.sh` discovers the downloaded speech model under `data/models` if present. The server runs on loopback with one application process and one local analysis worker. API testing also works independently of the interface.

To create explicitly labeled example content:

```sh
uv run python -m vaachak_backend.demo
```

This creates a demo teacher, classroom, student, four problem records and an assignment. It does not invent student submissions or progress. Login details are stored privately in `data/demo-accounts.json`. A synthetic reference voice is generated on macOS when `say` is available. Alternatively, use `POST /auth/register` and the teacher APIs, or run `uv run python -m vaachak_backend.cli create-teacher --email you@example.test`.

## Teacher and student workflows

- Teachers register/sign in, create classrooms by school/class/postal PIN, and provision student usernames/passwords. Teachers can reset their students' passwords, immediately revoking existing student sessions while preserving learning records. Postal PIN and classroom join codes are separate; student access uses teacher-provisioned accounts.
- Reusable problems support read-aloud recordings, choice questions, synonym/antonym matching and meaning questions with accepted answers and a teacher rubric.
- Teachers record reference audio in the browser or upload a file, supply the written sentence, teaching notes and an intended expression, then review playback and experimental pitch evidence. Browser microphone access requires localhost or HTTPS and permission; file upload remains available.
- Assign one or several problems to a whole classroom or one student. Assignment content, reference IDs and recipient lists are frozen; later library changes cannot silently rewrite assigned work.
- Students sign in, open assignments, listen to authenticated reference audio, record/upload reading attempts, and answer choice, matching and meaning exercises in the web interface or through the API.
- Student progress and teacher evidence views derive from saved attempts. Teacher review records a separate judgment while preserving automatic evidence.
- Duplicate student requests do not double-count. Pending analysis is stored in the database, processed sequentially, and automatically resumes after restart. Missing files, absent models and uncertain results remain visible rather than generating fake scores.

## Regional learning profiles and clear feedback

Teacher registration and student provisioning accept an optional `learning_profile`: country, state/region, city, first language and target accent. Both roles can edit their own profile, and teachers can edit profiles of students they own. Existing accounts start with blank profiles. These are explicitly entered learning preferences: the app does not request GPS, infer accent from geography or alter grades by region. A chosen target accent is context for future learning features; automatic accent-specific assessment is not implemented.

Two additive profile tables preserve existing account schemas and data. New reference and student audio records include a snapshot of profile context at upload time; older recordings are not relabeled from a current profile. Metadata records the editor/provenance and update time.

Attempt responses also provide `display_feedback`, a plain-language summary, a short list of next steps and separate reading dimensions. Automatic word match and teacher-assigned scores remain distinct. Pace, pauses, pitch and sound-level pronunciation never acquire invented accuracy percentages. Technical evidence remains available in the interface under an expandable section.

Progress charts use a completion donut for mutually exclusive practice states, separate skill bars and per-kind score histories. Ungraded work remains ungraded; one result does not establish a trend. A pie chart would not be appropriate for combining independent speech/quiz measurements into an overall ability score. [Chart-design reference](https://www.datawrapper.de/academy/how-to-create-a-pie-chart).

## AI and interpretation

Choice/matching questions use deterministic answer keys. Explicit teacher-accepted meanings can be matched directly. Other meanings can use a configured local or external model; local model judgments are provisional and require teacher confirmation by default.

Reading uses optional local English faster-whisper to report transcript word coverage, missing/extra words, estimated pace and comparable word-boundary pauses. These are **experimental speech-recognition measurements, not validated phoneme/pronunciation grades**.

Experimental pitch extraction is also implemented using a custom NumPy YIN-style estimator, with no additional model download. It stores timestamped fundamental frequency, a voiced flag and periodicity confidence, plus median pitch, voiced duration and relative pitch range. Teacher reference tracks are saved with recording measurements; student tracks are saved separately in attempt results. Matching words can be compared after centering each speaker's contour on their own median. Natural differences in absolute pitch are not treated as mistakes, and pitch never changes the word-match score.

Pitch analysis covers 65–650 Hz with 20 ms analysis steps; public/stored display tracks contain at most 1,000 representative points with their actual timestamps and sampling interval. Noise, music, breathy or irregular voices and octave errors can affect results. Confidence is periodicity strength, not a calibrated voicing probability. Phoneme grading, calibrated stress/prosody scores and emotion inference are not implemented. Original recordings remain unchanged. The [librosa pYIN documentation](https://librosa.org/doc/0.11.0/generated/librosa.pyin.html) is a research reference for separating frequency, voicing and confidence; this implementation does not use or claim to reproduce pYIN.

A `base.en` model has been downloaded under `data/models` on this machine. For a fresh installation, obtain a compatible faster-whisper model and set `VAACHAK_WHISPER_MODEL` to its local directory. Requests do not automatically download weights.

Optional local meaning suggestions, using an already installed Ollama model:

```sh
# Start Ollama in a separate terminal if it is not already running.
OLLAMA_HOST=127.0.0.1:11434 OLLAMA_NO_CLOUD=1 ollama serve
# In the backend terminal:
VAACHAK_TEXT_PROVIDER=ollama VAACHAK_TEXT_MODEL=qwen2.5:0.5b-instruct ./run_demo.sh
```

This small model is useful for demonstration, but testing found inconsistent partial-credit judgments. Teacher review is part of the workflow. No external API key is needed for local processing. xAI Grok and Groq are different providers; configure the intended provider explicitly using `.env.example` as a guide. Keep API keys server-side. External model calls happen only when configured; they send the student's meaning answer and the teacher's assessment criteria to that provider.

## Database and audio storage

PostgreSQL is the recommended shared database. Set `DATABASE_URL=postgresql+psycopg://USER:PASSWORD@HOST:5432/DB` to a new database dedicated to this service. The convenient local default is SQLite at `data/vaachak.sqlite3`. Current bootstrap creates missing tables; use versioned migrations before future changes to existing schemas.

`VAACHAK_DATA_DIR` selects a persistent private directory. Use an absolute path when running as a service, and back up both database and media together.

```text
data/
  vaachak.sqlite3
  recordings/<reference UUID>/original
  recordings/<reference UUID>/reference.wav
  attempts/<attempt UUID>/original
  attempts/<attempt UUID>/reference.wav
```

Original files are retained byte-for-byte with checksums. Analysis/playback copies are mono, 16 kHz, 16-bit PCM WAV. Source format metadata is stored when available. Conversion does not trim pauses, normalize speed or shift pitch. Browser capture requests disabled automatic gain/noise suppression/echo cancellation where supported; original device capture quality still limits future analysis.

Audio access is authenticated and restricted to the owning teacher or assigned student. The data directory is not a public static directory. Cloud migration can retain these UUIDs and move files to private object storage without changing problem IDs. Local files use private permissions, not app-level encryption.

Upload limit: 20 MiB, with a 22 MiB total request cap including multipart overhead. Recording duration: 0.5–120 seconds. Corrupt/truncated, silent and very quiet audio is rejected. Derived pitch evidence carries its algorithm version and remains separate from immutable source media.

Pending `Attempt` rows form the durable local analysis queue. One worker processes them sequentially and polls for saved work after startup, so a process interruption does not discard the submission or require recapture. A file lock prevents a second worker from using the same data directory. This is local restart recovery, not a distributed queue; run one application process per database/data directory.

## Verification

```sh
uv run pytest -q
# Docker required; starts and removes its own isolated PostgreSQL 16 container.
uv run python tests/postgres_check.py
# Full workflow over HTTP; starts/stops its own server and removes test records.
uv run python tests/live_smoke.py
```

`TEST_DATABASE_URL`, when supplied, must name a disposable database: tests clear this service's tables. Synthetic tests establish implementation behavior, not model accuracy on real children or diverse accents. Native smoke results, when generated, are under `data/verification`.

The final local verification passed **256 tests with SQLite and 256 with PostgreSQL 16**. A separate live HTTP smoke run passed using the installed Whisper model: authenticated audio delivery, original-file preservation, transcription, reference comparison and pitch evidence were checked. Pitch tests cover tones, harmonics, chirps, silence/noise, signal limits and relative comparisons across different voice registers. A 120-second synthetic signal took about 0.27 seconds to analyze on this machine; this is a local benchmark, not a throughput guarantee.

Browser checks exercised teacher classroom/student creation, all four problem builders, assignment creation, all four student exercise types, teacher review, both progress screens and reference/student playback. The 390 px teacher layout and mobile menu close/focus behavior were also checked. The saved Mira presentation example uses explicitly synthetic audio with one omitted word and actual backend-generated results. Live microphone capture still requires a short permission/device preflight on the presentation browser; upload and playback were verified. This is targeted demo acceptance, not a comprehensive browser/accessibility certification. The regional-profile update also passed a live HTTP check covering profile creation/partial edits, immutable upload context, plain-language feedback and completion chart counts. Browser checks verified self-editing, teacher editing and clearing profile fields, registration fields at 390 px, chart tabs and the updated teacher/student feedback screens.

Native checks found unreliable partial-credit judgments in the tiny local meaning model, including high-confidence errors. All AI meaning suggestions therefore require teacher confirmation by default. These checks establish implementation and failure-handling behavior, not grading accuracy on real learners.

See [API_GUIDE.md](API_GUIDE.md) for the frontend integration sequence, request shapes, scoring semantics and failure handling. [REQUIREMENTS.md](REQUIREMENTS.md) contains the captured product requirements and research links. Interactive API documentation is at **http://127.0.0.1:8000/docs**.

## Scope before broader deployment

The presentation target is one local server with its durable database queue. Distributed workers, teacher/self-service account recovery, shared rate limiting, complete retention/deletion workflows, remote hosting, versioned production migrations, model-quality calibration and a production security/accessibility review remain subsequent work. Teacher-managed student password reset is already available. Original media and database commits cannot be a cross-system transaction: normal failures clean up files, but a killed process can leave orphaned files requiring reconciliation.
