# Demo integration contract — 25 September 2026

The backend and presentation UI are implemented. This file records initial integration decisions, with key implementation updates below. Use [API_GUIDE.md](API_GUIDE.md) for the current client contract and assessment semantics, and [DEMO_GUIDE.md](DEMO_GUIDE.md) for the presentation.

Build the existing FastAPI service into a same-origin responsive web app. Preserve legacy routes/tests. New product API uses /teacher and /student prefixes. FastAPI serves the frontend at / and static files at /assets. JSON errors use `detail`; all private calls use Bearer authentication. UUID strings are identifiers, ISO UTC strings are dates. Empty states reflect real data.

## Authentication (root owns)
- POST /auth/register {email,password}: teacher account for local prototype, returns login response.
- POST /auth/login {identifier,password,role:"teacher"|"student"}; legacy {email,password} still works for teachers.
- Response {access_token,token_type,expires_in,user:{id,role,display_name}}.
- GET /auth/me → {id,role,display_name}.
- POST /auth/logout → 204.
- Teachers provision students through their classroom (no public student signup).

## Teacher product API (domain agent owns)
- GET/POST /teacher/classrooms. Create {school_name,name,postal_code}; return {id,school_name,name,postal_code,join_code,student_count}. Postal PIN and join code are separate.
- GET /teacher/classrooms/{id} → classroom plus students [{id,display_name,login_name}].
- POST /teacher/classrooms/{id}/students {display_name,login_name,password} → student. Teacher supplies initial password; hash only is stored.
- GET /teacher/students/{id} → identity, classroom and real progress/attempt evidence.
- GET /teacher/overview → counts and recent activity.
- GET/POST /teacher/problems. Create {title,kind,expected_text,teaching_notes,payload}. Kinds read_aloud,choice,matching,meaning.
  - read_aloud: expected_text is spoken sentence; payload {expression?:string}.
  - choice: expected_text is prompt; payload {options:[{id,text}],correct_option_id,skill:"synonym"|"antonym"|"vocabulary"}.
  - matching: expected_text prompt; payload {pairs:[{id,left,right}],skill:"synonym"|"antonym"|"vocabulary"}.
  - meaning: expected_text prompt; payload {accepted_answers:[string],rubric:string}.
- GET /teacher/problems/{id} → full problem including payload and recordings.
- Reference audio upload remains POST /problems/{id}/recordings multipart `file`; listing and playback existing routes.
- GET/POST /teacher/assignments. Create {title,classroom_id?:UUID,student_id?:UUID,problems:[{problem_id,recording_id?:UUID}]}. Exactly one target. Read-aloud requires a reference recording. Freeze content and recipients at assignment time. Return {id,title,target_label,created_at,student_count,problem_count}.
- GET /teacher/assignments/{id} → assignment with recipient progress.
- PATCH /teacher/attempts/{id}/review {score:0..1,feedback:string} → reviewed attempt.

## Student product API (domain agent owns)
- GET /student/overview → student identity, classroom, counts, progress, recent feedback.
- GET /student/assignments → [{id,title,teacher_name,problem_count,completed_count,created_at}].
- GET /student/assignments/{id} → {id,title,problems:[{id,title,kind,expected_text,teaching_notes,payload,reference_audio_url?,attempts:[]}]}.
- Student problem payload must not include correct answers, accepted meanings or teacher-only rubric. Matching payload gives shuffled `left:[{id,text}]` and `right:[{id,text}]` with independent IDs, never exposes pair mapping.
- POST /student/assignments/{id}/problems/{problem_id}/attempts JSON {request_id:UUID,answer:...}. Choice answer=option ID, matching answer={left_id:right_id}, meaning answer=string.
- POST /student/assignments/{id}/problems/{problem_id}/recordings multipart `file`, `request_id`: saves audio attempt.
- GET /student/attempts/{id} → status/results. All attempts immutable except analysis/review status. `request_id` makes retries idempotent; changed payload with same key is a conflict.
- Each attempt result {id,status,score:number|null,feedback,result,created_at}; status pending/completed/needs_review/failed. Automatic reading metrics are explicitly experimental word accuracy/pace, not phoneme grading. Experimental pitch tracks and word-aligned relative comparison are available, without pitch scores or emotion inference; original audio is preserved.
- Reference and attempt playback must authorize the assigned student or owning teacher. No answer-key leaks in response payloads.

## Code ownership and integration
- Root: api.py/db.py/security.py/cli.py, auth, integration, demo bootstrap, documentation and final verification.
- Domain agent: domain_models.py, domain_api.py, domain_tests. Exports `install_domain_routes(app, ctx)`; `ctx` supplies db dependency, current_teacher/current_student returning actor IDs, current_actor returning {id,role}, directory, factory. Domain models import Base/Problem/Recording/Teacher from db; root imports domain_models before create_all.
- Domain Student fields required for root auth: id, teacher_id, classroom_id, display_name, login_name (globally unique lowercase), password_hash, created_at.
- Frontend agent: backend/frontend/* only; run `frontend/build.sh` after editing JavaScript and retain the checked-in bundle. Running the app requires no frontend build or CDN.
- Speech agent: speech_service.py, prosody.py and their tests. Exports analyze_reading(audio_path, expected_text, reference_path=None) and evaluate_meaning(answer,accepted_answers,rubric). Results {status,score,feedback,result}. No fabricated results when model absent. Optional local ASR; optional text-provider config. Domain calls services outside long DB transactions using a database-backed, restart-safe local worker; BackgroundTasks is only the deterministic test fallback.

## Deadline priorities
Teacher creates classroom/student/problem → assigns → student logs in/practices/submits → teacher sees evidence/reviews. Live microphone capture with uploaded-file fallback. Voice original preserved, never denoised or pitch/time shifted. Full desktop/mobile browser paths and genuine empty/error/loading states. No fake learner data outside explicitly labeled demo fixtures.
