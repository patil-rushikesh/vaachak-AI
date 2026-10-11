# Vaachak Classroom — API contract

For building a new frontend (React Native) against the existing `classroom_web` backend.

The examples below originated from the 51-operation baseline. The enhanced backend has 71 operations and additional response fields; use `postman/openapi.json` and the milestone update below as the current contract.

---

## 0. Read this first: is the app offline-first?

**No. It is online, client–server.** This is the single most important thing to know before
starting, so here it is plainly:

- The backend is a FastAPI server holding a SQLite database. **Every screen is a network call.**
- No frontend is included. Clients must reach this API over the network.
- The server runs on *your* machine, so it does not need the **internet** — but the client always
  needs the **server**.

What needs the internet, specifically:

| Thing | Needs internet? |
|---|---|
| Logging in, classes, courses, progress, quizzes | No — just the local server |
| Speech-to-text and AI feedback (Groq) | **Yes** |
| Grading quizzes, rule-based grammar, scoring | No |

If the AI key is missing or Groq is unreachable, the server quietly falls back to a rule engine and
a transcript supplied by the client. Nothing errors; feedback just gets shallower.

### What this means for a React Native app

1. **The phone must reach the server over the network.** By default the server binds to
   `127.0.0.1`, which a phone cannot reach. Start it with `python run.py --host 0.0.0.0` and point
   the app at `http://<laptop-LAN-IP>:8000`. On Android, plain HTTP to a LAN IP needs a
   `usesCleartextTraffic` / network-security-config exception; on iOS it needs an ATS exception.
2. **There is no CORS middleware.** React Native native builds do not enforce CORS, so this is fine
   — but an Expo *web* build will be blocked. If you need web, add `CORSMiddleware` server-side.
3. **If you want the app to work offline, that is new backend work**, not a frontend concern. You
   would need a local store on the device, an attempt outbox, and a sync endpoint. None of that
   exists today. Worth deciding before the rebuild starts.

The reusable Dart libraries and Supabase infrastructure are separate from this API.

---

## 1. Basics

**Base URL** `http://<host>:8000`, all endpoints under `/api`.

**Auth** Bearer token.

```http
Authorization: Bearer <token>
```

Tokens come from `/api/auth/login` or `/api/auth/register`. They are opaque random strings, stored
hashed server-side, and last **30 days**. There is no refresh token — on `401`, send the user back
to the sign-in screen.

**Roles** `teacher`, `student`, `learner` (self-learner). The role is fixed at registration and
decides which endpoints are allowed. `student` and `learner` differ only in that a student is
expected to join a class; both answer tasks the same way.

**Content types** JSON everywhere, with two exceptions that are `multipart/form-data`:
`POST /api/attempts` and `POST /api/recordings`.

### Errors

| Status | Meaning | `detail` type |
|---|---|---|
| 401 | Not signed in, or the session expired | string |
| 403 | Signed in, wrong role, or a locked lesson | string |
| 404 | Not found — **also returned instead of 403 to avoid revealing that another teacher's class exists** | string |
| 409 | Email already registered | string |
| 413 / 415 | Audio too large / unsupported type | string |
| 422 | Validation failed | **string _or_ array** |
| 429 | Too many failed logins (10 per 10 minutes) | string |
| 502 / 503 | AI unavailable or not configured | string |

**`detail` is not always a string.** Hand-written errors give a string; FastAPI's own body
validation gives an array. Handle both:

```json
{ "detail": "Email or password is not right." }
```
```json
{ "detail": [ { "type": "string_too_short",
                "loc": ["body", "name"],
                "msg": "String should have at least 1 character",
                "input": "" } ] }
```

```ts
function errorMessage(detail: unknown): string {
  if (typeof detail === 'string') return detail;
  if (Array.isArray(detail)) {
    return detail.map(d => `${d.loc?.slice(-1)[0] ?? ''}: ${d.msg}`).join('; ');
  }
  return 'Something went wrong.';
}
```

### Timestamps

Every timestamp is **ISO-8601 with a UTC offset**: `"2026-10-11T04:19:11+00:00"`. Safe to pass
straight to `new Date()`.

The one exception is `stats.days[].day`, which is a calendar day (`"2026-10-11"`), not an instant.

> This was inconsistent until recently — some fields came back as `"2026-10-11 04:16:01"`, which
> `new Date()` rejects on iOS. It is now normalised for every endpoint and there is a test that
> sweeps the API to keep it that way. If you ever see a space instead of a `T`, that is a bug —
> report it rather than working around it.

---

## 2. Auth

### `POST /api/auth/register`
```json
{ "name": "Rohit More", "email": "rohit@school.test",
  "password": "at-least-8-chars", "role": "student" }
```
→ `200` — same shape as login. `409` if the email exists.

### `POST /api/auth/login`
```json
{ "email": "aarav@demo.test", "password": "demo-pass-123" }
```
→ `200`
```json
{ "token": "4fyGkynrjOz2GCI_TdJwDOd2TRw6lUBiDoqXCGQe27Y",
  "user": { "id": 2, "name": "Aarav Patil", "email": "aarav@demo.test", "role": "student" } }
```
→ `401` `{"detail": "Email or password is not right."}` · `429` after 10 failures in 10 minutes.

### `POST /api/auth/logout` · `GET /api/me`
`logout` invalidates the token server-side. `me` returns the `user` object above.

### `GET /api/health` — no auth
```json
{ "ok": true, "server_speech_to_text": true, "demo": true, "ai": true }
```
Call this on launch. **`ai` decides the whole speaking flow** (see §6): `true` means the server
transcribes, `false` means the client must supply the text itself.

---

## 3. Classes

| Method | Path | Role |
|---|---|---|
| GET | `/api/classes` | any — teacher gets owned, learner gets joined |
| POST | `/api/classes` | teacher |
| GET | `/api/classes/{id}` | member |
| POST | `/api/classes/join` | student, learner |
| POST | `/api/classes/{id}/code` | teacher — rotates the join code |
| DELETE | `/api/classes/{id}/students/{sid}` | teacher |

**Class object.** `code` is **only present for the teacher** — do not rely on it client-side for a
student.

```json
{ "id": 1, "name": "English speaking", "standard": "6", "section": "A",
  "pincode": "411001", "state": "Maharashtra", "district": "Pune",
  "language": "en", "academic_year": "2026-27", "color": 0,
  "teacher": "Priya Deshmukh", "students": 5, "code": "EZWHVX" }
```

`GET /api/classes/{id}` adds `roster: [{ id, name, email, joined_at }]`.

`color` is `0–5`, a stable index for picking a card colour.

**Create** — `standard` is `"KG"`, `"1"`–`"12"` or `"adult"`; `pincode` must match `^[1-9][0-9]{5}$`;
`academic_year` must match `^20\d{2}-\d{2}$`.

**Join** `{ "code": "EZWHVX" }` → the class object, or `404`
`{"detail": "No class has that code. Check it with your teacher."}`

---

## 4. Assignments

| Method | Path | Role |
|---|---|---|
| GET | `/api/classes/{id}/assignments` | member |
| POST | `/api/classes/{id}/assignments` | teacher |
| GET | `/api/assignments/{id}` | member — **shape differs by role** |
| DELETE | `/api/assignments/{id}` | teacher |

**Create**
```json
{ "title": "Contract demo", "instructions": "Say each one clearly.",
  "due_at": "2026-12-01T18:30:00+00:00",
  "student_id": null,          // null = whole class, or a learner id for one person
  "recording_id": null,        // optional teacher voice note
  "set_id": null,              // use a ready-made practice set instead of items
  "items": [ /* see §5 */ ] }
```
Send **either** `set_id` **or** `items`. An assignment with no items but a `recording_id` is a
listen-only assignment.

**List / get**
```json
{ "id": 5, "class_id": 1, "title": "Contract demo",
  "instructions": "Say each one clearly.", "due_at": null,
  "created_at": "2026-10-11T04:19:11+00:00",
  "student_id": null, "recording_id": null,
  "item_count": 2, "targeted": false,
  "done_items": 0, "avg_best": null,
  "items": [ ... ], "best": {} }
```

Role differences, important:

| Field | Teacher | Learner |
|---|---|---|
| `audience`, `completed` | present | absent |
| `done_items`, `avg_best`, `best` | absent | present |
| `items[]` | **full, including `correct` and `explain`** | **answers stripped** |

`best` maps item index → best score so far: `{"0": 88, "2": 100}`. Keys are **strings**.

---

## 5. Task items — the core data type

Six kinds. Three are spoken, three are tapped.

```jsonc
// spoken — graded on transcript
{ "kind": "read",  "text": "The train is late." }
{ "kind": "free",  "prompt": "Tell us about your family." }
{ "kind": "build", "words": ["We","play","cricket"], "answer": "We play cricket" }

// tapped — graded on the chosen index
{ "kind": "choice", "prompt": "She ___ home.",  "options": ["go","goes"], "correct": 1, "explain": "Add s." }
{ "kind": "fill",   "prompt": "Good ___.",      "options": ["morning","mornings"], "correct": 0, "explain": "..." }
{ "kind": "listen", "text": "I live in Pune.",  "options": ["I live in Pune.","I leave in Pune."], "correct": 0, "explain": "..." }
```

Rules the server enforces:

- `fill` **must** contain `___` in the prompt — render it as a blank.
- `correct` is a 0-based index into `options`. 2–6 options, all distinct.
- `build` shuffles `words` client-side; the learner reorders them.
- `listen` keeps its `text` in the learner payload **on purpose** — the client speaks it aloud with
  text-to-speech. Do not show it.

**What learners receive:** `correct` and `explain` are **stripped**. Grading happens on the server,
so a learner can never read the answer out of the response.

```json
{ "kind": "choice", "options": ["go","goes"], "prompt": "She ___ home." }
```

---

## 6. Attempts — submitting an answer

### `POST /api/attempts` — `multipart/form-data`, not JSON

| Field | When | Notes |
|---|---|---|
| `item_index` | always | 0-based |
| exactly one of `assignment_id` / `lesson_id` / `set_id` | always | where the task came from |
| `choice` | tapped tasks | the chosen option index |
| `transcript` | spoken tasks | what the learner said, as text |
| `audio` | spoken tasks | the recording, optional but recommended |

**Which to send for a spoken task depends on `health.ai`:**

- **`ai: true`** — send `audio` with an **empty** `transcript`. The server transcribes with Whisper
  and grades that. This is the good path: better with Indian accents, and no dependence on
  on-device speech.
- **`ai: false`** — the server cannot transcribe. Send a `transcript` you produced yourself
  (device speech-to-text, or let the user type). Sending neither returns `422`.

```ts
const form = new FormData();
form.append('lesson_id', String(lessonId));
form.append('item_index', String(index));
form.append('transcript', serverListens ? '' : typedText);
if (recordingUri) {
  form.append('audio', { uri: recordingUri, name: 'attempt.m4a', type: 'audio/mp4' } as any);
}
// Do NOT set Content-Type; let fetch set the multipart boundary.
await fetch(`${BASE}/api/attempts`, { method: 'POST', body: form,
  headers: { Authorization: `Bearer ${token}` } });
```

Accepted audio: `audio/webm`, `audio/ogg`, `audio/mp4`, `audio/mpeg`, `audio/wav`, `audio/aac`.
Max **8 MB** per attempt. React Native records `.m4a` (`audio/mp4`) on both platforms — that works.

### Response — tapped task
```json
{ "id": 17, "transcript": "go", "score": 0, "accuracy": 0,
  "words": [], "extra_words": [], "grammar": [],
  "tips": ["The right answer is “goes”.", "Add s."],
  "correct": false, "correct_index": 1, "chosen": 0, "chosen_text": "go",
  "target": "goes", "question": "She ___ home.", "kind": "choice" }
```

### Response — spoken task
```json
{ "id": 18, "transcript": "the train is lte", "score": 88, "accuracy": 88, "kind": "read",
  "words": [
    { "target": "the",   "heard": "the",   "status": "correct" },
    { "target": "late",  "heard": "lte",   "status": "close"   }
  ],
  "extra_words": [],
  "grammar": [
    { "said": "he like music", "fix": "he likes music",
      "why": "With he, she or it, add s to the verb.",
      "skill": "MORPH.AGREEMENT", "rule": "ai", "start": 0, "end": 0 }
  ],
  "tips": ["I understood you. Two small verb mistakes.", "..."],
  "source": "ai",
  "verdict": "I understood you. Two small verb mistakes.",
  "strengths": ["You answered in a full sentence."],
  "next_line": "Tell me which song your brother likes best.",
  "target": "The train is late." }
```

Every attempt response also carries G1 fair-feedback fields:

```jsonc
"evaluation_status": "scored",        // or "unscored" when the audio could not be fairly graded
"uncertainty_reasons": [],            // e.g. ["low_match"] (wrong sentence/mishearing), ["no_speech"]
"basis": "word_accuracy",             // how it was graded: word_accuracy | exact_match | rubric | objective
"feedback_version": "1.0",
"normalization_version": "1.1"        // 1.1 = word-boundary reconciliation
```

- **`evaluation_status: "unscored"`** means do **not** treat the score as a grade or advance skill
  evidence from it — show the learner the uncertainty message and let them retry. `score` may still
  be present for display but is not authoritative.
- **`basis`** tells the UI how to frame the result (read = word-by-word accuracy, build/objective =
  exact match, free = rubric). Label it so a learner understands what was judged.
- Word-boundary differences (`every day` vs `everyday`, `log in` vs `login`) are **not** mistakes:
  they score as correct. Genuine mispronunciations still flag.

Field notes:

- `words[].status` is `correct` | `close` | `wrong` | `missed`. Render as a word-by-word mark-up.
  `heard` is `null` for `missed`.
- `source` is `"ai"` or `"rules"` — tells you whether a model or the regex fallback produced this.
- `verdict`, `strengths`, `next_line` are **only present when `source === "ai"`**. Treat them as
  optional.
- `grammar[].start` / `end` are character offsets, and are `0` for AI-produced corrections — do not
  rely on them for highlighting; match on `said` instead.
- For `read`, `score` is word accuracy. If almost nothing matched, the server returns
  `verdict: "That did not sound like the sentence on the page."` with **no** grammar corrections,
  rather than inventing mistakes from a misheard sentence. Show that message as-is.
- **Never present any of this as an accent judgement.** The backend deliberately excludes accent
  features from scoring; the UI must not reintroduce them.

### `GET /api/attempts/{id}/audio`
Returns the raw audio. Own attempts always; a teacher can fetch attempts from their own class.

---

## 7. Courses, units, lessons

### Teacher authoring

| Method | Path | Body |
|---|---|---|
| POST | `/api/courses` | `{ title, summary?, level, visibility, sequential }` |
| PATCH | `/api/courses/{id}` | any subset of the above |
| DELETE | `/api/courses/{id}` | |
| POST | `/api/courses/{id}/publish` | `{ "published": true }` |
| POST | `/api/courses/{id}/units` | `{ "title": "Unit one" }` |
| PATCH | `/api/units/{id}` | `{ "title": "..." }` |
| DELETE | `/api/units/{id}` | |
| POST | `/api/units/{id}/move` | `{ "direction": "up" }` |
| POST | `/api/units/{id}/lessons` | `{ title, intro?, recording_id?, items[] }` |
| PUT | `/api/lessons/{id}` | same — **full replace, not a patch** |
| DELETE | `/api/lessons/{id}` | |
| POST | `/api/lessons/{id}/move` | `{ "direction": "down" }` |

`level` is `A1`–`C2`. `visibility` is `"public"` (any learner can find it) or `"classes"` (only
classes it is given to). `sequential: true` locks each lesson until the one before is finished.

**Publishing is validated**: `422` if the course has no lessons, or if any lesson has no tasks —
the message names the lesson. Draft courses are invisible to learners (`404`).

### `GET /api/courses`
Shape depends on role.

```json
// teacher
{ "mine": [ { "id": 1, "title": "...", "level": "A1", "status": "published",
              "visibility": "public", "sequential": true,
              "units": 2, "lessons": 4, "teacher": "Priya Deshmukh", "learners": 5 } ],
  "available": [] }

// learner — "mine" are started/assigned, "available" are public ones to join
{ "mine": [ { "id": 1, "title": "Spoken English: first steps", "...": "...",
              "progress": { "lessons_done": 1, "lessons_total": 4, "percent": 25,
                            "avg": 75, "next_lesson_id": 2 } } ],
  "available": [ { "id": 3, "title": "...", "teacher": "..." } ] }
```

Optional `?q=` filters on title, summary and level.

### `GET /api/courses/{id}`
`mode` is `"owner"` or `"learner"` — **branch on it**.

```json
// learner: the lesson path
{ "id": 2, "title": "...", "mode": "learner",
  "units": [ { "id": 3, "title": "Unit one",
               "lessons": [ { "id": 5, "title": "Lesson one",
                              "status": "open", "stars": 0, "item_count": 2,
                              "done_items": 0, "avg": null, "has_recording": false } ] } ],
  "progress": { "lessons_done": 0, "lessons_total": 1, "percent": 0,
                "avg": null, "next_lesson_id": 5 },
  "enrolled": true, "via_class": false }
```

`status` is `done` | `open` | `locked`. `stars` is 0–3 (3 at avg ≥ 90, 2 at ≥ 70, 1 when complete).

The owner shape instead has `units[].lessons[] = { id, title, item_count, has_recording }` plus
`classes: [{ id, name }]`.

### `GET /api/lessons/{id}`
```json
{ "id": 5, "title": "Lesson one", "intro": "Read this first.",
  "recording_id": null, "unit_title": "Unit one",
  "course": { "id": 2, "title": "Contract demo course" },
  "position": 1, "lesson_total": 1, "next_lesson_id": null,
  "mode": "learner", "items": [ ... ], "best": {} }
```
`403` `{"detail": "Finish the lesson before this one first."}` on a locked lesson in a sequential
course. As with assignments, learner `items[]` have the answers stripped.

### Enrolment and class assignment

| Method | Path | Role |
|---|---|---|
| POST / DELETE | `/api/courses/{id}/enroll` | learner, student |
| POST | `/api/classes/{id}/courses` `{ "course_id": 2 }` | teacher — course must be published |
| DELETE | `/api/classes/{cid}/courses/{course_id}` | teacher |
| GET | `/api/classes/{id}/courses` | member — teacher gets `class_percent`, learner gets `progress` |

---

## 8. Practice catalogue

### `GET /api/catalog?q=`
```json
[ { "code": "en", "name": "English", "native": "English", "status": "available",
    "sets": [ { "id": "en-everyday", "title": "Everyday sentences", "level": "A1",
                "skill": "Speaking", "about": "...", "item_count": 6 } ] },
  { "code": "hi", "name": "Hindi", "native": "हिन्दी", "status": "soon", "sets": [] } ]
```
Only English has content. Everything else is `status: "soon"` with an empty `sets` — render it as
"coming soon", not as a broken list.

### `GET /api/sets/{set_id}`
Returns the set with full `items` and the learner's `best` map. Set items have **no hidden answers**
— they are fixed content, not graded quizzes.

---

## 9. Progress and insight

### `GET /api/me/stats` — learner's own
```json
{ "attempts": 10, "avg_score": 77, "recent_avg": 77, "streak_days": 1,
  "last_active": "2026-10-11T04:16:01+00:00",
  "by_kind": { "read": 93, "choice": 50, "listen": 0, "build": 100, "fill": 100 },
  "grammar_focus": [ { "code": "MORPH.AGREEMENT", "label": "He, she, it verbs",
                       "domain": "Word endings", "hint": "Adding s with he, she and it",
                       "accent_only": false, "skill": "MORPH.AGREEMENT", "count": 3 } ],
  "sound_focus": [ { "target": "likes", "said": "like", "count": 1 } ],
  "days": [ { "day": "2026-09-28", "attempts": 0, "avg": null } ],
  "weak_skills": [ { "code": "...", "label": "...", "hint": "...", "misses": 3,
                     "stuck": true, "accent_only": false, "last_miss": "..." } ],
  "due_count": 6,
  "classes": [ { "id": 1, "name": "English speaking", "assignments": 2, "completed": 0 } ] }
```
`days` is always exactly 14 entries, oldest first — safe to render as a fixed strip.
`code` and `skill` in `grammar_focus` are the same value; prefer `code`.
**Always display `label`, never `code`.** Skip anything with `accent_only: true`.

### `GET /api/me/review` — what is due to come back
```json
{ "items": [ { "kind": "choice", "options": ["go","goes"], "prompt": "She ___ home.",
               "source": { "assignment_id": 5, "item_index": 1 },
               "last_score": 0, "box": 1 } ],
  "title": "Your review",
  "weak_skills": [ ... ] }
```
Up to 8, weakest first. **`source` is what you post back** — spread it into the attempt form so the
answer is graded against the right task:

```ts
Object.entries(item.source).forEach(([k, v]) => form.append(k, String(v)));
```

Scheduling is Leitner: a wrong answer returns immediately, then 1, 2, 4, 8, 16 days as it keeps
going right. `box` is 1–6.

### Teacher views

| Endpoint | Gives you |
|---|---|
| `GET /api/classes/{id}/attention` | the "who needs me" queue |
| `POST /api/classes/{id}/attention/dismiss` | `{ student_id, reason }` — hides that flag for good |
| `GET /api/classes/{id}/skill-grid` | learners × skills, miss counts |
| `GET /api/classes/{id}/performance` | per-learner averages and activity |
| `GET /api/classes/{id}/students/{sid}` | one learner's recent attempts and stats |
| `GET /api/courses/{id}/progress` | per-learner course progress + per-lesson funnel |

**Attention queue** — each row is one student, one reason, one action.
```json
{ "class": { ... },
  "rows": [ { "student_id": 2, "name": "Aarav Patil",
              "last_active": "2026-10-11T04:16:01+00:00", "attempts": 10,
              "reason": "stuck_skill",
              "why": "Keeps getting “He, she, it verbs” wrong (3 times)",
              "action": "practise",
              "action_label": "Set practice on he, she, it verbs",
              "detail": { "skill": "MORPH.AGREEMENT", "label": "He, she, it verbs" },
              "severity": 3 } ] }
```

`reason` ∈ `never_started` | `inactive` | `quiet` | `stuck_skill` | `declining` | `below_proficient`.
`action` ∈ `assign` | `practise` | `review` — map to a screen:

| action | what the button should do |
|---|---|
| `assign` | open "new assignment", targeted at `student_id` |
| `practise` | same, pre-seeded with `detail.label` as the topic |
| `review` | open that learner's detail screen |

`severity` is 2–4, already sorted worst first. **`why` and `action_label` are written for display —
show them verbatim rather than rebuilding the sentence.**

**Skill grid** — `rows[].counts` is positionally aligned with `skills[]`.
```json
{ "skills": [ { "code": "MORPH.AGREEMENT", "label": "He, she, it verbs",
                "domain": "Word endings", "hint": "...", "accent_only": false,
                "total": 6, "students": 3 } ],
  "rows": [ { "student_id": 2, "name": "Aarav Patil", "counts": [3, 1, 0] } ] }
```

**Performance** — `{ "class": {...}, "students": [...], "class_avg": 81 }`, each student with
`attempts`, `avg_score`, `recent_avg`, `last_active`, `assigned`, `completed`, `top_issue`,
`needs_help`.

**Student detail** — `{ "student": {...}, "stats": {...}, "recent": [...] }`, where each `recent`
entry is `{ id, assignment, kind, target, transcript, score, tips[], has_audio, created_at }`.
Use `has_audio` to decide whether to offer playback of `/api/attempts/{id}/audio`.

---

## 10. Recordings (teacher voice notes)

### `POST /api/recordings` — `multipart/form-data`
Fields: `title`, `duration_ms` (500–600000), `file`. Max **20 MB**.
→ `{ "id": 2, "title": "Contract note", "duration_ms": 2500 }`

Attach the returned `id` to an assignment (`recording_id`) or a lesson.

### `GET /api/recordings/{id}/audio`
Streams the audio. A learner may fetch it only if it is attached to work they can see.

### Playing audio in React Native — the one gotcha

Audio endpoints require `Authorization: Bearer <token>`. Query-string tokens are rejected.
Use an authenticated media source supported by the selected player, or fetch into protected
application storage before playback. Never place a session token in a playback URL.

Uploads must be decodable, match the declared MIME type, and expose a valid duration of at
most ten minutes. Re-record or re-export files whose container metadata cannot be validated.
Do not infer playback support solely from the filename extension.

---

## 11. AI question drafting

### `POST /api/ai/items` — teacher only
```json
{ "topic": "using a, an and the", "count": 4,
  "kinds": ["choice", "fill"], "level": "A1",
  "context": "optional passage to build questions from" }
```
→ `{ "items": [ ... ], "asked_for": 4 }`

- `count` 1–12, clamped server-side.
- Items come back **already validated** — malformed drafts are dropped, so `items.length` may be
  less than `asked_for`. Show that honestly.
- `503` if no AI key is configured; `502` if the model produced nothing usable.
- Items arrive in full authoring shape, **with `correct` and `explain`**.

**This is a draft, not content.** The product rule, which the frontend must preserve: a teacher
reviews every item before it is saved. The web client marks each as an unchecked draft and refuses
to save the lesson until each is kept or deleted. Rebuild that gate — do not auto-save generated
questions.

---

## 12. Suggested build order

1. `GET /api/health` → login → `GET /api/me`. Store the token in secure storage, not AsyncStorage.
2. Learner home: `/api/me/stats` + `/api/me/review` + `/api/courses`.
3. The task runner (§5 + §6). This is the heart of the app and the hardest part — audio recording,
   the two feedback shapes, and the `health.ai` branch.
4. Courses and lessons.
5. Classes and assignments.
6. Teacher screens: attention queue, skill grid, performance.
7. Authoring: course builder, lesson editor, AI drafting.

### Things that will bite you if you skip them

- `multipart/form-data` on attempts, not JSON.
- `detail` is a safe string; structured `error` and sanitized validation `fields` carry additional information.
- Learner payloads have answers stripped — never assume `correct` exists.
- `best` map keys are strings, not numbers.
- `verdict` / `strengths` / `next_line` only exist when `source === "ai"`.
- `404` sometimes means "not yours", not "does not exist" — don't show "deleted" to the user.
- The server binds to `127.0.0.1` by default; a phone needs `--host 0.0.0.0`.
- There is no offline support. See §0.

### Generating a typed client

The server publishes typed success and error contracts at `/api/openapi.json` (docs at
`/api/docs`). All JSON operations declare response models. Some nested content and optional
additive fields remain extensible; generated clients should preserve the task `kind`
discriminator and handle documented optional fields rather than assuming every feedback
response has AI-only properties.

## Backend milestone update

The authoritative current inventory is `postman/API_LIST.txt` and typed schema is
`postman/openapi.json`. The additive backend release provides 71 application operations.
See `docs/BACKEND_IMPLEMENTATION_STATUS.md` and `deploy/backend/README.md` for migration,
submission recovery, lifecycle and deployment details.

All errors now include `{detail, error: {code, message, request_id}}`; validation errors
also include sanitized `fields`. Responses carry `X-Request-ID`. Audio requires an
Authorization bearer header; query-string tokens are no longer accepted. Media must
be valid decodable audio. DELETE on content with learner attempts returns 409; use
its archive operation instead. The new behavior supersedes older examples above.
