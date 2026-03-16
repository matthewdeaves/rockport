# Implementation Plan: Fix Image-to-Video Support

**Branch**: `005-fix-image-to-video` | **Date**: 2026-03-16 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/005-fix-image-to-video/spec.md`

## Summary

Fix the video generation sidecar's image-to-video support by correcting Bedrock API field names and payload structures. The current code has 5 bugs: wrong field names for single-shot image payloads, wrong task type and structure for multi-shot requests, raw data URIs passed instead of stripped base64, no duration enforcement for image-conditioned requests, and no alpha channel detection. All changes are in `sidecar/video_api.py` only — no schema changes, no new files, no new dependencies.

## Technical Context

**Language/Version**: Python 3.11
**Primary Dependencies**: FastAPI, boto3, Pillow, psycopg2, pydantic (all already installed)
**Storage**: PostgreSQL 15 (existing, no schema changes)
**Testing**: Manual smoke testing via curl/httpx against deployed sidecar
**Target Platform**: Linux (EC2 t4g.small, Amazon Linux 2023)
**Project Type**: Web service (FastAPI sidecar)
**Performance Goals**: N/A (async video generation, ~10-20 jobs/day)
**Constraints**: 256MB memory limit (systemd MemoryMax), single file change
**Scale/Scope**: Single operator, low volume

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Cost Minimization | PASS | No new infrastructure, no additional AWS costs |
| II. Security | PASS | No auth changes, no new endpoints, no new IAM permissions |
| III. LiteLLM-First | PASS | This is the video sidecar (explicitly out of LiteLLM scope per constitution). Sidecar is permitted custom code. |
| IV. Scope Containment | PASS | Bug fix to existing feature, no new capabilities |
| V. AWS London + Cloudflare | PASS | Video sidecar uses us-east-1 (Nova Reel requirement, already established) |

**Post-Phase 1 re-check**: No changes — all design decisions stay within existing sidecar architecture.

## Project Structure

### Documentation (this feature)

```text
specs/005-fix-image-to-video/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Bedrock API research (Phase 0, pre-existing)
├── data-model.md        # Data model (Phase 1)
├── quickstart.md        # Quick verification guide (Phase 1)
└── tasks.md             # Implementation tasks (Phase 2, via /speckit.tasks)
```

### Source Code (repository root)

```text
sidecar/
├── video_api.py         # All changes here — endpoints, validation, Bedrock payload building
└── db.py                # No changes needed
```

**Structure Decision**: All changes are in the existing `sidecar/video_api.py`. No new files or directories needed. This is a bug fix to existing code, not a new feature.

## Current Code Analysis

### Bug 1: Single-shot image payload (lines 288-290)
**Current**: `text_params["image"] = req.image` — passes raw data URI as `image` field
**Correct**: `textToVideoParams.images` array with `{format: "png", source: {bytes: "<raw-base64>"}}` objects

### Bug 2: Multi-shot task type (lines 271-286)
**Current**: Uses `taskType: "TEXT_VIDEO"` with `textToVideoParams.videos` array
**Correct**: Uses `taskType: "MULTI_SHOT_MANUAL"` with `multiShotManualParams.shots` array

### Bug 3: Multi-shot image format (line 276)
**Current**: `v["imageDataURI"] = shot.image` — passes raw data URI as `imageDataURI`
**Correct**: Per-shot `image: {format, source: {bytes}}` object

### Bug 4: No data URI stripping
**Current**: Raw data URIs (with `data:image/png;base64,` prefix) sent to Bedrock
**Correct**: Strip prefix, extract format string, pass raw base64 in `source.bytes`

### Bug 5: No duration enforcement for image + single-shot
**Current**: Allows any 6-120s duration with image
**Correct**: Must be exactly 6s when image is provided

### Bug 6: No alpha channel detection
**Current**: `validate_image` checks format and dimensions only
**Correct**: Check for alpha channel — strip if fully opaque, reject if any transparency

## Implementation Approach

### Helper function: `parse_image_data_uri(data_uri) -> (raw_base64, format_str)`

New function to:
1. Strip `data:image/{format};base64,` prefix
2. Extract and normalize format (`jpg` → `jpeg`)
3. Return `(raw_base64_string, format_string)` tuple

### Modified function: `validate_image(data_uri) -> (raw_base64, format_str)`

Change return type from `None` to `(str, str)` — returns the parsed image data after validation. Add:
1. Alpha channel detection using `img.mode` check
2. If alpha present and all pixels opaque (`getextrema()[0] == 255`), strip via `img.convert("RGB")` and re-encode
3. If alpha present and any pixel transparent, reject with error
4. Return parsed `(raw_base64, format_str)` for direct use in Bedrock payload

### Modified: Single-shot Bedrock payload (lines 287-299)

Replace:
```python
text_params = {"text": req.prompt}
if req.image:
    text_params["image"] = req.image
```
With:
```python
text_params = {"text": req.prompt}
if req.image:
    raw_b64, fmt = validate_image(req.image)  # already called above, but now returns data
    text_params["images"] = [{"format": fmt, "source": {"bytes": raw_b64}}]
```

Plus duration enforcement: reject if `req.image` and `duration != 6`.

### Modified: Multi-shot Bedrock payload (lines 271-286)

Replace `TEXT_VIDEO` / `textToVideoParams.videos` with `MULTI_SHOT_MANUAL` / `multiShotManualParams.shots`, formatting per-shot images correctly.

## Complexity Tracking

No constitution violations — table omitted.
