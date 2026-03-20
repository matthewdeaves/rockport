# Contract: Video Prompt Validation

Applies to existing `POST /v1/videos/generations` endpoint. No new endpoints.

## Validation Rules (Nova Reel only)

### Negation Detection

Rejects prompts containing whole-word negations: `no`, `not`, `without`, `don't`, `avoid`.

Word boundary matching required — "Nottingham", "knotted", "another" must NOT trigger.

**Error response (HTTP 400):**
```json
{
  "error": {
    "type": "prompt_validation_error",
    "rule": "negation",
    "message": "Nova Reel prompt contains negation word '{word}' at position {pos}. Nova Reel interprets negation subjects as positive signals — describe only what you want to see. Rephrase without negation words (no, not, without, don't, avoid).",
    "shot": 3
  }
}
```

`shot` field included only for multi-shot requests (1-indexed).

### Camera Keyword Positioning (Warning)

Camera keywords: `dolly`, `pan`, `tilt`, `track`, `orbit`, `zoom`, `following shot`, `static shot`.

AWS recommends placing camera motion keywords at the start or end of the prompt for best results. Keywords found in the middle (between the first and last clause separators) produce a non-blocking warning in the response `warnings` array.

**Warning (included in 202 response, does not block request):**
```json
{
  "warnings": [
    {
      "type": "prompt_quality_warning",
      "rule": "camera_position",
      "message": "Camera keyword '{keyword}' found in the middle of the prompt. For best results, place camera motion keywords at the start or end.",
      "shot": null
    }
  ]
}
```

## Request Changes

No changes to the request schema. Validation is applied to the `prompt` field (single-shot) or each `shots[].prompt` (multi-shot) before processing.

## Scope

- Applies to: Nova Reel requests only
- Does NOT apply to: Luma Ray2 requests
- Validation runs before any Bedrock call (zero cost on rejection)
