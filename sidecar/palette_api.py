"""Rockport palette-guided image generation.

Bedrock no longer has an image model that accepts a hex colour palette directly
(Nova Canvas COLOR_GUIDED_GENERATION retired 2026-09-30). The closest surviving
mechanism is Stability's Style Guide model, which generates an image matching the
style of a reference image — the Midjourney `--sref` equivalent.

This endpoint bridges the gap: it renders the caller's hex palette into a swatch
PNG, optionally augments the prompt with the nearest CSS colour names, and
forwards the whole thing to LiteLLM's `/v1/images/edits` as a `stability-style-guide`
request using the caller's own API key. LiteLLM therefore still does auth, budget
enforcement, --claude-only restriction and spend logging; the sidecar never talks
to Bedrock for this path.

Cost-first defaults: one image, fidelity 0.5, 1:1 aspect ratio.
"""

import base64
import io
import logging
import math
import os
import re
import uuid

import httpx
from fastapi import APIRouter, Header, HTTPException
from PIL import Image, ImageColor, ImageDraw
from pydantic import BaseModel, Field

logger = logging.getLogger("rockport-palette")

router = APIRouter()

LITELLM_URL = os.environ.get("LITELLM_URL", "http://127.0.0.1:4000")

STYLE_GUIDE_MODEL = "stability-style-guide"
SWATCH_SIZE = 1024
MAX_COLORS = 8
ASPECT_RATIOS = ("1:1", "16:9", "21:9", "2:3", "3:2", "4:5", "5:4", "9:16", "9:21")
LAYOUTS = ("stripes", "blocks")
HEX_RE = re.compile(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")

# CSS named colours, used to describe the palette in words so the prompt itself
# also pushes the model towards the requested colours (style-guide alone can be loose).
_CSS_COLORS = {name: ImageColor.getrgb(name) for name in ImageColor.colormap}


class PaletteRequest(BaseModel):
    prompt: str = Field(..., min_length=1, max_length=10_000)
    colors: list[str] = Field(..., min_length=1, max_length=MAX_COLORS)
    weights: list[float] | None = None
    fidelity: float = Field(default=0.5, ge=0.0, le=1.0)
    negative_prompt: str | None = Field(default=None, max_length=10_000)
    aspect_ratio: str = "1:1"
    seed: int | None = Field(default=None, ge=0, le=4_294_967_295)
    layout: str = "stripes"
    augment_prompt: bool = True


def _validation_error(message: str) -> HTTPException:
    return HTTPException(status_code=400, detail={
        "error": {"type": "validation_error", "message": message}
    })


def normalise_hex(color: str) -> str:
    """Validate a #RGB / #RRGGBB string and return lowercase #rrggbb."""
    if not HEX_RE.match(color):
        raise _validation_error(f"Invalid colour '{color}'. Use #RGB or #RRGGBB hex.")
    if len(color) == 4:
        color = "#" + "".join(ch * 2 for ch in color[1:])
    return color.lower()


def nearest_css_name(rgb: tuple[int, int, int]) -> str:
    """Nearest CSS colour name by Euclidean RGB distance."""
    r, g, b = rgb
    best_name, best_dist = "gray", math.inf
    for name, (cr, cg, cb) in _CSS_COLORS.items():
        d = (r - cr) ** 2 + (g - cg) ** 2 + (b - cb) ** 2
        if d < best_dist:
            best_name, best_dist = name, d
    return best_name


def render_swatch(colors: list[str], weights: list[float], layout: str) -> bytes:
    """Render the palette to a SWATCH_SIZE² PNG. Stripes are proportional to weight;
    blocks lay colours on a near-square grid (equal cells, weight ignored)."""
    img = Image.new("RGB", (SWATCH_SIZE, SWATCH_SIZE))
    draw = ImageDraw.Draw(img)
    rgbs = [ImageColor.getrgb(c) for c in colors]

    if layout == "blocks":
        cols = math.ceil(math.sqrt(len(rgbs)))
        rows = math.ceil(len(rgbs) / cols)
        cell_w, cell_h = SWATCH_SIZE / cols, SWATCH_SIZE / rows
        for idx in range(rows * cols):
            rgb = rgbs[idx] if idx < len(rgbs) else rgbs[-1]
            r, c = divmod(idx, cols)
            draw.rectangle([round(c * cell_w), round(r * cell_h),
                            round((c + 1) * cell_w) - 1, round((r + 1) * cell_h) - 1], fill=rgb)
    else:
        total = sum(weights)
        start, acc = 0, 0.0
        for i, (rgb, w) in enumerate(zip(rgbs, weights)):
            acc += w
            end = SWATCH_SIZE if i == len(rgbs) - 1 else round(SWATCH_SIZE * acc / total)
            draw.rectangle([start, 0, end - 1, SWATCH_SIZE - 1], fill=rgb)
            start = end

    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


@router.post("/v1/images/palette")
def palette_generation(req: PaletteRequest, authorization: str = Header(None)):
    """Generate an image that sticks to a hex colour palette (via Stability Style Guide)."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail={
            "error": {"type": "authentication_error", "message": "Invalid Authorization header"}
        })

    colors = [normalise_hex(c) for c in req.colors]
    if req.weights is not None:
        if len(req.weights) != len(colors):
            raise _validation_error("weights must have one entry per colour.")
        if any(not math.isfinite(w) or w <= 0 for w in req.weights):
            raise _validation_error("weights must all be positive finite numbers.")
        weights = req.weights
    else:
        weights = [1.0] * len(colors)
    if req.aspect_ratio not in ASPECT_RATIOS:
        raise _validation_error(f"aspect_ratio must be one of {list(ASPECT_RATIOS)} (got {req.aspect_ratio}).")
    if req.layout not in LAYOUTS:
        raise _validation_error(f"layout must be one of {list(LAYOUTS)} (got {req.layout}).")

    names = [nearest_css_name(ImageColor.getrgb(c)) for c in colors]
    prompt = req.prompt
    if req.augment_prompt:
        # Dedupe while preserving order so "#111111, #121212" doesn't say "black, black"
        unique_names = list(dict.fromkeys(names))
        prompt = f"{req.prompt}. Colour palette limited to: {', '.join(unique_names)}."

    swatch = render_swatch(colors, weights, req.layout)

    # Forward to LiteLLM /v1/images/edits with the caller's key so LiteLLM enforces
    # auth, budgets, model restrictions and logs spend exactly as for a direct call.
    form: dict[str, str] = {
        "model": STYLE_GUIDE_MODEL,
        "prompt": prompt,
        "fidelity": str(req.fidelity),
        "aspect_ratio": req.aspect_ratio,
    }
    if req.negative_prompt:
        form["negative_prompt"] = req.negative_prompt
    if req.seed is not None:
        form["seed"] = str(req.seed)

    try:
        resp = httpx.post(
            f"{LITELLM_URL}/v1/images/edits",
            headers={"Authorization": authorization},
            data=form,
            files={"image": ("palette.png", swatch, "image/png")},
            timeout=120,
        )
    except httpx.RequestError as exc:
        error_ref = str(uuid.uuid4())[:8]
        logger.error("LiteLLM unreachable for palette request [ref=%s]: %s: %s", error_ref, type(exc).__name__, exc)
        raise HTTPException(status_code=502, detail={
            "error": {"type": "upstream_error",
                      "message": f"Image service unreachable. Reference: {error_ref}"}
        })

    try:
        body = resp.json()
    except ValueError:
        body = {"error": {"type": "upstream_error", "message": resp.text[:500]}}

    if resp.status_code != 200:
        # LiteLLM's own error shapes are already client-safe (auth, budget, model access,
        # Stability validation). Pass status + body through unchanged.
        raise HTTPException(status_code=resp.status_code, detail=body.get("detail", body),
                            headers={"Retry-After": "5"} if resp.status_code == 429 else None)

    body["palette"] = {
        "model": STYLE_GUIDE_MODEL,
        "colors": colors,
        "weights": weights,
        "color_names": names,
        "layout": req.layout,
        "fidelity": req.fidelity,
        "prompt": prompt,
        "swatch_b64": base64.b64encode(swatch).decode("ascii"),
    }
    return body
