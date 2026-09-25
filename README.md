# VaachakAI

Offline-first English learning in Flutter, with a pure Dart learning engine and a Supabase teacher portal. Product requirements remain in [VaachakAI.md](VaachakAI.md).

**This repository is an implemented and tested development baseline, not a finished production release.** The four-phase specification is larger than the implementation currently delivered. See [implementation status](docs/IMPLEMENTATION_STATUS.md) for the precise boundaries, remaining engineering, and external release gates. There are no fake model responses or seeded learner metrics in the application.

## Run

Use Flutter **3.47.5 / Dart 3.13.4**. The SDK installed during implementation is at `/Users/admin/.local/share/vaachak/flutter`. It was not added to your global shell configuration.

```sh
export PATH="/Users/admin/.local/share/vaachak/flutter/bin:$PATH"
flutter pub get --enforce-lockfile
cd apps/vaachak_app
flutter run -d chrome
```

Web runs the teacher portal. Without school configuration it shows a clear connection screen and no learner data. Configure a provisioned Supabase deployment with public client configuration:

```sh
flutter run -d chrome \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_PUBLIC_ANON_KEY \
  --dart-define=VAACHAK_ENV=dev
```

Android runs the offline profile picker, learner dashboard, choice practice, grammar coach, reading coach, model packs, and the same teacher portal. An Android SDK and connected ARM64 device are required:

```sh
flutter run -d DEVICE_ID --dart-define=ALLOW_DRAFT_CONTENT=true
```

`ALLOW_DRAFT_CONTENT` is for adult developer/educator evaluation only. It unlocks the small starter bank: **15 draft questions, 40 draft grammar patterns, and one draft reading passage**. Production mode does not present this unreviewed teaching content. It needs a signed, reviewed content bank; the release validator enforces three approved items per node, rung, and age band. The full 1,500-item/media bank described in the specification is not supplied.

Profiles use a 6–12 digit PIN, encrypted local storage, lockout after repeated failures, and an inactivity lock. The minor flag is independent of the presentation age band. The paper-consent reference records an external witnessed consent; it does not itself verify a guardian's identity or make the app legally compliant.

## Workspace

| Location | Implementation |
|---|---|
| `apps/vaachak_app` | Flutter Android learner and web/Android teacher UI |
| `packages/vaachak_engine` | 70-node graph loader, BKT, path planner, ladder, staircase, grammar, alignment, event fold; no Flutter or I/O imports |
| `packages/vaachak_content` | Content schemas, bank loader, release coverage checks |
| `packages/vaachak_store` | Drift, SQLCipher Community encryption, PIN hashing, HLC/ULID event log, transactions, replay, acknowledgements, erasure |
| `packages/vaachak_speech` | Signal quality gate and sherpa-onnx ASR/TTS worker |
| `packages/vaachak_explain` | Immediate templates, strict output validation, optional flutter_gemma adapter |
| `packages/vaachak_packs` | Device tiers, Ed25519 verification, streaming SHA-256 checks, atomic activation and retained versions |
| `packages/vaachak_sync` | AES-GCM bundles, HTTPS batching, persistent retry, QR fountain frames, file and LAN transport utilities |
| `tools/content_pipeline` | Review CSV round trip, validation, immutable Ed25519 manifest signing |
| `infra/supabase` | Isolated dev/qa/prod schemas, RLS, ingestion, BKT replay, insights, interventions, export/erasure, SQL and pgTAP tests |

## Verification

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r tools/content_pipeline/requirements.txt
FLUTTER=/path/to/flutter/bin/flutter .venv/bin/python tools/check.py
```

This runs formatting, analysis, package tests, Flutter widget tests, Python tests, development-content validation, and a release teacher-web build. It does **not** certify model quality, Android hardware performance, pedagogy, privacy compliance, or accessibility.

For a disposable PostgreSQL 16 database with pgcrypto and pgTAP installed:

```sh
PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres python3 tools/sql_check.py --bootstrap
```

The bootstrap supplies local test auth objects; never run `tests/local_auth.sql` against a Supabase deployment. Supabase already owns `auth.users`, `auth.uid()` and `auth.jwt()`.

For Android instrumentation, run `flutter test integration_test/offline_test.dart -d DEVICE_ID` from the app directory. The Android SDK and ARM64 emulator are installed; final device execution results are tracked in [verification](docs/VERIFICATION.md). Native speech and optional Gemma tests use explicitly supplied signed development fixtures; see [Phase 2](docs/PHASE_2.md). `tools/benchmarks/android_capture.sh` records startup, RAM, battery and thermal information; it is a measurement helper, not evidence that the performance targets have been achieved.

## Configuration and release

- [Backend operations](docs/OPERATIONS.md)
- [Implementation and release gaps](docs/IMPLEMENTATION_STATUS.md)
- [Architecture decisions](docs/ARCHITECTURE.md)
- [Model pack contract](docs/MODEL_PACKS.md)
- [Phase 2 implementation and native test instructions](docs/PHASE_2.md)

No secrets, signing keys, model weights, cloud deployment, or production learner data are included. Android release tasks require a real private `android/key.properties`; they never fall back to debug signing. CI builds a debug APK and a release web artifact. Publish only after completing the documented release gates.

The learner dashboard now includes resumable reviewed-choice checks for vocabulary, grammar and sentence formation. See [assessment behavior and remaining work](docs/ASSESSMENT.md). Read-aloud reading checks now support reviewed passages and approved speech-model versions; see [reading assessment](docs/READING_ASSESSMENT.md). Listening, pronunciation and free-speaking checks remain unavailable.

Phase 1 core-engine, encrypted-persistence and learner-UI engineering is complete against the pasted roadmap checklist. See [Phase 1 acceptance evidence and release gates](docs/PHASE_1.md). The end-to-end platform and production release remain incomplete.

Phase 2 connects offline speech, verified model-pack installation and optional local grammar rewording. The host suite passed 165 Dart/Flutter and 10 Python tests; Android build/installation and native speech integration also passed. Android Gemma inference/safe template fallback and offline profile/PIN/grammar/background-lock tests passed. Phase 2 engineering and emulator acceptance are complete; physical-phone benchmarks, human-speech evaluation and production content/model approval remain release gates. See [Phase 2 scope and release gates](docs/PHASE_2.md).

Phase 3 connects class joining, teacher approval, foreground synchronization, signed teacher interventions and encrypted file/QR/LAN transfer workflows. Real local backend and Android learner/teacher tests passed. See [Phase 3 setup, evidence and deployment status](docs/PHASE_3.md).

Phase 4 adds recoverable Play updates with explicit restart, signed CDN catalogs, overlapping pack trust keys, purpose-specific consent withdrawal and production release checks. See [Phase 4 implementation and acceptance limits](docs/PHASE_4.md).
