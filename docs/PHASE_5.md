> Historical reference: the web and Android frontends and their build tooling have been removed. See the root README for current setup.

# Phase 5: classroom classification, teacher recordings, assigned practice

## What exists
- **Classification** (`infra/supabase/templates/phase5.sql`): classes carry standard (KG, 1-12, adult), section, pincode (6-digit Indian format), state, district, instruction language (ISO 639-1) and academic year. Schools (`orgs`) carry pincode, state, district and primary language. Learners inherit location through their class; no learner-level location is stored.
- **Teacher RPCs:** `create_class`, `update_class_classification`, `register_recording`, `delete_recording`, `assign_recording` (whole class, or one learner), `revoke_assignment`.
- **Learner RPC:** `my_practice_assignments` returns only assignments for learners owned by the calling device, in classes that have approved them, with `core` + `serverSync` consent.
- **Storage:** private bucket `teacher-recordings-<env>`. Teachers upload only under their own folder; a learner may read an object only while an active, consented assignment covers it (`can_play_recording`).
- **App:** teacher "Create classroom" form and "Record lesson and assign" screen (`teacher.dart`, `class_setup_dialog.dart`, `teacher_recording_page.dart`); learner "Practice from your teacher" list (`school_page.dart`, `practice_assignments_page.dart`). Downloads are checked against the registered size and SHA-256 before playback.

## Verified
`infra/supabase/tests/phase5.sql` passed on PostgreSQL 16 together with the existing `security.sql` and `phase3.sql` suites. The storage policies were exercised against a stub `storage` schema, not a real Supabase project.

## Not verified
- The Dart code has not been compiled, analysed, formatted or run (no Flutter toolchain was available when it was written). Run `dart format`, `flutter analyze` and `tools/check.py` first.
- `audioplayers: ^6.0.0` was added to `apps/vaachak_app/pubspec.yaml` without a lockfile update. Run `flutter pub get` and commit `pubspec.lock`; `--enforce-lockfile` fails until then.
- The migration has not been applied to the hosted Supabase project, and the storage bucket and policies have not run on real Supabase Storage.
- No recording, upload or playback has run on a device or in a browser. Browsers record Opus/WebM; Android records AAC/MP4.

## Not built yet
Quizzes (create, assign, results), a teacher view of who has played an assignment, learner completion tracking, and a recordings library for reuse.
