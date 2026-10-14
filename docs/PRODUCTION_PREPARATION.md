# Current release preparation status

Updated 15 October 2026 from code/configuration and recorded 11 October 2026 acceptance. The application has been deployed; older statements that no hosting or signed APK exists are superseded.

| Deliverable | Recorded status |
| --- | --- |
| Backend | Render Free with Neon PostgreSQL and private audio storage; hosted smoke and persistence verified |
| Web | Expo static web deployed on Vercel |
| Android | Signed standalone 1.0.0/code 2 APK; signature, emulator install and hosted learner smoke verified |
| iPhone distribution | Hosted Safari web app selected as the free route; no signed IPA created |
| iOS development runtime | Expo Go simulator journeys verified within the recorded scope |
| AI | Live Groq transcription, coaching/citations and teacher drafting smoke verified; no representative human quality study |
| Recovery email | SMTP unconfigured at last hosted acceptance; operator reset available |
| Operations and study | External backup/cleanup schedule, cloud restore drill, wider device/accessibility acceptance, content review and human evaluation remain |

Deployment is an engineering milestone, not certification of legal compliance, educational benefit, unlimited scale or every device state. Use [implementation status](IMPLEMENTATION_STATUS.md), [verification](VERIFICATION.md) and the [release runbook](../deploy/backend/README.md) for the current scope.

The [legacy preparation record](LEGACY_PRODUCTION_PREPARATION.md) concerns the earlier Flutter/Supabase app and its then-failing build. It does not describe the shipped Expo APK.
