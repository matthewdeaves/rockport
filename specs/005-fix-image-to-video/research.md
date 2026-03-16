# Research: Fix Image-to-Video Support

**Date**: 2026-03-16 | **Feature**: 005-fix-image-to-video

## R-001: Bedrock Nova Reel Image-to-Video API Structure

**Decision**: Use the documented Bedrock `StartAsyncInvoke` API with correct field names for image payloads.

**Rationale**: The current sidecar uses incorrect field names (`image`, `imageDataURI`, `videos`) that don't match the Bedrock API. The correct structures are documented in AWS Nova Reel documentation.

**Findings**:

### Single-shot with image (taskType: TEXT_VIDEO)

```json
{
  "taskType": "TEXT_VIDEO",
  "textToVideoParams": {
    "text": "prompt text",
    "images": [
      {
        "format": "png",
        "source": {
          "bytes": "<raw-base64-no-data-uri-prefix>"
        }
      }
    ]
  },
  "videoGenerationConfig": {
    "durationSeconds": 6,
    "fps": 24,
    "dimension": "1280x720"
  }
}
```

- `images` is an array (plural), not `image` (singular)
- Each element has `format` ("png" or "jpeg") and `source.bytes` (raw base64)
- Duration is fixed at 6 seconds when an image is provided

### Multi-shot with images (taskType: MULTI_SHOT_MANUAL)

```json
{
  "taskType": "MULTI_SHOT_MANUAL",
  "multiShotManualParams": {
    "shots": [
      {"text": "shot 1 prompt"},
      {
        "text": "shot 2 prompt",
        "image": {
          "format": "png",
          "source": {"bytes": "<raw-base64>"}
        }
      }
    ]
  },
  "videoGenerationConfig": {
    "fps": 24,
    "dimension": "1280x720"
  }
}
```

- taskType is `MULTI_SHOT_MANUAL` (not `TEXT_VIDEO`)
- Top-level key is `multiShotManualParams` (not `textToVideoParams`)
- Per-shot image is `image` (singular object, not array)
- Duration is not specified — it's derived from number of shots x 6 seconds

**Alternatives considered**: S3 URI input (`source.s3Location.uri`) — rejected because the sidecar already accepts data URIs from clients and converting to S3 would add unnecessary complexity and latency.

---

## R-002: Data URI to Raw Base64 Conversion

**Decision**: Strip the `data:image/{format};base64,` prefix from data URIs, extract the format string, and pass raw base64 to Bedrock.

**Rationale**: Bedrock expects raw base64 bytes in `source.bytes`, not data URIs. The format must be extracted from the data URI header and passed separately in the `format` field.

**Findings**:

- Data URI format: `data:image/png;base64,iVBORw0KGgo...`
- Extract format: split on `/` and `;` to get `png` or `jpeg`
- Handle `data:image/jpg;base64,...` by normalizing `jpg` → `jpeg`
- The existing `validate_image` function already parses the data URI and decodes base64 — the conversion helper can reuse that parsing logic

---

## R-003: Duration Enforcement for Image-Conditioned Single-Shot

**Decision**: Reject single-shot requests that include an image and specify a duration other than 6 seconds.

**Rationale**: Nova Reel v1.1 only supports 6-second duration for single-shot image-to-video. Allowing other durations would cause a Bedrock API error.

**Findings**:

- If `duration` is not specified and `image` is present, default to 6 (already the default)
- If `duration` is specified as 6, allow it
- If `duration` is specified as anything else with an image, return 400 with a clear error

---

## R-004: Alpha/Transparency Detection

**Decision**: Check for alpha channel in PNG images using Pillow's `mode` attribute. If all pixels are fully opaque (alpha=255), strip the alpha channel via `img.convert("RGB")` and proceed. If any pixel has transparency or translucency, reject with a descriptive error.

**Rationale**: Per AWS Nova Reel docs: "PNG images may contain an additional alpha channel, but that channel must not contain any transparent or translucent pixels." Many common tools (Photoshop, GIMP, macOS screenshots) save PNGs as RGBA by default even when fully opaque — rejecting those would frustrate users unnecessarily.

**Findings**:

- Pillow image modes with alpha: `RGBA`, `LA`, `PA`
- JPEG images never have alpha (no check needed)
- Check `img.mode` after opening with Pillow — if alpha mode detected:
  - Get alpha channel via `img.getchannel("A")`
  - Check `alpha.getextrema()` — returns `(min, max)` of alpha values
  - If `min == 255`, all pixels are fully opaque → strip alpha with `img.convert("RGB")`, re-encode to get clean bytes
  - If `min < 255`, some pixels are transparent → reject with error
- `validate_image` must return the (potentially converted) raw bytes and format to the caller, not just validate

---

## R-005: Multi-Shot Text-Only Handling

**Decision**: Use `MULTI_SHOT_MANUAL` for all multi-shot requests, regardless of whether images are present.

**Rationale**: The current code incorrectly uses `TEXT_VIDEO` with `textToVideoParams.videos` for multi-shot. The correct API is always `MULTI_SHOT_MANUAL` with `multiShotManualParams.shots` for multi-shot requests. This works for both text-only and image-enhanced shots.

**Alternatives considered**: Using `MULTI_SHOT_AUTOMATED` for text-only multi-shot (accepts a single long prompt and auto-segments). Rejected because the user has already explicitly defined per-shot prompts, so manual mode is the correct semantic match.
