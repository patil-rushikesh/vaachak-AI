> Historical reference: the web and Android frontends and their build tooling have been removed. See the root README for current setup.

# Phase 3 verification — 23 September 2026

Verification was rerun after the Phase 4 changes. All executable checks below passed. Complete field acceptance is still pending email OTP and two-phone testing.

| Check | Result |
| --- | --- |
| Local PostgreSQL behavior and 12 pgTAP assertions | Passed |
| Desktop real PostgREST round trip | Passed |
| Android real PostgREST round trip | Passed |
| Teacher UI: approval, six attempts/evidence, pin delivery | Passed |
| Learner UI: consent, join, approved sync, withdrawal, erasure | Passed |
| Native Android QR image decoder | Passed: 100 events across three rendered frames |
| Authenticated `.vbundle` file export/import | Passed on Android |
| Hosted enrollment, guardian approval, pairing, rate-limit and erasure assertions | Passed; synthetic fixtures rolled back |
| Hosted class isolation and ingestion security assertions | Passed; synthetic fixtures rolled back |
| Hosted RLS audit | Enabled on all 29 tables in each of dev/qa/prod |
| Anonymous hosted table read and device RPC probes | All six rejected with HTTP 401 / SQLSTATE 42501 |
| Static analysis | Passed |

The service integration verified duplicate-safe replay, denied cross-class access, encrypted LAN loopback relay, signed teacher interventions and erasure acknowledgement. No live school records were used. The new native QR test exercises the same Android decoder plugin used by the scanner, with rendered QR images; it does not simulate physical camera optics, framing or lighting.

## Still requiring external inputs

- **Hosted email OTP and authenticated hosted app journey:** a reachable inbox controlled by the owner is needed. The request for a test address is pending; no email was sent to an invented address.
- **Physical QR:** scan between real phones under representative lighting and motion.
- **Cross-phone hotspot:** verify encrypted transfer over two devices' actual Wi-Fi interfaces. Loopback transport passed; it is not a substitute for radio/network testing.

Only one Android emulator was connected during this run. No production rollout or new API permissions were applied.

## Evidence and reproduction

Structured summary: [phase3-reverification.json](verification/phase3-reverification.json). HTTP evidence: [phase3-hosted-api.json](verification/phase3-hosted-api.json). Run logs: `/tmp/phase3-reverification.log`, `/tmp/phase3-native-qr.log`, `/tmp/phase3-verification-analysis.log`.

```sh
python3 tools/local_phase3.py start
python3 tools/phase3_check.py --android
```

The runner now includes all four Android tests, including `phase3_qr_test.dart`. Local state is synthetic and isolated; the hosted tests run through an authorized SQL editor with rollback. The normal hosted-config APK is restored after instrumentation so the emulator is left usable.
