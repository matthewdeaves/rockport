# Contract: Nova Canvas Advanced Endpoints

Three new synchronous endpoints on the sidecar (port 4001), routed via Cloudflare Tunnel.

All endpoints authenticate via LiteLLM `/key/info`, enforce budgets, and log spend. Keys created with `--claude-only` receive HTTP 403.

## POST /v1/images/variations

Generate image variations from a reference image with controllable similarity.

**Request:**
```json
{
  "images": ["data:image/png;base64,..."],
  "prompt": "armoured knight, side profile, mid-stride walking pose",
  "similarity_strength": 0.7,
  "seed": 57,
  "cfg_scale": 6.5,
  "n": 1,
  "width": 1280,
  "height": 720,
  "quality": "standard"
}
```

| Field | Type | Required | Constraints |
|-------|------|----------|-------------|
| `images` | array of data URIs | Yes | 1-5 images, PNG/JPEG, no transparency, max 10MB each |
| `prompt` | string | Yes | 1-1024 characters |
| `similarity_strength` | float | No | 0.2-1.0, default 0.7 |
| `seed` | int | No | 0-2,147,483,646 |
| `cfg_scale` | float | No | 1.1-10.0, default 6.5 |
| `n` | int | No | 1-5, default 1 |
| `width` | int | No | 320-4096, divisible by 16 |
| `height` | int | No | 320-4096, divisible by 16 |
| `quality` | string | No | `standard` (default), `premium` |

Note: `images` uses data URI format (consistent with video sidecar) but Bedrock receives raw base64. The sidecar strips the data URI prefix.

**Response (HTTP 200):**
```json
{
  "images": [
    {"b64_json": "<base64-encoded-png>"},
    {"b64_json": "<base64-encoded-png>"}
  ],
  "model": "nova-canvas",
  "cost": 0.08
}
```

## POST /v1/images/background-removal

Remove background from an image, returning PNG with transparency.

**Request:**
```json
{
  "image": "data:image/png;base64,..."
}
```

| Field | Type | Required | Constraints |
|-------|------|----------|-------------|
| `image` | data URI | Yes | PNG/JPEG, no transparency, max 10MB |

**Response (HTTP 200):**
```json
{
  "images": [
    {"b64_json": "<base64-encoded-png-with-alpha>"}
  ],
  "model": "nova-canvas",
  "cost": 0.04
}
```

## POST /v1/images/outpaint

Extend an image by filling masked regions with generated content.

**Request:**
```json
{
  "image": "data:image/png;base64,...",
  "prompt": "castle courtyard with stone walls extending to the sides",
  "mask_prompt": "the knight character",
  "outpainting_mode": "PRECISE",
  "seed": 57,
  "cfg_scale": 7.0,
  "n": 1,
  "quality": "standard"
}
```

| Field | Type | Required | Constraints |
|-------|------|----------|-------------|
| `image` | data URI | Yes | PNG/JPEG, max 10MB |
| `prompt` | string | Yes | 1-1024 characters |
| `mask_prompt` | string | One of mask_prompt or mask_image required | Natural language describing region to preserve |
| `mask_image` | data URI | One of mask_prompt or mask_image required | Same dimensions as input; black=keep, white=edit |
| `outpainting_mode` | string | No | `DEFAULT`, `PRECISE` (default) |
| `seed` | int | No | 0-2,147,483,646 |
| `cfg_scale` | float | No | 1.1-10.0, default 7.0 |
| `n` | int | No | 1-5, default 1 |
| `quality` | string | No | `standard` (default), `premium` |

Note: Output dimensions match input dimensions. No width/height parameters — Bedrock does not accept them for outpainting.

**Response (HTTP 200):**
```json
{
  "images": [
    {"b64_json": "<base64-encoded-png>"}
  ],
  "model": "nova-canvas",
  "cost": 0.04
}
```

## Common Error Responses

| Status | Condition | Body |
|--------|-----------|------|
| 400 | Invalid parameters | `{"error": {"type": "validation_error", "message": "..."}}` |
| 401 | Invalid/revoked API key | `{"error": {"type": "auth_error", "message": "..."}}` |
| 402 | Budget exceeded | `{"error": {"type": "budget_exceeded", "message": "Estimated cost $X.XX exceeds remaining budget $Y.YY"}}` |
| 403 | Claude-only key | `{"error": {"type": "forbidden", "message": "This endpoint requires an unrestricted API key. Keys created with --claude-only cannot access image generation services."}}` |
| 502 | Bedrock error | `{"error": {"type": "upstream_error", "message": "..."}}` |
