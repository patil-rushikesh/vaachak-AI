> Historical Flutter/Dart/Supabase record, retained on 15 October 2026. Statements below describe that implementation and its original verification dates, not the current Expo/FastAPI release. Some referenced app paths no longer exist. See [current implementation](IMPLEMENTATION_STATUS.md) and [current architecture](ARCHITECTURE.md).

> Historical reference: the web and Android frontends and their build tooling have been removed. See the root README for current setup.

# Backend and release operations

## Deploying the database

Use an authorized Supabase project. Apply the ordered platform and Phase 3 migrations on a fresh project with the Supabase CLI or a trusted administrative database connection. `infra/supabase/config.toml` exposes the three environment schemas for local Supabase. Hosted projects must expose the chosen schema in their Data API settings. Deploy production in a separate project even though schema isolation is provided.

The reproducible migration is rendered from `infra/supabase/templates/environment.sql` and the graph asset with `python3 infra/supabase/render_migration.py`. Edit the template during initial development; after a deployment, create a new migration instead of changing applied migration history.

Provision organizations, teachers (existing Auth IDs), classes, assignment date windows, pseudonymous learners, enrollments, authenticated devices, device bindings, guardians and consents through trusted administrative operations. Clients have no direct mutation grants on these tables. A device's authenticated user must match `devices.user_id`; an unbound device is rejected. Both core and server-sync consent are required to ingest ordinary events, and minors require a matching verified guardian record.

Teacher and school-device sign-in use email and password with school-provisioned accounts. No account is automatically created by the portal. Disable public signup and email confirmations in the target project's Auth configuration; administrator-assisted password recovery avoids email delivery. See PRODUCTION_PREPARATION.md for the currently verified hosted configuration. Service-role credentials never belong in Flutter configuration. The client uses only a public anon key and an authenticated user token.

Enable pg_cron and apply `maintenance.sql` after reviewing the deployment. It prepares next month's event partition, builds evidence-backed insights and refreshes class aggregates every ten minutes. These jobs have not been deployed from this workspace.

## Erasure and revocation

`erase_learner` permits an authenticated bound device or service role. It locks the learner, records minimal tombstone/delivery targets, removes learner-linked events, derived state, consent and guardian records, clears affected class aggregates, and appends a hashed-target audit record. Replaying old uploads cannot recreate an erased learner. Teachers cannot directly erase a learner solely because they can view the class.

Core-consent revocation invokes the same erasure function. Other purpose revocations update authoritative consent records. Local erasure retains a minimal event for propagation. The Phase 3 delivery agent pulls erasures before upload, purges local profiles and acknowledges delivery. Disconnected devices still require reconnection; verify acknowledgements and offline cache expiry before signing off an erasure request. Define backup expiry and statutory retention with counsel; the code does not decide those obligations.

## Recovery and incidents

- Model or pack failure: keep the previous verified version, use template/text modes, and reinstall a known signed manifest. Never bypass signature checks.
- Database open failure: the app reports failure without replacing the encrypted database. Preserve its encrypted files and keystore state. Automated snapshot restore is not implemented; do not delete/recreate the key as a recovery shortcut.
- Storage full: an attempt reports that it did not save and offers retry. Free space before proceeding. There is no proven crash-safe RAM spill queue.
- Sync failures: retain unacknowledged events and persistent exponential retry state. Review auth binding, server consent and clock skew before resetting cursors.
- Suspected data exposure: suspend affected credentials, preserve access/audit evidence without audio, identify affected learners/devices, and follow the organization's legally reviewed notification procedure. There is no automated breach-notification workflow in this baseline.
- Key rotation: release a build trusting both authorized public keys, switch new manifests, then retire the old key only after the installed base has migrated. Do not replace trust anchors through an unsigned remote file.

## Android releases

Configure `apps/vaachak_app/android/key.properties` outside version control with `storeFile`, `storePassword`, `keyAlias` and `keyPassword`. Build an ARM64 AAB after passing content, model, privacy and phone checks. Play update priority 4 or higher selects immediate updates; schema-changing releases must use priority 4 or 5. Routine updates use flexible mode and explicit restart. Run `tools/release_check.py` with production defines before building. See `PHASE_4.md` for catalog signing, key rotation and recovery. Schema v1 creation is implemented; test every future migration against encrypted database fixtures before raising the schema version.

Screenshots and Android automatic backups are disabled. No audio capture is written to disk by the app. There is no telemetry or advertising integration. These measures are not a substitute for the outstanding security/accessibility/legal reviews in the implementation status document.
