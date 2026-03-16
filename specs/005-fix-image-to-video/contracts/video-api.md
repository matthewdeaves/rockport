# API Contract: Video Generation Endpoints

**Date**: 2026-03-16 | **Feature**: 005-fix-image-to-video

## POST /v1/videos/generations

No changes to the request/response contract. The `image` field on the request body and `ShotRequest.image` field already exist. This fix only corrects how those fields are translated to Bedrock API calls internally.

### Request Body (unchanged)

```json
{
  "prompt": "string (1-4000 chars, required for single-shot)",
  "duration": "integer (6-120, multiple of 6, optional — forced to 6 when image present)",
  "image": "string (data URI, optional — e.g. data:image/png;base64,...)",
  "shots": [
    {
      "prompt": "string (1-512 chars)",
      "image": "string (data URI, optional)"
    }
  ],
  "seed": "integer (optional)"
}
```

### New Validation Error (added)

**Single-shot with image and duration != 6**:
```json
{
  "error": {
    "type": "validation_error",
    "message": "Single-shot with image is fixed at 6 seconds. Remove 'duration' or set it to 6."
  }
}
```

**PNG with actual transparency** (pixels with alpha < 255):
```json
{
  "error": {
    "type": "validation_error",
    "message": "Image contains transparent pixels (got RGBA mode with alpha < 255). Nova Reel requires fully opaque images. Use an opaque PNG or JPEG."
  }
}
```

Note: PNGs with an alpha channel where all pixels are fully opaque (alpha=255) are accepted — the alpha channel is silently stripped.

### Bedrock Payload Mapping (internal, fixed by this feature)

| Client Input | Bedrock Output (single-shot) | Bedrock Output (multi-shot) |
|---|---|---|
| `prompt` + no image | `TEXT_VIDEO` / `textToVideoParams.text` | `MULTI_SHOT_MANUAL` / `multiShotManualParams.shots[].text` |
| `prompt` + `image` | `TEXT_VIDEO` / `textToVideoParams.text` + `textToVideoParams.images[]` | `MULTI_SHOT_MANUAL` / `multiShotManualParams.shots[].text` + `shots[].image` |

## GET /v1/videos/generations/{job_id}

No changes.

## GET /v1/videos/generations

No changes.

## GET /v1/videos/health

No changes.
