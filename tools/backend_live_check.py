#!/usr/bin/env python3
"""Opt-in speech check against a running configured server; uses/deletes a synthetic account."""

import argparse
import json
from pathlib import Path
import time
import uuid
import httpx

p = argparse.ArgumentParser()
p.add_argument("--base-url", default="http://127.0.0.1:8000")
p.add_argument("--audio", type=Path, required=True)
p.add_argument(
    "--output", type=Path, default=Path("docs/verification/backend-live-speech.json")
)
a = p.parse_args()
with httpx.Client(base_url=a.base_url, timeout=130) as client:
    user = client.post(
        "/api/auth/register",
        json={
            "name": "Synthetic ASR check",
            "email": str(uuid.uuid4()) + "@example.test",
            "password": "synthetic-test-password",
            "role": "learner",
        },
    )
    user.raise_for_status()
    headers = {"Authorization": "Bearer " + user.json()["token"]}
    try:
        start = time.monotonic()
        with a.audio.open("rb") as f:
            r = client.post(
                "/api/attempts",
                headers=headers,
                data={
                    "set_id": "en-present-agreement",
                    "item_index": 0,
                    "client_uuid": str(uuid.uuid4()),
                },
                files={"audio": (a.audio.name, f, "audio/wav")},
            )
        value = r.json()
        report = {
            "http_status": r.status_code,
            "latency_ms": round((time.monotonic() - start) * 1000, 2),
            "input_mode": value.get("input_mode"),
            "transcript_origin": value.get("transcript_origin"),
            "transcript_nonempty": bool(value.get("transcript")),
            "feedback_source": value.get("source"),
            "provider_model": value.get("provider_model"),
            "fixture": a.audio.name,
            "limitation": "Synthesized speech plumbing check; not a human accent or learning evaluation.",
        }
        a.output.parent.mkdir(parents=True, exist_ok=True)
        a.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report))
        r.raise_for_status()
        assert (
            report["input_mode"] == "recorded"
            and report["transcript_origin"] == "server_asr"
            and report["transcript_nonempty"]
        )
    finally:
        erased = client.request(
            "DELETE",
            "/api/me",
            headers=headers,
            json={"password": "synthetic-test-password"},
        )
        erased.raise_for_status()
