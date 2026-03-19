# Data Model: Migrate Stability AI Image Endpoints to LiteLLM Native

**Date**: 2026-03-19
**Feature**: 010-migrate-stability-to-litellm

## Entity Changes

### No Database Schema Changes

This migration does not modify any database tables. LiteLLM's `/v1/images/edits` handler writes spend to the same `LiteLLM_SpendLogs` and `LiteLLM_VerificationToken` tables that the sidecar's `db.log_image_spend()` currently writes to. The tracking format may differ slightly (LiteLLM uses its own spend logging format), but the data ends up in the same tables and is visible through the same CLI commands.

## Configuration Model Changes

### New: 13 Image Edit Model Entries in litellm-config.yaml

Each entry follows this structure:

```yaml
- model_name: stability-{operation}      # User-facing name
  litellm_params:
    model: bedrock/stability.{model-id}  # Bedrock model ID (no us. prefix)
    aws_region_name: us-west-2           # All Stability AI models in us-west-2
  model_info:
    mode: image_edit                     # Routes to /v1/images/edits handler
```

Full mapping:

| User-Facing Name | Bedrock Model ID | Cost |
|---|---|---|
| `stability-structure` | `stability.stable-image-control-structure-v1:0` | $0.04 |
| `stability-sketch` | `stability.stable-image-control-sketch-v1:0` | $0.04 |
| `stability-style-transfer` | `stability.stable-style-transfer-v1:0` | $0.06 |
| `stability-remove-background` | `stability.stable-image-remove-background-v1:0` | $0.04 |
| `stability-search-replace` | `stability.stable-image-search-replace-v1:0` | $0.04 |
| `stability-upscale` | `stability.stable-conservative-upscale-v1:0` | $0.06 |
| `stability-style-guide` | `stability.stable-image-style-guide-v1:0` | $0.04 |
| `stability-inpaint` | `stability.stable-image-inpaint-v1:0` | $0.04 |
| `stability-erase` | `stability.stable-image-erase-object-v1:0` | $0.04 |
| `stability-creative-upscale` | `stability.stable-creative-upscale-v1:0` | $0.06 |
| `stability-fast-upscale` | `stability.stable-fast-upscale-v1:0` | $0.04 |
| `stability-search-recolor` | `stability.stable-image-search-recolor-v1:0` | $0.04 |
| `stability-outpaint` | `stability.stable-outpaint-v1:0` | $0.04 |

### Modified: Tunnel Ingress Rules

Before (4 rules):
1. `/v1/videos*` → `:4001`
2. `/v1/images/generations*` → `:4000`
3. `/v1/images/*` → `:4001`
4. Default → `:4000`

After (5 rules):
1. `/v1/videos*` → `:4001`
2. `/v1/images/generations*` → `:4000`
3. `/v1/images/edits*` → `:4000` **(NEW)**
4. `/v1/images/*` → `:4001` (now only catches Nova Canvas: variations, background-removal, outpaint)
5. Default → `:4000`

### Unchanged: WAF Rules

The existing `not starts_with(http.request.uri.path, "/v1/images/")` already allows `/v1/images/edits`. No WAF expression changes needed. The 13 removed Stability AI sidecar paths were never explicitly listed in the WAF — they were always covered by this prefix catch-all. WAF header comments should be updated to document the new routing.

## Sidecar Code Removal

### Removed Endpoints (13)
All `@router.post("/v1/images/{operation}")` functions for Stability AI operations.

### Removed Helpers (Stability-only)
- `invoke_stability_model()` — Bedrock invoke wrapper for Stability AI
- `_build_stability_payload()` — Common payload builder
- `_validate_stability_image()` — Stability AI image validation
- `_validate_output_format()` — Output format validation
- `STABILITY_ASPECT_RATIOS` — Allowed aspect ratios constant
- `STABILITY_STYLE_PRESETS` — Style presets constant
- `STABILITY_MAX_PIXELS` — Max pixel count constant
- `STABILITY_OUTPUT_FORMATS` — Output format set constant

### Preserved Helpers (shared with Nova Canvas)
- `authenticate_image_request()` — Auth via LiteLLM /key/info
- `check_budget()` — Budget enforcement
- `parse_data_uri()` — Data URI parsing
- `decode_and_validate_image()` — Image decode + validation
- `init_clients()` — Bedrock client initialization
- `configure()` — Shared configuration setup
