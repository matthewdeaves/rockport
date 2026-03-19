# Research: Complete Image Services

## Model IDs (Verified Against AWS Docs)

All cross-region IDs use `us.` prefix. Text-to-image models (SD3.5, Ultra, Core) have no cross-region profile.

| Model | Base ID | Cross-Region ID | Region |
|---|---|---|---|
| Inpaint | `stability.stable-image-inpaint-v1:0` | `us.stability.stable-image-inpaint-v1:0` | us-west-2 |
| Erase Object | `stability.stable-image-erase-object-v1:0` | `us.stability.stable-image-erase-object-v1:0` | us-west-2 |
| Creative Upscale | `stability.stable-creative-upscale-v1:0` | `us.stability.stable-creative-upscale-v1:0` | us-west-2 |
| Fast Upscale | `stability.stable-fast-upscale-v1:0` | `us.stability.stable-fast-upscale-v1:0` | us-west-2 |
| Outpaint | `stability.stable-outpaint-v1:0` | `us.stability.stable-outpaint-v1:0` | us-west-2 |
| Search & Recolor | `stability.stable-image-search-recolor-v1:0` | `us.stability.stable-image-search-recolor-v1:0` | us-west-2 |
| Ultra v1.1 | `stability.stable-image-ultra-v1:1` | N/A | us-west-2 |
| Core v1.1 | `stability.stable-image-core-v1:1` | N/A | us-west-2 |

### Previously incorrect IDs (corrected)

- Outpaint: `stable-outpaint` NOT `stable-image-outpaint`
- Creative Upscale: `stable-creative-upscale` NOT `stable-image-creative-upscale`
- Fast Upscale: `stable-fast-upscale` NOT `stable-image-fast-upscale`

## New Endpoint API Specifications

### Inpaint (`us.stability.stable-image-inpaint-v1:0`)

| Parameter | Type | Required | Default | Range |
|---|---|---|---|---|
| image | base64 | Yes | — | 64px min, 9.4MP max, JPEG/PNG/WebP |
| prompt | string | Yes | — | 0-10,000 chars |
| mask | base64 | No | — | B/W mask; white=inpaint. Falls back to alpha channel if omitted |
| grow_mask | int | No | 5 | 0-20 |
| negative_prompt | string | No | — | 0-10,000 chars |
| seed | int | No | random | 0-4,294,967,294 |
| output_format | string | No | png | jpeg, png, webp |
| style_preset | string | No | — | 17 presets |

### Erase Object (`us.stability.stable-image-erase-object-v1:0`)

| Parameter | Type | Required | Default | Range |
|---|---|---|---|---|
| image | base64 | Yes | — | 64px min, 9.4MP max, JPEG/PNG/WebP |
| mask | base64 | No | — | B/W mask; white=erase. Falls back to alpha channel |
| grow_mask | int | No | 5 | 0-20 |
| seed | int | No | random | 0-4,294,967,294 |
| output_format | string | No | png | jpeg, png, webp |

No prompt, no negative_prompt, no style_preset.

### Creative Upscale (`us.stability.stable-creative-upscale-v1:0`)

| Parameter | Type | Required | Default | Range |
|---|---|---|---|---|
| image | base64 | Yes | — | 64px min, 1MP max (4,096-1,048,576 pixels), JPEG/PNG/WebP |
| prompt | string | Yes | — | 0-10,000 chars |
| creativity | float | No | 0.3 | 0.1-0.5 |
| negative_prompt | string | No | — | 0-10,000 chars |
| seed | int | No | random | 0-4,294,967,294 |
| output_format | string | No | png | jpeg, png, webp |
| style_preset | string | No | — | 17 presets |

Output: up to 4K.

### Fast Upscale (`us.stability.stable-fast-upscale-v1:0`)

| Parameter | Type | Required | Default | Range |
|---|---|---|---|---|
| image | base64 | Yes | — | 32-1,536px per side, 1,024-1,048,576 total pixels, JPEG/PNG/WebP |
| output_format | string | No | png | jpeg, png, webp |

No prompt, no seed, no negative_prompt. Simplest endpoint — deterministic 4x upscale.

### Search & Recolor (`us.stability.stable-image-search-recolor-v1:0`)

| Parameter | Type | Required | Default | Range |
|---|---|---|---|---|
| image | base64 | Yes | — | 64px min, 9.4MP max, JPEG/PNG/WebP |
| prompt | string | Yes | — | 0-10,000 chars (desired colour/appearance) |
| select_prompt | string | Yes | — | 0-10,000 chars (object to find) |
| negative_prompt | string | No | — | 0-10,000 chars |
| grow_mask | int | No | 5 | 0-20 |
| seed | int | No | random | 0-4,294,967,294 |
| output_format | string | No | png | jpeg, png, webp |
| style_preset | string | No | — | 17 presets |

Note: Uses `select_prompt` (not `search_prompt` like Search & Replace).

### Stability Outpaint (`us.stability.stable-outpaint-v1:0`)

Endpoint: `/v1/images/stability-outpaint` (avoids conflict with Nova Canvas `/v1/images/outpaint`)

| Parameter | Type | Required | Default | Range |
|---|---|---|---|---|
| image | base64 | Yes | — | 64px min, 9.4MP max, JPEG/PNG/WebP |
| left | int | No* | 0 | 0-2000 |
| right | int | No* | 0 | 0-2000 |
| up | int | No* | 0 | 0-2000 |
| down | int | No* | 0 | 0-2000 |
| prompt | string | No | — | 0-10,000 chars |
| creativity | float | No | 0.5 | 0.1-1.0 |
| seed | int | No | random | 0-4,294,967,294 |
| output_format | string | No | png | jpeg, png, webp |
| style_preset | string | No | — | 17 presets |

*At least one of left/right/up/down must be non-zero. No negative_prompt.

## LiteLLM Config Models

### Stable Image Ultra v1.1

- Model ID: `stability.stable-image-ultra-v1:1`
- Region: us-west-2
- Mode: text-to-image + image-to-image
- Params: prompt (required), aspect_ratio (9 options), output_format (JPEG/PNG only — no WebP), seed, negative_prompt
- Image-to-image: add `image` (base64) + `strength` (0-1, default 0.35)
- Cost: ~$0.14/image

### Stable Image Core v1.1

- Model ID: `stability.stable-image-core-v1:1`
- Region: us-west-2
- Mode: text-to-image only
- Params: prompt (required), aspect_ratio (9 options), output_format (JPEG/PNG only — no WebP), seed, negative_prompt
- Cost: ~$0.04/image

### Decision: LiteLLM vs Sidecar for Ultra/Core

**Decision**: Add to LiteLLM config as `bedrock/stability.stable-image-ultra-v1:1` and `bedrock/stability.stable-image-core-v1:1`.
**Rationale**: These are standard text-to-image models with the same Bedrock invoke pattern as SD3.5 Large. LiteLLM already handles SD3.5 Large. No custom code needed.
**Alternative rejected**: Sidecar endpoints — would duplicate LiteLLM's existing Bedrock image generation pipeline for no benefit.

## Existing Endpoint Gaps

| Endpoint | Missing Parameter | Bedrock Supports It? | Action |
|---|---|---|---|
| `/v1/images/structure` | `aspect_ratio` | Yes | Add optional field |
| `/v1/images/sketch` | `aspect_ratio` | Yes | Add optional field |
| `/v1/images/search-replace` | `aspect_ratio` | Yes | Add optional field |
| `/v1/images/variations` | `negative_text` | Yes (as `negativeText` in IMAGE_VARIATION) | Add optional field |
| `/v1/images/outpaint` (Nova) | `negative_text`, quality validation, mask_prompt max_length | Yes | Add field, fix validation |
| `/v1/images/style-transfer` | `style_preset` | No (confirmed) | No action needed |
| `/v1/images/upscale` (Conservative) | `style_preset` | No (confirmed) | No action needed |

## Nova Canvas Style Presets

LiteLLM passes through `textToImageParams` to Bedrock. The `style` parameter is part of `textToImageParams` for TEXT_IMAGE task type.

**Decision**: Document the pass-through — no sidecar code needed. Users include `style` in their request body alongside the prompt.
**Valid values**: 3D_ANIMATED_FAMILY_FILM, DESIGN_SKETCH, FLAT_VECTOR_ILLUSTRATION, GRAPHIC_NOVEL_ILLUSTRATION, MAXIMALISM, MIDCENTURY_RETRO, PHOTOREALISM, SOFT_DIGITAL_PAINTING

## Automated Multi-Shot Video

Nova Reel supports `MULTI_SHOT_AUTOMATED` task type:
- Single prompt up to 4000 chars
- Model determines shot breakdown
- Duration 12-120 seconds
- Same S3 output bucket, same async invoke pattern

**Decision**: Add as a new mode option in the video sidecar alongside existing single-shot and multi-shot-manual.
**Rationale**: Minimal code — same Bedrock async invoke, different `taskType` and `textToVideoParams` structure.

## Infrastructure

**No changes needed**:
- WAF: `/v1/images/*` wildcard already covers all new paths
- Tunnel: `/v1/images/*` → sidecar routing already in place
- IAM: `bedrock:InvokeModel` on `foundation-model/*` covers all new model IDs
- IAM: `aws-marketplace:Subscribe` already added for auto-activation
- S3: No new buckets needed (video uses existing buckets)

## Common Response Format

All Stability AI models return:
```json
{
  "seeds": [integer],
  "finish_reasons": [null | "Filter reason: prompt" | "Filter reason: output image" | "Filter reason: input image" | "Inference error"],
  "images": ["base64_string"]
}
```

The existing `invoke_stability_model` helper already handles this format.
