"""Create demo accounts, a class, assignments and a little practice history.

    python server/seed.py            # adds demo data if the database has no users
    python server/seed.py --reset    # wipes the database first
"""
from __future__ import annotations

import json
import random
import sys
from datetime import datetime, timedelta, timezone

import db
import feedback
from main import SETS, hash_password, new_code

PASSWORD = "demo-pass-123"
PEOPLE = [
    ("teacher", "Priya Deshmukh", "teacher@demo.test"),
    ("student", "Aarav Patil", "aarav@demo.test"),
    ("student", "Diya Kulkarni", "diya@demo.test"),
    ("student", "Kabir Shaikh", "kabir@demo.test"),
    ("student", "Sana Shaikh", "sana@demo.test"),
    ("student", "Omkar Jadhav", "omkar@demo.test"),
    ("learner", "Meera Joshi", "meera@demo.test"),
]
# What each demo learner "said": a few typical mistakes so the stats are not empty.
SPOKEN = {
    "aarav@demo.test": {"She goes to school.": "she goes to school", "He likes music.": "he like music", "It works well.": "it works well"},
    "diya@demo.test": {"She goes to school.": "she go to school", "He likes music.": "he likes music", "She has a book.": "she have a book"},
    "kabir@demo.test": {"Think about the three things we need.": "sink about the free things we need"},
}


def seed(reset: bool = False) -> None:
    if reset:
        for f in db.data_dir().glob("classroom.db*"):
            f.unlink()
    db.init()
    conn = db.connect()
    if conn.execute("SELECT count(*) n FROM users").fetchone()["n"]:
        print("Database already has users; nothing seeded. Use --reset to start over.")
        return
    ids = {}
    for role, name, email in PEOPLE:
        ids[email] = conn.execute("INSERT INTO users(role,name,email,pw_hash) VALUES(?,?,?,?)", (role, name, email, hash_password(PASSWORD))).lastrowid
    teacher = ids["teacher@demo.test"]
    code = new_code(conn)
    cid = conn.execute(
        "INSERT INTO classes(teacher_id,name,standard,section,pincode,state,district,language,academic_year,code,color) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
        (teacher, "English speaking", "6", "A", "411001", "Maharashtra", "Pune", "en", "2026-27", code, 0)).lastrowid
    conn.execute("INSERT INTO classes(teacher_id,name,standard,section,pincode,state,district,language,academic_year,code,color) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                 (teacher, "Grammar club", "8", "B", "411001", "Maharashtra", "Pune", "en", "2026-27", new_code(conn), 1))
    for email in ("aarav@demo.test", "diya@demo.test", "kabir@demo.test", "sana@demo.test", "omkar@demo.test"):
        conn.execute("INSERT INTO enrollments(class_id,student_id) VALUES(?,?)", (cid, ids[email]))

    def add_assignment(set_id: str, title: str, instructions: str, student: int | None = None, days_ago: int = 3) -> int:
        stamp = (datetime.now(timezone.utc) - timedelta(days=days_ago)).isoformat()
        return conn.execute(
            "INSERT INTO assignments(class_id,teacher_id,student_id,title,instructions,due_at,items,created_at) VALUES(?,?,?,?,?,?,?,?)",
            (cid, teacher, student, title, instructions, (datetime.now(timezone.utc) + timedelta(days=4)).isoformat(), json.dumps(SETS[set_id]["items"]), stamp)).lastrowid

    a1 = add_assignment("en-present-agreement", "He, she, it: the -s verb", "Read each sentence aloud. Watch the verb ending.")
    a2 = add_assignment("en-th-sounds", "The th sound", "Tongue between your teeth!", days_ago=1)
    add_assignment("en-present-agreement", "Extra practice: verb endings", "A few more for you, Diya.", student=ids["diya@demo.test"], days_ago=1)

    # Sana started well, then stopped: the teacher should be told she has gone quiet.
    for n, (target, heard) in enumerate([("She goes to school.", "she goes to school"),
                                         ("He likes music.", "he like music")]):
        res = feedback.analyse("read", target, heard)
        res["kind"], res["target"] = "read", target
        conn.execute("INSERT INTO attempts(user_id,assignment_id,item_index,kind,target,transcript,score,accuracy,result,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                     (ids["sana@demo.test"], a1, n, "read", target, heard, res["score"], res["accuracy"],
                      json.dumps(res), (datetime.now(timezone.utc) - timedelta(days=14 + n)).isoformat()))
    # Omkar is enrolled and has never answered anything. Nobody would notice without the queue.

    random.seed(7)
    for email, said in SPOKEN.items():
        for n, (target, heard) in enumerate(said.items()):
            assignment = a2 if "three" in target else a1
            items = SETS["en-th-sounds" if assignment == a2 else "en-present-agreement"]["items"]
            idx = next(i for i, it in enumerate(items) if it["text"] == target)
            res = feedback.analyse("read", target, heard)
            res["kind"], res["target"] = "read", target
            stamp = (datetime.now(timezone.utc) - timedelta(days=n % 3, hours=n)).isoformat()
            conn.execute("INSERT INTO attempts(user_id,assignment_id,item_index,kind,target,transcript,score,accuracy,result,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                         (ids[email], assignment, idx, "read", target, heard, res["score"], res["accuracy"], json.dumps(res), stamp))

    # A published sample course, given to the demo class, with some progress.
    def ch(kind, stem, options, correct, explain=None):
        item = {"kind": kind, ("text" if kind == "listen" else "prompt"): stem, "options": options, "correct": correct}
        if explain:
            item["explain"] = explain
        return item

    course = conn.execute("INSERT INTO courses(teacher_id,title,summary,level,visibility,sequential,status) VALUES(?,?,?,?,?,?,?)",
                          (teacher, "Spoken English: first steps", "Greet people, talk about yourself and your day, and fix the most common verb mistakes.", "A1", "public", 1, "published")).lastrowid
    plan = [
        ("Greetings", [
            ("Saying hello", "Use Good morning before noon, Good afternoon until evening, and Good night only when leaving or going to bed.", [
                ch("choice", "What do you say when you meet someone at 9 in the morning?", ["Good night", "Good morning", "Good bye"], 1, "Good morning is for the start of the day."),
                ch("fill", "Good ___, how are you?", ["morning", "mornings", "mourning"], 0),
                {"kind": "read", "text": "Good morning, how are you?"},
            ]),
            ("Introduce yourself", "Say your name, where you live and what you do. Use I am or My name is.", [
                {"kind": "build", "words": ["My", "name", "is", "Aarav."], "answer": "My name is Aarav."},
                ch("listen", "I live in Pune.", ["I live in Pune.", "I leave in Pune.", "I love in Pune."], 0),
                {"kind": "free", "prompt": "Tell us your name and where you live."},
            ]),
        ]),
        ("Daily life", [
            ("He, she, it", "With he, she or it, the verb gets an s: she goes, he likes, it works.", [
                ch("choice", "Pick the correct sentence.", ["She go to school.", "She goes to school.", "She going to school."], 1, "With she, add s to the verb."),
                ch("fill", "My brother ___ music.", ["like", "likes", "liking"], 1),
                ch("fill", "They ___ football on Sunday.", ["plays", "play", "playing"], 1, "They takes the plain verb."),
            ]),
            ("The th sound", "Put your tongue between your teeth and blow softly: think, three, thanks.", [
                {"kind": "read", "text": "Think about the three things we need."},
                ch("listen", "Thank you very much.", ["Thank you very much.", "Tank you very much.", "Fank you very much."], 0),
            ]),
        ]),
    ]
    lesson_ids = {}
    for upos, (utitle, lessons) in enumerate(plan, start=1):
        uid = conn.execute("INSERT INTO units(course_id,position,title) VALUES(?,?,?)", (course, upos, utitle)).lastrowid
        for lpos, (ltitle, intro, items) in enumerate(lessons, start=1):
            lesson_ids[ltitle] = (conn.execute("INSERT INTO lessons(unit_id,course_id,position,title,intro,items) VALUES(?,?,?,?,?,?)",
                                               (uid, course, lpos, ltitle, intro, json.dumps(items))).lastrowid, items)
    conn.execute("INSERT INTO class_courses(class_id,course_id) VALUES(?,?)", (cid, course))
    from items import grade_quiz

    def do(email: str, lesson: str, idx: int, pick: int | None = None, said: str | None = None, days_ago: int = 0) -> None:
        lid, its = lesson_ids[lesson]
        it = its[idx]
        stamp = (datetime.now(timezone.utc) - timedelta(days=days_ago, minutes=idx)).isoformat()
        if it["kind"] in ("choice", "fill", "listen"):
            res = grade_quiz(it, it["correct"] if pick is None else pick)
            res["kind"], text, target = it["kind"], res["chosen_text"], res["target"]
        else:
            target = it.get("text") or it.get("answer")
            text = said or target
            res = feedback.analyse(it["kind"], target, text, it.get("answer"))
            res["kind"], res["target"] = it["kind"], target
        conn.execute("INSERT INTO attempts(user_id,lesson_id,item_index,kind,target,transcript,score,accuracy,result,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                     (ids[email], lid, idx, it["kind"], target, text, res["score"], res["accuracy"], json.dumps(res), stamp))

    for i in range(3):
        do("aarav@demo.test", "Saying hello", i, said="good morning how are you", days_ago=1)
    do("aarav@demo.test", "Introduce yourself", 0, said="My name is Aarav.", days_ago=0)
    do("aarav@demo.test", "Introduce yourself", 1, pick=1, days_ago=0)
    do("diya@demo.test", "Saying hello", 0, days_ago=2)
    do("diya@demo.test", "Saying hello", 1, pick=2, days_ago=2)
    conn.commit()
    conn.close()
    print(f"Seeded. Password for every demo account: {PASSWORD}")
    for _, name, email in PEOPLE:
        print(f"  {email:22} {name}")
    print(f"Class join code (English speaking): {code}")
    print("Sana has gone quiet and Omkar never started, so the teacher's Needs you tab has something to show.")
    print("Sample course: Spoken English: first steps (given to the English speaking class)")


if __name__ == "__main__":
    seed("--reset" in sys.argv)
