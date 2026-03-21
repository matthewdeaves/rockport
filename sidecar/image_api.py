"""Rockport Image Service Endpoints.

Synchronous endpoints for Nova Canvas advanced operations (IMAGE_VARIATION,
BACKGROUND_REMOVAL, OUTPAINTING).

All endpoints authenticate via LiteLLM /key/info, enforce budgets, block
--claude-only keys, and log spend to LiteLLM's unified tracking tables.
"""

import base64
import io
import json
import logging
import time
import uuid

import boto3
from botocore.exceptions import ClientError
from fastapi import APIRouter, Header, HTTPException
from PIL import Image
from pydantic import BaseModel, Field

import db

logger = logging.getLogger("rockport-image")

router = APIRouter()

# Boto3 client — initialized by video_api.py lifespan, shared via module-level reference
bedrock_us_east_1 = None


def init_clients():
    """Initialize Bedrock clients for image endpoints. Called from video_api.py lifespan."""
    global bedrock_us_east_1
    bedrock_us_east_1 = boto3.client("bedrock-runtime", region_name="us-east-1")


# --- Shared Infrastructure ---

LITELLM_URL = None  # Set from video_api.py
MASTER_KEY = None   # Set from video_api.py


def configure(litellm_url: str, master_key: str):
    """Set shared configuration from video_api.py."""
    global LITELLM_URL, MASTER_KEY
    LITELLM_URL = litellm_url
    MASTER_KEY = master_key


def authenticate_image_request(authorization: str) -> dict:
    """Authenticate and authorize an image service request.

    Validates the API key via LiteLLM /key/info, checks for --claude-only
    restriction (returns 403), and returns auth info for budget enforcement.
    """
    import httpx
    from video_api import hash_key, is_claude_only_key

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
    except httpx.RequestError as exc:
        logger.error("Auth service unreachable: %s: %s", type(exc).__name__, exc)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error", "message": "Could not reach auth service"}
        })

    if resp.status_code != 200:
        raise HTTPException(status_code=401, detail={
            "error": {"type": "authentication_error", "message": "Invalid API key"}
        })

    info = resp.json().get("info", resp.json())
    auth = {
        "key_hash": key_hash,
        "spend": info.get("spend", 0),
        "max_budget": info.get("max_budget"),
        "models": info.get("models", []),
    }

    if is_claude_only_key(auth):
        raise HTTPException(status_code=403, detail={
            "error": {
                "type": "forbidden",
                "message": "This endpoint requires an unrestricted API key. "
                           "Keys created with --claude-only cannot access image generation services.",
            }
        })

    return auth


def check_budget(auth: dict, estimated_cost: float):
    """Raise HTTP 402 if estimated cost exceeds remaining budget."""
    max_budget = auth.get("max_budget")
    if max_budget is not None:
        remaining = max_budget - auth["spend"]
        if estimated_cost > remaining:
            raise HTTPException(status_code=402, detail={
                "error": {
                    "type": "budget_exceeded",
                    "message": f"Estimated cost ${estimated_cost:.2f} exceeds remaining budget ${remaining:.2f}",
                }
            })


def decode_and_validate_image(
    data_uri: str,
    max_bytes: int = 10 * 1024 * 1024,
    allowed_formats: set[str] = frozenset({"JPEG", "PNG"}),
    min_size: tuple[int, int] | None = None,
    max_pixels: int | None = None,
    check_transparency: bool = True,
) -> tuple[str, str, Image.Image]:
    """Decode and validate an image from a data URI.

    Returns (raw_base64, format_lower, pil_image).
    """
    if not data_uri.startswith("data:image/"):
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error", "message": "Must be a data:image/ URI"}
        })
    header, b64data = data_uri.split(",", 1)
    raw = base64.b64decode(b64data)
    if len(raw) > max_bytes:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"Image exceeds {max_bytes // (1024*1024)}MB limit"}
        })

    try:
        img = Image.open(io.BytesIO(raw))
        img.load()
    except Exception:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error", "message": "Could not decode image"}
        })

    if img.format not in allowed_formats:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"Image must be {' or '.join(allowed_formats)} (got {img.format})"}
        })

    w, h = img.size
    if min_size:
        if w < min_size[0] or h < min_size[1]:
            raise HTTPException(status_code=400, detail={
                "error": {"type": "validation_error",
                          "message": f"Image must be at least {min_size[0]}x{min_size[1]} (got {w}x{h})"}
            })
    if max_pixels and w * h > max_pixels:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"Image exceeds {max_pixels} total pixels (got {w*h})"}
        })

    if check_transparency and img.mode in ("RGBA", "LA", "PA"):
        alpha = img.getchannel("A")
        if alpha.getextrema()[0] < 255:
            raise HTTPException(status_code=400, detail={
                "error": {"type": "validation_error",
                          "message": "Image contains transparent pixels. Nova Canvas requires fully opaque images."}
            })

    return b64data, img.format.lower(), img


# --- Cost Calculation ---

def calculate_nova_canvas_cost(n: int, width: int = 1024, height: int = 1024, quality: str = "standard") -> float:
    """Calculate Nova Canvas cost per the pricing table.

    Standard up to 1024x1024: $0.04/image
    Premium up to 1024x1024 or Standard up to 2048x2048: $0.06/image
    Premium up to 2048x2048: $0.08/image
    """
    large = width > 1024 or height > 1024
    if quality == "premium":
        per_image = 0.08 if large else 0.06
    else:
        per_image = 0.06 if large else 0.04
    return per_image * n


def _make_image_response(images: list[str], model: str, cost: float) -> dict:
    """Build an OpenAI-compatible image endpoint response."""
    return {
        "created": int(time.time()),
        "data": [{"b64_json": img} for img in images],
        "model": model,
        "cost": cost,
    }


# --- Nova Canvas Endpoints ---

class ImageVariationRequest(BaseModel):
    images: list[str] = Field(..., min_length=1, max_length=5)
    prompt: str = Field(..., min_length=1, max_length=1024)
    similarity_strength: float = Field(default=0.7, ge=0.2, le=1.0)
    negative_text: str | None = Field(default=None, max_length=1024)
    seed: int | None = Field(default=None, ge=0, le=2_147_483_646)
    cfg_scale: float = Field(default=6.5, ge=1.1, le=10.0)
    n: int = Field(default=1, ge=1, le=5)
    width: int = Field(default=1024, ge=320, le=4096)
    height: int = Field(default=1024, ge=320, le=4096)
    quality: str = Field(default="standard")


@router.post("/v1/images/variations")
def create_image_variation(req: ImageVariationRequest, authorization: str = Header(...)):
    auth = authenticate_image_request(authorization)

    if req.quality not in ("standard", "premium"):
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error", "message": "quality must be 'standard' or 'premium'"}
        })
    if req.width % 16 != 0 or req.height % 16 != 0:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error", "message": "width and height must be divisible by 16"}
        })

    cost = calculate_nova_canvas_cost(req.n, req.width, req.height, req.quality)
    check_budget(auth, cost)

    # Parse and validate images
    raw_images = []
    for i, img_uri in enumerate(req.images):
        b64, fmt, pil_img = decode_and_validate_image(
            img_uri, max_bytes=10 * 1024 * 1024,
            allowed_formats={"JPEG", "PNG"}, check_transparency=True,
        )
        # Re-encode to raw base64 (strip data URI prefix)
        raw = base64.b64decode(b64)
        raw_images.append(base64.b64encode(raw).decode("ascii"))

    variation_params = {
        "text": req.prompt,
        "images": raw_images,
        "similarityStrength": req.similarity_strength,
    }
    if req.negative_text:
        variation_params["negativeText"] = req.negative_text

    payload = {
        "taskType": "IMAGE_VARIATION",
        "imageVariationParams": variation_params,
        "imageGenerationConfig": {
            "numberOfImages": req.n,
            "width": req.width,
            "height": req.height,
            "quality": req.quality,
            "cfgScale": req.cfg_scale,
        },
    }
    if req.seed is not None:
        payload["imageGenerationConfig"]["seed"] = req.seed

    try:
        response = bedrock_us_east_1.invoke_model(
            modelId="amazon.nova-canvas-v1:0",
            body=json.dumps(payload),
            accept="application/json",
            contentType="application/json",
        )
    except ClientError as exc:
        error_ref = str(uuid.uuid4())[:8]
        error_msg = exc.response.get("Error", {}).get("Message", str(exc)) if hasattr(exc, "response") else str(exc)
        logger.error("Nova Canvas IMAGE_VARIATION failed [ref=%s]: %s", error_ref, error_msg)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error",
                      "message": f"The upstream service returned an error. Reference: {error_ref}"}
        })
    except Exception as exc:
        error_ref = str(uuid.uuid4())[:8]
        logger.error("Nova Canvas IMAGE_VARIATION unexpected error [ref=%s]: %s: %s", error_ref, type(exc).__name__, exc)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error",
                      "message": f"An unexpected error occurred. Reference: {error_ref}"}
        })

    result = json.loads(response["body"].read())
    if result.get("error"):
        error_ref = str(uuid.uuid4())[:8]
        logger.error("Nova Canvas IMAGE_VARIATION returned error [ref=%s]: %s", error_ref, result["error"])
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error",
                      "message": f"The upstream service returned an error. Reference: {error_ref}"}
        })
    images = result.get("images") or []

    request_id = str(uuid.uuid4())
    db.log_image_spend(auth["key_hash"], "nova-canvas-variation", cost, request_id)

    return _make_image_response(images, "nova-canvas", cost)


class BackgroundRemovalRequest(BaseModel):
    image: str


@router.post("/v1/images/background-removal")
def remove_background(req: BackgroundRemovalRequest, authorization: str = Header(...)):
    auth = authenticate_image_request(authorization)

    cost = 0.04  # Always 1 image, standard quality
    check_budget(auth, cost)

    b64, fmt, pil_img = decode_and_validate_image(
        req.image, max_bytes=10 * 1024 * 1024,
        allowed_formats={"JPEG", "PNG"}, check_transparency=True,
    )
    raw = base64.b64decode(b64)
    raw_b64 = base64.b64encode(raw).decode("ascii")

    payload = {
        "taskType": "BACKGROUND_REMOVAL",
        "backgroundRemovalParams": {"image": raw_b64},
    }

    try:
        response = bedrock_us_east_1.invoke_model(
            modelId="amazon.nova-canvas-v1:0",
            body=json.dumps(payload),
            accept="application/json",
            contentType="application/json",
        )
    except ClientError as exc:
        error_ref = str(uuid.uuid4())[:8]
        error_msg = exc.response.get("Error", {}).get("Message", str(exc)) if hasattr(exc, "response") else str(exc)
        logger.error("Nova Canvas BACKGROUND_REMOVAL failed [ref=%s]: %s", error_ref, error_msg)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error",
                      "message": f"The upstream service returned an error. Reference: {error_ref}"}
        })
    except Exception as exc:
        error_ref = str(uuid.uuid4())[:8]
        logger.error("Nova Canvas BACKGROUND_REMOVAL unexpected error [ref=%s]: %s: %s", error_ref, type(exc).__name__, exc)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error",
                      "message": f"An unexpected error occurred. Reference: {error_ref}"}
        })

    result = json.loads(response["body"].read())
    if result.get("error"):
        error_ref = str(uuid.uuid4())[:8]
        logger.error("Nova Canvas BACKGROUND_REMOVAL returned error [ref=%s]: %s", error_ref, result["error"])
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error",
                      "message": f"The upstream service returned an error. Reference: {error_ref}"}
        })
    images = result.get("images") or []

    request_id = str(uuid.uuid4())
    db.log_image_spend(auth["key_hash"], "nova-canvas-background-removal", cost, request_id)

    return _make_image_response(images, "nova-canvas", cost)


class OutpaintRequest(BaseModel):
    image: str
    prompt: str = Field(..., min_length=1, max_length=1024)
    mask_prompt: str | None = Field(default=None, max_length=1024)
    mask_image: str | None = None
    negative_text: str | None = Field(default=None, max_length=1024)
    outpainting_mode: str = Field(default="PRECISE")
    seed: int | None = Field(default=None, ge=0, le=2_147_483_646)
    cfg_scale: float = Field(default=7.0, ge=1.1, le=10.0)
    n: int = Field(default=1, ge=1, le=5)
    quality: str = Field(default="standard")


@router.post("/v1/images/outpaint")
def outpaint_image(req: OutpaintRequest, authorization: str = Header(...)):
    auth = authenticate_image_request(authorization)

    if req.quality not in ("standard", "premium"):
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error", "message": "quality must be 'standard' or 'premium'"}
        })
    if req.outpainting_mode not in ("DEFAULT", "PRECISE"):
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error", "message": "outpainting_mode must be 'DEFAULT' or 'PRECISE'"}
        })
    if req.mask_prompt and req.mask_image:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error", "message": "Provide mask_prompt or mask_image, not both"}
        })
    if not req.mask_prompt and not req.mask_image:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": "One of mask_prompt or mask_image is required for outpainting"}
        })

    cost = calculate_nova_canvas_cost(req.n, quality=req.quality)
    check_budget(auth, cost)

    b64, fmt, pil_img = decode_and_validate_image(
        req.image, max_bytes=10 * 1024 * 1024,
        allowed_formats={"JPEG", "PNG"}, check_transparency=False,
    )
    raw = base64.b64decode(b64)
    raw_b64 = base64.b64encode(raw).decode("ascii")

    outpainting_params = {
        "image": raw_b64,
        "text": req.prompt,
        "outPaintingMode": req.outpainting_mode,
    }
    if req.negative_text:
        outpainting_params["negativeText"] = req.negative_text
    if req.mask_prompt:
        outpainting_params["maskPrompt"] = req.mask_prompt
    elif req.mask_image:
        mask_b64_data, _, _ = decode_and_validate_image(
            req.mask_image, max_bytes=10 * 1024 * 1024,
            allowed_formats={"JPEG", "PNG"}, check_transparency=False,
        )
        mask_raw = base64.b64decode(mask_b64_data)
        outpainting_params["maskImage"] = base64.b64encode(mask_raw).decode("ascii")

    payload = {
        "taskType": "OUTPAINTING",
        "outPaintingParams": outpainting_params,
        "imageGenerationConfig": {
            "numberOfImages": req.n,
            "quality": req.quality,
            "cfgScale": req.cfg_scale,
        },
    }
    if req.seed is not None:
        payload["imageGenerationConfig"]["seed"] = req.seed

    try:
        response = bedrock_us_east_1.invoke_model(
            modelId="amazon.nova-canvas-v1:0",
            body=json.dumps(payload),
            accept="application/json",
            contentType="application/json",
        )
    except ClientError as exc:
        error_ref = str(uuid.uuid4())[:8]
        error_msg = exc.response.get("Error", {}).get("Message", str(exc)) if hasattr(exc, "response") else str(exc)
        logger.error("Nova Canvas OUTPAINTING failed [ref=%s]: %s", error_ref, error_msg)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error",
                      "message": f"The upstream service returned an error. Reference: {error_ref}"}
        })
    except Exception as exc:
        error_ref = str(uuid.uuid4())[:8]
        logger.error("Nova Canvas OUTPAINTING unexpected error [ref=%s]: %s: %s", error_ref, type(exc).__name__, exc)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error",
                      "message": f"An unexpected error occurred. Reference: {error_ref}"}
        })

    result = json.loads(response["body"].read())
    if result.get("error"):
        error_ref = str(uuid.uuid4())[:8]
        logger.error("Nova Canvas OUTPAINTING returned error [ref=%s]: %s", error_ref, result["error"])
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error",
                      "message": f"The upstream service returned an error. Reference: {error_ref}"}
        })
    images = result.get("images") or []

    request_id = str(uuid.uuid4())
    db.log_image_spend(auth["key_hash"], "nova-canvas-outpaint", cost, request_id)

    return _make_image_response(images, "nova-canvas", cost)
