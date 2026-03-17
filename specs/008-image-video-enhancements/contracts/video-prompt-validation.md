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

### Camera Keyword Positioning

Camera keywords: `dolly`, `pan`, `tilt`, `track`, `orbit`, `zoom`, `following shot`, `static shot`.

Must appear only after the last comma or period in the prompt. Case-insensitive matching.

**Error response (HTTP 400):**
```json
{
  "error": {
    "type": "prompt_validation_error",
    "rule": "camera_position",
    "message": "Camera keyword '{keyword}' found before the final clause. Camera motion keywords must be placed at the end of the prompt, after the last comma or period. Move '{keyword}' to the end.",
    "shot": null
  }
}
```

### Minimum Length

Prompts must be at least 50 characters.

**Error response (HTTP 400):**
```json
{
  "error": {
    "type": "prompt_validation_error",
    "rule": "min_length",
    "message": "Prompt is {length} characters (minimum 50). Short prompts give the model too much freedom, resulting in warping and morphing artefacts. Add more detail describing the subject, action, environment, and style.",
    "shot": null
  }
}
```

## Request Changes

No changes to the request schema. Validation is applied to the `prompt` field (single-shot) or each `shots[].prompt` (multi-shot) before processing.

## Scope

- Applies to: Nova Reel requests only
- Does NOT apply to: Luma Ray2 requests
- Validation runs before any Bedrock call (zero cost on rejection)
