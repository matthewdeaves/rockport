"""Rockport Video Generation Sidecar API.

FastAPI service that proxies video generation requests to Amazon Nova Reel
via Bedrock's async invoke API. Runs alongside LiteLLM on the same EC2 instance.

All endpoints use def (not async def) so FastAPI runs them in a threadpool,
avoiding event loop blocking from synchronous boto3 and psycopg2 calls.
"""

import base64
import hashlib
import io
import json
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

import boto3
import httpx
from botocore.config import Config as BotoConfig
from botocore.exceptions import ClientError
from fastapi import Depends, FastAPI, HTTPException, Header, Query
from fastapi.responses import JSONResponse
from PIL import Image
from pydantic import BaseModel, Field

import db

# --- Configuration ---

LITELLM_URL = os.environ.get("LITELLM_URL", "http://127.0.0.1:4000")
MASTER_KEY = os.environ.get("LITELLM_MASTER_KEY", "")
VIDEO_BUCKET = os.environ.get("VIDEO_BUCKET", "")
VIDEO_MODEL_ID = "amazon.nova-reel-v1:1"
COST_PER_SECOND = 0.08
MAX_CONCURRENT_JOBS = int(os.environ.get("VIDEO_MAX_CONCURRENT_JOBS", "3"))
MAX_IMAGE_BYTES = 10 * 1024 * 1024  # 10MB limit for base64 image payloads

# --- Boto3 clients (initialized on startup) ---

bedrock_client = None
s3_client = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global bedrock_client, s3_client
    database_url = os.environ.get("DATABASE_URL", "")
    db.init_pool(database_url)
    db.ensure_tables()
    bedrock_client = boto3.client("bedrock-runtime", region_name="us-east-1")
    s3_client = boto3.client("s3", region_name="us-east-1", config=BotoConfig(signature_version="s3v4"))
    yield
    db.close_pool()


app = FastAPI(title="Rockport Video API", docs_url=None, redoc_url=None, lifespan=lifespan)


# --- Auth ---

def hash_key(key: str) -> str:
    """Hash an API key the same way LiteLLM does (SHA-256)."""
    return hashlib.sha256(key.encode()).hexdigest()


def authenticate(authorization: str = Header(...)) -> dict:
    """Validate the user's API key by calling LiteLLM's /key/info endpoint."""
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail={
            "error": {"type": "authentication_error", "message": "Invalid Authorization header"}
        })
    user_key = authorization[7:]
    key_hash = hash_key(user_key)

    try:
        resp = httpx.get(
            f"{LITELLM_URL}/key/info",
            params={"key": user_key},
            headers={"Authorization": f"Bearer {MASTER_KEY}"},
            timeout=10,
        )
    except httpx.RequestError:
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error", "message": "Could not reach auth service"}
        })

    if resp.status_code != 200:
        raise HTTPException(status_code=401, detail={
            "error": {"type": "authentication_error", "message": "Invalid API key"}
        })

    info = resp.json().get("info", resp.json())
    return {
        "key_hash": key_hash,
        "spend": info.get("spend", 0),
        "max_budget": info.get("max_budget"),
    }


# --- Request models ---

class ShotRequest(BaseModel):
    prompt: str = Field(..., min_length=1, max_length=512)
    image: str | None = None


class VideoGenerationRequest(BaseModel):
    prompt: str | None = Field(default=None, min_length=1, max_length=4000)
    duration: int | None = None
    image: str | None = None
    shots: list[ShotRequest] | None = None
    seed: int | None = None


# --- Image validation ---

def validate_image(data_uri: str) -> None:
    """Validate a base64 data URI image is 1280x720 PNG or JPEG."""
    try:
        if not data_uri.startswith("data:image/"):
            raise ValueError("Must be a data:image/ URI")
        header, b64data = data_uri.split(",", 1)
        if len(b64data) > MAX_IMAGE_BYTES * 4 // 3:  # base64 expansion ratio
            raise ValueError("Image too large")
        raw = base64.b64decode(b64data)
        if len(raw) > MAX_IMAGE_BYTES:
            raise ValueError("Image too large")
    except (ValueError, Exception) as e:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"Invalid base64 image data URI: {e}"}
        })

    try:
        img = Image.open(io.BytesIO(raw))
        img.load()  # Force decode to catch truncated images
    except Exception:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": "Could not decode image"}
        })

    if img.format not in ("JPEG", "PNG"):
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"Image must be PNG or JPEG (got {img.format})"}
        })
    if img.size != (1280, 720):
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"Image must be 1280x720 (got {img.size[0]}x{img.size[1]})"}
        })


# --- Endpoints ---

@app.get("/v1/videos/health")
def health():
    """Health check — verifies DB connectivity and Bedrock reachability."""
    db_ok = False
    bedrock_ok = False

    try:
        with db._get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
        db_ok = True
    except Exception:
        pass

    try:
        bedrock_client.list_async_invokes(maxResults=1)
        bedrock_ok = True
    except Exception:
        pass

    status = "healthy" if (db_ok and bedrock_ok) else "unhealthy"
    code = 200 if status == "healthy" else 503
    return JSONResponse(
        status_code=code,
        content={
            "status": status,
            "database": "connected" if db_ok else "disconnected",
            "bedrock": "reachable" if bedrock_ok else "unreachable",
        },
    )


@app.post("/v1/videos/generations", status_code=202)
def create_video(req: VideoGenerationRequest, auth: dict = Depends(authenticate)):
    """Submit a video generation job (single-shot or multi-shot)."""
    key_hash = auth["key_hash"]

    # --- Determine mode and validate ---
    if req.prompt and req.shots:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": "Cannot provide both 'prompt' and 'shots'. Use one mode."}
        })
    if not req.prompt and not req.shots:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": "Must provide either 'prompt' (single-shot) or 'shots' (multi-shot)."}
        })

    if req.shots:
        mode = "multi_shot"
        num_shots = len(req.shots)
        if num_shots < 2 or num_shots > 20:
            raise HTTPException(status_code=400, detail={
                "error": {"type": "validation_error",
                          "message": f"Multi-shot requires 2-20 shots (got {num_shots})."}
            })
        duration = 6 * num_shots
        for shot in req.shots:
            if shot.image:
                validate_image(shot.image)
        prompt_store = json.dumps([s.prompt for s in req.shots])
    else:
        mode = "single_shot"
        num_shots = 1
        duration = req.duration or 6
        if duration < 6 or duration > 120:
            raise HTTPException(status_code=400, detail={
                "error": {"type": "validation_error",
                          "message": f"Duration must be 6-120 seconds (got {duration})."}
            })
        if duration % 6 != 0:
            raise HTTPException(status_code=400, detail={
                "error": {"type": "validation_error",
                          "message": f"Duration must be a multiple of 6 seconds (got {duration})."}
            })
        if req.image:
            validate_image(req.image)
        prompt_store = req.prompt

    estimated_cost = duration * COST_PER_SECOND

    # --- Budget enforcement ---
    max_budget = auth.get("max_budget")
    if max_budget is not None:
        remaining = max_budget - auth["spend"]
        if estimated_cost > remaining:
            raise HTTPException(status_code=402, detail={
                "error": {
                    "type": "budget_exceeded",
                    "message": f"Estimated cost ${estimated_cost:.2f} exceeds remaining budget ${remaining:.2f}",
                    "estimated_cost": estimated_cost,
                    "remaining_budget": remaining,
                }
            })

    # --- Concurrent job limit ---
    in_progress = db.count_in_progress_jobs(key_hash)
    if in_progress >= MAX_CONCURRENT_JOBS:
        raise HTTPException(status_code=429, detail={
            "error": {
                "type": "concurrent_limit",
                "message": f"Concurrent job limit reached ({in_progress}/{MAX_CONCURRENT_JOBS} in progress)",
                "in_progress": in_progress,
                "limit": MAX_CONCURRENT_JOBS,
            }
        })

    # --- Build Bedrock request ---
    job_id = uuid.uuid4()
    s3_output_uri = f"s3://{VIDEO_BUCKET}/jobs/{job_id}/"

    if mode == "multi_shot":
        videos = []
        for shot in req.shots:
            v = {"text": shot.prompt}
            if shot.image:
                v["imageDataURI"] = shot.image
            videos.append(v)
        model_input = {
            "taskType": "TEXT_VIDEO",
            "textToVideoParams": {"videos": videos},
            "videoGenerationConfig": {
                "fps": 24,
                "durationSeconds": duration,
                "dimension": "1280x720",
            },
        }
    else:
        text_params = {"text": req.prompt}
        if req.image:
            text_params["image"] = req.image
        model_input = {
            "taskType": "TEXT_VIDEO",
            "textToVideoParams": text_params,
            "videoGenerationConfig": {
                "fps": 24,
                "durationSeconds": duration,
                "dimension": "1280x720",
            },
        }

    if req.seed is not None:
        model_input["videoGenerationConfig"]["seed"] = req.seed

    # --- Call Bedrock ---
    try:
        response = bedrock_client.start_async_invoke(
            modelId=VIDEO_MODEL_ID,
            modelInput=model_input,
            outputDataConfig={"s3OutputDataConfig": {"s3Uri": s3_output_uri}},
        )
    except ClientError as e:
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error",
                      "message": f"Bedrock error: {e.response['Error']['Message']}"}
        })

    invocation_arn = response["invocationArn"]

    # --- Store job ---
    job = db.insert_job(
        job_id=job_id,
        api_key_hash=key_hash,
        invocation_arn=invocation_arn,
        mode=mode,
        prompt=prompt_store,
        num_shots=num_shots,
        duration_seconds=duration,
    )

    return job


@app.get("/v1/videos/generations/{job_id}")
def get_video_status(job_id: str, auth: dict = Depends(authenticate)):
    """Poll job status. Always re-checks Bedrock for in-progress jobs (restart recovery)."""
    job = db.get_job(job_id, auth["key_hash"])
    if not job:
        raise HTTPException(status_code=404, detail={
            "error": {"type": "not_found", "message": "Job not found"}
        })

    # For in-progress jobs, always re-poll Bedrock (ensures restart recovery per SC-007)
    if job["status"] == "in_progress":
        row = db.get_job_internals(job_id)
        if row:
            invocation_arn, duration_seconds, mode, created_at = row
            try:
                bedrock_resp = bedrock_client.get_async_invoke(invocationArn=invocation_arn)
                bedrock_status = bedrock_resp["status"]

                if bedrock_status == "Completed":
                    s3_uri = bedrock_resp["outputDataConfig"]["s3OutputDataConfig"]["s3Uri"]
                    cost = float(duration_seconds * COST_PER_SECOND)
                    # Atomic CAS: only one poller processes the transition
                    if db.try_complete_job(job_id, s3_uri):
                        db.log_spend(
                            api_key_hash=auth["key_hash"],
                            job_id=job_id,
                            cost=cost,
                            duration_seconds=duration_seconds,
                            mode=mode,
                            start_time=created_at,
                        )
                    job["status"] = "completed"
                    job["cost"] = cost
                    job["s3_uri"] = s3_uri
                    job["completed_at"] = datetime.now(timezone.utc).isoformat()

                elif bedrock_status == "Failed":
                    error_msg = bedrock_resp.get("failureMessage", "Video generation failed")
                    db.try_fail_job(job_id, error_msg)
                    job["status"] = "failed"
                    job["cost"] = 0
                    job["error"] = error_msg
                    job["completed_at"] = datetime.now(timezone.utc).isoformat()

            except ClientError:
                pass  # Leave as in_progress, will retry on next poll

    # Generate presigned URL for completed jobs
    # Bedrock writes output under a random subdirectory: s3://bucket/jobs/{id}/{random}/output.mp4
    if job["status"] == "completed" and job.get("s3_uri"):
        s3_uri = job["s3_uri"]
        bucket = s3_uri.split("/")[2]
        key_prefix = "/".join(s3_uri.split("/")[3:])

        try:
            # Find output.mp4 under the prefix (Bedrock adds a random subdirectory)
            resp = s3_client.list_objects_v2(Bucket=bucket, Prefix=key_prefix, MaxKeys=10)
            mp4_key = None
            for obj in resp.get("Contents", []):
                if obj["Key"].endswith("/output.mp4"):
                    mp4_key = obj["Key"]
                    break

            if mp4_key:
                url = s3_client.generate_presigned_url(
                    "get_object",
                    Params={"Bucket": bucket, "Key": mp4_key},
                    ExpiresIn=3600,
                )
                job["url"] = url
                job["url_expires_at"] = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
            else:
                db.mark_expired(job_id)
                job["status"] = "expired"
                job["error"] = "Video file has been deleted (7-day retention period expired)"
        except ClientError:
            pass  # Transient S3 error — omit URL, don't mark expired

    # Clean up internal fields
    job.pop("s3_uri", None)
    return job


@app.get("/v1/videos/generations")
def list_videos(
    auth: dict = Depends(authenticate),
    limit: int = Query(default=20, ge=1, le=100),
    status: str | None = Query(default=None),
):
    """List recent jobs for the authenticated key."""
    valid_statuses = {"in_progress", "completed", "failed", "expired"}
    if status and status not in valid_statuses:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"Invalid status filter. Must be one of: {', '.join(valid_statuses)}"}
        })

    jobs = db.list_jobs(auth["key_hash"], limit=limit, status_filter=status)
    total = len(jobs)
    return {"data": jobs, "total": total}
