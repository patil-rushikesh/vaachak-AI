> Historical Flutter/Dart/Supabase record, retained on 15 October 2026. Statements below describe that implementation and its original verification dates, not the current Expo/FastAPI release. Some referenced app paths no longer exist. See [current implementation](IMPLEMENTATION_STATUS.md) and [current architecture](ARCHITECTURE.md).

> Historical reference: the web and Android frontends and their build tooling have been removed. See the root README for current setup.

# Production preparation evidence

This workspace is not approved for production deployment. The most recent complete APK predates incompatible changes to the learning engine/content APIs. A fresh whole-workspace analysis currently reports 353 issues. Do not replace the working testing APK with a build from this state.

## Email and password

Teacher and school-device login now use the same validated email/password form. OTP requests and code-entry controls were removed. Passwords are hidden by default, submissions are serialized, successful login clears the password field, and errors do not disclose account existence or backend details. Passwords are not stored by application code; authenticated sessions use platform secure storage. Accounts are school-provisioned; there is no self-assigned teacher privilege or public signup UI. Password recovery is an administrator-assisted process, without email delivery.

Three widget tests pass: validation/no OTP, duplicate-request suppression/password handling, and generic failure/retry. The local Supabase configuration disables signup and email confirmations. The approved hosted changes are applied and verified through the public Auth settings endpoint: `disable_signup=true`, `mailer_autoconfirm=true`. Public signup and email confirmation are disabled. Existing hosted users still need passwords provisioned and real authentication acceptance testing.

## QA and production parity

`tools/environment_parity.py` compares normalized `pg_dump` schema definitions including grants. The local QA and production definitions match. `infra/supabase/tests/environment_parity.sql` provides a read-only dashboard-compatible inventory of tables, RLS flags, columns, routines/ACLs, policies, indexes and constraints.

Hosted QA and production each contain 360 inventoried objects and produce the same fingerprint: `7c05004e2949bff86fe22ea0946dac48`. The security and Phase 3 behavior SQL suites also passed locally in both QA and production schemas with rollback-only synthetic fixtures. No production learner data was copied to QA. These schemas share a Supabase project and therefore share Auth configuration, hosting capacity and administrative control; schema parity is not full deployment isolation.

## Internet-sourced content

Eight original language exercises based on [NASA's Earth facts](https://science.nasa.gov/earth/facts/) were added to the content bank, with source, retrieval date and adaptation metadata. No imagery, logos or third-party text were copied. See [NASA usage guidance](https://www.nasa.gov/nasa-brand-center/images-and-media/) and `content/earth-sources.json`. Structural validation passed. Rushikesh Patil explicitly approved these eight items in this conversation; approval, exact item hashes and the user-supplied reviewer contact are recorded in `verification/rushikesh-approval.json`. The contact is not bundled in the APK assets. This approval does not cover the remaining curriculum, rubric calibration or speech-model versions.

## Release decision

No production deployment was performed. Whole-app compilation, all-role acceptance, approved curriculum/models, production signing/trust anchors, operational recovery, organization/privacy details and physical-phone acceptance must have evidence before the release decision changes. Render is optional hosting, not a substitute for these checks. The repository currently has no configured Git remote for a reproducible Render deployment.

Machine-readable evidence: `verification/production-preparation.json`.
