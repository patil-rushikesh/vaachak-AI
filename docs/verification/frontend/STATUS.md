> Documentation reconciliation, 15 October 2026: Historical frontend run status. Use [current verification](../../VERIFICATION.md) and [implementation status](../../IMPLEMENTATION_STATUS.md) for later G1/G2, iOS runtime, hosted deployment and signed Android evidence.

# Frontend implementation and verification

**Historical baseline.** The latest expanded page/control and physical Android results are in [the 11 October end-to-end report](../END_TO_END_TEST_REPORT.md). Counts and Android limitations below refer to the earlier run.

Verified locally on 11 October 2026. Source: `apps/vaachak`.

## Delivered

A shared Expo / React Native application for iOS, Android and web, with responsive learner and teacher navigation, reusable accessible controls, warm green visual styling and six practice formats. Learners can join classes, enroll in courses, submit typed/recorded answers, inspect feedback, retry, dispute transcripts, review evidence and manage their account. Teachers can manage classes, reviewed AI-assisted content, courses, assignments, follow-up actions and learner evidence.

The API layer handles authentication, deadlines, readable errors with support references, read retries, cache isolation and idempotent submission recovery. Opaque pending submission IDs persist across restarts without persisting answer recordings. Web recording is converted to PCM WAV. Native recording handles permissions, background transitions and temporary-file cleanup.

The isolated app includes a locked dependency tree, Docker/Nginx web deployment, Compose configuration, Expo build profiles, automated CI definition and a runbook. No changes to backend business logic were required.

## Verification evidence

- TypeScript check: passed.
- Unit tests: 12 passed, covering API errors/session behavior, WAV output and task validation.
- Backend contract registry: all 71 operations match the checked-in OpenAPI contract. This is contract coverage, not 71 independently tested UI journeys.
- Expo Doctor: 21 checks passed.
- Web, iOS and Android JavaScript/Hermes exports: passed. These are not signed native application builds.
- iOS Expo Go simulator: sign-in, Today, practice selection, typed submission and live AI feedback verified. A synthetic sentence earned 100% task score; this is task feedback, not a proficiency measure. See `ios-practice.png`. The temporary test simulator was removed after verification to reclaim disk space.
- Docker web image: built; HTTP 200 for the frontend and proxied API readiness endpoint.
- Browser tests: 18 passed across desktop and mobile web.
- Web visual inspection: see `web-welcome.png`.
- Browser end-to-end scenarios cover six task formats, teacher publishing, feedback/journal/settings, class joining, teacher follow-up, readable credential errors, server retry, lost-response reconciliation, restart recovery and synthetic microphone recording. See `results.json` for the final result.
- Android UI validation remains blocked: the isolated emulator requires approximately 7.4 GB free to initialize userdata; the Mac had approximately 6.4 GiB free at the last check. The existing user AVD was preserved. Android export passed, but no successful Android visual journey is claimed.

## Remaining release work

Configure the production HTTPS API origin and EAS signing/project identity; build signed APK/IPA packages. Complete Android emulator and real-device recording, permissions, accessibility, background/long-session and acceptance tests. Public deployment and store submission were not performed.

Teacher draft edits currently live in memory, so navigation or app termination can lose unsaved edits. Durable authoring drafts and full offline operation are follow-up work. Archive discovery/restoration needs a backend listing enhancement. Review compatible upstream fixes for the npm build-tool advisories before public release. Production Nginx does not contain the Node build dependency tree.

The local preview at `http://localhost:8090` proxies the existing backend on port 8000. Automated browser tests use a separate disposable backend on port 8002 and preview on 8082; provider keys are blank in that test backend. No credentials are included in this evidence directory.
