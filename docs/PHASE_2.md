# Phase 2 — On-device AI and model packs

The implementation covers the **Phase 2: On-device AI & Model Pack System** engineering checklist from the pasted roadmap. Host-side checks, Android compilation/installation and real desktop/Android Whisper/Piper smoke have passed. Android Gemma native inference also passed, with safe template retention rather than an accepted model explanation. The corrected offline-profile UI test also passed on Android. The Phase 2 engineering checklist and emulator acceptance checks are complete; production model approval, physical-phone acceptance and the broader seven-skill assessment roadmap remain separate gates.

## Implemented acceptance checklist

| Requirement | Implementation | Evidence and limits |
| --- | --- | --- |
| Offline Whisper/Zipformer recognition | Pinned sherpa-onnx adapter loads signed Whisper encoder/decoder or Zipformer encoder/decoder/joiner and tokens in a background worker | Real desktop and Android Whisper/Piper smoke passed. Supported configurations are tested; transcription accuracy is not certified |
| Piper-compatible TTS | Signed VITS model, tokens and espeak data; PCM synthesis and memory-only Android playback | Runtime paths and data files are verified; Android emulator PCM playback/stop passed. Physical audio routing and phone latency remain device checks |
| Reference-anchored alignment | Normalized, phonetic-fallback edit alignment classifies omissions, substitutions and repetitions; hesitation classification uses actual supported timing | Word timestamps are merged only from complete, unambiguous native token intervals. Missing/ambiguous intervals remain untimed; confidence and word timing are not invented |
| WCPM and pre-scoring quality | Bounded PCM capture, clipping/silence/noise rejection, alignment-derived accuracy and WCPM | Synthetic quality/alignment fixtures pass; quality thresholds need a consented human-speech evaluation corpus |
| Learner flow | Reading coach and reviewed reading assessment connect consent, recording, signal gate, inference, feedback, replay and numeric evidence | Error/cancellation/background paths preserve safe fallback. No voice samples are written into learner events |
| Device tiers | Android native RAM, storage, SDK, ABI and thermal detection; refreshed compatibility before installation/use | Tier A requires at least 6 GB RAM plus storage/OS/thermal eligibility; B and C cover supported lower-memory devices. Unsupported devices fail closed |
| Signed downloads and sideloads | Ed25519 manifest verification, SHA-256/length checks for every file, strict runtime schema, signed model/data references | Tests cover wrong keys, mutation, tampering, paths, symlinks, additional unsigned files and unsupported runtime configurations |
| Pack lifecycle | Interrupted download resume, HTTP Range checks, atomic activation, retained previous versions and verified rollback | Current storage checks include retained versions; no partial or overflowing transfer becomes active |
| Local Gemma execution | Pinned flutter_gemma + LiteRT-LM adapter, verified Tier A `.litertlm` activation, CPU backend and bounded output | Authorized development fixture generated actual text on Android; the explanation flow retained its template because no model explanation passed acceptance. Release model distribution still requires applicable rights and review |
| Strict explanation fallback | Immediate reviewed template; explicit optional local rewording; exact JSON shape, length/corrected-form/safety checks and reviewed practice-only output | Child mode never calls the model. Raw learner sentences are excluded from prompts. Native load/inference has a six-second learner-facing budget; invalid, unavailable, late and failed results retain the template |
| Resource lifecycle | Shared speech/explainer lease, lazy model loading, cancellation, background/dispose cleanup and idle release | Unit tests exercise overlapping requests, late activation/results and failing cleanup. Physical RAM/thermal/energy measurements remain outstanding |

The grammar coach does not present a general chat interface. It asks for a constrained rewording of a rule-backed correction. Rule-based safety filtering is not a proof that arbitrary model text is harmless or linguistically correct; reviewed templates remain the reliable fallback.

## Reproducing verification

Run the ordinary suite with `tools/check.py`. It covers formatting, analysis, package and app tests, the Python content/signing pipeline, content structure and the teacher web release build. Real model tests are opt-in and are not silently substituted by fake responses.

Prepare development-only signed model fixtures outside the repository:

```sh
.venv/bin/python tools/prepare_phase2_smoke.py /path/to/extracted/speech-models /path/to/new/speech-fixture
.venv/bin/python tools/prepare_explainer_smoke.py /path/to/authorized/model.litertlm /path/to/new/explainer-fixture
```

These tools create an ephemeral development key and retain only its public sidecar. Do not install that key as a school release trust anchor. Test model preparation does not approve curriculum or accept model terms on someone else's behalf.

From `apps/vaachak_app`, run Android instrumentation on an ARM64 emulator/device:

```sh
flutter test integration_test/offline_test.dart -d DEVICE_ID
flutter test integration_test/phase2_models_test.dart -d DEVICE_ID \
  --dart-define=PHASE2_PACK_DIR=/device/path/speech-fixture/pack
flutter test integration_test/phase2_explainer_test.dart -d DEVICE_ID \
  --dart-define=PHASE2_EXPLAINER_PACK_DIR=/device/path/explainer-fixture/pack
```

Each supplied fixture must be readable by the test app and have `test-public-key.txt` beside its `pack` directory. The explainer test requires genuine native Tier A eligibility, proves that native inference returned text, and separately reports whether the explanation passed display validation or fell back. Logs contain metrics/source rather than generated content. The offline UI test creates and erases only its own uniquely named profile, using the real encrypted store and PIN flow with test-only reviewed grammar content.

See `MODEL_PACKS.md` for the pack contract and desktop speech test invocation; see `VERIFICATION.md` for executed outcomes. The ARM64 API 30 emulator compiled and installed the app and passed the actual signed speech-model integration test, including native playback and encrypted evidence. Gemma native inference, safe fallback and offline profile/PIN/grammar/background-lock instrumentation also passed.

## Remaining release gates and broader scope

- Evaluate real microphone speech, playback, interruptions and secure storage on physical reference phones. Emulator tests used synthesized speech; the selected tiny.en fixture lacks word timing, and the tested Gemma explanation retained its reviewed template.
- Measure latency, RAM, cold start, thermal throttling, battery and storage across the supported device tiers. Emulator timing is not a phone-performance claim.
- Approve each shipping ASR/TTS/Gemma model, applicable licensing and exact versions; calibrate reading rubrics against human speech and retain a consented evaluation corpus.
- Supply reviewed curriculum and school release signing keys. Bundled content remains draft; development fixtures never become production approvals.
- Listening, phoneme-level pronunciation, free-speaking assessment, the full initial seven-skill workflow, complete sync/pairing UI and production operations belong to the broader roadmap and remain tracked in `IMPLEMENTATION_STATUS.md`.

Phase 2 runs pretrained models locally. It introduces no reinforcement learning or on-device model-weight training; learner adaptation continues through BKT and the explainable planner.
