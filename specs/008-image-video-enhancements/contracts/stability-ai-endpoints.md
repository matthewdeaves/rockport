# Contract: Stability AI Image Service Endpoints

Seven new synchronous endpoints on the sidecar (port 4001), routed via Cloudflare Tunnel. All use us-west-2 Bedrock client.

All endpoints authenticate via LiteLLM `/key/info`, enforce budgets, and log spend. Keys created with `--claude-only` receive HTTP 403.

## POST /v1/images/structure

Preserve structural skeleton/pose while changing visual style.

**Model ID**: `us.stability.stable-image-control-structure-v1:0`

**Request:**
```json
{
  "image": "data:image/png;base64,...",
  "prompt": "armoured knight in pixel art style",
  "control_strength": 0.7,
  "negative_prompt": "blurry, low quality",
  "seed": 0,
  "output_format": "png",
  "style_preset": "pixel-art"
}
```

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| `image` | data URI | Yes | — | PNG/JPEG/WebP, 64px min, 9.4MP max |
| `prompt` | string | Yes | — | 0-10,000 chars |
| `control_strength` | float | No | 0.7 | 0-1 |
| `negative_prompt` | string | No | — | 0-10,000 chars |
| `seed` | int | No | 0 | 0-4,294,967,294 |
| `output_format` | string | No | `png` | `jpeg`, `png`, `webp` |
| `style_preset` | string | No | — | See presets list below |

---

## POST /v1/images/sketch

Generate polished image from a rough sketch.

**Model ID**: `us.stability.stable-image-control-sketch-v1:0`

**Request:** Same schema as `/v1/images/structure`.

---

## POST /v1/images/style-transfer

Restyle a subject image using a style reference.

**Model ID**: `us.stability.stable-style-transfer-v1:0`

**Request:**
```json
{
  "init_image": "data:image/png;base64,...",
  "style_image": "data:image/png;base64,...",
  "prompt": "knight character",
  "negative_prompt": "",
  "seed": 0,
  "output_format": "png",
  "composition_fidelity": 0.9,
  "style_strength": 1.0,
  "change_strength": 0.9
}
```

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| `init_image` | data URI | Yes | — | Subject image. PNG/JPEG/WebP, 64px min, 9.4MP max |
| `style_image` | data URI | Yes | — | Style reference. Same constraints |
| `prompt` | string | No | — | 0-10,000 chars |
| `negative_prompt` | string | No | — | 0-10,000 chars |
| `seed` | int | No | 0 | 0-4,294,967,294 |
| `output_format` | string | No | `png` | `jpeg`, `png`, `webp` |
| `composition_fidelity` | float | No | 0.9 | 0-1 |
| `style_strength` | float | No | 1.0 | 0-1 |
| `change_strength` | float | No | 0.9 | 0.1-1 |

Note: No `style_preset` for this service. Uses `init_image`/`style_image` instead of `image`.

---

## POST /v1/images/remove-background

Strip background, return PNG with transparency.

**Model ID**: `us.stability.stable-image-remove-background-v1:0`

**Request:**
```json
{
  "image": "data:image/png;base64,...",
  "output_format": "png"
}
```

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| `image` | data URI | Yes | — | PNG/JPEG/WebP, 64px min, 9.4MP max |
| `output_format` | string | No | `png` | `jpeg`, `png`, `webp` |

---

## POST /v1/images/search-replace

Find and replace elements in an image.

**Model ID**: `us.stability.stable-image-search-replace-v1:0`

**Request:**
```json
{
  "image": "data:image/png;base64,...",
  "prompt": "jacket",
  "search_prompt": "sweater",
  "negative_prompt": "",
  "seed": 0,
  "output_format": "png",
  "grow_mask": 5,
  "style_preset": "photographic"
}
```

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| `image` | data URI | Yes | — | PNG/JPEG/WebP, 64px min, 9.4MP max |
| `prompt` | string | Yes | — | Replacement content. 0-10,000 chars |
| `search_prompt` | string | Yes | — | What to find. 0-10,000 chars |
| `negative_prompt` | string | No | — | 0-10,000 chars |
| `seed` | int | No | 0 | 0-4,294,967,294 |
| `output_format` | string | No | `png` | `jpeg`, `png`, `webp` |
| `grow_mask` | int | No | 5 | 0-20 |
| `style_preset` | string | No | — | See presets list below |

---

## POST /v1/images/upscale

Conservative upscale preserving detail (up to 4K).

**Model ID**: `us.stability.stable-conservative-upscale-v1:0`

**Request:**
```json
{
  "image": "data:image/png;base64,...",
  "prompt": "high quality character art",
  "creativity": 0.35,
  "negative_prompt": "",
  "seed": 0,
  "output_format": "png"
}
```

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| `image` | data URI | Yes | — | 64x64 to 1MP input, PNG/JPEG/WebP |
| `prompt` | string | Yes | — | 0-10,000 chars |
| `creativity` | float | No | 0.35 | 0.1-0.5 |
| `negative_prompt` | string | No | — | 0-10,000 chars |
| `seed` | int | No | 0 | 0-4,294,967,294 |
| `output_format` | string | No | `png` | `jpeg`, `png`, `webp` |

Note: No `style_preset` for this service. Output is 20-40x larger than input (up to 4K).

---

## POST /v1/images/style-guide

Generate new images matching a style reference.

**Model ID**: `us.stability.stable-image-style-guide-v1:0`

**Request:**
```json
{
  "image": "data:image/png;base64,...",
  "prompt": "knight character standing in a courtyard",
  "aspect_ratio": "16:9",
  "fidelity": 0.5,
  "negative_prompt": "",
  "seed": 0,
  "output_format": "png",
  "style_preset": "digital-art"
}
```

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| `image` | data URI | Yes | — | Style reference. PNG/JPEG/WebP, 64px min, 9.4MP max |
| `prompt` | string | Yes | — | 0-10,000 chars |
| `aspect_ratio` | string | No | `1:1` | `16:9`, `1:1`, `21:9`, `2:3`, `3:2`, `4:5`, `5:4`, `9:16`, `9:21` |
| `fidelity` | float | No | 0.5 | 0-1 |
| `negative_prompt` | string | No | — | 0-10,000 chars |
| `seed` | int | No | 0 | 0-4,294,967,294 |
| `output_format` | string | No | `png` | `jpeg`, `png`, `webp` |
| `style_preset` | string | No | — | See presets list below |

---

## Common Response Format (all endpoints)

**Success (HTTP 200):**
```json
{
  "images": [
    {"b64_json": "<base64-encoded-image>"}
  ],
  "model": "stability-structure",
  "cost": 0.04
}
```

**Error responses:** Same as Nova Canvas endpoints (400, 401, 402, 403, 502).

## Style Presets

Available for: Structure, Sketch, Search and Replace, Style Guide.
NOT available for: Remove Background, Conservative Upscale, Style Transfer.

`3d-model`, `analog-film`, `anime`, `cinematic`, `comic-book`, `digital-art`, `enhance`, `fantasy-art`, `isometric`, `line-art`, `low-poly`, `modeling-compound`, `neon-punk`, `origami`, `photographic`, `pixel-art`, `tile-texture`

## Data URI Handling

All endpoints accept images as data URIs (`data:image/png;base64,...`) for consistency with the video sidecar. The sidecar strips the prefix and passes raw base64 to Bedrock. Stability AI services also accept WebP (`data:image/webp;base64,...`).
