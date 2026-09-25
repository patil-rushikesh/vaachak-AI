"""Create explicitly labeled local demo content, without invented learner results."""
import json
import os
import secrets
import shutil
import subprocess
from pathlib import Path

from fastapi.testclient import TestClient

from .api import create_app


def main():
    # Seeding is not a server restart. Do not mark a running server's jobs failed.
    app = create_app(recover_jobs=False, analysis_worker=False)
    directory = app.state.data_directory
    account_file = directory / "demo-accounts.json"
    with TestClient(app) as client:
        if account_file.exists():
            accounts = json.loads(account_file.read_text())
            login = client.post("/auth/login", json={"identifier": accounts["teacher_email"],
                                                     "password": accounts["teacher_password"], "role": "teacher"})
            if login.status_code == 200:
                if not accounts.get("assignment_id"):
                    raise SystemExit(f"Demo setup was interrupted. Existing accounts are preserved in {account_file}; finish assigning their saved problems through /docs.")
                client.headers["Authorization"] = f"Bearer {login.json()['access_token']}"
                assignment = client.get(f"/teacher/assignments/{accounts['assignment_id']}")
                if assignment.status_code != 200:
                    raise SystemExit("Stored demo assignment is unavailable. Check DATABASE_URL and VAACHAK_DATA_DIR; existing records were not replaced.")
                print(f"Demo already exists. Credentials: {account_file}")
                return
            raise SystemExit("Demo account file exists but login failed. Check DATABASE_URL and VAACHAK_DATA_DIR; existing records were not replaced.")

        suffix = secrets.token_hex(3)
        accounts = {"teacher_email": f"demo.teacher.{suffix}@example.test", "teacher_password": secrets.token_urlsafe(12),
                    "student_login": f"aarav-demo-{suffix}", "student_password": secrets.token_urlsafe(12)}

        def request(method, path, body=None, **kwargs):
            response = client.request(method, path, json=body, **kwargs)
            if response.status_code >= 400:
                raise RuntimeError(f"Demo setup failed at {method} {path}: {response.status_code} {response.text}")
            return response.json()

        auth = request("POST", "/auth/register", {"email": accounts["teacher_email"], "password": accounts["teacher_password"]})
        client.headers["Authorization"] = f"Bearer {auth['access_token']}"
        room = request("POST", "/teacher/classrooms", {"school_name": "Vachak Demo School", "name": "Class 6 · English", "postal_code": "411001"})
        student = request("POST", f"/teacher/classrooms/{room['id']}/students", {
            "display_name": "Aarav (demo)", "login_name": accounts["student_login"], "password": accounts["student_password"],
        })
        accounts["classroom_id"] = room["id"]
        accounts["student_id"] = student["id"]
        account_file.write_text(json.dumps(accounts, indent=2) + "\n")
        account_file.chmod(0o600)

        examples = [
            {"title": "A word for happy", "kind": "choice", "expected_text": "Which word means the same as happy?",
             "teaching_notes": "Look for a word with a similar meaning.",
             "payload": {"skill": "synonym", "options": [{"id": "joyful", "text": "Joyful"}, {"id": "tired", "text": "Tired"}, {"id": "angry", "text": "Angry"}], "correct_option_id": "joyful"}},
            {"title": "Opposites attract", "kind": "matching", "expected_text": "Match each word to its opposite.",
             "teaching_notes": "Take your time and check every pair.",
             "payload": {"skill": "antonym", "pairs": [{"id": "hot", "left": "Hot", "right": "Cold"}, {"id": "early", "left": "Early", "right": "Late"}, {"id": "bright", "left": "Bright", "right": "Dark"}]}},
            {"title": "Say it in your own words", "kind": "meaning", "expected_text": "What does 'Please lend me a hand with these books' mean?",
             "teaching_notes": "Explain the idea in your own words. You do not need the exact sentence.",
             "payload": {"accepted_answers": ["Please help me carry these books", "They are asking for help with the books"],
                         "rubric": "The speaker is asking someone to help with carrying or handling books. 'Lend me a hand' means help, not literally give a body part."}},
        ]
        selected = []
        for body in examples:
            problem = request("POST", "/teacher/problems", body)
            selected.append({"problem_id": problem["id"]})

        voice = request("POST", "/teacher/problems", {
            "title": "Read with a welcoming voice", "kind": "read_aloud",
            "expected_text": "Okay, this is my house. I love reading books with my friends.",
            "teaching_notes": "Listen, pause between the sentences, and read naturally. This demo reference uses a synthetic voice.",
            "payload": {"expression": "Warm and welcoming"},
        })
        fixture_dir = directory / "demo-fixtures"
        fixture_dir.mkdir(exist_ok=True)
        wav = fixture_dir / "synthetic-reference.wav"
        if shutil.which("say") and shutil.which("ffmpeg"):
            original = fixture_dir / "synthetic-reference.aiff"
            subprocess.run(["say", "-v", "Samantha", "-o", str(original), voice["expected_text"]], check=True)
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(original), str(wav)], check=True)
        if wav.exists():
            with wav.open("rb") as file:
                recording = request("POST", f"/problems/{voice['id']}/recordings", files={"file": ("synthetic-reference.wav", file, "audio/wav")})
            selected.append({"problem_id": voice["id"], "recording_id": recording["id"]})
        assignment = request("POST", "/teacher/assignments", {"title": "Your first English practice", "classroom_id": room["id"], "problems": selected})
        accounts["assignment_id"] = assignment["id"]
        account_file.write_text(json.dumps(accounts, indent=2) + "\n")
        print(f"Created demo classroom, student, four practice records and an assignment. No learner attempts were generated.\nCredentials: {account_file}")


if __name__ == "__main__":
    main()
