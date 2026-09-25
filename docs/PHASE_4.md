# Phase 4: updates, privacy and production hardening

## Engineering scope

The update and privacy workflows are implemented. This milestone does not authorize a production rollout or establish legal compliance. Phase 3's real email OTP and physical QR/LAN checks remain deferred at the owner's request.

### Binary updates

The native profile picker opens an update screen backed by Google Play. Routine updates download without restarting an active learning session; the user selects **Restart and install**. Priority 4–5 releases use the immediate flow. The release contract requires schema-changing binaries to use priority 4 or 5; `tools/release_check.py --schema-migration --play-priority 4` checks this before release preparation. A future binary's schema cannot be inferred from its version code alone.

On startup and foreground resume, the app checks Play's persisted state, resumes an already accepted immediate flow and recovers a downloaded flexible update. Check requests have a 20-second timeout, share one in-flight operation, and cancel their timeout on disposal. Cancelled downloads, unsupported update modes, unavailable Play services and failed restart attempts preserve saved learning. Failed restart remains retryable.

Actual Play distribution requires the signed package to be available through an authorized Play test/production track. Unit tests simulate Play states; the emulator test invokes the actual plugin and verifies the sideloaded-build fallback. A real Store-delivered version transition is not claimed. The implementation follows [Android's update recovery and flexible-install guidance](https://developer.android.com/guide/playcore/in-app-updates/kotlin-java).

### Content and model releases

The offline pack screen accepts a signed HTTPS catalog URL, optionally preconfigured with `PACK_CATALOG_URL`. A catalog contains schema version 1, a positive monotonically increasing sequence, UTC issued/expiry timestamps, key ID and pack entries. Each entry contains a signed pack manifest and an HTTPS directory `baseUrl`. Catalog validity is limited to 90 days. The Ed25519 signature covers canonical JSON excluding `signature`.

Catalogs are capped at 1 MiB/100 packs; redirects, bad signatures, expired catalogs, sequence rollback/reuse, duplicate pack IDs and unsigned pack manifests fail closed. Replay state persists by catalog URL across app restarts and signing-key changes. Only newer compatible versions are offered. Download bytes still pass the existing signed-size/hash, exact-file-inventory, free-space, resumable-download and atomic-activation checks. Previous verified versions remain available for explicit rollback. Installation reserves 500 MB beyond space for both staging and the activated copy, and refuses unsafe downloads before reading payload bytes.

Use `tools/content_pipeline/catalog.py SOURCE OUTPUT --key KEY_FILE --key-id KEY_ID` to sign a catalog. The signing key must be Ed25519, owner-readable only, and outside pack directories. Output filenames are immutable. Upload versioned files/manifests first and publish the signed catalog last; never put private keys on the CDN. The repository does not include a production CDN or school signing key.

`PACK_PUBLIC_KEYS` accepts a JSON map of up to eight key IDs to base64 Ed25519 public keys, enabling overlapping rotation. Legacy `PACK_KEY_ID`/`PACK_PUBLIC_KEY` configuration remains supported. Pack compatibility now uses the actual installed Android app version rather than a hard-coded version. Reopen learning after changing content packs.

### Privacy controls

The privacy sheet shows microphone and school-sharing status and independent withdrawal actions. Granting each purpose for a minor requires a 6–120 character witnessed guardian reference through the store API. Learning, microphone and school sharing are separate choices; telemetry/advertising and audio retention remain disabled. Core-consent withdrawal erases the profile and retains only the propagation tombstone. Withdrawals require no new guardian evidence and remain queued when sharing is off.

Microphone granting remains in the reading flow; school-sharing granting remains in class joining. The privacy sheet links these choices in plain language and explains that erase withdraws learning consent. `SCHOOL_PRIVACY_CONTACT` supplies the school's contact text. SQLCipher storage, memory-only PCM handling, cancellation/clearing on lifecycle transitions and consent rechecks remain in place. Phase 3's existing remote erasure/acknowledgement mechanism is reused, not redeployed.

A teacher-entered reference records an organizational consent process; it does not itself verify a guardian's identity. The school must approve its evidence, privacy notice, contact, retention, rights and incident procedures before launch. Current official materials are listed by [MeitY under the DPDP Rules 2025](https://www.meity.gov.in/documents/act-and-policies/digital-personal-data-protection-rules-2025-gDOxUjMtQWa). The code and tests are engineering evidence, not a declaration of statutory compliance.

## Release preparation

Run the full repository check and native Phase 4 test, then the production gate:

```sh
FLUTTER=/path/to/flutter python3 tools/check.py
cd apps/vaachak_app
flutter test integration_test/phase4_test.dart -d emulator-5554
cd ../..
python3 tools/release_check.py --defines /secure/path/production-defines.json --play-priority 0
```

The gate rejects development configuration, test/service credentials, absent pack trust anchors, insecure endpoints, absent privacy contact, missing Android signing configuration and unapproved curriculum. It never publishes. Android Gradle separately refuses unsigned release builds. The current development configuration intentionally fails this gate; see `verification/phase4-release-readiness.json`. Actual model licenses/approval, production content, release keys, a CDN, Play track access and physical-phone acceptance remain owner-supplied release requirements.

## Verification

The full host suite passed **184 Dart/Flutter tests and 14 Python tests**, format/analysis checks, content validation and release web compilation. Final focused update/widget regression passed 15 tests. Native Android Phase 4 instrumentation passed after testing guardian enforcement, privacy withdrawal, encrypted reopen, erasure queue, actual app version lookup and the real sideloaded Play fallback. See `VERIFICATION.md` for logs and scope. Structured startup/memory measurements can be reproduced with `tools/benchmarks/android_report.py --serial emulator-5554 --output report.json`; use `--adb` for an SDK binary outside PATH. The report marks emulator runs explicitly and does not equate startup/idle PSS with ASR/TTS, thermal or battery acceptance.

Final pack regression adds the storage-reserve test: 19 pack tests passed, bringing aggregate Dart/Flutter coverage to **185**. The normal ARM64 debug APK and hosted-config release web build both passed. The app was installed and cold-launched five times without AndroidRuntime errors. Android Activity launch times were 1,808 / 1,341 / 1,245 / 1,156 / 1,131 ms (median **1,245 ms**); observed idle PSS was **327,564 KiB**. These debug-emulator measurements do not establish production cold-start, model-loaded memory or phone targets. Raw structured results: `verification/phase4-emulator-benchmark.json`.
