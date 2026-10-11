#!/usr/bin/env python3
"""Local operator report. Aggregate counts only; no raw answers or identities."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "classroom_web/server"))
import db


def metrics():
    with db.connect() as conn:
        events = {
            r[0]: r[1]
            for r in conn.execute(
                "SELECT name,count(*) FROM product_events GROUP BY name"
            )
        }
        helpful = conn.execute(
            "SELECT count(*),sum(CASE WHEN helpful=1 THEN 1 ELSE 0 END) FROM feedback_reports WHERE helpful IS NOT NULL"
        ).fetchone()
        return {
            "event_counts": events,
            "feedback_ratings": helpful[0],
            "helpful_ratings": helpful[1] or 0,
            "reports_by_category": {
                r[0]: r[1]
                for r in conn.execute(
                    "SELECT category,count(*) FROM feedback_reports GROUP BY category"
                )
            },
            "interpretation": "Opt-in event counts and voluntary ratings; not a representative retention or learning-efficacy estimate. Exclude synthetic test databases from participant analysis.",
        }


if __name__ == "__main__":
    print(json.dumps(metrics(), indent=2))
