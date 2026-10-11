#!/usr/bin/env python3
"""Reproducible synthetic policy invariants, not a human learning/relevance study."""

import json
import os
from pathlib import Path
import sys
import tempfile
from datetime import datetime, timedelta, timezone

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "classroom_web/server"))
import db
import insights

NOW = datetime(2026, 10, 11, 12, tzinfo=timezone.utc)
CODE = "MORPH.AGREEMENT"
insights._now = lambda: NOW


def baseline(conn):
    """Pre-enhancement rule: all clean >=80 answers clear all earlier mistakes."""
    misses = clean = 0
    for r in conn.execute("SELECT result,score FROM attempts ORDER BY created_at,id"):
        value = json.loads(r["result"])
        if any(g.get("skill") == CODE for g in value.get("grammar", [])):
            misses += 1
            clean = 0
        if r["score"] >= 80 and not value.get("grammar"):
            clean += 1
    return misses >= 3 and clean < 2


def row(conn, days, score, tag=None, task="original", disputed=False):
    grammar = [{"skill": CODE}] if score < 80 else []
    result = {"grammar": grammar, "assessed_skills": [tag] if tag else []}
    conn.execute(
        """INSERT INTO attempts(user_id,item_index,kind,transcript,score,result,item_snapshot,input_mode,disputed,created_at)
        VALUES(1,0,'free','synthetic',?,?,?,?,?,?)""",
        (
            score,
            json.dumps(result),
            json.dumps({"prompt": task}),
            "typed",
            disputed,
            (NOW - timedelta(days=days)).isoformat(),
        ),
    )


def main():
    os.environ["VAACHAK_DATA"] = tempfile.mkdtemp(prefix="vaachak_policy_eval_")
    db.init()
    results = []
    cases = [
        ("unrelated_success", True),
        ("immediate_same_task", True),
        ("delayed_different_task", False),
        ("disputed_errors", False),
        ("no_success", True),
    ]
    with db.connect() as conn:
        conn.execute(
            "INSERT INTO users(id,role,name,email,pw_hash) VALUES(1,'learner','Synthetic','synthetic@example.test','not-a-login-hash')"
        )
        for case, expected in cases:
            conn.execute("DELETE FROM attempts")
            for days in (5, 4, 3):
                row(conn, days, 40, disputed=case == "disputed_errors")
            if case == "unrelated_success":
                row(conn, 2, 100, "SYN.ARTICLE", "other")
                row(conn, 1, 100, "SYN.ARTICLE", "other2")
            elif case == "immediate_same_task":
                row(conn, 2.99, 100, CODE)
                row(conn, 2.98, 100, CODE)
            elif case == "delayed_different_task":
                row(conn, 2, 100, CODE, "other")
                row(conn, 1, 100, CODE, "other2")
            conn.commit()
            old = baseline(conn)
            new = insights.skill_counts(conn, 1).get(CODE, {}).get("stuck", False)
            results.append(
                {
                    "case": case,
                    "expected_stuck": expected,
                    "baseline_stuck": old,
                    "enhanced_stuck": new,
                    "baseline_correct": old == expected,
                    "enhanced_correct": new == expected,
                }
            )
    report = {
        "dataset": "five synthetic correctness cases; no human participants",
        "clock": NOW.isoformat(),
        "policy_version": "skill-review-v1",
        "baseline": "original global clean-success heuristic",
        "baseline_correct": sum(r["baseline_correct"] for r in results),
        "enhanced_correct": sum(r["enhanced_correct"] for r in results),
        "cases": results,
        "limitation": "This tests designed invariants, not pedagogical efficacy or instructor-rated relevance.",
    }
    target = ROOT / "docs/verification/review-policy-evaluation.json"
    target.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    assert all(r["enhanced_correct"] for r in results)


if __name__ == "__main__":
    main()
