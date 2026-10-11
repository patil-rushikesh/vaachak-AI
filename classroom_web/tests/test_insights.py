"""The teacher's attention queue and the learner's review schedule.

These decide what a teacher acts on and what a learner sees next, so the thresholds are
pinned down here rather than left to chance.
"""
import json
from datetime import datetime, timedelta, timezone

import pytest

import db
import insights
from conftest import make_user

QUIZ = {"kind": "choice", "prompt": "She ___ to school.", "options": ["go", "goes"], "correct": 1}


def ago(days, hours=0):
    return (datetime.now(timezone.utc) - timedelta(days=days, hours=hours)).isoformat()


def put_attempt(conn, user_id, *, score, when, skill=None, assignment_id=None, lesson_id=None,
                set_id=None, item_index=0, kind="free"):
    """Write an attempt straight in, so history can be dated in the past."""
    grammar = [{"skill": skill, "said": "x", "fix": "y", "why": "z", "rule": "t", "start": 0, "end": 0}] if skill else []
    result = {"score": score, "grammar": grammar, "words": [], "tips": [], "extra_words": [], "kind": kind}
    conn.execute(
        "INSERT INTO attempts(user_id,assignment_id,lesson_id,set_id,item_index,kind,target,transcript,"
        "score,accuracy,result,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
        (user_id, assignment_id, lesson_id, set_id, item_index, kind, "t", "said", score, score,
         json.dumps(result), when))
    conn.commit()


@pytest.fixture()
def room(client, world):
    """A class with one assignment and a direct database handle."""
    aid = client.post(f"/api/classes/{world['cls']['id']}/assignments", headers=world["t"],
                      json={"title": "Q", "items": [QUIZ]}).json()["id"]
    conn = db.connect()
    ids = {r["email"]: r["id"] for r in conn.execute("SELECT id, email FROM users")}
    yield {"conn": conn, "class_id": world["cls"]["id"], "assignment_id": aid,
           "asha": ids["asha@s.test"], "bala": ids["bala@s.test"], **world}
    conn.close()


def reasons(room, who=None):
    rows = insights.attention(room["conn"], room["class_id"], 1)
    return {(r["name"], r["reason"]) for r in rows} if who is None else {r["reason"] for r in rows if r["student_id"] == who}


# ----------------------------------------------------------------------------- attention rules
def test_a_learner_who_never_started_is_flagged_first(room):
    rows = insights.attention(room["conn"], room["class_id"], 1)
    assert rows, "two enrolled learners with no attempts should both be flagged"
    assert all(r["reason"] == "never_started" for r in rows)
    assert all(r["action"] == "assign" and r["action_label"] for r in rows), "every row needs one action"


def test_going_quiet_is_flagged_after_a_week(room):
    put_attempt(room["conn"], room["asha"], score=90, when=ago(insights.INACTIVE_DAYS + 1),
                assignment_id=room["assignment_id"])
    assert "inactive" in reasons(room, room["asha"])
    put_attempt(room["conn"], room["asha"], score=90, when=ago(1), assignment_id=room["assignment_id"])
    assert "inactive" not in reasons(room, room["asha"])


def test_the_quiet_student_working_far_less_than_the_class_is_surfaced(room):
    for i in range(12):
        put_attempt(room["conn"], room["bala"], score=95, when=ago(0, i), assignment_id=room["assignment_id"])
    put_attempt(room["conn"], room["asha"], score=95, when=ago(0, 1), assignment_id=room["assignment_id"])
    got = reasons(room, room["asha"])
    assert "quiet" in got, got
    assert "quiet" not in reasons(room, room["bala"])


def test_the_same_skill_going_wrong_repeatedly_becomes_one_action(room):
    for i in range(insights.STUCK_MISSES):
        put_attempt(room["conn"], room["asha"], score=40, when=ago(0, i + 1),
                    skill="MORPH.AGREEMENT", assignment_id=room["assignment_id"])
    row = next(r for r in insights.attention(room["conn"], room["class_id"], 1)
               if r["student_id"] == room["asha"] and r["reason"] == "stuck_skill")
    assert row["detail"]["skill"] == "MORPH.AGREEMENT"
    assert "He, she, it verbs" in row["why"]
    assert row["action"] == "practise"


def test_unrelated_success_does_not_clear_a_stuck_skill(room):
    for i in range(insights.STUCK_MISSES):
        put_attempt(room["conn"], room["asha"], score=40, when=ago(3, i), skill="MORPH.AGREEMENT",
                    assignment_id=room["assignment_id"])
    for i in range(2):
        put_attempt(room["conn"], room["asha"], score=95, when=ago(0, i + 1), assignment_id=room["assignment_id"])
    assert "stuck_skill" in reasons(room, room["asha"])


def test_an_accent_feature_is_never_a_reason_to_flag_anyone(room):
    for i in range(insights.STUCK_MISSES + 2):
        put_attempt(room["conn"], room["asha"], score=40, when=ago(0, i + 1),
                    skill="PHON.RETROFLEX", assignment_id=room["assignment_id"])
    assert "stuck_skill" not in reasons(room, room["asha"])
    assert insights.weak_skills(room["conn"], room["asha"]) == []


def test_falling_scores_are_noticed(room):
    for i, s in enumerate([90, 88, 92]):
        put_attempt(room["conn"], room["asha"], score=s, when=ago(2, i), assignment_id=room["assignment_id"])
    for i, s in enumerate([60, 55, 58]):
        put_attempt(room["conn"], room["asha"], score=s, when=ago(0, 3 - i), assignment_id=room["assignment_id"])
    assert "declining" in reasons(room, room["asha"])


def test_steady_scores_are_left_alone(room):
    for i, s in enumerate([85, 88, 86, 87, 89, 85]):
        put_attempt(room["conn"], room["asha"], score=s, when=ago(0, 6 - i), assignment_id=room["assignment_id"])
    got = reasons(room, room["asha"])
    assert "declining" not in got and "below_proficient" not in got, got


def test_the_student_doing_the_work_but_not_getting_it_is_surfaced(room):
    for i in range(6):
        put_attempt(room["conn"], room["asha"], score=45, when=ago(0, 6 - i), assignment_id=room["assignment_id"])
    assert "below_proficient" in reasons(room, room["asha"])


def test_a_dismissed_flag_never_comes_back(client, room):
    assert "never_started" in reasons(room, room["asha"])
    r = client.post(f"/api/classes/{room['class_id']}/attention/dismiss", headers=room["t"],
                    json={"student_id": room["asha"], "reason": "never_started"})
    assert r.status_code == 200
    assert "never_started" not in reasons(room, room["asha"])
    assert "never_started" in reasons(room, room["bala"]), "dismissing one learner must not hide the others"


def test_only_this_class_teacher_sees_the_queue(client, room):
    other = make_user(client, "teacher", "Other", "other@t.test")
    assert client.get(f"/api/classes/{room['class_id']}/attention", headers=other).status_code == 404
    assert client.get(f"/api/classes/{room['class_id']}/attention", headers=room["a"]).status_code == 403
    assert client.get(f"/api/classes/{room['class_id']}/attention", headers=room["t"]).status_code == 200


def test_the_skill_grid_counts_per_learner(client, room):
    put_attempt(room["conn"], room["asha"], score=40, when=ago(0, 1), skill="SYN.ARTICLE",
                assignment_id=room["assignment_id"])
    put_attempt(room["conn"], room["asha"], score=40, when=ago(0, 2), skill="SYN.ARTICLE",
                assignment_id=room["assignment_id"])
    put_attempt(room["conn"], room["bala"], score=40, when=ago(0, 1), skill="SYN.ARTICLE",
                assignment_id=room["assignment_id"])
    grid = client.get(f"/api/classes/{room['class_id']}/skill-grid", headers=room["t"]).json()
    top = grid["skills"][0]
    assert top["code"] == "SYN.ARTICLE" and top["total"] == 3 and top["students"] == 2
    assert top["label"] == "A, an and the"
    by_name = {r["name"]: r["counts"][0] for r in grid["rows"]}
    assert by_name == {"Asha": 2, "Bala": 1}


# ----------------------------------------------------------------------------- review schedule
def test_a_wrong_answer_can_be_retried_straight_away(room):
    put_attempt(room["conn"], room["asha"], score=0, when=ago(0), assignment_id=room["assignment_id"])
    due = insights.due_for_review(room["conn"], room["asha"])
    assert len(due) == 1 and due[0]["box"] == 1


def test_a_right_answer_does_not_come_back_the_same_day(room):
    put_attempt(room["conn"], room["asha"], score=100, when=ago(0), assignment_id=room["assignment_id"])
    assert insights.due_for_review(room["conn"], room["asha"]) == []


def test_intervals_grow_as_the_learner_keeps_getting_it_right(room):
    """One pass waits a day; two passes wait two. Each task is tested on its own."""
    conn, uid, aid = room["conn"], room["asha"], room["assignment_id"]
    put_attempt(conn, uid, score=100, when=ago(0.5), assignment_id=aid, item_index=0)
    put_attempt(conn, uid, score=100, when=ago(1.5), assignment_id=aid, item_index=1)
    put_attempt(conn, uid, score=100, when=ago(3), assignment_id=aid, item_index=2)
    put_attempt(conn, uid, score=100, when=ago(1.5), assignment_id=aid, item_index=2)
    put_attempt(conn, uid, score=100, when=ago(4), assignment_id=aid, item_index=3)
    put_attempt(conn, uid, score=100, when=ago(2.5), assignment_id=aid, item_index=3)
    indexes = {d["source"]["item_index"]: d["box"] for d in insights.due_for_review(conn, uid)}
    assert 0 not in indexes, "box 2 waits a day, and only half a day has passed"
    assert indexes.get(1) == 2, "box 2 and a day and a half gone: due"
    assert 2 not in indexes, "box 3 waits two days, and only a day and a half has passed"
    assert indexes.get(3) == 3, "box 3 and two and a half days gone: due"


def test_getting_it_wrong_again_sends_it_back_to_the_start(room):
    conn, uid = room["conn"], room["asha"]
    for _ in range(3):
        put_attempt(conn, uid, score=100, when=ago(9), assignment_id=room["assignment_id"])
    put_attempt(conn, uid, score=20, when=ago(0), assignment_id=room["assignment_id"])
    due = insights.due_for_review(conn, uid)
    assert len(due) == 1 and due[0]["box"] == 1


def test_a_task_answered_well_enough_times_is_done(room):
    conn, uid = room["conn"], room["asha"]
    for i in range(len(insights.BOX_DAYS) + 1):
        put_attempt(conn, uid, score=100, when=ago(200 - i * 20), assignment_id=room["assignment_id"])
    assert insights.due_for_review(conn, uid) == []


def test_review_returns_explainable_priorities(room):
    conn, uid = room["conn"], room["asha"]
    put_attempt(conn, uid, score=70, when=ago(0), assignment_id=room["assignment_id"], item_index=0)
    put_attempt(conn, uid, score=10, when=ago(0), assignment_id=room["assignment_id"], item_index=1)
    put_attempt(conn, uid, score=40, when=ago(0), assignment_id=room["assignment_id"], item_index=2)
    due = insights.due_for_review(conn, uid)
    assert len(due) == 3
    assert all(d["reason"] == "repeated_skill_error" and d["evidence_ids"] for d in due)
    assert [d["priority"] for d in due] == sorted([d["priority"] for d in due], reverse=True)


def test_review_only_offers_tasks_the_learner_may_still_open(client, world):
    """A lesson that has become locked must not leak back through the review list."""
    from test_courses import build_course
    cid, l1, l2 = build_course(client, world["t"], sequential=True)
    client.post("/api/attempts", headers=world["a"], data={"lesson_id": l1, "item_index": 0, "choice": 0})
    assert [i["source"]["lesson_id"] for i in client.get("/api/me/review", headers=world["a"]).json()["items"]] == [l1]
    client.post(f"/api/courses/{cid}/publish", headers=world["t"], json={"published": False})
    assert client.get("/api/me/review", headers=world["a"]).json()["items"] == []
