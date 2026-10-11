# Vaachak · React Native application

One Expo SDK 57 / React Native / TypeScript app for **iOS, Android and web**. This isolated directory owns its dependencies, theme, features, tests and web container. It uses the existing FastAPI backend; no provider secret belongs in this app.

## Run locally

From the repository root, start the backend:

```sh
.venv313/bin/python classroom_web/run.py --host 0.0.0.0 --port 8000
```

Then from `apps/vaachak`:

```sh
npm ci
npm run dev:web
# Open http://localhost:8090 (web requests proxy to localhost:8000)
```

For native development, use a separate terminal:

```sh
npx expo start --port 8091
# Press i for iOS or a for Android. Install the SDK-compatible Expo Go when prompted.
```

iOS simulator defaults to `http://127.0.0.1:8000`; Android emulator defaults to `http://10.0.2.2:8000`. For a physical device, put your computer's LAN API address in `.env.local` as `EXPO_PUBLIC_API_URL=http://YOUR_LAN_IP:8000`, then restart Metro. The device must be on the same network. Production native builds require an HTTPS address.

If a VPN or another service interferes with emulator networking, use:

```sh
adb reverse tcp:8091 tcp:8091
REACT_NATIVE_PACKAGER_HOSTNAME=127.0.0.1 npx expo start --lan --port 8091
adb shell am start -a android.intent.action.VIEW -d exp://127.0.0.1:8091 host.exp.exponent
```

Check for existing services before choosing ports. Do not stop unrelated applications to free a port.

## Folder boundaries

```text
App.tsx                  Authenticated navigation and responsive app shell
src/api/                 API client, generated schema/operation registry, domain types,
                         task validation and pending submission identities
src/components/          Accessible shared controls, audio and submission recovery
src/features/            Auth, learner journeys, task player, classes, teacher studio,
                         courses, reviewed authoring, recording and preferences
src/providers/           Session lifecycle and native secure credential storage
src/theme/               Color and spacing tokens
scripts/                 Local proxy/static server, API drift check, icon generator
 tests/                  Client/validation/audio tests and browser journey tests
 deploy/                 Non-root Nginx configuration
Dockerfile, compose.yaml Web + existing backend containers
```

## Implemented journeys

- Registration/sign-in, instructor invitation support, operator-issued reset token, logout, preferences, optional research preference, password change, export and account deletion.
- Learner Today, practice catalogue, course outline/enrolment, locked lessons, class joining, assignments, personal review, explainable recommendations, paginated history and linked attempt comparison.
- All six tasks: read, free response, word building, choice, fill and listening. Native TTS, recording, playback and typed alternatives. Listening text stays hidden in the task UI.
- Single-task feedback with source/input labels, transcript disputes and retry linkage. No accent score or unsupported proficiency claim.
- Teacher classrooms, roster removal, code rotation, attention/evidence/skill views, snooze/resolve, targeted follow-up and its evidence journal.
- Courses, units and lessons; ordering, publish/unpublish, access settings, class assignment and progress. Structured task editor, human review gate for AI drafts, optional reviewed language skill, and teacher reference recordings.
- Archive and guarded deletion. Archive restoration needs operator/API support because the backend does not list archived content. The legacy permanent-dismiss endpoint is intentionally superseded in the UI by snooze/resolve.

## Reliability, privacy and accessibility

The API client sets bearer headers, never URL tokens; multipart boundaries are left to the runtime. Native sessions use Expo SecureStore. Web tokens stay in tab memory, so a page reload requires sign-in. Query caches are cleared on account changes. Temporary connection loss during native startup preserves the credential and offers retry.

Attempt UUIDs, task versions and retry IDs are sent to the server. Ambiguous attempts use submission lookup instead of posting a new identity. Pending UUIDs (no answer or audio) survive restart in native secure storage or web session storage. Today can recover the completed evidence after sign-in. This is recovery, **not offline synchronization**; unsent answers and in-progress sessions do not survive app termination.

Native recordings stop when backgrounded and temporary recording files are cleaned up when the player is released. Web recordings are converted to PCM WAV so duration can be validated by the backend; production web recording needs HTTPS. Shared playback uses bearer-authenticated sources on native and short-lived blob URLs on web.

Buttons have generous touch targets and labels, selected controls expose state, fields are labeled, errors use an alert role, and layouts adapt from bottom tabs to a desktop sidebar. Screens provide loading, empty, validation, unauthorized and retry states. Lists of attempt evidence are paginated. React Query caches repeated reads; mutations are never retried automatically. Native-stack transitions avoid JS-driven screen animations.

## Docker

```sh
# Set these in your shell or an ignored Compose environment file.
export VAACHAK_TEACHER_INVITE='choose-a-private-invite'
# Optional backend-only GROQ_API_KEY enables AI/ASR. Never EXPO_PUBLIC_GROQ_API_KEY.
docker compose up --build -d
# http://localhost:8090
```

The web image builds static assets and serves them as uid 101. `/api` proxies internally to the backend; there is no browser CORS dependency. A named volume retains SQLite and audio. Local HTTP is bound to loopback. For public deployment, place the web service behind HTTPS (the repository's Caddy deployment is the starting point); route both `/api` and web traffic through that origin. Do not publish this local HTTP Compose configuration directly to the Internet. Containerization packages the web app and API; iOS still builds on macOS/Xcode and Android through its platform toolchain or EAS.

## Validation

```sh
npm run typecheck
npm run api:check
npm test
npm run build:all
npx expo-doctor
```

Browser tests require a **disposable** backend on port 8002, an exported app served on 8082 and Chrome (or set Playwright's channel to a downloaded Chromium):

```sh
# Repository root, separate terminal. Explicit blanks prevent loading a real provider key.
VAACHAK_DATA=/tmp/vaachak-frontend-e2e GROQ_API_KEY='' VAACHAK_GROQ_KEY='' \
 PYTHONPATH=classroom_web/server .venv313/bin/python -m uvicorn main:app --port 8002
# apps/vaachak, separate terminal
npm run build:web
API_PORT=8002 PORT=8082 node scripts/serve.mjs
# apps/vaachak
npm run test:e2e
```

Tests create synthetic accounts and content in that disposable database. They use fake browser microphone input, not your microphone. Traces may contain synthetic session tokens, so test-results is ignored. See `../../docs/verification/frontend/` for sanitized verification evidence.

Regenerate schema declarations using `npx --package openapi-typescript@7.13.0 --package typescript@5.9.3 openapi-typescript ../../postman/openapi.json -o src/api/schema.d.ts`. `npm run api:check` detects registry drift. The registry covers all 71 API operations; that is not a claim that 71 distinct UI journeys were tested.

## Release gates and bounded limitations

- Set a deployed HTTPS API URL and complete EAS project/signing setup. `eas.json` provides preview APK and release profiles; no signed APK/IPA or app-store upload is claimed. Use a development build for final verification, not only Expo Go.
- Run real-device microphone/permission, accessibility, slow-network, long-session and user acceptance testing. Simulator/browser results do not establish speech or learning efficacy.
- Publish reviewed teaching content and complete the user study in the product plan. The skill picker excludes acoustic/accent categories; the backend is not a phoneme-scoring model.
- Authoring edits are in memory. Leaving the editor or terminating the app can lose unsaved changes; durable teacher drafts and full offline support remain follow-up work.
- Archive discovery/restoration has a backend listing gap. Multiple-role accounts, push notifications and translated interfaces are not implemented.
- The Expo build tool dependency tree currently reports upstream npm advisories (braces, node-forge and xcode/uuid). The static Nginx runtime does not ship Node tooling. Review patched compatible upstream releases before public release; do not apply npm's suggested downgrade to Expo 44 blindly.

## User-value additions

See [implementation status](../../docs/USER_VALUE_IMPLEMENTATION_STATUS.md) for shipped features, current test evidence, and remaining release gates. The current backend contract has 94 operations. Personal sessions, teacher drafts, transcript confirmation, optional public quiz downloads, and scripted conversations are incremental additions. Run the generation worker alongside the API; Compose includes it.

Native Maestro flows live in `tests/native/`. Use only disposable emulator accounts, pass `TEST_EMAIL` and `TEST_PASSWORD` at execution, and keep runner output outside source control. Current flows target Expo Go through `exp://127.0.0.1:8091`; Android requires `adb reverse tcp:8091 tcp:8091` and a reachable API URL. These smoke flows do not replace signed-build, microphone, notification, or full accessibility acceptance.

For repeatable Android ATD smoke checks, run `node scripts/seed-native.mjs /tmp/new-native-account.json` against the disposable API on port 8002. Start logged out, then run `guest.yaml`, `learner.yaml`, and `practice.yaml` in that order, supplying the synthetic credentials to the learner flow. These flows target the ATD image without a software keyboard. Use a normal emulator with appropriate keyboard handling for keyboard-occlusion acceptance. Maestro 2.11.0 was verified against its official release checksum and installed under `/Users/admin/.maestro`; Java 21 was already available. Native runner logs stay outside the repository because they may contain test input values.
