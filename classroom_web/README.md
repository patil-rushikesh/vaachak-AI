# Vaachak Classroom

A Google-Classroom-style app for learning spoken English. Runs locally; no cloud account needed.

**New here? [USAGE.md](USAGE.md) walks through the app for teachers, students and self-learners.**
This file is the technical reference.

**Three logins**
- **Teacher** – create classes (standard, section, pincode, district, state, language), share a join code, record a voice lesson in the browser and assign it to the whole class or one learner, add extra practice for a single learner, see class and per-learner performance.
- **Student** – join a class with the code, see classwork and due dates, play the teacher's recording, practise, see own stats.
- **Self-learner** – no class needed; search the practice catalogue (English open, other languages listed as "coming soon") and practise.

**Courses (new)**
- A teacher builds a course: units → lessons → tasks, with a teaching note and an optional voice note per lesson. Task types: read aloud, speak an answer, build a sentence, multiple choice, fill in the blank, listen and choose.
- Publish it, then give it to a class (it appears in the class's Courses tab) or leave it public so any learner can find and start it. Draft courses are never visible to learners.
- Learners work through lessons in order (the teacher can switch that off). A lesson is finished when every task has been answered; stars (1 to 3) show how well, and any task can be retried.
- The teacher's Learners tab shows each learner's progress, average and last activity, plus a lesson-by-lesson view.
- Review (under Practice): picks the tasks a learner got wrong or only half right, so weak spots come back until they score 80 or more.
- Quiz answers are graded on the server and the correct answer is never sent to the learner's browser before they answer.

**For the teacher, when time is short**
- **Needs you** is the first thing you see in a class: a short list of who needs attention, why, and one button to do something about it. It flags a learner who never started, who has gone quiet for a week, who is working far less than the class, who keeps getting the same skill wrong, whose scores are falling, or who is doing the work but not getting it. "Not useful" removes a flag for good, so the list stays worth reading.
- **Skills** shows a grid of which skills each learner gets wrong, so you can see what to teach next rather than guessing.
- **Draft tasks with AI** writes practice questions from a topic, or from a passage you paste. Everything arrives as a draft you must read: fix anything wrong, Keep what you want, delete the rest. The app refuses to save a lesson while an AI draft is still unchecked, and drafting again adds to what you have rather than replacing it.

**For the learner**
- **Today** is one screen with one thing to do next, chosen for them: review what they got wrong, carry on with their course, or start one. No menu to work through.
- **What to work on** names the skills they keep getting wrong, in plain words, each with a button that practises it.
- **Review** brings mistakes back on a spaced schedule (Leitner boxes: straight away, then after 1, 2, 4, 8 and 16 days). Answer it well and it comes back later; get it wrong and it returns at once. A task that survives the longest gap stops appearing.

**Feedback after every answer**: the words are transcribed, grammar mistakes are shown with the fix and a reason (red-pen style), reading mistakes are marked word by word, and sentence-building tasks check word order. Progress shows scores, streak, grammar to review and sounds to practise.

## Run it (Windows PowerShell)

```powershell
cd classroom_web
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python run.py --seed          # first time: loads demo accounts. Later: python run.py
```

Open http://localhost:8000 in **Chrome or Edge**.

Demo accounts (password `demo-pass-123`): `teacher@demo.test`, `aarav@demo.test` (student), `meera@demo.test` (self-learner). Demo class join code is printed by the seed step; the teacher sees it on the class page.
`--seed` wipes the database. Without it, your data in `data/` is kept. To get the sample course on an older database, double-click `start-fresh.bat` (it asks first, then resets the demo data).

## The AI (Groq)

Put your key in a file called `vaachak.env` next to `run.py`:

```
GROQ_API_KEY=gsk_your_key_here
```

That file is in `.gitignore`, so the key never gets committed. Then check it:

```powershell
python check_ai.py                          # key, models, and a real feedback call
python check_ai.py path\to\a\recording.m4a  # also test speech-to-text on real audio
```

Groq renames models from time to time. If the check reports that none of the feedback models are
available, it prints the exact line to paste into `vaachak.env`, for example:

```
VAACHAK_CHAT_MODEL=openai/gpt-oss-120b
```

The check never suggests a guard or moderation model: those answer the models endpoint but cannot
write feedback.

With a key present:
- **Speech-to-text runs on the server** (Whisper), not in the browser. The learner taps Record, taps Stop, and the feedback appears. No typing step, no dependence on Chrome's speech engine, and it handles Indian accents far better.
- **Feedback comes from a language model.** It judges whatever the learner actually said, not a fixed list of patterns, and returns corrections in the learner's own words plus a sentence to try next.
- The model is told to correct meaning and grammar, **never accent**, and that Indian English is correct English.
- Mistakes are filed under a fixed list of skills (`server/skills.py`), which is what makes "what is this learner weak at" answerable. The list was built from the mistakes Marathi and Hindi speakers actually make in English.

### Accent is never marked wrong
Retroflex t and d, long vowels and Indian rhythm are correct English and are excluded from scoring, from the skill counts, and from the teacher's flags. Words like *prepone* and *do the needful* are never "corrected". Words are compared by how they sound rather than how they are spelt, so `bought`/`bot` and `school`/`skool` are not treated as errors. The app deliberately stays quiet when unsure: wrongly telling a learner their correct speech is wrong costs more than missing one real slip. Only sound contrasts that change meaning are practised: th, v/w, z/s, sh/s, f/p.

With no key, or no internet, the app falls back to the built-in rules and the browser's own speech recognition. Nothing breaks; the feedback is just shallower.

### Limits worth knowing
- Reading-aloud scores come from comparing words, not from listening to your pronunciation. If almost nothing matches, the app says it could not hear the sentence instead of inventing grammar mistakes.
- Groq's free tier is rate-limited. On HTTP 429 the app quietly falls back to the rules.
- The learner's speech is passed to the model as fenced data with an instruction to treat it as speech only, so a learner cannot talk the coach into changing its behaviour.

## How speech works
- Recording uses the browser microphone (MediaRecorder). Audio files are saved under `data/audio/` on this computer.
- With a Groq key, the server transcribes (see above). Without one, the browser's built-in speech recognition is used (Chrome/Edge), and you can type if it fails.
- Fully offline transcription instead of Groq: `pip install faster-whisper`, then set `VAACHAK_WHISPER_MODEL=small.en`.
- **Pronunciation feedback is inferred from the transcribed words**, not from the sound itself. It is a guide, not an acoustic grade. Nothing in the app scores your accent.

## Data
SQLite file at `data/classroom.db`. Passwords are PBKDF2-hashed; session tokens are stored hashed; login attempts are throttled. Set `VAACHAK_DATA` to move the data folder.

## Tests
```powershell
pip install -r requirements-dev.txt
python -m pytest
```

## Where the thresholds live
`server/insights.py`, at the top: how many days of silence counts as quiet, how many misses make a skill "stuck", what counts as below proficient, and the review intervals. Change the numbers there; nothing else needs touching.

## Not built yet
Server-side acoustic pronunciation scoring (the marks come from the transcript, not the sound). Languages other than English. Email and password reset. A teacher preview that runs a lesson as a learner. Games and leaderboards. A two-way link where a learner sends a recording to the teacher and gets a reply back. Editing a lesson's tasks after learners have answered can shift which task their old answers belong to, so prefer adding tasks at the end. The Flutter app in `../` has a Supabase design for cloud sync; this web app is a standalone local version.
