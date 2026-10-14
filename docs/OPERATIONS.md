# Current operations entry point

Updated 15 October 2026. The active application is Expo/FastAPI, with Render hosting, Neon PostgreSQL and private S3-compatible audio, and Vercel web hosting. Last recorded hosted acceptance: 11 October 2026.

Use the [deployment and operator runbook](../deploy/backend/README.md) for environment variables, one-instance topology, inline jobs, local Docker, logs, backup/restore, retention, account recovery and release distribution. Configuration lives in `render.yaml`, `deploy/backend/`, `apps/vaachak/vercel.json` and `apps/vaachak/eas.json`.

- Keep provider keys, database/bucket credentials, teacher invitations and test-user passwords outside Git and frontend bundles.
- The cloud database and private audio bucket are durable; Render local files are temporary. SQLite backup commands apply only to local SQLite installations; cloud database and object storage need their own protected exports.
- SMTP was not configured at last acceptance; operator-assisted reset is available. Implemented cleanup/backup commands need an external schedule and verified restore procedure.
- Render Free can sleep and provider calls have quotas. Inspect correlated request logs and readiness before retrying mutations; reuse submission identities when reconciling an uncertain result.
- Do not point destructive test suites or demo-reset commands at the deployed database.

[Legacy operations](LEGACY_OPERATIONS.md) applies only to the retained Supabase/event-sync implementation; it is not the current deployment procedure.
