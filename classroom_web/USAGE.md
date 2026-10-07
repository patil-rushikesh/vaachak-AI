# How to use Vaachak Classroom

A walk through the app for each of the three kinds of user. If you only want to get it running,
the first section is enough.

---

## Start it

Double-click **`start.bat`** in this folder. It makes a Python environment the first time, installs
what it needs, and opens your browser at <http://localhost:8000>.

Use **Chrome or Edge**. Leave the black window open while you use the app; closing it stops the server.

| If this happens | Do this |
|---|---|
| "only one usage of each socket address" | It is already running. Just open <http://localhost:8000>. |
| "Could not create a Python environment" | Install Python 3.10 or newer from python.org, ticking **Add Python to PATH**. |
| You want the demo data back | Run **`start-fresh.bat`** and type `YES`. This erases everything in `data\`. |
| The browser asks for the microphone | Allow it. Speaking practice needs it. |

**Demo accounts**, password `demo-pass-123` for all of them:

| Role | Email |
|---|---|
| Teacher | `teacher@demo.test` |
| Student | `aarav@demo.test`, `diya@demo.test`, `kabir@demo.test`, `sana@demo.test`, `omkar@demo.test` |
| Self-learner | `meera@demo.test` |

To watch a teacher and a student at the same time, open one in a normal window and the other in an
Incognito window. Signing in twice in the same window signs the first one out.

### Turn the AI on

Without a key the app still works, but feedback comes from a fixed list of rules and is much
shallower. With a key, the server listens to the recording itself and the feedback is written for
whatever the learner actually said.

1. Make a file called **`vaachak.env`** in this folder containing one line:
   `GROQ_API_KEY=gsk_your_key_here` (get one free at <https://console.groq.com/keys>).
2. Run `python check_ai.py`. It tells you whether the key works and which models you have.
3. Restart the app.

`vaachak.env` is in `.gitignore`, so your key is never committed.

---

## If you are a teacher

### Make a class
**Classes → Create class.** Give it a name, standard, section, pincode, district and state. You get a
six-character join code — share that with your students. They enter it under Classes to join.

### Start with "Needs you"
Opening a class lands you on **Needs you**, not on a list of files. It is a short list of who needs
you and why, worst first, with one button each:

| What it says | What it means | The button does |
|---|---|---|
| Has not answered anything yet | Enrolled, never started | Gives them a short task |
| Nothing for N days | Gone quiet | Gives them a short task |
| Only N answers while the class has done much more | Hanging back quietly | Gives them a short task |
| Keeps getting "X" wrong | Stuck on one skill | Sets practice aimed at that skill |
| Scores falling: 90 down to 60 | Slipping | Opens their answers |
| Doing the work but averaging 45 | Trying but not getting it | Opens their answers |

If a flag is not useful for that student, press **Not useful** and it never comes back. The list is
only worth reading if it stays short, so use that.

### See what to teach next
**Skills** is a grid of every learner against the skills they get wrong most. A column with big
numbers across several learners is a lesson for the whole class. One big number in one row is a
conversation with one student.

### Build a course
**Courses → New course.** A course holds units, a unit holds lessons, and a lesson holds a teaching
note, an optional voice note, and tasks.

- **Draft tasks with AI** writes questions from a topic, or from a passage you paste in.
  Everything arrives marked **AI draft**. Read each one, fix anything wrong, then press **Keep**, or
  **Delete** it. The app will not save the lesson while a draft is still unchecked, and drafting
  again *adds* to what you have rather than replacing it.
- **Publish** when it is ready. Then give it to a class from the course page, or leave it public so
  any self-learner can find it. Drafts are invisible to learners.
- By default a learner must finish each lesson before the next opens. Turn that off under
  **Course details** if you want them to roam.

### Set work for one class or one student
**Classwork → New assignment.** Pick a ready-made practice set, or write your own tasks, or draft
them with AI. Record a voice lesson in your browser if you want them to hear you first. Under
**Assign to**, choose the whole class or one learner.

### Task types
Read aloud · Speak an answer · Build a sentence · Multiple choice · Fill in the blank · Listen and choose.
The first three use the microphone; the last three are tapped.

---

## If you are a student

**Today** is your home. It gives you one thing to do, already chosen:

- **Go over N things again** — tasks you got wrong before, come back to be fixed.
- **Carry on with …** — the next lesson in your course.
- Otherwise, something to start.

**What to work on** names the things you keep getting wrong in plain words, each with a button that
practises it. **This week** shows which days you spoke. There is no unbroken-streak counter; missing a
day costs you nothing.

### Doing a speaking task
Tap **Record**, say the sentence out loud, tap **Stop**. That is all — the feedback appears by itself.
If the words that come back are not what you said, use **Not what you said? Correct it**. If you cannot
speak right now, open **Can't speak right now? Type your answer**.

You get a score out of 100, the mistakes with the fix and a short reason, what you did well, and one
sentence to try saying next.

**Your accent is never marked wrong.** Indian English is correct English. Only sounds that change the
meaning of a word are practised.

### Joining a class
**Classes**, enter the six-character code from your teacher.

---

## If you are a self-learner

Everything a student has, except you do not need a class. **Courses** lists the public ones; open one
and press Start. **Practice** has sets you can do any time. You can still join a class later with a
code if a teacher gives you one.

---

## Things worth knowing

- **Pronunciation marks come from the words that were heard, not from the sound itself.** They are a
  guide, not a verdict. The app says "that did not sound like the sentence on the page" rather than
  inventing grammar mistakes when it mishears you.
- **Everything stays on this computer.** `data\classroom.db` holds the accounts and answers;
  `data\audio\` holds the recordings. With an AI key, the recording and the text are sent to Groq to
  be transcribed and marked; nothing else leaves.
- **Review timing**: a task you got wrong comes back immediately, then after 1, 2, 4, 8 and 16 days as
  you keep getting it right. One that survives the longest gap stops appearing.
- **Changing the thresholds**: the top of `server/insights.py` holds how many days count as quiet,
  how many misses make a skill "stuck", and the review intervals. Change the numbers there.
- **Editing a lesson's tasks after learners have answered** can shift which task their old answers
  belong to. Prefer adding new tasks at the end.

## Running the tests

```powershell
pip install -r requirements-dev.txt
python -m pytest
```
