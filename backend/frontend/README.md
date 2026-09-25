# Vachak web workspace

This frontend is served by the existing FastAPI application. It has no CDN dependencies and requires no build tools to **run**: `index.html` loads the checked-in `bundle.js` and `style.css`.

The editable source is `app.js`, `api.js`, `audio.js`, and `insights.js`. After editing JavaScript, rebuild the browser artifact from this directory:

```sh
./build.sh
```

The build uses a pinned esbuild release to produce an ES2018 classic script. This also checks source syntax before generating the browser file. Node's `--check` alone was insufficient to catch malformed nested templates in this environment.

Run the focused chart-data checks with `node --test insights.test.mjs` from this directory. These cover empty and invalid completion data, a mixed status chart, and the distinction between an ungraded attempt and a genuine zero score.

The interface includes teacher and student sign-in, teacher account creation, classroom/student management, teacher-managed student password reset, four problem types, reference audio recording/upload, reusable problem assignments, student submissions, progress, teacher review, and analysis retry. Protected audio is fetched with the session bearer token and played through revocable blob URLs. Sessions are scoped to the browser tab.

Microphone capture requires localhost or HTTPS. If browser or device permissions block recording, the audio upload control remains available. Recordings automatically stop just before the backend's two-minute limit. Leaving a screen or signing out releases microphone tracks and audio resources.

Reading scores are labeled as experimental word matching. Pitch contours and word-aligned pitch comparisons are ungraded evidence; they do not infer mood or emotion. Pending analysis and teacher-review states never display a fabricated score.

Reading results lead with plain-language feedback, a small next step, and words worth another listen. Technical measurements remain in a collapsed section. Progress charts show current practice status as a parts-of-a-whole donut and separate score histories for each activity type; teacher-reviewed points are marked. Pace, pitch, and pronunciation do not receive invented percentage scores.

Optional language and region fields are available at registration, student provisioning, and in editable learning profiles. These are entered manually, with no device geolocation. Accent preference is chosen independently of region and does not change current grading.
