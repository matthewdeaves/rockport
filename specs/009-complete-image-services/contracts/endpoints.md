# API Endpoint Contracts

## New Sidecar Endpoints (port 4001)

### POST /v1/images/inpaint
**Model**: `us.stability.stable-image-inpaint-v1:0`
**Auth**: Bearer token, blocks --claude-only keys
**Request**: `InpaintRequest` — image (required), prompt (required), mask, grow_mask, negative_prompt, seed, output_format, style_preset
**Response**: `{"images": [{"b64_json": "..."}], "model": "stability-inpaint", "cost": 0.04}`
**Errors**: 400 (validation), 402 (over budget), 403 (claude-only key), 502 (Bedrock error)

### POST /v1/images/erase
**Model**: `us.stability.stable-image-erase-object-v1:0`
**Auth**: Bearer token, blocks --claude-only keys
**Request**: `EraseRequest` — image (required), mask, grow_mask, seed, output_format
**Response**: `{"images": [{"b64_json": "..."}], "model": "stability-erase", "cost": 0.04}`
**Errors**: 400, 402, 403, 502

### POST /v1/images/creative-upscale
**Model**: `us.stability.stable-creative-upscale-v1:0`
**Auth**: Bearer token, blocks --claude-only keys
**Request**: `CreativeUpscaleRequest` — image (required, max 1MP), prompt (required), creativity, negative_prompt, seed, output_format, style_preset
**Response**: `{"images": [{"b64_json": "..."}], "model": "stability-creative-upscale", "cost": 0.06}`
**Errors**: 400 (including image too large), 402, 403, 502

### POST /v1/images/fast-upscale
**Model**: `us.stability.stable-fast-upscale-v1:0`
**Auth**: Bearer token, blocks --claude-only keys
**Request**: `FastUpscaleRequest` — image (required, 32-1536px, 1024-1048576 pixels), output_format
**Response**: `{"images": [{"b64_json": "..."}], "model": "stability-fast-upscale", "cost": 0.04}`
**Errors**: 400, 402, 403, 502

### POST /v1/images/search-recolor
**Model**: `us.stability.stable-image-search-recolor-v1:0`
**Auth**: Bearer token, blocks --claude-only keys
**Request**: `SearchRecolorRequest` — image (required), prompt (required), select_prompt (required), negative_prompt, grow_mask, seed, output_format, style_preset
**Response**: `{"images": [{"b64_json": "..."}], "model": "stability-search-recolor", "cost": 0.04}`
**Errors**: 400, 402, 403, 502

### POST /v1/images/stability-outpaint
**Model**: `us.stability.stable-outpaint-v1:0`
**Auth**: Bearer token, blocks --claude-only keys
**Request**: `StabilityOutpaintRequest` — image (required), left/right/up/down (at least one > 0), prompt, creativity, seed, output_format, style_preset
**Response**: `{"images": [{"b64_json": "..."}], "model": "stability-outpaint", "cost": 0.04}`
**Errors**: 400 (including all directions zero), 402, 403, 502

## New LiteLLM Models (port 4000)

### POST /v1/images/generations (model: stable-image-ultra)
**Model**: `bedrock/stability.stable-image-ultra-v1:1` (us-west-2)
**Request**: Standard OpenAI image generation format — prompt, model, size/aspect_ratio, n
**Response**: Standard OpenAI ImageResponse — `{"data": [{"b64_json": "..."}]}`

### POST /v1/images/generations (model: stable-image-core)
**Model**: `bedrock/stability.stable-image-core-v1:1` (us-west-2)
**Request**: Standard OpenAI image generation format — prompt, model
**Response**: Standard OpenAI ImageResponse — `{"data": [{"b64_json": "..."}]}`

## Updated Existing Endpoints

### POST /v1/images/structure (+ aspect_ratio)
### POST /v1/images/sketch (+ aspect_ratio)
### POST /v1/images/search-replace (+ aspect_ratio)
### POST /v1/images/variations (+ negative_text)
### POST /v1/images/outpaint (+ negative_text, quality validation, mask_prompt max_length)
