# Vachak AI — 5–7 minute presentation

Open [Vachak AI](http://127.0.0.1:8000/). This machine already has the local speech model (`base.en`) and Ollama meaning model (`qwen2.5:0.5b-instruct`); no API key or extra model download is needed. The backend is currently running with both enabled.

## Prepare before sharing your screen

Open two fresh tabs at the address above: one teacher and one student. Sessions use `sessionStorage`, so the tabs can hold different roles. Read the credentials privately from `backend/data/demo-accounts.json`; do not display that file during the presentation. It has owner-only permissions (`0600`).

| Account | Credential fields | Purpose |
| --- | --- | --- |
| Teacher | `teacher_email`, `teacher_password` | Create, assign and review work |
| Aarav (demo) | `student_login`, `student_password` | Account for further live submissions (may already contain your test attempts) |
| Mira (presentation demo) | `presentation_student_login`, `presentation_student_password` | Completed evidence if time or microphone access is limited |

Keep these files ready in the upload picker:

- Teacher reference: `/Users/admin/genai/backend/data/demo-fixtures/synthetic-reference.wav`
- Student attempt: `/Users/admin/genai/backend/data/demo-fixtures/synthetic-student.wav`

Both are **synthetic demonstration recordings**, not recordings of a real learner. The reference sentence is: “Okay, this is my house. I love reading books with my friends.”

## New profile and visual feedback features

Open **Learning profile** to enter country, state/region, city, first language and an accent to practice. These fields are optional and can also be entered during teacher registration or student creation. Teachers can edit a student's profile from that student's progress screen. Use clearly fictional values if demonstrating with the demo accounts. Region is supplied context, not an automatically detected accent or a grading factor. New recordings preserve the profile at upload time; existing recordings keep their original context.

Feedback now leads with a short explanation and next steps. Reading cards keep word matching, pace, pauses and voice expression separate; the full measurements can still be expanded. Progress uses a completion donut, separate skill bars and score histories. Unassessed pronunciation and experimental pitch are not shown as accuracy percentages.

## Walkthrough

1. **0:00–0:45 — Teacher and classroom.** Sign in as the teacher. Open **My classrooms → Class 6 · English** at Vachak Demo School and show Aarav's roster entry. Explain the setup path: create a classroom with school, class/section and postal PIN, then **Add student** with a name, unique username and initial password. Show these forms briefly; use the existing classroom and Aarav for the live flow. Student progress also has a teacher-managed password reset.

2. **0:45–2:00 — Create a reusable voice practice.** Open **Problem library**, create a reading practice titled “Live reading practice,” and enter the reference sentence above. Add a short teaching note such as “Pause after house.” Use **Upload audio** to select `synthetic-reference.wav`, or **Start recording → Stop recording** to capture your own example. Preview it, then **Save practice**. Show its stable problem ID and saved reference recording. The library also supports choice, matching and meaning questions.

3. **2:00–2:40 — Assign it.** Open **Assignments**, create an assignment titled “Live reading,” select **An individual student**, then **Class 6 · English → Aarav (demo)**. Select the new reading practice and its reference, and save. Point out that the same flow can assign several practices to an entire classroom. Assigned content and recipients are saved as a snapshot.

4. **2:40–4:00 — Student listens and responds.** Switch to Aarav's tab, open **My assignments → Live reading**, and enter the practice. Play the teacher reference. Record a short response or upload `synthetic-student.wav`, preview it, and choose **Send my recording**. The app shows **Analyzing** while the local queue works. Open the feedback to show the recognized words, missing/extra words, pace, pauses and experimental pitch contour. Call the displayed percentage a **word-match score**; it is not a validated pronunciation grade. Live recordings can produce different results.

5. **4:00–5:20 — Meaning and teacher judgment.** In Aarav's existing **Your first English practice** assignment, open **Say it in your own words**. Submit “Could you help me carry these books?” using **Check my answer**. A paraphrase waits for teacher review. The local model may provide a provisional suggestion; if it cannot assess the response, the teacher can still review the saved answer. Switch to the teacher's **Student progress → Aarav**, find the attempt and choose **Give feedback**. Read the response and rubric, enter your judgment (100% is appropriate for this complete paraphrase), add feedback and **Save teacher feedback**. Reopen the student's feedback to show the confirmed result. AI suggestions are private to the teacher and do not automatically become student grades.

6. **5:20–6:30 — Show the complete picture.** In the teacher tab, open **Student progress → Mira (presentation demo)**, in the **Presentation practice** classroom. All four types already have saved results: reading **92% word match** with “books” missed, choice **100%**, matching **100%**, and meaning **100% confirmed by the teacher**. Show the recordings, evidence and progress together. Expand the reading evidence and **Compare expression word by word**: pitch is centered on each speaker's own median, so a naturally higher voice is not marked wrong.

Close with: “The teacher provides the example, the student practices, the system records evidence, and the teacher can review the outcome.” Pitch is experimental and ungraded; the app does not infer emotion or provide calibrated phoneme/pronunciation grades. Original audio is preserved for future analysis.

## If microphone access or analysis delays the demo

Microphone capture requires browser permission and localhost/HTTPS. Live microphone capture has not yet been verified on this presentation setup; normal audio playback has been checked. Use **Upload audio** with the saved WAV files if recording is blocked. Recordings must be 0.5–120 seconds and at most 20 MiB.

If processing takes longer than the presentation allows, move directly to Mira's saved results. To show the student view, sign out in the student tab and sign in using the `presentation_student_*` credentials. Open **My progress** or **Presentation — English practice**. A **Teacher review** result means the work is saved but needs judgment; it is not a failed submission. Pending work resumes after a backend restart.

## Start, stop and keep a private backup

If the services have stopped, start Ollama in one terminal, only if it is not already running:

```sh
OLLAMA_HOST=127.0.0.1:11434 OLLAMA_NO_CLOUD=1 ollama serve
```

Then start the app in another terminal:

```sh
cd /Users/admin/genai/backend
VAACHAK_TEXT_PROVIDER=ollama VAACHAK_TEXT_MODEL=qwen2.5:0.5b-instruct ./run_demo.sh
```

The script finds the downloaded speech model automatically. Run one backend process. Existing accounts and evidence are already saved; reseeding is unnecessary.

Stop the backend with **Ctrl+C** in its terminal and wait for shutdown. Stop Ollama with **Ctrl+C** too if you started it in a terminal. For a consistent private backup, stop the backend first, then run:

```sh
cd /Users/admin/genai/backend
umask 077
mkdir -p "$HOME/vachak-private-backups"
tar --exclude='data/models' --exclude='data/.analysis-worker.lock' \
  -czf "$HOME/vachak-private-backups/data-$(date +%Y%m%d-%H%M%S).tar.gz" data
```

This keeps the database, recordings, fixtures and credential file together, excluding downloaded model weights. Keep the archive private and outside source control. Restart with the same command and data directory when ready.
