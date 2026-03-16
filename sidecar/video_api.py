"""Rockport Video Generation Sidecar API.

FastAPI service that proxies video generation requests to Amazon Bedrock
video models (Nova Reel, Luma Ray2) via the async invoke API. Runs alongside
LiteLLM on the same EC2 instance.

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

# Limit Pillow decompression to accommodate Ray2's 4096x4096 max
Image.MAX_IMAGE_PIXELS = 4096 * 4096 * 2

# --- Configuration ---

LITELLM_URL = os.environ.get("LITELLM_URL", "http://127.0.0.1:4000")
MASTER_KEY = os.environ.get("LITELLM_MASTER_KEY", "")
MAX_CONCURRENT_JOBS = int(os.environ.get("VIDEO_MAX_CONCURRENT_JOBS", "3"))

# Per-region S3 buckets (Bedrock async invoke requires same-region bucket)
VIDEO_BUCKETS = {
    "us-east-1": os.environ.get("VIDEO_BUCKET", ""),
    "us-west-2": os.environ.get("VIDEO_BUCKET_US_WEST_2", ""),
}

# --- Video Model Registry ---

VIDEO_MODELS = {
    "nova-reel": {
        "bedrock_model_id": "amazon.nova-reel-v1:1",
        "region": "us-east-1",
        "durations": list(range(6, 121, 6)),  # 6, 12, 18, ..., 120
        "duration_must_be_multiple_of": 6,
        "resolutions": None,  # fixed 1280x720
        "aspect_ratios": None,  # fixed 16:9
        "supports_multi_shot": True,
        "supports_loop": False,
        "supports_seed": True,
        "supports_end_image": False,
        "cost_per_second": {"default": 0.08},
        "image_exact_size": (1280, 720),
        "image_min_size": None,
        "image_max_size": None,
        "image_max_bytes": 10 * 1024 * 1024,
        "default_resolution": None,
        "default_aspect_ratio": None,
    },
    "luma-ray2": {
        "bedrock_model_id": "luma.ray-v2:0",
        "region": "us-west-2",
        "durations": [5, 9],
        "duration_must_be_multiple_of": None,
        "resolutions": ["540p", "720p"],
        "aspect_ratios": ["16:9", "9:16", "1:1", "4:3", "3:4", "21:9", "9:21"],
        "supports_multi_shot": False,
        "supports_loop": True,
        "supports_seed": False,
        "supports_end_image": True,
        "cost_per_second": {"540p": 0.75, "720p": 1.50},
        "image_exact_size": None,
        "image_min_size": (512, 512),
        "image_max_size": (4096, 4096),
        "image_max_bytes": 25 * 1024 * 1024,
        "default_resolution": "720p",
        "default_aspect_ratio": "16:9",
    },
}

# --- Boto3 clients (initialized on startup, keyed by region) ---

bedrock_clients: dict[str, object] = {}
s3_clients: dict[str, object] = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    database_url = os.environ.get("DATABASE_URL", "")
    db.init_pool(database_url)
    db.ensure_tables()
    # Initialize one Bedrock + S3 client per region used by video models
    regions = {m["region"] for m in VIDEO_MODELS.values()}
    for region in regions:
        bedrock_clients[region] = boto3.client("bedrock-runtime", region_name=region)
        s3_clients[region] = boto3.client("s3", region_name=region, config=BotoConfig(signature_version="s3v4"))
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
    image: str | None = Field(default=None, max_length=14_000_000)


class VideoGenerationRequest(BaseModel):
    model: str | None = None
    prompt: str | None = Field(default=None, min_length=1, max_length=5000)
    duration: int | None = None
    image: str | None = Field(default=None, max_length=35_000_000)
    end_image: str | None = Field(default=None, max_length=35_000_000)
    shots: list[ShotRequest] | None = None
    seed: int | None = None
    aspect_ratio: str | None = None
    resolution: str | None = None
    loop: bool | None = None


# --- Image validation ---

def validate_image_nova_reel(data_uri: str) -> tuple[bytes, str]:
    """Validate a Nova Reel image: exactly 1280x720, PNG or JPEG, max 10MB.

    Returns (raw_bytes, format_str) where format_str is 'png' or 'jpeg'.
    If the image has a fully-opaque alpha channel, it is stripped automatically.
    """
    max_bytes = VIDEO_MODELS["nova-reel"]["image_max_bytes"]
    raw, img = _decode_image(data_uri, max_bytes)

    if img.size != (1280, 720):
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"Image must be 1280x720 (got {img.size[0]}x{img.size[1]})"}
        })

    fmt = img.format
    # Alpha channel handling (PNG only — JPEG never has alpha)
    if img.mode in ("RGBA", "LA", "PA"):
        alpha = img.getchannel("A")
        min_alpha = alpha.getextrema()[0]
        if min_alpha < 255:
            raise HTTPException(status_code=400, detail={
                "error": {"type": "validation_error",
                          "message": f"Image contains transparent pixels (got {img.mode} mode "
                                     f"with alpha < 255). Nova Reel requires fully opaque images."}
            })
        img = img.convert("RGB")
        buf = io.BytesIO()
        img.save(buf, format=fmt)
        raw = buf.getvalue()

    return raw, fmt.lower()


def validate_image_ray2(data_uri: str) -> tuple[bytes, str]:
    """Validate a Ray2 image: 512x512 to 4096x4096, PNG or JPEG, max 25MB.

    Returns (raw_bytes, format_str) where format_str is 'png' or 'jpeg'.
    """
    model = VIDEO_MODELS["luma-ray2"]
    max_bytes = model["image_max_bytes"]
    raw, img = _decode_image(data_uri, max_bytes)

    min_w, min_h = model["image_min_size"]
    max_w, max_h = model["image_max_size"]
    w, h = img.size
    if w < min_w or h < min_h:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"Image must be at least {min_w}x{min_h} (got {w}x{h})"}
        })
    if w > max_w or h > max_h:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"Image must be at most {max_w}x{max_h} (got {w}x{h})"}
        })

    return raw, img.format.lower()


def _decode_image(data_uri: str, max_bytes: int) -> tuple[bytes, Image.Image]:
    """Decode a data URI into raw bytes and a PIL Image. Validates format is PNG or JPEG."""
    try:
        if not data_uri.startswith("data:image/"):
            raise ValueError("Must be a data:image/ URI")
        header, b64data = data_uri.split(",", 1)
        if len(b64data) > max_bytes * 4 // 3:
            raise ValueError("Image too large")
        raw = base64.b64decode(b64data)
        if len(raw) > max_bytes:
            raise ValueError("Image too large")
    except (ValueError, Exception) as e:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"Invalid base64 image data URI: {e}"}
        })

    try:
        img = Image.open(io.BytesIO(raw))
        img.load()
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

    return raw, img


def parse_nova_reel_image(data_uri: str) -> tuple[str, str]:
    """Parse and validate a Nova Reel image, returning (raw_base64, format_str)."""
    raw_bytes, fmt = validate_image_nova_reel(data_uri)
    return base64.b64encode(raw_bytes).decode("ascii"), fmt


def parse_ray2_image(data_uri: str) -> tuple[str, str]:
    """Parse and validate a Ray2 image, returning (raw_base64, media_type)."""
    raw_bytes, fmt = validate_image_ray2(data_uri)
    media_type = "image/jpeg" if fmt == "jpeg" else "image/png"
    return base64.b64encode(raw_bytes).decode("ascii"), media_type


# --- Cost calculation ---

def calculate_cost(model_name: str, duration: int, resolution: str | None = None) -> float:
    """Calculate cost for a video job based on model and resolution."""
    model = VIDEO_MODELS[model_name]
    pricing = model["cost_per_second"]
    if "default" in pricing:
        return duration * pricing["default"]
    # Resolution-dependent pricing (Ray2)
    res = resolution or model["default_resolution"]
    return duration * pricing.get(res, 0)


# --- Endpoints ---

@app.get("/v1/videos/health")
def health():
    """Health check — verifies DB connectivity and per-model Bedrock reachability."""
    db_ok = False
    try:
        with db._get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
        db_ok = True
    except Exception:
        pass

    models_status = {}
    any_model_ok = False
    for name, model in VIDEO_MODELS.items():
        region = model["region"]
        client = bedrock_clients.get(region)
        ok = False
        if client:
            try:
                client.list_async_invokes(maxResults=1)
                ok = True
                any_model_ok = True
            except Exception:
                pass
        models_status[name] = {"status": "healthy" if ok else "unavailable", "region": region}

    overall = "healthy" if (db_ok and any_model_ok) else "unhealthy"
    code = 200 if overall == "healthy" else 503
    return JSONResponse(
        status_code=code,
        content={
            "status": overall,
            "database": "connected" if db_ok else "disconnected",
            "models": models_status,
        },
    )


@app.post("/v1/videos/generations", status_code=202)
def create_video(req: VideoGenerationRequest, auth: dict = Depends(authenticate)):
    """Submit a video generation job (single-shot or multi-shot)."""
    key_hash = auth["key_hash"]

    # --- Resolve model ---
    model_name = req.model or "nova-reel"
    if model_name not in VIDEO_MODELS:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"Unknown model '{model_name}'. Available: {', '.join(VIDEO_MODELS.keys())}"}
        })
    model = VIDEO_MODELS[model_name]

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

    # --- Multi-shot validation ---
    if req.shots:
        if not model["supports_multi_shot"]:
            raise HTTPException(status_code=400, detail={
                "error": {"type": "validation_error",
                          "message": f"Multi-shot mode is not supported by {model_name}. Use nova-reel instead."}
            })
        mode = "multi_shot"
        num_shots = len(req.shots)
        if num_shots < 2 or num_shots > 20:
            raise HTTPException(status_code=400, detail={
                "error": {"type": "validation_error",
                          "message": f"Multi-shot requires 2-20 shots (got {num_shots})."}
            })
        duration = 6 * num_shots
        parsed_images: dict[int, tuple[str, str]] = {}
        for i, shot in enumerate(req.shots):
            if shot.image:
                parsed_images[i] = parse_nova_reel_image(shot.image)
        prompt_store = json.dumps([s.prompt for s in req.shots])
        resolution = None
    else:
        mode = "single_shot"
        num_shots = 1
        duration = req.duration or (model["durations"][0] if model["durations"] else 6)

        # Duration validation
        if duration not in model["durations"]:
            if model["duration_must_be_multiple_of"]:
                low, high = model["durations"][0], model["durations"][-1]
                mult = model["duration_must_be_multiple_of"]
                raise HTTPException(status_code=400, detail={
                    "error": {"type": "validation_error",
                              "message": f"Duration must be {low}-{high} seconds and a multiple of {mult} (got {duration})."}
                })
            else:
                raise HTTPException(status_code=400, detail={
                    "error": {"type": "validation_error",
                              "message": f"Duration must be one of {model['durations']} seconds for {model_name} (got {duration})."}
                })

        # Ray2-specific: aspect_ratio, resolution
        resolution = None
        if model["resolutions"]:
            resolution = req.resolution or model["default_resolution"]
            if resolution not in model["resolutions"]:
                raise HTTPException(status_code=400, detail={
                    "error": {"type": "validation_error",
                              "message": f"Resolution must be one of {model['resolutions']} for {model_name} (got {resolution})."}
                })
        if model["aspect_ratios"]:
            aspect_ratio = req.aspect_ratio or model["default_aspect_ratio"]
            if aspect_ratio not in model["aspect_ratios"]:
                raise HTTPException(status_code=400, detail={
                    "error": {"type": "validation_error",
                              "message": f"Aspect ratio must be one of {model['aspect_ratios']} for {model_name} (got {req.aspect_ratio})."}
                })
        else:
            aspect_ratio = None

        # end_image validation
        if req.end_image and not model["supports_end_image"]:
            raise HTTPException(status_code=400, detail={
                "error": {"type": "validation_error",
                          "message": f"End image (end_image) is not supported by {model_name}. Use luma-ray2 instead."}
            })

        # Image validation (model-specific)
        parsed_image: tuple[str, str] | None = None
        parsed_end_image: tuple[str, str] | None = None

        if model_name == "nova-reel":
            if req.image:
                if duration != 6:
                    raise HTTPException(status_code=400, detail={
                        "error": {"type": "validation_error",
                                  "message": "Single-shot with image is fixed at 6 seconds. "
                                             "Remove 'duration' or set it to 6."}
                    })
                parsed_image = parse_nova_reel_image(req.image)
        elif model_name == "luma-ray2":
            if req.image:
                parsed_image = parse_ray2_image(req.image)
            if req.end_image:
                parsed_end_image = parse_ray2_image(req.end_image)

        prompt_store = req.prompt

    estimated_cost = calculate_cost(model_name, duration, resolution)

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
    region = model["region"]
    bucket = VIDEO_BUCKETS.get(region, "")
    s3_output_uri = f"s3://{bucket}/jobs/{job_id}/"

    if model_name == "nova-reel":
        model_input = _build_nova_reel_payload(req, mode, duration, parsed_images if req.shots else {},
                                                parsed_image if not req.shots else None)
    elif model_name == "luma-ray2":
        model_input = _build_ray2_payload(req.prompt, duration, aspect_ratio, resolution,
                                           req.loop, parsed_image, parsed_end_image)

    # --- Call Bedrock ---
    client = bedrock_clients[region]
    try:
        response = client.start_async_invoke(
            modelId=model["bedrock_model_id"],
            modelInput=model_input,
            outputDataConfig={"s3OutputDataConfig": {"s3Uri": s3_output_uri}},
        )
    except ClientError:
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error",
                      "message": "Video generation request failed. Check image format and dimensions."}
        })

    invocation_arn = response["invocationArn"]

    # --- Store job ---
    job = db.insert_job(
        job_id=job_id,
        api_key_hash=key_hash,
        invocation_arn=invocation_arn,
        model=model_name,
        mode=mode,
        prompt=prompt_store,
        num_shots=num_shots,
        duration_seconds=duration,
        cost=estimated_cost,
        resolution=resolution,
    )

    return job


def _build_nova_reel_payload(req, mode, duration, parsed_images, parsed_image):
    """Build Nova Reel modelInput payload."""
    if mode == "multi_shot":
        shots_payload = []
        for i, shot in enumerate(req.shots):
            s = {"text": shot.prompt}
            if i in parsed_images:
                raw_b64, fmt = parsed_images[i]
                s["image"] = {"format": fmt, "source": {"bytes": raw_b64}}
            shots_payload.append(s)
        model_input = {
            "taskType": "MULTI_SHOT_MANUAL",
            "multiShotManualParams": {"shots": shots_payload},
            "videoGenerationConfig": {
                "fps": 24,
                "dimension": "1280x720",
            },
        }
    else:
        text_params = {"text": req.prompt}
        if parsed_image:
            raw_b64, fmt = parsed_image
            text_params["images"] = [{"format": fmt, "source": {"bytes": raw_b64}}]
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

    return model_input


def _build_ray2_payload(prompt, duration, aspect_ratio, resolution, loop, parsed_image, parsed_end_image):
    """Build Luma Ray2 modelInput payload."""
    model_input = {
        "prompt": prompt,
        "duration": f"{duration}s",
    }
    if aspect_ratio:
        model_input["aspect_ratio"] = aspect_ratio
    if resolution:
        model_input["resolution"] = resolution
    if loop:
        model_input["loop"] = True

    # Keyframes for image-to-video
    if parsed_image:
        raw_b64, media_type = parsed_image
        keyframes = {
            "frame0": {
                "type": "image",
                "source": {"type": "base64", "media_type": media_type, "data": raw_b64},
            }
        }
        if parsed_end_image:
            end_b64, end_media = parsed_end_image
            keyframes["frame1"] = {
                "type": "image",
                "source": {"type": "base64", "media_type": end_media, "data": end_b64},
            }
        model_input["keyframes"] = keyframes

    return model_input


@app.get("/v1/videos/generations/{job_id}")
def get_video_status(job_id: str, auth: dict = Depends(authenticate)):
    """Poll job status. Always re-checks Bedrock for in-progress jobs (restart recovery)."""
    job = db.get_job(job_id, auth["key_hash"])
    if not job:
        raise HTTPException(status_code=404, detail={
            "error": {"type": "not_found", "message": "Job not found"}
        })

    # For in-progress jobs, always re-poll Bedrock
    if job["status"] == "in_progress":
        row = db.get_job_internals(job_id)
        if row:
            invocation_arn, duration_seconds, mode, created_at, job_model, job_resolution = row
            model = VIDEO_MODELS.get(job_model, VIDEO_MODELS["nova-reel"])
            region = model["region"]
            client = bedrock_clients.get(region)
            if client:
                try:
                    bedrock_resp = client.get_async_invoke(invocationArn=invocation_arn)
                    bedrock_status = bedrock_resp["status"]

                    if bedrock_status == "Completed":
                        s3_uri = bedrock_resp["outputDataConfig"]["s3OutputDataConfig"]["s3Uri"]
                        cost = calculate_cost(job_model, duration_seconds, job_resolution)
                        if db.try_complete_job(job_id, s3_uri):
                            db.log_spend(
                                api_key_hash=auth["key_hash"],
                                job_id=job_id,
                                cost=cost,
                                duration_seconds=duration_seconds,
                                mode=mode,
                                model=job_model,
                                start_time=created_at,
                            )
                        job["status"] = "completed"
                        job["cost"] = cost
                        job["s3_uri"] = s3_uri
                        job["completed_at"] = datetime.now(timezone.utc).isoformat()

                    elif bedrock_status == "Failed":
                        error_msg = "Video generation failed"
                        db.try_fail_job(job_id, error_msg)
                        job["status"] = "failed"
                        job["cost"] = 0
                        job["error"] = error_msg
                        job["completed_at"] = datetime.now(timezone.utc).isoformat()

                except ClientError:
                    pass

    # Generate presigned URL for completed jobs
    if job["status"] == "completed" and job.get("s3_uri"):
        s3_uri = job["s3_uri"]
        bucket = s3_uri.split("/")[2]
        key_prefix = "/".join(s3_uri.split("/")[3:])

        # Determine correct S3 client from bucket name
        s3 = None
        for region, client in s3_clients.items():
            if VIDEO_BUCKETS.get(region) == bucket:
                s3 = client
                break
        if not s3:
            s3 = list(s3_clients.values())[0]  # fallback

        try:
            resp = s3.list_objects_v2(Bucket=bucket, Prefix=key_prefix, MaxKeys=10)
            mp4_key = None
            for obj in resp.get("Contents", []):
                if obj["Key"].endswith("/output.mp4"):
                    mp4_key = obj["Key"]
                    break

            if mp4_key:
                url = s3.generate_presigned_url(
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
            pass

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
