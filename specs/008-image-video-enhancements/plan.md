# Implementation Plan: Image & Video Generation Enhancements

**Branch**: `008-image-video-enhancements` | **Date**: 2026-03-17 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/008-image-video-enhancements/spec.md`

## Summary

Add video prompt validation (negation detection, camera keyword positioning, minimum length), auto-resize for Nova Reel images, three Nova Canvas advanced endpoints (IMAGE_VARIATION, BACKGROUND_REMOVAL, OUTPAINTING), and seven Stability AI Image Service endpoints to the existing video sidecar. All new image endpoints are synchronous, authenticate via LiteLLM, and track spend in existing tables. Infrastructure changes: WAF allowlist, tunnel routing split, IAM permissions.

## Technical Context

**Language/Version**: Python 3.11
**Primary Dependencies**: FastAPI, uvicorn, boto3, Pillow, psycopg2, pydantic, httpx (all existing in sidecar)
**Storage**: PostgreSQL 15 (existing — spend logging to LiteLLM_SpendLogs and LiteLLM_VerificationToken)
**Testing**: bash smoke tests (`tests/smoke-test.sh`)
**Target Platform**: Linux (EC2 t3.small, 2GB RAM)
**Project Type**: Web service (API proxy sidecar)
**Performance Goals**: Synchronous image endpoints bounded by Bedrock latency (5-30s per call). No additional proxy latency beyond validation.
**Constraints**: 256MB sidecar MemoryMax (may need increase for large Stability AI images). Total instance RAM 2GB shared with LiteLLM (1280MB) + PostgreSQL (~150MB).
**Scale/Scope**: Single operator, low concurrency. ~10 new endpoints, ~500-800 lines of new Python code.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Cost Minimization | PASS | No new infrastructure. Same t3.small. Bedrock costs are per-use (user pays). No new AWS services. |
| II. Security | PASS | Reuses existing LiteLLM key auth. `--claude-only` keys blocked from new endpoints (FR-022a). No new secrets, no new network exposure. |
| III. LiteLLM-First | PASS with justification | Custom code required because LiteLLM raises NotImplementedError for IMAGE_VARIATION, BACKGROUND_REMOVAL, OUTPAINTING. Stability AI services have no LiteLLM support. Video sidecar is established precedent for custom code where LiteLLM cannot deliver. |
| IV. Scope Containment | PASS | Serves core use case (image/video generation through Bedrock). No dashboard, billing, caching, or transformation. Prompt validation is input rejection, not prompt transformation. |
| V. AWS London + Cloudflare | PASS | Compute stays in eu-west-2. Cross-region Bedrock calls (us-east-1 for Nova Canvas, us-west-2 for Stability AI) already established pattern. |

**Post-Phase 1 re-check**: No changes. Design adds no new infrastructure, services, or cost.

## Project Structure

### Documentation (this feature)

```text
specs/008-image-video-enhancements/
├── plan.md
├── spec.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── video-prompt-validation.md
│   ├── auto-resize.md
│   ├── nova-canvas-endpoints.md
│   └── stability-ai-endpoints.md
├── checklists/
│   └── requirements.md
└── tasks.md                         # Phase 2 (/speckit.tasks)
```

### Source Code (repository root)

```text
sidecar/
├── video_api.py          # Existing — add prompt validation, auto-resize, image endpoints
├── image_api.py          # New — Nova Canvas + Stability AI endpoint handlers
├── prompt_validation.py  # New — negation detection, camera keyword check, min length
├── image_resize.py       # New — auto-resize logic (scale, crop, fit)
├── db.py                 # Existing — add image spend logging functions
└── requirements.txt      # Existing — no new deps needed

config/
├── rockport-video.service  # May need MemoryMax increase (256MB → 384MB)
└── litellm-config.yaml     # No changes

terraform/
├── waf.tf                  # Add new image endpoint paths to allowlist
├── tunnel.tf               # Add /v1/images/* routing split (generations→4000, rest→4001)
├── main.tf                 # Verify IAM covers Stability AI model IDs
└── s3.tf                   # No changes (image endpoints don't use S3)

tests/
└── smoke-test.sh           # Add image endpoint smoke tests

scripts/
└── rockport.sh             # No changes (spend tracking already reads LiteLLM tables)
```

**Structure Decision**: Extend the existing sidecar with new modules. `image_api.py` contains all new image endpoint definitions. `prompt_validation.py` and `image_resize.py` are extracted as separate modules for testability. The main `video_api.py` imports and registers the new routes, and calls prompt validation/resize in the existing video generation flow.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Custom image endpoints (vs LiteLLM-First) | LiteLLM raises NotImplementedError for 3 Nova Canvas task types; has zero Stability AI Image Service support | No configuration-only path exists; verified in research |
