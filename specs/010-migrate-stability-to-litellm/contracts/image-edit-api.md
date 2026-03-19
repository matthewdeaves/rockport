# Contract: Image Edit API (LiteLLM Native)

**Date**: 2026-03-19
**Feature**: 010-migrate-stability-to-litellm

## Endpoint

`POST /v1/images/edits`

This is LiteLLM's native endpoint, following the OpenAI image edit API format.

## Request Format

**Content-Type**: `multipart/form-data`

| Field | Type | Required | Description |
|---|---|---|---|
| `model` | string | Yes | One of the 13 `stability-*` model names |
| `image` | file | Yes | Input image file (PNG, JPEG, WebP) |
| `prompt` | string | Varies | Text prompt (required for most operations, optional for erase/remove-bg) |
| `mask` | file | No | Mask image for inpaint/erase operations |
| `negative_prompt` | string | No | What to avoid in the output |
| `seed` | integer | No | Reproducibility seed (0–4294967294) |
| `size` | string | No | Maps to `aspect_ratio` internally |

**Operation-specific fields** (passed as additional form fields):

| Field | Operations | Type | Description |
|---|---|---|---|
| `control_strength` | structure, sketch | float 0.0–1.0 | How much the control image influences output |
| `creativity` | upscale, creative-upscale, outpaint | float 0.1–0.5 | Amount of creative interpretation |
| `grow_mask` | search-replace, inpaint, erase, search-recolor | int 0–20 | Mask expansion pixels |
| `search_prompt` | search-replace | string | What to find in the image |
| `select_prompt` | search-recolor | string | What to select for recoloring |
| `left`, `right`, `up`, `down` | outpaint | int 0–2000 | Pixels to extend in each direction |
| `init_image` | style-transfer | file | Source style image |
| `style_image` | style-transfer | file | Target style image |
| `fidelity` | style-guide | float 0.0–1.0 | How closely to match the style |
| `output_format` | all | string | `png`, `jpeg`, or `webp` |

## Response Format

```json
{
  "created": 1234567890,
  "data": [
    {
      "b64_json": "<base64-encoded-image>",
      "revised_prompt": null
    }
  ]
}
```

## Error Responses

| Status | Meaning |
|---|---|
| 400 | Invalid parameters or Bedrock validation error |
| 401 | Invalid API key |
| 403 | Model not in key's allowed list (e.g., claude-only key) |
| 402 | Budget exceeded |
| 500 | Bedrock service error |

## Transition from Sidecar API

| Old Sidecar Endpoint | New LiteLLM Request |
|---|---|
| `POST /v1/images/structure` (JSON) | `POST /v1/images/edits` with `model=stability-structure` (multipart) |
| `POST /v1/images/inpaint` (JSON) | `POST /v1/images/edits` with `model=stability-inpaint` (multipart) |
| ... (same pattern for all 13) | |

**Key difference**: Sidecar used JSON body with data URI images. LiteLLM uses multipart form-data with file uploads.
