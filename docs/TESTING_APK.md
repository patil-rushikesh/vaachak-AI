# Sharing a testing APK

Build a signed, optimized ARM64 APK with:

```sh
python3 tools/build_testing_apk.py --defines .env.supabase-dev.json
```

The builder uses Flutter release AOT compilation, R8 and resource shrinking, one ARM64 ABI, and compressed native libraries. Native libraries extract on installation, so the installed app needs more storage than the download. It does not remove speech, QR, database or language-model runtime functionality.

The APK and SHA-256 checksum are in `build/share/`. `latest-testing-build.json` identifies the latest successful artifact. Share the APK and checksum; never share signing files or private credentials.

## Tester instructions

- Use an ARM64 Android phone running Android 8 or later.
- Download the APK, open it in the file manager, and allow installation from that source if Android prompts. Install **VaachakAI Testing**.
- This app uses the development backend and separate storage from the normal app. Use synthetic learner data for testing.
- Test profile creation, PIN unlock, offline learning, closing/reopening the app, and privacy controls. Report the APK build number, phone model, Android version, steps, and observed result.
- Speech and Gemma weights are not bundled. Their signed model packs and trusted-key configuration must be provided separately before those features can be exercised. Teacher sign-in additionally requires account provisioning; real email OTP verification remains pending.
- Later APKs built with the same testing key can update this app without uninstalling it. Keep that key private and backed up.

## Signing and configuration

The testing application ID is `ai.vaachak.vaachak_app.testing`. The persistent private testing key is stored outside the repository in `~/.local/share/vaachak/testing-signing/`, with restricted permissions. It is separate from production signing. The helper requires the dev environment, an HTTPS backend, and a public Supabase key; it rejects known test-session and service-role configuration fields.

Production release signing still requires `android/key.properties`. This APK is for private development testing, not a production rollout or Play Store submission. Existing physical-device, curriculum-review and real-account acceptance gates still apply.
