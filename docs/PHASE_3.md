# Phase 3: school synchronization and teacher workflows

## Implemented

- Isolated `dev`, `qa`, and `prod` database schemas with monthly event partitions, device ownership, immutable event identities, consent enforcement and default-deny row-level security.
- Expiring class codes, join rate limiting, pending enrollment, teacher approval and witnessed guardian consent for minors.
- Authenticated HTTPS synchronization, duplicate-safe uploads, paginated teacher updates, consent revocation, remote erasure and delivery acknowledgement. Foreground sync runs on resume and every 60 seconds; pending events survive offline operation.
- Teacher roster, observed mastery, evidence-linked insights and approve/reject/assign/replace/pin controls. Native teacher roster cache expires after 24 hours and is read-only offline; the browser portal requires connectivity.
- Per-pair encrypted `.vbundle` files, animated QR and private-address LAN transfer. Teacher devices persist encrypted learner bundles for later relay. Teacher interventions carry Ed25519 signatures anchored to online-registered teacher keys. Cached pairings expire after seven days; refresh checks revocation sooner.
- Learner school screen with explicit progress-sharing consent, class joining, manual sync and stop-sharing controls. Production configuration requires HTTPS; local cleartext is limited to the explicit development path.

## Verification

The full host check passed 170 Dart/Flutter tests and 10 Python tests, formatting, analysis, content validation and a release web build. Two opt-in model/backend tests are skipped in the ordinary suite and have separate run instructions.

Actual PostgreSQL 16 and PostgREST 16.3—not mocked RPCs—were used for SQL behavior checks, 12 pgTAP checks and desktop/Android integration. The local HTTP gateway only adapts the Supabase URL prefix and CORS. Local synthetic JWT identities exercise authenticated database policies; this does not test hosted email delivery.

All three Android emulator checks passed:

1. Service flow: six scored attempts, idempotent replay, denied cross-class access, QR reconstruction, encrypted LAN loopback relay, signed teacher intervention and acknowledged erasure.
2. Teacher screen: pending enrollment approval, six-attempt evidence display and a pin delivered to the learner.
3. Learner screen: consent, joining, approved progress upload, sharing revocation and erasure delivery.

Logs: `/tmp/phase3-full-checks4.log`, `/tmp/phase3-final-analysis.log`, `/tmp/phase3-final-backend.log`, `/tmp/phase3-android-school.log`, `/tmp/phase3-android-teacher3.log`, `/tmp/phase3-android-learner4.log`.

## Reproduce locally

Install PostgreSQL 16 with pgTAP and PostgREST, then run from the repository root:

```sh
python3 tools/local_phase3.py start
python3 tools/phase3_check.py
python3 tools/phase3_check.py --android
```

The Android option requires a running `emulator-5554`. The local runner uses loopback ports 55432–55434 and synthetic accounts in an isolated database. State and short-lived local tokens are stored outside the repository under `~/.local/share/vaachak/phase3-local`; restart the backend to renew test tokens. Stop with `python3 tools/local_phase3.py stop`.

The hosted migrations are `infra/supabase/migrations/202609230001_platform.sql` followed by `202609230002_phase3.sql`. Never deploy `tests/local_auth.sql` or local synthetic fixtures to a hosted project. App configuration uses `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `VAACHAK_ENV`; the supplied publishable key is in an ignored local definitions file. No service-role key is embedded in the app.

## Acceptance limits

Camera scanning between physical devices, hotspot transfer between two phones, reference-phone performance and real hosted email OTP remain field/deployment checks. Automated QR reconstruction and loopback LAN tests establish codec/transport behavior, not optical camera or Wi-Fi hardware performance. Offline erasure/revocation requires reconnection or cache expiry. The transfer format is bounded to 500 events per bundle; large histories need multiple deliveries and server acknowledgement. The teacher transfer screen provides a batch number so later intervention history can be transferred; send batches in order. Production curriculum, school identities/trust anchors, key rotation and Phase 2 model approval gates still apply.

## Hosted status

On 2026-09-23, both migrations were applied transactionally through the Supabase SQL editor to project `svteovpdzoqoemkosael`, after confirming that its application namespaces had no tables. The owner approved exposing `dev`, `qa` and `prod` through the Data API. Hosted verification found 29 tables per environment, RLS enabled on all tables, seven expected Phase 3 RPCs and 70 skill nodes. Authenticated role checks passed; anonymous class queries returned HTTP 401 and anonymous joining lacks execute permission. Existing public/GraphQL exposure settings were preserved.

These were manual SQL-editor migrations; do not blindly replay the create migrations through a CLI migration runner. The owner authorized synthetic test identities. Hosted Phase 3 and baseline security SQL assertions passed using transaction-scoped synthetic users, school and class, with all fixtures rolled back. They covered minor approval, pairing access, invalid-code rate limiting, erasure delivery and acknowledgement. No real school roster or permanent synthetic login was created. Hosted email OTP and a real hosted app login journey have not yet been exercised; these require a reachable test inbox. Local app end-to-end acceptance is complete.

The final normal ARM64 debug APK and release web bundle were rebuilt with the supplied hosted project configuration. The APK was installed and cold-launched on the emulator (`Status: ok`, 1,466 ms startup in this run); AndroidRuntime reported no errors. This is a development artifact, not a signed production release or reference-phone benchmark.

Phase 3 was reverified after Phase 4. Local SQL/pgTAP, desktop and three Android school flows, hosted security assertions and six anonymous API denials passed. A new fourth Android test passed native QR image decoding (100 events, three frames) and authenticated file transfer. See [the verification report](PHASE_3_VERIFICATION.md) for evidence and remaining real-email/physical-device checks.
