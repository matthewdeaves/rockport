"""PostgreSQL database layer for video generation jobs.

Uses LiteLLM's existing PostgreSQL database with a new rockport_video_jobs table.
Also writes to LiteLLM_SpendLogs and LiteLLM_VerificationToken for unified spend tracking.

The `prompt` column stores plain text for single-shot mode and a JSON array of
shot prompt strings for multi-shot mode (determined by the `mode` column).
"""

import json
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from decimal import Decimal

import psycopg2
from psycopg2 import pool

COST_PER_SECOND = Decimal("0.08")

_pool = None


def init_pool(database_url: str) -> None:
    global _pool
    _pool = pool.ThreadedConnectionPool(1, 5, database_url)


def close_pool() -> None:
    if _pool:
        _pool.closeall()


@contextmanager
def _get_conn(autocommit=False):
    """Context manager that gets a connection, handles rollback on error, and returns it."""
    conn = _pool.getconn()
    try:
        if autocommit:
            conn.autocommit = True
        yield conn
        if not autocommit:
            conn.commit()
    except Exception:
        if not autocommit:
            conn.rollback()
        raise
    finally:
        if autocommit:
            conn.autocommit = False
        _pool.putconn(conn)


def ensure_tables() -> None:
    """Create the rockport_video_jobs table if it doesn't exist."""
    with _get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS rockport_video_jobs (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    api_key_hash VARCHAR(128) NOT NULL,
                    invocation_arn VARCHAR(512) UNIQUE NOT NULL,
                    status VARCHAR(20) NOT NULL DEFAULT 'in_progress',
                    mode VARCHAR(20) NOT NULL,
                    prompt TEXT NOT NULL,
                    num_shots INTEGER NOT NULL DEFAULT 1,
                    duration_seconds INTEGER NOT NULL,
                    cost DECIMAL(10,4) DEFAULT 0,
                    s3_uri VARCHAR(512),
                    error_message TEXT,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    completed_at TIMESTAMPTZ
                );
                CREATE INDEX IF NOT EXISTS idx_video_jobs_api_key_hash ON rockport_video_jobs (api_key_hash);
                CREATE INDEX IF NOT EXISTS idx_video_jobs_status ON rockport_video_jobs (status);
                CREATE INDEX IF NOT EXISTS idx_video_jobs_created_at ON rockport_video_jobs (created_at);
            """)


def insert_job(
    job_id: uuid.UUID,
    api_key_hash: str,
    invocation_arn: str,
    mode: str,
    prompt: str,
    num_shots: int,
    duration_seconds: int,
) -> dict:
    """Insert a new video job. Returns the job dict."""
    estimated_cost = Decimal(duration_seconds) * COST_PER_SECOND
    with _get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO rockport_video_jobs
                    (id, api_key_hash, invocation_arn, mode, prompt, num_shots,
                     duration_seconds, cost, status)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'in_progress')
                RETURNING id, status, mode, duration_seconds, cost, created_at
                """,
                (str(job_id), api_key_hash, invocation_arn, mode, prompt,
                 num_shots, duration_seconds, estimated_cost),
            )
            row = cur.fetchone()
    return {
        "id": str(row[0]),
        "status": row[1],
        "mode": row[2],
        "duration": row[3],
        "estimated_cost": float(row[4]),
        "created_at": row[5].isoformat(),
    }


def get_job(job_id: str, api_key_hash: str) -> dict | None:
    """Get a job by ID, scoped to the requesting key. Returns None if not found."""
    with _get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, status, mode, duration_seconds, cost, s3_uri,
                       error_message, created_at, completed_at
                FROM rockport_video_jobs
                WHERE id = %s AND api_key_hash = %s
                """,
                (job_id, api_key_hash),
            )
            row = cur.fetchone()
    if not row:
        return None
    return {
        "id": str(row[0]),
        "status": row[1],
        "mode": row[2],
        "duration": row[3],
        "cost": float(row[4]),
        "s3_uri": row[5],
        "error": row[6],
        "created_at": row[7].isoformat(),
        "completed_at": row[8].isoformat() if row[8] else None,
    }


def get_job_internals(job_id: str) -> tuple | None:
    """Get internal job fields needed for Bedrock polling."""
    with _get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT invocation_arn, duration_seconds, mode, created_at FROM rockport_video_jobs WHERE id = %s",
                (job_id,),
            )
            return cur.fetchone()


def list_jobs(
    api_key_hash: str,
    limit: int = 20,
    status_filter: str | None = None,
) -> list[dict]:
    """List recent jobs for a key, ordered by most recent first."""
    with _get_conn() as conn:
        with conn.cursor() as cur:
            query = """
                SELECT id, status, mode, duration_seconds, cost, created_at, completed_at
                FROM rockport_video_jobs
                WHERE api_key_hash = %s
            """
            params: list = [api_key_hash]
            if status_filter:
                query += " AND status = %s"
                params.append(status_filter)
            query += " ORDER BY created_at DESC LIMIT %s"
            params.append(limit)
            cur.execute(query, params)
            rows = cur.fetchall()
    return [
        {
            "id": str(r[0]),
            "status": r[1],
            "mode": r[2],
            "duration": r[3],
            "cost": float(r[4]),
            "created_at": r[5].isoformat(),
            "completed_at": r[6].isoformat() if r[6] else None,
        }
        for r in rows
    ]


def try_complete_job(
    job_id: str,
    s3_uri: str,
) -> bool:
    """Atomically transition job from in_progress to completed. Returns True if this call did the transition."""
    with _get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE rockport_video_jobs
                SET status = 'completed', s3_uri = %s, completed_at = NOW()
                WHERE id = %s AND status = 'in_progress'
                RETURNING id
                """,
                (s3_uri, job_id),
            )
            return cur.fetchone() is not None


def try_fail_job(
    job_id: str,
    error_message: str,
) -> bool:
    """Atomically transition job from in_progress to failed. Returns True if this call did the transition."""
    with _get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE rockport_video_jobs
                SET status = 'failed', error_message = %s, cost = 0, completed_at = NOW()
                WHERE id = %s AND status = 'in_progress'
                RETURNING id
                """,
                (error_message, job_id),
            )
            return cur.fetchone() is not None


def mark_expired(job_id: str) -> None:
    """Mark a completed job as expired (video file deleted)."""
    with _get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE rockport_video_jobs
                SET status = 'expired',
                    error_message = 'Video file has been deleted (7-day retention period expired)'
                WHERE id = %s AND status = 'completed'
                """,
                (job_id,),
            )


def count_in_progress_jobs(api_key_hash: str) -> int:
    """Count in-progress jobs for a given API key."""
    with _get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT COUNT(*) FROM rockport_video_jobs
                WHERE api_key_hash = %s AND status = 'in_progress'
                """,
                (api_key_hash,),
            )
            return cur.fetchone()[0]


def log_spend(
    api_key_hash: str,
    job_id: str,
    cost: float,
    duration_seconds: int,
    mode: str,
    start_time: datetime,
) -> None:
    """Write spend to LiteLLM_SpendLogs and increment LiteLLM_VerificationToken.spend."""
    with _get_conn() as conn:
        with conn.cursor() as cur:
            metadata = json.dumps({
                "video_job_id": job_id,
                "duration_seconds": duration_seconds,
                "mode": mode,
            })
            cur.execute(
                """
                INSERT INTO "LiteLLM_SpendLogs"
                    (request_id, api_key, model, spend, total_tokens,
                     prompt_tokens, completion_tokens, "startTime", metadata)
                VALUES (%s, %s, %s, %s, 0, 0, 0, %s, %s)
                """,
                (job_id, api_key_hash, "nova-reel", cost,
                 start_time, metadata),
            )
            cur.execute(
                """
                UPDATE "LiteLLM_VerificationToken"
                SET spend = spend + %s
                WHERE token = %s
                """,
                (cost, api_key_hash),
            )
