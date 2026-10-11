"""Durable bounded teacher-only generation; outputs remain review-required drafts."""

import json
import os
import logging
import time
from datetime import datetime, timedelta, timezone
from uuid import UUID
from fastapi import APIRouter, Depends, HTTPException
from pydantic import Field
import ai
import db
import evidence
import contracts
from items import clean_item, ItemIn
from main import GenerateIn, teacher_only, get_db

router = APIRouter(prefix="/api", responses=contracts.ERRORS)
logger = logging.getLogger("vaachak.jobs")


class JobIn(GenerateIn):
    client_uuid: UUID


def result(row):
    return {
        "id": row["id"],
        "status": row["status"],
        "items": json.loads(row["items"]),
        "error_code": row["error_code"],
        "tries": row["tries"],
        "review_required": True,
    }


@router.post("/ai/jobs", response_model=contracts.Response)
def enqueue(body: JobIn, user=Depends(teacher_only), conn=Depends(get_db)):
    key = str(body.client_uuid)
    payload = body.model_dump(mode="json", exclude={"client_uuid"})
    digest = evidence.digest(payload)
    conn.execute("BEGIN IMMEDIATE")
    try:
        old = conn.execute(
            "SELECT * FROM generation_jobs WHERE id=?", (key,)
        ).fetchone()
        if old:
            if old["user_id"] != user["id"] or old["request_hash"] != digest:
                raise HTTPException(409, "Job identity already used.")
            conn.commit()
            return result(old)
        if (
            conn.execute(
                "SELECT count(*) FROM generation_jobs WHERE user_id=? AND status IN ('queued','running')",
                (user["id"],),
            ).fetchone()[0]
            >= 2
        ):
            raise HTTPException(
                429,
                "Two drafts are already being prepared. Review them before requesting more.",
            )
        since = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
        total = conn.execute(
            "SELECT count(*) FROM generation_jobs WHERE created_at>?", (since,)
        ).fetchone()[0]
        mine = conn.execute(
            "SELECT count(*) FROM generation_jobs WHERE created_at>? AND user_id=?",
            (since, user["id"]),
        ).fetchone()[0]
        if total >= int(os.getenv("VAACHAK_GENERATION_DAILY_JOBS", "50")) or mine >= 10:
            raise HTTPException(
                429,
                "The draft-generation budget is reached. Existing practice and manual authoring are still available.",
            )
        conn.execute(
            "INSERT INTO generation_jobs(id,user_id,request_hash,payload,status,created_at) VALUES(?,?,?,?,?,?)",
            (key, user["id"], digest, json.dumps(payload), "queued", evidence.now()),
        )
        conn.commit()
        if os.getenv("VAACHAK_RUN_WORKER") == "inline":
            from inline_worker import wake
            wake()
        return read_job(body.client_uuid, user, conn)
    except Exception:
        conn.rollback()
        raise


@router.get("/ai/jobs/{job_id}", response_model=contracts.Response)
def read_job(job_id: UUID, user=Depends(teacher_only), conn=Depends(get_db)):
    row = conn.execute(
        "SELECT * FROM generation_jobs WHERE id=? AND user_id=?",
        (str(job_id), user["id"]),
    ).fetchone()
    if not row:
        raise HTTPException(404, "Draft job not found.")
    return result(row)


@router.get("/ai/jobs", response_model=list[contracts.Response])
def list_jobs(user=Depends(teacher_only), conn=Depends(get_db)):
    return [
        result(r)
        for r in conn.execute(
            "SELECT * FROM generation_jobs WHERE user_id=? ORDER BY created_at DESC LIMIT 30",
            (user["id"],),
        )
    ]


def work_once():
    """One worker can safely lease one job without holding DB locks during I/O."""
    with db.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute(
            "UPDATE generation_jobs SET status=CASE WHEN tries<2 THEN 'queued' ELSE 'failed' END,error_code='worker_interrupted' WHERE status='running' AND lease_until<?",
            (evidence.now(),),
        )
        row = conn.execute(
            "SELECT * FROM generation_jobs WHERE status='queued' ORDER BY created_at LIMIT 1"
        ).fetchone()
        if not row:
            conn.commit()
            return False
        lease = (datetime.now(timezone.utc) + timedelta(minutes=10)).isoformat()
        conn.execute(
            "UPDATE generation_jobs SET status='running',lease_until=?,tries=tries+1 WHERE id=?",
            (lease, row["id"]),
        )
        conn.commit()
        started = time.monotonic()
        state = "completed"
        error = None
        items = []
        try:
            if not ai.configured():
                raise ValueError("provider_unavailable")
            p = json.loads(row["payload"])
            raw = ai.generate_items(
                p["topic"], p["count"], p.get("kinds"), p["level"], p.get("context")
            )
            if not raw:
                raise ValueError("generation_unavailable")
            items = [clean_item(ItemIn(**i)) for i in raw][: p["count"]]
        except Exception:
            state = "failed"
            error = "generation_unavailable"
        conn.execute(
            "UPDATE generation_jobs SET status=?,items=?,error_code=?,model=? WHERE id=? AND lease_until=?",
            (
                state,
                json.dumps(items),
                error,
                ai.last_model() if items else None,
                row["id"],
                lease,
            ),
        )
        conn.commit()
        logger.info(
            json.dumps(
                {
                    "event": "generation_job",
                    "job_id": row["id"],
                    "status": state,
                    "duration_ms": round((time.monotonic() - started) * 1000),
                    "error_code": error,
                }
            )
        )
        return True
