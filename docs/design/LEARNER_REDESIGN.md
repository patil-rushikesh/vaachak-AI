# Learner experience redesign

The redesigned APK is built from the verified application workspace at `build/login-apk-workspace`, retaining the working engine/content contracts and email/password sign-in. The main workspace's concurrent engine/application rewrite is not overwritten. `journey_dashboard.dart` is also available in the main app source as an independent presentation component.

## Experience

- Welcoming profile picker with an original Flutter-drawn companion, cream background, forest-green text, lime highlight panels, and rounded touch targets.
- A single next-lesson call to action. Home becomes a short learning trail instead of a long diagnostic report.
- Three destinations: Learn, Explore, and Progress. Reading, grammar, skill checks, and school connection have labelled entry points.
- Three saved answers form a gentle daily goal. Counts derive from the learner's deduplicated persisted evidence and local calendar day. No invented streaks, XP, leaderboard, deadline penalties, or locked lessons.
- Practice is limited to five questions at a time. Choosing an option does not immediately submit it: a separate Check answer action allows correction before saving.
- Corrective feedback, incremental progress and a completion dialog use actual saved answers. Storage errors retain retry behavior and do not grant completion.
- Advanced profile-picker actions are grouped under More options. Offline packs, app updates, transfer, teacher portal, privacy and locking remain reachable.
- English/Hindi labels and large-text layouts are retained. No third-party art or network-only visual assets are added.

## References

[Duolingo's home-screen design](https://blog.duolingo.com/new-duolingo-home-screen-design/) informed a clear next step and ordered practice choices. [Unacademy practice sessions](https://unacademy.com/helpcenter/category/81000187579/article/81000382735) and [Physics Wallah](https://www.pw.live/) informed grouped learning activities. The user also named WhiteHat Jr; no reliable current official UI reference was available in the search, so its interface is not represented as reviewed. Visuals, copy, mascot and implementation are original.

## Verification

The screenshot in `build/share/vaachak-redesign-preview.png` is an actual Flutter widget render with a synthetic learner fixture, not a captured real learner profile. Navigation callbacks, empty-path actions, Hindi/English layouts, all age bands at 200% text, existing privacy/lock flows, answer persistence and completion are covered by tests. Release-mode installation and launch are verified separately; real hosted account sign-in still needs a provisioned account.
