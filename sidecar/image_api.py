"""Rockport Image Service Endpoints.

Synchronous endpoints for Nova Canvas advanced operations (IMAGE_VARIATION,
BACKGROUND_REMOVAL, OUTPAINTING) and Stability AI Image Services (Structure,
Sketch, Style Transfer, Remove Background, Search and Replace, Upscale,
Style Guide).

All endpoints authenticate via LiteLLM /key/info, enforce budgets, block
--claude-only keys, and log spend to LiteLLM's unified tracking tables.
"""

import base64
import io
import json
import logging
import uuid

import boto3
from botocore.exceptions import ClientError
from fastapi import APIRouter, Header, HTTPException
from PIL import Image
from pydantic import BaseModel, Field

import db

logger = logging.getLogger("rockport-image")

router = APIRouter()

# Boto3 clients — initialized by video_api.py lifespan, shared via module-level reference
bedrock_us_east_1 = None
bedrock_us_west_2 = None


def init_clients():
    """Initialize Bedrock clients for image endpoints. Called from video_api.py lifespan."""
    global bedrock_us_east_1, bedrock_us_west_2
    bedrock_us_east_1 = boto3.client("bedrock-runtime", region_name="us-east-1")
    bedrock_us_west_2 = boto3.client("bedrock-runtime", region_name="us-west-2")


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


def parse_data_uri(data_uri: str, max_bytes: int = 10 * 1024 * 1024) -> tuple[str, str]:
    """Parse a data URI into (raw_base64, media_type).

    Returns raw base64 string (no prefix) suitable for Bedrock API calls.
    """
    if not data_uri.startswith("data:image/"):
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error", "message": "Must be a data:image/ URI"}
        })
    header, b64data = data_uri.split(",", 1)
    # Extract media type from header (e.g., "data:image/png;base64" -> "image/png")
    media_type = header.split(";")[0].replace("data:", "")

    raw = base64.b64decode(b64data)
    if len(raw) > max_bytes:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"Image exceeds {max_bytes // (1024*1024)}MB limit"}
        })
    return b64data, media_type


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


# Stability AI estimated costs per service (to be confirmed on first deploy)
STABILITY_COSTS = {
    "stability-structure": 0.04,
    "stability-sketch": 0.04,
    "stability-style-transfer": 0.06,
    "stability-remove-background": 0.04,
    "stability-search-replace": 0.04,
    "stability-upscale": 0.06,
    "stability-style-guide": 0.04,
}


def calculate_stability_cost(model_name: str) -> float:
    """Get the estimated per-image cost for a Stability AI service."""
    return STABILITY_COSTS.get(model_name, 0.04)


def invoke_stability_model(client, model_id: str, payload: dict) -> list[str]:
    """Invoke a Stability AI model and return the list of base64 images.

    Handles the common response format (seeds, finish_reasons, images).
    Raises HTTPException on errors.
    """
    try:
        response = client.invoke_model(
            modelId=model_id,
            body=json.dumps(payload),
            accept="application/json",
            contentType="application/json",
        )
    except ClientError as exc:
        error_msg = exc.response.get("Error", {}).get("Message", str(exc)) if hasattr(exc, "response") else str(exc)
        logger.error("Stability AI invoke failed for %s: %s", model_id, error_msg)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error", "message": f"Image service request failed: {error_msg}"}
        })
    except Exception as exc:
        logger.error("Stability AI unexpected error for %s: %s: %s", model_id, type(exc).__name__, exc)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error", "message": f"Image service request failed: {type(exc).__name__}"}
        })

    result = json.loads(response["body"].read())

    # Check for error in response body
    if result.get("error"):
        logger.error("Stability AI %s returned error: %s", model_id, result["error"])
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error", "message": f"Image service error: {result['error']}"}
        })

    # Check finish_reasons for errors
    finish_reasons = result.get("finish_reasons", [])
    for reason in finish_reasons:
        if reason and reason.startswith("Filter reason:"):
            raise HTTPException(status_code=400, detail={
                "error": {"type": "content_filter", "message": f"Request blocked by content filter: {reason}"}
            })
        if reason == "Inference error":
            raise HTTPException(status_code=502, detail={
                "error": {"type": "upstream_error", "message": "Stability AI inference error"}
            })

    return result.get("images") or []


def _make_image_response(images: list[str], model: str, cost: float) -> dict:
    """Build a standard image endpoint response."""
    return {
        "images": [{"b64_json": img} for img in images],
        "model": model,
        "cost": cost,
    }


# Valid style presets for Stability AI services that support them
STABILITY_STYLE_PRESETS = {
    "3d-model", "analog-film", "anime", "cinematic", "comic-book",
    "digital-art", "enhance", "fantasy-art", "isometric", "line-art",
    "low-poly", "modeling-compound", "neon-punk", "origami",
    "photographic", "pixel-art", "tile-texture",
}

STABILITY_ASPECT_RATIOS = {
    "16:9", "1:1", "21:9", "2:3", "3:2", "4:5", "5:4", "9:16", "9:21",
}

# Max total pixels for Stability AI (approx 3072x3072)
STABILITY_MAX_PIXELS = 9_437_184


# --- Nova Canvas Endpoints ---

class ImageVariationRequest(BaseModel):
    images: list[str] = Field(..., min_length=1, max_length=5)
    prompt: str = Field(..., min_length=1, max_length=1024)
    similarity_strength: float = Field(default=0.7, ge=0.2, le=1.0)
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

    payload = {
        "taskType": "IMAGE_VARIATION",
        "imageVariationParams": {
            "text": req.prompt,
            "images": raw_images,
            "similarityStrength": req.similarity_strength,
        },
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
        error_msg = exc.response.get("Error", {}).get("Message", str(exc)) if hasattr(exc, "response") else str(exc)
        logger.error("Nova Canvas IMAGE_VARIATION failed: %s", error_msg)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error", "message": f"Image variation request failed: {error_msg}"}
        })
    except Exception as exc:
        logger.error("Nova Canvas IMAGE_VARIATION unexpected error: %s: %s", type(exc).__name__, exc)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error", "message": f"Image variation request failed: {type(exc).__name__}"}
        })

    result = json.loads(response["body"].read())
    if result.get("error"):
        logger.error("Nova Canvas IMAGE_VARIATION returned error: %s", result["error"])
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error", "message": f"Image variation request failed: {result['error']}"}
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
        error_msg = exc.response.get("Error", {}).get("Message", str(exc)) if hasattr(exc, "response") else str(exc)
        logger.error("Nova Canvas BACKGROUND_REMOVAL failed: %s", error_msg)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error", "message": f"Background removal failed: {error_msg}"}
        })
    except Exception as exc:
        logger.error("Nova Canvas BACKGROUND_REMOVAL unexpected error: %s: %s", type(exc).__name__, exc)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error", "message": f"Background removal failed: {type(exc).__name__}"}
        })

    result = json.loads(response["body"].read())
    if result.get("error"):
        logger.error("Nova Canvas BACKGROUND_REMOVAL returned error: %s", result["error"])
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error", "message": f"Background removal failed: {result['error']}"}
        })
    images = result.get("images") or []

    request_id = str(uuid.uuid4())
    db.log_image_spend(auth["key_hash"], "nova-canvas-background-removal", cost, request_id)

    return _make_image_response(images, "nova-canvas", cost)


class OutpaintRequest(BaseModel):
    image: str
    prompt: str = Field(..., min_length=1, max_length=1024)
    mask_prompt: str | None = None
    mask_image: str | None = None
    outpainting_mode: str = Field(default="PRECISE")
    seed: int | None = Field(default=None, ge=0, le=2_147_483_646)
    cfg_scale: float = Field(default=7.0, ge=1.1, le=10.0)
    n: int = Field(default=1, ge=1, le=5)
    quality: str = Field(default="standard")


@router.post("/v1/images/outpaint")
def outpaint_image(req: OutpaintRequest, authorization: str = Header(...)):
    auth = authenticate_image_request(authorization)

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
        error_msg = exc.response.get("Error", {}).get("Message", str(exc)) if hasattr(exc, "response") else str(exc)
        logger.error("Nova Canvas OUTPAINTING failed: %s", error_msg)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error", "message": f"Outpainting request failed: {error_msg}"}
        })
    except Exception as exc:
        logger.error("Nova Canvas OUTPAINTING unexpected error: %s: %s", type(exc).__name__, exc)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error", "message": f"Outpainting request failed: {type(exc).__name__}"}
        })

    result = json.loads(response["body"].read())
    if result.get("error"):
        logger.error("Nova Canvas OUTPAINTING returned error: %s", result["error"])
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error", "message": f"Outpainting request failed: {result['error']}"}
        })
    images = result.get("images") or []

    request_id = str(uuid.uuid4())
    db.log_image_spend(auth["key_hash"], "nova-canvas-outpaint", cost, request_id)

    return _make_image_response(images, "nova-canvas", cost)


# --- Stability AI Endpoints ---

def _validate_stability_image(data_uri: str, max_bytes: int = 25 * 1024 * 1024) -> str:
    """Validate and extract raw base64 for a Stability AI image.

    Accepts PNG, JPEG, WebP. Min 64px, max 9.4MP.
    Returns raw base64 string.
    """
    b64, fmt, img = decode_and_validate_image(
        data_uri, max_bytes=max_bytes,
        allowed_formats={"JPEG", "PNG", "WEBP"},
        min_size=(64, 64),
        max_pixels=STABILITY_MAX_PIXELS,
        check_transparency=False,
    )
    raw = base64.b64decode(b64)
    return base64.b64encode(raw).decode("ascii")


STABILITY_OUTPUT_FORMATS = {"png", "jpeg", "webp"}


def _validate_output_format(output_format: str):
    """Validate Stability AI output_format parameter."""
    if output_format not in STABILITY_OUTPUT_FORMATS:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"output_format must be one of: {', '.join(sorted(STABILITY_OUTPUT_FORMATS))} (got '{output_format}')"}
        })


def _build_stability_payload(
    image_b64: str,
    prompt: str | None = None,
    negative_prompt: str | None = None,
    seed: int | None = None,
    output_format: str = "png",
    style_preset: str | None = None,
    **extra_params,
) -> dict:
    """Build a common Stability AI request payload."""
    _validate_output_format(output_format)
    payload = {"image": image_b64}
    if prompt is not None:
        payload["prompt"] = prompt
    if negative_prompt:
        payload["negative_prompt"] = negative_prompt
    if seed is not None:
        payload["seed"] = seed
    if output_format:
        payload["output_format"] = output_format
    if style_preset:
        if style_preset not in STABILITY_STYLE_PRESETS:
            raise HTTPException(status_code=400, detail={
                "error": {"type": "validation_error",
                          "message": f"Invalid style_preset. Must be one of: {', '.join(sorted(STABILITY_STYLE_PRESETS))}"}
            })
        payload["style_preset"] = style_preset
    payload.update(extra_params)
    return payload


class StructureRequest(BaseModel):
    image: str
    prompt: str = Field(..., min_length=0, max_length=10000)
    control_strength: float = Field(default=0.7, ge=0.0, le=1.0)
    negative_prompt: str | None = Field(default=None, max_length=10000)
    seed: int | None = Field(default=None, ge=0, le=4_294_967_294)
    output_format: str = Field(default="png")
    style_preset: str | None = None


@router.post("/v1/images/structure")
def structure_control(req: StructureRequest, authorization: str = Header(...)):
    auth = authenticate_image_request(authorization)
    model_name = "stability-structure"
    cost = calculate_stability_cost(model_name)
    check_budget(auth, cost)

    image_b64 = _validate_stability_image(req.image)
    payload = _build_stability_payload(
        image_b64, req.prompt, req.negative_prompt, req.seed,
        req.output_format, req.style_preset,
        control_strength=req.control_strength,
    )

    images = invoke_stability_model(
        bedrock_us_west_2, "us.stability.stable-image-control-structure-v1:0", payload,
    )

    request_id = str(uuid.uuid4())
    db.log_image_spend(auth["key_hash"], model_name, cost, request_id)
    return _make_image_response(images, model_name, cost)


class SketchRequest(BaseModel):
    image: str
    prompt: str = Field(..., min_length=0, max_length=10000)
    control_strength: float = Field(default=0.7, ge=0.0, le=1.0)
    negative_prompt: str | None = Field(default=None, max_length=10000)
    seed: int | None = Field(default=None, ge=0, le=4_294_967_294)
    output_format: str = Field(default="png")
    style_preset: str | None = None


@router.post("/v1/images/sketch")
def sketch_to_image(req: SketchRequest, authorization: str = Header(...)):
    auth = authenticate_image_request(authorization)
    model_name = "stability-sketch"
    cost = calculate_stability_cost(model_name)
    check_budget(auth, cost)

    image_b64 = _validate_stability_image(req.image)
    payload = _build_stability_payload(
        image_b64, req.prompt, req.negative_prompt, req.seed,
        req.output_format, req.style_preset,
        control_strength=req.control_strength,
    )

    images = invoke_stability_model(
        bedrock_us_west_2, "us.stability.stable-image-control-sketch-v1:0", payload,
    )

    request_id = str(uuid.uuid4())
    db.log_image_spend(auth["key_hash"], model_name, cost, request_id)
    return _make_image_response(images, model_name, cost)


class StyleTransferRequest(BaseModel):
    init_image: str
    style_image: str
    prompt: str | None = Field(default=None, max_length=10000)
    negative_prompt: str | None = Field(default=None, max_length=10000)
    seed: int | None = Field(default=None, ge=0, le=4_294_967_294)
    output_format: str = Field(default="png")
    composition_fidelity: float = Field(default=0.9, ge=0.0, le=1.0)
    style_strength: float = Field(default=1.0, ge=0.0, le=1.0)
    change_strength: float = Field(default=0.9, ge=0.1, le=1.0)


@router.post("/v1/images/style-transfer")
def style_transfer(req: StyleTransferRequest, authorization: str = Header(...)):
    auth = authenticate_image_request(authorization)
    model_name = "stability-style-transfer"
    cost = calculate_stability_cost(model_name)
    check_budget(auth, cost)

    _validate_output_format(req.output_format)
    init_b64 = _validate_stability_image(req.init_image)
    style_b64 = _validate_stability_image(req.style_image)

    payload = {
        "init_image": init_b64,
        "style_image": style_b64,
        "output_format": req.output_format,
        "composition_fidelity": req.composition_fidelity,
        "style_strength": req.style_strength,
        "change_strength": req.change_strength,
    }
    if req.prompt:
        payload["prompt"] = req.prompt
    if req.negative_prompt:
        payload["negative_prompt"] = req.negative_prompt
    if req.seed is not None:
        payload["seed"] = req.seed

    images = invoke_stability_model(
        bedrock_us_west_2, "us.stability.stable-style-transfer-v1:0", payload,
    )

    request_id = str(uuid.uuid4())
    db.log_image_spend(auth["key_hash"], model_name, cost, request_id)
    return _make_image_response(images, model_name, cost)


class StabilityRemoveBackgroundRequest(BaseModel):
    image: str
    output_format: str = Field(default="png")


@router.post("/v1/images/remove-background")
def stability_remove_background(req: StabilityRemoveBackgroundRequest, authorization: str = Header(...)):
    auth = authenticate_image_request(authorization)
    model_name = "stability-remove-background"
    cost = calculate_stability_cost(model_name)
    check_budget(auth, cost)

    _validate_output_format(req.output_format)
    image_b64 = _validate_stability_image(req.image)
    payload = {"image": image_b64, "output_format": req.output_format}

    images = invoke_stability_model(
        bedrock_us_west_2, "us.stability.stable-image-remove-background-v1:0", payload,
    )

    request_id = str(uuid.uuid4())
    db.log_image_spend(auth["key_hash"], model_name, cost, request_id)
    return _make_image_response(images, model_name, cost)


class SearchReplaceRequest(BaseModel):
    image: str
    prompt: str = Field(..., min_length=1, max_length=10000)
    search_prompt: str = Field(..., min_length=1, max_length=10000)
    negative_prompt: str | None = Field(default=None, max_length=10000)
    seed: int | None = Field(default=None, ge=0, le=4_294_967_294)
    output_format: str = Field(default="png")
    grow_mask: int = Field(default=5, ge=0, le=20)
    style_preset: str | None = None


@router.post("/v1/images/search-replace")
def search_and_replace(req: SearchReplaceRequest, authorization: str = Header(...)):
    auth = authenticate_image_request(authorization)
    model_name = "stability-search-replace"
    cost = calculate_stability_cost(model_name)
    check_budget(auth, cost)

    image_b64 = _validate_stability_image(req.image)
    payload = _build_stability_payload(
        image_b64, req.prompt, req.negative_prompt, req.seed,
        req.output_format, req.style_preset,
        search_prompt=req.search_prompt,
        grow_mask=req.grow_mask,
    )

    images = invoke_stability_model(
        bedrock_us_west_2, "us.stability.stable-image-search-replace-v1:0", payload,
    )

    request_id = str(uuid.uuid4())
    db.log_image_spend(auth["key_hash"], model_name, cost, request_id)
    return _make_image_response(images, model_name, cost)


class UpscaleRequest(BaseModel):
    image: str
    prompt: str = Field(..., min_length=0, max_length=10000)
    creativity: float = Field(default=0.35, ge=0.1, le=0.5)
    negative_prompt: str | None = Field(default=None, max_length=10000)
    seed: int | None = Field(default=None, ge=0, le=4_294_967_294)
    output_format: str = Field(default="png")


@router.post("/v1/images/upscale")
def conservative_upscale(req: UpscaleRequest, authorization: str = Header(...)):
    auth = authenticate_image_request(authorization)
    model_name = "stability-upscale"
    cost = calculate_stability_cost(model_name)
    check_budget(auth, cost)

    _validate_output_format(req.output_format)
    # Upscale has stricter input limits: max 1MP
    b64, fmt, img = decode_and_validate_image(
        req.image, max_bytes=25 * 1024 * 1024,
        allowed_formats={"JPEG", "PNG", "WEBP"},
        min_size=(64, 64),
        max_pixels=1_000_000,
        check_transparency=False,
    )
    raw = base64.b64decode(b64)
    image_b64 = base64.b64encode(raw).decode("ascii")

    payload = {
        "image": image_b64,
        "prompt": req.prompt,
        "creativity": req.creativity,
        "output_format": req.output_format,
    }
    if req.negative_prompt:
        payload["negative_prompt"] = req.negative_prompt
    if req.seed is not None:
        payload["seed"] = req.seed

    images = invoke_stability_model(
        bedrock_us_west_2, "us.stability.stable-conservative-upscale-v1:0", payload,
    )

    request_id = str(uuid.uuid4())
    db.log_image_spend(auth["key_hash"], model_name, cost, request_id)
    return _make_image_response(images, model_name, cost)


class StyleGuideRequest(BaseModel):
    image: str
    prompt: str = Field(..., min_length=1, max_length=10000)
    aspect_ratio: str = Field(default="1:1")
    fidelity: float = Field(default=0.5, ge=0.0, le=1.0)
    negative_prompt: str | None = Field(default=None, max_length=10000)
    seed: int | None = Field(default=None, ge=0, le=4_294_967_294)
    output_format: str = Field(default="png")
    style_preset: str | None = None


@router.post("/v1/images/style-guide")
def style_guide(req: StyleGuideRequest, authorization: str = Header(...)):
    auth = authenticate_image_request(authorization)
    model_name = "stability-style-guide"
    cost = calculate_stability_cost(model_name)
    check_budget(auth, cost)

    if req.aspect_ratio not in STABILITY_ASPECT_RATIOS:
        raise HTTPException(status_code=400, detail={
            "error": {"type": "validation_error",
                      "message": f"aspect_ratio must be one of: {', '.join(sorted(STABILITY_ASPECT_RATIOS))}"}
        })

    image_b64 = _validate_stability_image(req.image)
    payload = _build_stability_payload(
        image_b64, req.prompt, req.negative_prompt, req.seed,
        req.output_format, req.style_preset,
        aspect_ratio=req.aspect_ratio,
        fidelity=req.fidelity,
    )

    images = invoke_stability_model(
        bedrock_us_west_2, "us.stability.stable-image-style-guide-v1:0", payload,
    )

    request_id = str(uuid.uuid4())
    db.log_image_spend(auth["key_hash"], model_name, cost, request_id)
    return _make_image_response(images, model_name, cost)
