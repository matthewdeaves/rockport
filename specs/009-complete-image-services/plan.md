# Implementation Plan: Complete Image Services

**Branch**: `009-complete-image-services` | **Date**: 2026-03-19 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/009-complete-image-services/spec.md`

## Summary

Add 6 new Stability AI sidecar endpoints (inpaint, erase, creative upscale, fast upscale, search & recolor, stability outpaint), 2 new LiteLLM text-to-image models (Ultra, Core), complete missing parameters on existing endpoints, expose Nova Canvas style presets, and add automated multi-shot video generation. Follows established sidecar patterns — no new architecture.

## Technical Context

**Language/Version**: Python 3.11 (sidecar), YAML (LiteLLM config), Bash (smoke tests), HCL (Terraform)
**Primary Dependencies**: FastAPI, uvicorn, boto3, Pillow, pydantic, psycopg2 (all already installed)
**Storage**: PostgreSQL 15 (spend logging to existing LiteLLM_SpendLogs table)
**Testing**: Bash smoke tests (invalid-input routing verification pattern)
**Target Platform**: EC2 t3.small (2GB RAM, 512MB swap) behind Cloudflare Tunnel
**Project Type**: API proxy with image/video sidecar service
**Performance Goals**: Same as existing endpoints — sub-30s response for image operations
**Constraints**: 256MB MemoryMax for sidecar, all Stability AI models in us-west-2
**Scale/Scope**: Single instance, ~8 hours/day usage, handful of users

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Gate | Status | Notes |
|------|--------|-------|
| I. Cost Minimization | PASS | No new compute. Pay-per-use Bedrock models only. No additional infra. |
| II. Security | PASS | All new endpoints use existing auth (LiteLLM `/key/info`), budget checks, and `--claude-only` blocking. No new auth mechanisms. |
| III. LiteLLM-First | PASS | Sidecar is established precedent (spec 008). LiteLLM raises NotImplementedError for these Stability image services. Ultra/Core go through LiteLLM config (not custom code). |
| IV. Scope Containment | PASS | Extends existing image generation capability. No UI, no billing, no new services. Core use case: image generation through proxy. |
| V. AWS London + Cloudflare | PASS | Stability AI models in us-west-2 (existing client). WAF, tunnel, IAM all already configured. |

## Project Structure

### Documentation (this feature)

```text
specs/009-complete-image-services/
├── plan.md              # This file
├── research.md          # Model API specifications
├── data-model.md        # Endpoint request/response models
├── quickstart.md        # Testing guide
├── contracts/           # API endpoint contracts
└── tasks.md             # Implementation tasks
```

### Source Code (repository root)

```text
sidecar/
├── image_api.py         # Add 6 new endpoints + update existing
└── video_api.py         # Add MULTI_SHOT_AUTOMATED support

config/
└── litellm-config.yaml  # Add stable-image-ultra + stable-image-core

tests/
└── smoke-test.sh        # Add smoke tests for new endpoints

scripts/
└── rockport.sh          # Update spend models display (if needed)
```

**Structure Decision**: All changes extend existing files. No new files or directories needed in the source tree.

## Complexity Tracking

No constitution violations to justify.
