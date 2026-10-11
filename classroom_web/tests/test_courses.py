from pathlib import Path
WAV = (Path(__file__).resolve().parents[2] / "postman/fixtures/silence.wav").read_bytes()
import sqlite3

import db
from conftest import make_user

QUIZ = {"kind": "choice", "prompt": "Pick the right word: She ___ to school.", "options": ["go", "goes"], "correct": 1, "explain": "Add s with she."}
FILL = {"kind": "fill", "prompt": "They ___ happy.", "options": ["is", "are"], "correct": 1}
LISTEN = {"kind": "listen", "text": "I like apples.", "options": ["I like apples.", "I lick apples."], "correct": 0}
READ = {"kind": "read", "text": "Good morning."}


def build_course(client, t, publish=True, sequential=True, visibility="public"):
    c = client.post("/api/courses", headers=t, json={"title": "First steps", "summary": "Basics", "level": "A1", "visibility": visibility, "sequential": sequential}).json()
    u = client.post(f"/api/courses/{c['id']}/units", headers=t, json={"title": "Greetings"}).json()
    l1 = client.post(f"/api/units/{u['id']}/lessons", headers=t, json={"title": "Hello", "intro": "Say hello.", "items": [QUIZ, FILL]}).json()
    l2 = client.post(f"/api/units/{u['id']}/lessons", headers=t, json={"title": "Listen", "items": [LISTEN, READ]}).json()
    if publish:
        r = client.post(f"/api/courses/{c['id']}/publish", headers=t, json={"published": True})
        assert r.status_code == 200, r.text
    return c["id"], l1["id"], l2["id"]


def answer(client, h, lesson_id, idx, choice=None, transcript=""):
    data = {"lesson_id": lesson_id, "item_index": idx, "transcript": transcript}
    if choice is not None:
        data["choice"] = choice
    return client.post("/api/attempts", headers=h, data=data)


def test_only_teachers_author(client, world):
    r = client.post("/api/courses", headers=world["a"], json={"title": "Nope"})
    assert r.status_code == 403


def test_teacher_cannot_touch_another_teachers_course(client, world):
    cid, l1, _ = build_course(client, world["t"])
    other = make_user(client, "teacher", "Mr Other", "other@t.test")
    assert client.patch(f"/api/courses/{cid}", headers=other, json={"title": "Hijack"}).status_code == 404
    assert client.put(f"/api/lessons/{l1}", headers=other, json={"title": "x", "items": [READ]}).status_code == 404
    assert client.delete(f"/api/courses/{cid}", headers=other).status_code == 404
    assert client.get(f"/api/courses/{cid}", headers=other).status_code == 404


def test_publish_needs_lessons_with_tasks(client, world):
    t = world["t"]
    c = client.post("/api/courses", headers=t, json={"title": "Empty"}).json()
    assert client.post(f"/api/courses/{c['id']}/publish", headers=t, json={"published": True}).status_code == 422
    u = client.post(f"/api/courses/{c['id']}/units", headers=t, json={"title": "U"}).json()
    client.post(f"/api/units/{u['id']}/lessons", headers=t, json={"title": "No tasks", "items": []})
    r = client.post(f"/api/courses/{c['id']}/publish", headers=t, json={"published": True})
    assert r.status_code == 422 and "No tasks" in r.json()["detail"]


def test_quiz_item_validation(client, world):
    t = world["t"]
    c = client.post("/api/courses", headers=t, json={"title": "C"}).json()
    u = client.post(f"/api/courses/{c['id']}/units", headers=t, json={"title": "U"}).json()
    bad = [
        {"kind": "choice", "prompt": "Q", "options": ["only one"], "correct": 0},
        {"kind": "choice", "prompt": "Q", "options": ["a", "b"], "correct": 5},
        {"kind": "choice", "prompt": "Q", "options": ["a", "A"], "correct": 0},
        {"kind": "fill", "prompt": "No blank here", "options": ["a", "b"], "correct": 0},
        {"kind": "choice", "prompt": "", "options": ["a", "b"], "correct": 0},
    ]
    for item in bad:
        r = client.post(f"/api/units/{u['id']}/lessons", headers=t, json={"title": "L", "items": [item]})
        assert r.status_code == 422, item


def test_draft_course_is_hidden_from_learners(client, world):
    cid, l1, _ = build_course(client, world["t"], publish=False)
    assert client.get(f"/api/courses/{cid}", headers=world["a"]).status_code == 404
    assert client.get(f"/api/lessons/{l1}", headers=world["a"]).status_code == 404
    assert client.get("/api/courses", headers=world["a"]).json()["available"] == []


def test_learner_view_does_not_leak_answers(client, world):
    _, l1, _ = build_course(client, world["t"])
    items = client.get(f"/api/lessons/{l1}", headers=world["a"]).json()["items"]
    assert all("correct" not in i and "explain" not in i for i in items)
    owner = client.get(f"/api/lessons/{l1}", headers=world["t"]).json()["items"]
    assert owner[0]["correct"] == 1


def test_quiz_is_graded_on_the_server(client, world):
    _, l1, _ = build_course(client, world["t"])
    wrong = answer(client, world["a"], l1, 0, choice=0).json()
    assert wrong["score"] == 0 and wrong["correct_index"] == 1 and any("Add s" in t for t in wrong["tips"])
    right = answer(client, world["a"], l1, 0, choice=1).json()
    assert right["score"] == 100 and right["correct"] is True
    assert answer(client, world["a"], l1, 0).status_code == 422  # no choice sent
    assert answer(client, world["a"], l1, 0, choice=5).status_code == 422  # out of range


def test_sequential_lessons_unlock_in_order(client, world):
    cid, l1, l2 = build_course(client, world["t"])
    a = world["a"]
    assert client.get(f"/api/lessons/{l2}", headers=a).status_code == 403
    assert answer(client, a, l2, 0, choice=0).status_code == 403
    answer(client, a, l1, 0, choice=1)
    assert client.get(f"/api/lessons/{l2}", headers=a).status_code == 403  # only half done
    answer(client, a, l1, 1, choice=1)
    assert client.get(f"/api/lessons/{l2}", headers=a).status_code == 200
    view = client.get(f"/api/courses/{cid}", headers=a).json()
    states = [x["status"] for x in view["units"][0]["lessons"]]
    assert states == ["done", "open"]
    assert view["progress"]["next_lesson_id"] == l2 and view["progress"]["percent"] == 50


def test_non_sequential_course_is_open(client, world):
    _, _, l2 = build_course(client, world["t"], sequential=False)
    assert client.get(f"/api/lessons/{l2}", headers=world["a"]).status_code == 200


def test_stars_follow_score(client, world):
    cid, l1, _ = build_course(client, world["t"])
    answer(client, world["a"], l1, 0, choice=1)
    answer(client, world["a"], l1, 1, choice=0)  # wrong -> avg 50 -> one star
    lesson = client.get(f"/api/courses/{cid}", headers=world["a"]).json()["units"][0]["lessons"][0]
    assert lesson["stars"] == 1 and lesson["avg"] == 50
    answer(client, world["a"], l1, 1, choice=1)  # retry keeps the best score
    lesson = client.get(f"/api/courses/{cid}", headers=world["a"]).json()["units"][0]["lessons"][0]
    assert lesson["stars"] == 3


def test_speaking_item_in_a_lesson_is_graded_with_feedback(client, world):
    _, l1, l2 = build_course(client, world["t"], sequential=False)
    r = answer(client, world["a"], l2, 1, transcript="good mourning").json()
    assert r["kind"] == "read" and r["score"] < 100 and r["words"]


def test_class_assignment_and_public_visibility(client, world):
    cid, _, _ = build_course(client, world["t"], visibility="classes")
    outsider = make_user(client, "learner", "Out", "out@l.test")
    assert client.get(f"/api/courses/{cid}", headers=outsider).status_code == 404  # classes-only
    assert client.get(f"/api/courses/{cid}", headers=world["a"]).status_code == 404  # not yet given to the class
    r = client.post(f"/api/classes/{world['cls']['id']}/courses", headers=world["t"], json={"course_id": cid})
    assert r.status_code == 200
    mine = client.get("/api/courses", headers=world["a"]).json()["mine"]
    assert [c["id"] for c in mine] == [cid]
    assert client.get(f"/api/courses/{cid}", headers=outsider).status_code == 404  # still hidden from non-members
    rows = client.get(f"/api/classes/{world['cls']['id']}/courses", headers=world["t"]).json()
    assert rows[0]["id"] == cid and rows[0]["class_percent"] == 0
    client.delete(f"/api/classes/{world['cls']['id']}/courses/{cid}", headers=world["t"])
    assert client.get(f"/api/courses/{cid}", headers=world["a"]).status_code == 404


def test_cannot_assign_draft_or_foreign_course(client, world):
    draft, _, _ = build_course(client, world["t"], publish=False)
    assert client.post(f"/api/classes/{world['cls']['id']}/courses", headers=world["t"], json={"course_id": draft}).status_code == 422
    other = make_user(client, "teacher", "Mr Other", "other@t.test")
    cid, _, _ = build_course(client, other)
    assert client.post(f"/api/classes/{world['cls']['id']}/courses", headers=world["t"], json={"course_id": cid}).status_code == 404


def test_self_learner_enrols_in_public_course(client, world):
    cid, l1, _ = build_course(client, world["t"])
    me = make_user(client, "learner", "Solo", "solo@l.test")
    listing = client.get("/api/courses?q=first", headers=me).json()
    assert [c["id"] for c in listing["available"]] == [cid] and listing["mine"] == []
    assert client.post(f"/api/courses/{cid}/enroll", headers=me).status_code == 200
    listing = client.get("/api/courses", headers=me).json()
    assert [c["id"] for c in listing["mine"]] == [cid] and listing["available"] == []
    assert answer(client, me, l1, 0, choice=1).json()["score"] == 100


def test_teacher_sees_course_progress(client, world):
    cid, l1, _ = build_course(client, world["t"])
    answer(client, world["a"], l1, 0, choice=1)
    answer(client, world["a"], l1, 1, choice=1)
    client.post(f"/api/classes/{world['cls']['id']}/courses", headers=world["t"], json={"course_id": cid})
    p = client.get(f"/api/courses/{cid}/progress", headers=world["t"]).json()
    by = {x["name"]: x for x in p["learners"]}
    assert by["Asha"]["lessons_done"] == 1 and by["Bala"]["lessons_done"] == 0
    assert p["lessons"][0]["completed"] == 1
    assert client.get(f"/api/courses/{cid}/progress", headers=world["a"]).status_code == 403


def test_move_and_delete_keep_order(client, world):
    cid, l1, l2 = build_course(client, world["t"])
    client.post(f"/api/lessons/{l2}/move", headers=world["t"], json={"direction": "up"})
    ids = [l["id"] for l in client.get(f"/api/courses/{cid}", headers=world["t"]).json()["units"][0]["lessons"]]
    assert ids == [l2, l1]
    client.delete(f"/api/lessons/{l2}", headers=world["t"])
    ids = [l["id"] for l in client.get(f"/api/courses/{cid}", headers=world["t"]).json()["units"][0]["lessons"]]
    assert ids == [l1]


def test_lesson_voice_note_plays_for_learners_only(client, world):
    cid, l1, _ = build_course(client, world["t"])
    rec = client.post("/api/recordings", headers=world["t"], data={"title": "Intro", "duration_ms": "2000"}, files={"file": ("a.wav", WAV, "audio/wav")}).json()
    client.put(f"/api/lessons/{l1}", headers=world["t"], json={"title": "Hello", "recording_id": rec["id"], "items": [QUIZ]})
    assert client.get(f"/api/recordings/{rec['id']}/audio", headers=world["a"]).status_code == 200
    outsider = make_user(client, "learner", "Out", "out@l.test")
    client.patch(f"/api/courses/{cid}", headers=world["t"], json={"visibility": "classes"})
    assert client.get(f"/api/recordings/{rec['id']}/audio", headers=outsider).status_code == 404


def test_quiz_in_class_assignment_is_graded_and_hidden(client, world):
    cls = world["cls"]["id"]
    r = client.post(f"/api/classes/{cls}/assignments", headers=world["t"], json={"title": "Quiz", "items": [QUIZ]})
    assert r.status_code == 200, r.text
    aid = r.json()["id"]
    item = client.get(f"/api/assignments/{aid}", headers=world["a"]).json()["items"][0]
    assert "correct" not in item
    res = client.post("/api/attempts", headers=world["a"], data={"assignment_id": aid, "item_index": 0, "choice": 1}).json()
    assert res["score"] == 100


def test_review_surfaces_weak_items_with_their_source(client, world):
    cid, l1, _ = build_course(client, world["t"])
    assert client.get("/api/me/review", headers=world["a"]).json()["items"] == []
    answer(client, world["a"], l1, 0, choice=0)  # wrong
    answer(client, world["a"], l1, 1, choice=1)  # right: not reviewed
    rv = client.get("/api/me/review", headers=world["a"]).json()
    assert len(rv["items"]) == 1
    it = rv["items"][0]
    assert it["source"] == {"lesson_id": l1, "item_index": 0} and "correct" not in it
    answer(client, world["a"], l1, 0, choice=1)  # now mastered
    assert client.get("/api/me/review", headers=world["a"]).json()["items"] == []


def test_old_database_is_upgraded_in_place(tmp_path, monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("VAACHAK_DATA", str(tmp_path))
    conn = sqlite3.connect(tmp_path / "classroom.db")
    conn.executescript("""CREATE TABLE users(id INTEGER PRIMARY KEY, role TEXT, name TEXT, email TEXT, pw_hash TEXT, created_at TEXT);
    CREATE TABLE attempts(id INTEGER PRIMARY KEY, user_id INTEGER, assignment_id INTEGER, set_id TEXT, item_index INTEGER,
      kind TEXT, target TEXT, transcript TEXT, score INTEGER, accuracy INTEGER, result TEXT, audio_file TEXT, audio_mime TEXT, created_at TEXT);
    INSERT INTO attempts(user_id,item_index,kind,transcript,score,result) VALUES(1,0,'read','hi',90,'{}');""")
    conn.commit()
    conn.close()
    db.init()
    conn = db.connect()
    cols = {r["name"] for r in conn.execute("PRAGMA table_info(attempts)")}
    assert "lesson_id" in cols
    assert conn.execute("SELECT count(*) n FROM attempts").fetchone()["n"] == 1
    assert conn.execute("SELECT count(*) n FROM courses").fetchone()["n"] == 0
    conn.close()
