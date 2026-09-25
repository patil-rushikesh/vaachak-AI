# Model and content packs

The signer accepts a directory and creates a detached `manifest.json`. Each file is signed indirectly through its path, byte length and SHA-256 digest. After signing, distribute the manifest alongside the unchanged files. The app accepts a folder or an HTTPS URL ending in `/manifest.json`.

The school supplies `PACK_KEY_ID` and a base64-encoded 32-byte Ed25519 public key using `--dart-define=PACK_PUBLIC_KEY=...`. An empty trust set disables installation. Never put the private key in Dart, build arguments, assets, Git, or the pack directory.

```sh
.venv/bin/python tools/content_pipeline/pipeline.py review-export apps/vaachak_app/assets review.csv
# An educator completes the exported review sheet against the exact versions.
.venv/bin/python tools/content_pipeline/pipeline.py review-import apps/vaachak_app/assets review.csv
.venv/bin/python tools/content_pipeline/pipeline.py validate apps/vaachak_app/assets --release
```

The last command currently fails because the seed bank is unreviewed and lacks coverage. Do not turn draft status into approval to bypass this gate.

```sh
.venv/bin/python tools/content_pipeline/pipeline.py sign /absolute/path/to/reviewed-pack /absolute/path/to/manifest.json \
  --key /secure/release-key.pem --key-id school-2026 \
  --pack-id school.core --version 1.0.0 --kind core --tier C \
  --runtime /absolute/path/to/runtime.json
```

`--runtime` is optional for content-only packs. A speech pack runtime describes actual signed files, for example:

```json
{
  "asr": {"type": "whisper", "encoder": "encoder.onnx", "decoder": "decoder.onnx", "tokens": "tokens.txt"},
  "tts": {"model": "voice.onnx", "tokens": "voice-tokens.txt", "dataDir": "espeak-ng-data"}
}
```

Zipformer transducer uses `type: "zipformer"` and adds a signed `joiner` file. The TTS data directory must contain signed files; no external path can be referenced. These filenames are a contract example, not supplied model assets. Use the pinned [sherpa-onnx APIs](https://pub.dev/packages/sherpa_onnx/versions/1.13.8) and evaluate compatible models before release.

The optional explainer adapter targets a local `.litertlm` file through [flutter_gemma](https://pub.dev/packages/flutter_gemma/versions/1.9.0). The grammar coach exposes an explicit local rewording action for students/adults. It loads only a verified Tier A model, keeps the reviewed template visible, and accepts a result only after strict JSON, corrected-form, length, practice and safety validation. Children always use templates. A shared lease prevents speech and explanation models from being resident concurrently. Native cleanup completes before the speech lease is released.

A standalone speech model pack uses `--kind speech`, avoiding any invented curriculum approval. Both `core` and `speech` packs are capped at 350 MB. An explainer uses `--kind explainer --tier A` and the runtime:

```json
{"explainer":{"type":"litertlm","model":"gemma.litertlm"}}
```

Every referenced model/data file must be inside the signed file set. Piper's `espeak-ng-data` filenames may contain spaces and `!`; traversal, symlinks, unknown runtime fields and unsigned installed files are rejected. The Python signer validates the same runtime schema before signing. Preserve the applicable model/data licenses and obtain required access rights before release.

The pack screen can restore the previous retained version. Rollback rechecks its signature, every file digest, and current device compatibility before atomically switching the active pointer. Old versions count against the 2 GB storage budget. Pack cleanup and delta patching need a future maintenance UI. Large downloads have inactivity timeouts and preserve partial files; a server that does not honor Range requests cannot resume that partial file without removing it first.

## Reading assessment approval

Reading passages may be supplied in signed `passages.json`. Each approved passage names exact `assessmentModelIds` (`packId@version`) and a reviewed `targetWcpm`. The reading assessment refuses unlisted model versions. Include text, rubric, eligibility and model versions in educator review using the content pipeline. See `READING_ASSESSMENT.md`; the bundled draft passage is not eligible.

## Real-model smoke tests

`tools/prepare_phase2_smoke.py <extracted-models-directory> <new-output-directory>` packages the official sherpa-onnx Whisper tiny.en int8 and Piper en_US-lessac-medium archives into a development-only signed pack. It generates an ephemeral test signing key, destroys the private key, and keeps a test public key alongside the pack. This is not a school release pack or curriculum approval. The model files stay outside the repository.

On macOS, set `PHASE2_PACK_DIR` to the output's `pack` directory and `SHERPA_LIBRARY_PATH` to the pinned `sherpa_onnx_macos` package's `macos` directory, then run `flutter test --no-pub test/real_models_test.dart` from `apps/vaachak_app`. The check performs signature/hash verification, real Piper synthesis, real Whisper decoding, reference alignment, numeric-only encrypted evidence persistence and duplicate-save validation. The ordinary suite explicitly skips this test unless model paths are provided.

On Android, copy the prepared fixture directory to the test app's accessible files directory and run `flutter test integration_test/phase2_models_test.dart -d <device> --dart-define=PHASE2_PACK_DIR=<device-directory>/pack`. This uses actual native capability detection, SQLCipher, sherpa and memory-only AudioTrack playback. `integration_test/offline_test.dart` separately checks profile creation, PIN unlock, grammar fallback, evidence and background locking. Emulator results are not reference-phone performance or microphone-accuracy validation.

The authorized [Gemma 3 1B int4 LiteRT-LM artifact](https://huggingface.co/litert-community/Gemma3-1B-IT/blob/main/gemma3-1b-it-int4.litertlm) was downloaded after license acceptance and checked against its published SHA-256: `1325ae366d31950f137c9c357b9fa89448b176d76998180c08ceaca78bba98be`. The development-only signed fixture is retained outside the repository at `/Users/admin/.local/share/vaachak/phase2-explainer-smoke/pack`; the redundant download copy was removed to conserve disk space. This artifact check does not establish successful Gemma inference, shipping approval or representative-device performance.

For another authorized local file, run `tools/prepare_explainer_smoke.py /path/to/model.litertlm /path/to/new-output`. The script never downloads models or accepts terms. Copy the resulting fixture and public sidecar to an app-readable device directory, then run `flutter test integration_test/phase2_explainer_test.dart -d <device> --dart-define=PHASE2_EXPLAINER_PACK_DIR=<device-directory>/pack`. Actual native Tier A capability is required. The test reports native inference separately from accepted validated explanations or template fallback, without logging generated text.

Real desktop Whisper/Piper inference now passes, including signed-pack verification and encrypted numeric evidence. The selected tiny.en model lacks the native attention output needed for word intervals, so `hasWordTiming` is false; no hesitation timings are fabricated. Android signed speech integration also passed, including native playback/stop and encrypted numeric evidence. Android Gemma native inference also passed; the explanation request safely retained its reviewed template, with no accepted generated explanation. The corrected Android profile/PIN/grammar/background-lock flow also passed. See `VERIFICATION.md` for the final run record.
