import io

from .conftest import make_user


def test_auth_roles_and_bad_login(client):
    make_user(client, "teacher", "T", "t@x.test")
    assert client.post("/api/auth/login", json={"email": "t@x.test", "password": "wrong-password"}).status_code == 401
    assert client.post("/api/auth/register", json={"name": "T2", "email": "t@x.test", "password": "password-123", "role": "student"}).status_code == 409
    assert client.post("/api/auth/register", json={"name": "T", "email": "bad", "password": "password-123", "role": "student"}).status_code == 422
    assert client.post("/api/auth/register", json={"name": "T", "email": "s@x.test", "password": "short", "role": "student"}).status_code == 422
    assert client.get("/api/me").status_code == 401
    assert client.get("/api/me", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_login_is_throttled(client):
    make_user(client, "student", "S", "s@x.test")
    codes = [client.post("/api/auth/login", json={"email": "s@x.test", "password": "bad-password"}).status_code for _ in range(11)]
    assert codes[:10] == [401] * 10 and codes[10] == 429


def test_teacher_creates_classified_class_and_students_join(client, world):
    c = world["cls"]
    assert (c["standard"], c["pincode"], c["district"], c["language"]) == ("5", "411001", "Pune", "en")
    assert client.post("/api/classes", headers=world["a"], json={"name": "x"}).status_code == 403
    assert client.post("/api/classes", headers=world["t"], json={"name": "x", "pincode": "011001"}).status_code == 422
    assert client.post("/api/classes", headers=world["t"], json={"name": "x", "standard": "13"}).status_code == 422
    roster = client.get(f"/api/classes/{c['id']}", headers=world["t"]).json()["roster"]
    assert sorted(r["name"] for r in roster) == ["Asha", "Bala"]
    mine = client.get("/api/classes", headers=world["a"]).json()
    assert len(mine) == 1 and "code" not in mine[0] and mine[0]["teacher"] == "Ms Rao"
    assert client.post("/api/classes/join", headers=world["a"], json={"code": "NOPE99"}).status_code == 404


def test_class_is_private_to_members(client, world):
    cid = world["cls"]["id"]
    outsider = make_user(client, "student", "Out", "out@s.test")
    other_teacher = make_user(client, "teacher", "Other", "other@t.test")
    for h in (outsider, other_teacher):
        assert client.get(f"/api/classes/{cid}", headers=h).status_code == 404
        assert client.get(f"/api/classes/{cid}/assignments", headers=h).status_code == 404
    assert client.get(f"/api/classes/{cid}/performance", headers=other_teacher).status_code == 404
    assert client.get(f"/api/classes/{cid}/performance", headers=world["a"]).status_code == 403


def make_assignment(client, world, **extra):
    body = {"title": "Verbs", "set_id": "en-present-agreement", **extra}
    r = client.post(f"/api/classes/{world['cls']['id']}/assignments", headers=world["t"], json=body)
    assert r.status_code == 200, r.text
    return r.json()


def test_assignment_class_wide_and_targeted(client, world):
    cid = world["cls"]["id"]
    wide = make_assignment(client, world)
    me_a = client.get("/api/me", headers=world["a"]).json()["id"]
    targeted = make_assignment(client, world, title="Extra for Asha", student_id=me_a)
    seen_a = [x["title"] for x in client.get(f"/api/classes/{cid}/assignments", headers=world["a"]).json()]
    seen_b = [x["title"] for x in client.get(f"/api/classes/{cid}/assignments", headers=world["b"]).json()]
    assert "Extra for Asha" in seen_a and "Extra for Asha" not in seen_b and "Verbs" in seen_b
    assert client.get(f"/api/assignments/{targeted['id']}", headers=world["b"]).status_code == 404
    assert client.get(f"/api/assignments/{wide['id']}", headers=world["b"]).status_code == 200
    stranger = make_user(client, "student", "Out", "out@s.test")
    assert client.post(f"/api/classes/{cid}/assignments", headers=world["t"], json={"title": "T", "set_id": "en-everyday", "student_id": stranger and 99999}).status_code == 422
    assert client.post(f"/api/classes/{cid}/assignments", headers=world["a"], json={"title": "T", "set_id": "en-everyday"}).status_code == 403
    assert client.post(f"/api/classes/{cid}/assignments", headers=world["t"], json={"title": "T"}).status_code == 422
    custom = {"title": "Mine", "items": [{"kind": "read", "text": "I like tea."}, {"kind": "build", "words": ["tea", "I", "like"], "answer": "I like tea."}]}
    assert client.post(f"/api/classes/{cid}/assignments", headers=world["t"], json=custom).status_code == 200
    bad = {"title": "Bad", "items": [{"kind": "build", "words": ["tea", "I"], "answer": "I like tea."}]}
    assert client.post(f"/api/classes/{cid}/assignments", headers=world["t"], json=bad).status_code == 422


def attempt(client, headers, assignment_id, idx, text):
    return client.post("/api/attempts", headers=headers, data={"assignment_id": assignment_id, "item_index": idx, "transcript": text})


def test_attempt_feedback_and_stats(client, world):
    a = make_assignment(client, world)
    r = attempt(client, world["a"], a["id"], 0, "she go to school")
    assert r.status_code == 200
    body = r.json()
    assert body["score"] < 100 and any(g["fix"].lower() == "she goes" for g in body["grammar"])
    assert any("goes" in t for t in body["tips"])
    ok = attempt(client, world["a"], a["id"], 1, "he likes music").json()
    assert ok["score"] == 100 and ok["grammar"] == []
    # nothing heard, bad index, other student's assignment access
    assert attempt(client, world["a"], a["id"], 0, "   ").status_code == 422
    assert attempt(client, world["a"], a["id"], 99, "x").status_code == 422
    assert client.post("/api/attempts", headers=world["a"], data={"item_index": 0, "transcript": "x"}).status_code == 422
    stats = client.get("/api/me/stats", headers=world["a"]).json()
    assert stats["attempts"] == 2 and stats["streak_days"] == 1
    assert stats["grammar_focus"][0]["skill"] == "MORPH.AGREEMENT"
    assert stats["grammar_focus"][0]["label"] == "He, she, it verbs"  # the UI shows words, not codes
    assert stats["classes"][0]["assignments"] == 1
    # teacher sees performance
    perf = client.get(f"/api/classes/{world['cls']['id']}/performance", headers=world["t"]).json()
    asha = next(s for s in perf["students"] if s["name"] == "Asha")
    bala = next(s for s in perf["students"] if s["name"] == "Bala")
    assert asha["attempts"] == 2 and bala["attempts"] == 0 and bala["avg_score"] is None
    detail = client.get(f"/api/classes/{world['cls']['id']}/students/{asha['id']}", headers=world["t"]).json()
    assert detail["recent"][0]["transcript"] and detail["stats"]["attempts"] == 2


def test_finishing_every_item_marks_completion(client, world):
    a = make_assignment(client, world)
    n = a["item_count"]
    from server_items import items_of
    for i, text in enumerate(items_of("en-present-agreement")):
        assert attempt(client, world["a"], a["id"], i, text).status_code == 200
    mine = client.get(f"/api/assignments/{a['id']}", headers=world["a"]).json()
    assert mine["done_items"] == n
    listed = client.get(f"/api/classes/{world['cls']['id']}/assignments", headers=world["t"]).json()[0]
    assert listed["audience"] == 2 and listed["completed"] == 1


def test_self_practice_and_catalog(client):
    me = make_user(client, "learner", "Meera", "m@l.test")
    langs = client.get("/api/catalog", headers=me).json()
    assert langs[0]["code"] == "en" and langs[0]["status"] == "available" and len(langs[0]["sets"]) >= 5
    assert any(l["code"] == "mr" and l["status"] == "soon" for l in langs)
    found = client.get("/api/catalog?q=marathi", headers=me).json()
    assert [l["code"] for l in found] == ["mr"]
    th = client.get("/api/catalog?q=th sound", headers=me).json()
    assert th and th[0]["sets"][0]["id"] == "en-th-sounds"
    s = client.get("/api/sets/en-th-sounds", headers=me).json()
    r = client.post("/api/attempts", headers=me, data={"set_id": "en-th-sounds", "item_index": 0, "transcript": "sink about the free things we need"}).json()
    assert r["score"] < 80 and any("th" in t for t in r["tips"])
    assert client.get("/api/sets/en-th-sounds", headers=me).json()["best"]["0"] == r["score"]
    assert client.post("/api/attempts", headers=me, data={"set_id": "nope", "item_index": 0, "transcript": "x"}).status_code == 404
    build = client.get("/api/sets/en-build", headers=me).json()["items"][0]
    ok = client.post("/api/attempts", headers=me, data={"set_id": "en-build", "item_index": 0, "transcript": build["answer"]}).json()
    assert ok["score"] == 100


def test_recording_upload_and_access(client, world):
    cid = world["cls"]["id"]
    audio = ("lesson.webm", io.BytesIO(b"\x1aE\xdf\xa3" + b"0" * 2000), "audio/webm")
    rec = client.post("/api/recordings", headers=world["t"], data={"title": "Poem", "duration_ms": "4000"}, files={"file": audio})
    assert rec.status_code == 200, rec.text
    rid = rec.json()["id"]
    bad = client.post("/api/recordings", headers=world["t"], data={"title": "x", "duration_ms": "4000"}, files={"file": ("a.exe", io.BytesIO(b"MZ"), "application/x-msdownload")})
    assert bad.status_code == 415
    assert client.post("/api/recordings", headers=world["a"], data={"title": "x", "duration_ms": "4000"}, files={"file": audio}).status_code == 403
    # nobody but the teacher can play it until it is assigned
    assert client.get(f"/api/recordings/{rid}/audio", headers=world["a"]).status_code == 404
    make_assignment(client, world, recording_id=rid)
    assert client.get(f"/api/recordings/{rid}/audio", headers=world["a"]).status_code == 200
    assert client.get(f"/api/recordings/{rid}/audio", headers=world["t"]).status_code == 200
    outsider = make_user(client, "student", "Out", "out@s.test")
    assert client.get(f"/api/recordings/{rid}/audio", headers=outsider).status_code == 404
    # token in the query string works for <audio> elements
    token = world["a"]["Authorization"][7:]
    assert client.get(f"/api/recordings/{rid}/audio?token={token}").status_code == 200
    # recording only, no items, is a valid "listen" assignment
    r = client.post(f"/api/classes/{cid}/assignments", headers=world["t"], json={"title": "Listen", "recording_id": rid})
    assert r.status_code == 200 and r.json()["item_count"] == 0


def test_student_audio_attempt_playable_by_teacher_only(client, world):
    a = make_assignment(client, world)
    r = client.post("/api/attempts", headers=world["a"], data={"assignment_id": a["id"], "item_index": 0, "transcript": "she goes to school"},
                    files={"audio": ("a.webm", io.BytesIO(b"\x1aE\xdf\xa3" + b"1" * 500), "audio/webm")})
    aid = r.json()["id"]
    assert client.get(f"/api/attempts/{aid}/audio", headers=world["t"]).status_code == 200
    assert client.get(f"/api/attempts/{aid}/audio", headers=world["a"]).status_code == 200
    assert client.get(f"/api/attempts/{aid}/audio", headers=world["b"]).status_code == 404
    assert client.post("/api/attempts", headers=world["a"], data={"assignment_id": a["id"], "item_index": 0},
                       files={"audio": ("a.webm", io.BytesIO(b"x" * 10), "audio/webm")}).status_code == 422  # no transcript, no server ASR


def test_remove_student_and_new_code(client, world):
    cid = world["cls"]["id"]
    bid = client.get("/api/me", headers=world["b"]).json()["id"]
    assert client.delete(f"/api/classes/{cid}/students/{bid}", headers=world["t"]).status_code == 200
    assert client.get(f"/api/classes/{cid}", headers=world["b"]).status_code == 404
    old = world["cls"]["code"]
    new = client.post(f"/api/classes/{cid}/code", headers=world["t"]).json()["code"]
    assert new != old and client.post("/api/classes/join", headers=world["b"], json={"code": old}).status_code == 404


# ----------------------------------------------------------------------------- timestamp shape
import re as _re  # noqa: E402

ISO_UTC = _re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(\+00:00|Z)$")
DATE_ONLY = _re.compile(r"^\d{4}-\d{2}-\d{2}$")
TS_KEYS = {"created_at", "updated_at", "due_at", "last_active", "joined_at", "last_miss",
           "assigned_at", "expires_at"}


def _bad_timestamps(obj, path=""):
    """Every timestamp must be ISO-8601 with a timezone, so JavaScript's Date() accepts it."""
    bad = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in TS_KEYS and isinstance(v, str) and not ISO_UTC.match(v):
                bad.append(f"{path}.{k} = {v!r}")
            else:
                bad += _bad_timestamps(v, f"{path}.{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj[:5]):
            bad += _bad_timestamps(v, f"{path}[{i}]")
    return bad


def test_every_timestamp_the_api_returns_is_iso_utc(client, world):
    """A React Native client must be able to call new Date() on any timestamp we send."""
    cls = world["cls"]["id"]
    a = client.post(f"/api/classes/{cls}/assignments", headers=world["t"], json={
        "title": "Dates", "due_at": "2026-12-01T18:30:00+00:00",
        "items": [{"kind": "read", "text": "The train is late."}]}).json()
    client.post("/api/attempts", headers=world["a"],
                data={"assignment_id": a["id"], "item_index": 0, "transcript": "the train is late"})
    paths = [
        "/api/me", "/api/classes", f"/api/classes/{cls}", f"/api/classes/{cls}/assignments",
        f"/api/assignments/{a['id']}", f"/api/classes/{cls}/performance",
        f"/api/classes/{cls}/attention", f"/api/classes/{cls}/skill-grid",
        f"/api/classes/{cls}/students/{world['cls'] and 0 or 0}",
    ]
    checked = 0
    for p in paths:
        for who in ("t", "a"):
            r = client.get(p, headers=world[who])
            if r.status_code != 200:
                continue
            bad = _bad_timestamps(r.json(), p)
            assert not bad, f"{p} as {who}: " + "; ".join(bad)
            checked += 1
    for p in ("/api/me/stats", "/api/me/review"):
        r = client.get(p, headers=world["a"])
        assert r.status_code == 200
        assert not _bad_timestamps(r.json(), p), _bad_timestamps(r.json(), p)
        checked += 1
    assert checked >= 8, "the sweep must actually have reached the endpoints"


def test_the_day_buckets_stay_plain_dates(client, world):
    """stats.days[].day is a calendar day, not an instant: it must not grow a time."""
    days = client.get("/api/me/stats", headers=world["a"]).json()["days"]
    assert days and all(DATE_ONLY.match(d["day"]) for d in days), days[:3]


def test_audio_survives_the_json_normaliser_intact(client, world):
    """Binary must come back byte-for-byte. (The content-type guard in the middleware is
    separately there to avoid buffering a whole audio file in memory.)"""
    rec = client.post("/api/recordings", headers=world["t"],
                      data={"title": "n", "duration_ms": "2000"},
                      files={"file": ("a.webm", b"BINARY\x00\xff" * 30, "audio/webm")}).json()
    r = client.get(f"/api/recordings/{rec['id']}/audio", headers=world["t"])
    assert r.status_code == 200
    assert r.content == b"BINARY\x00\xff" * 30, "binary audio must stream through untouched"
    assert r.headers["content-type"] == "audio/webm"
