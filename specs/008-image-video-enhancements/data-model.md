# Data Model: Image & Video Generation Enhancements

**Date**: 2026-03-17
**Feature**: 008-image-video-enhancements

## Overview

This feature adds no new persistent data entities. All new image endpoints are synchronous — they invoke Bedrock, return results inline, and log spend to existing LiteLLM tables. Video prompt validation and auto-resize are request-time transformations with no storage.

## Existing Entities (modified interactions only)

### LiteLLM_SpendLogs (existing table — new writes)

Nova Canvas and Stability AI image operations write spend entries to this table using the same pattern as the video sidecar.

- `request_id`: UUID — unique per image operation
- `api_key`: hashed key
- `model`: model identifier (e.g., `nova-canvas-variation`, `stability-structure`)
- `spend`: decimal cost of the operation
- `startTime` / `endTime`: request timing
- `completionTokens` / `promptTokens`: 0 (not applicable for image operations)

### LiteLLM_VerificationToken (existing table — spend update)

Per-key spend counter incremented after each image operation, same as video sidecar pattern.

- `spend` column: incremented by operation cost
- Used for budget enforcement (pre-request check: estimated cost vs remaining budget)

## Request/Response Models (in-memory, not persisted)

### Prompt Validation Rule

| Field | Type | Description |
|-------|------|-------------|
| name | string | Rule identifier: `negation`, `camera-position`, `min-length` |
| scope | string | Model scope: `nova-reel` only |
| pattern | regex/function | Detection logic (word boundary matching for negation, clause-boundary parsing for camera) |
| error_template | string | HTTP 400 response message template with guidance |

### Resize Operation

| Field | Type | Description |
|-------|------|-------------|
| mode | enum | `scale` (default), `crop-center`, `crop-top`, `crop-bottom`, `fit` |
| target_width | int | Always 1280 |
| target_height | int | Always 720 |
| pad_color | enum | `black` (default), `white` — only used with `fit` mode |
| original_width | int | Source image width (returned in response metadata) |
| original_height | int | Source image height (returned in response metadata) |
| applied | bool | Whether resize was performed (false if already 1280x720) |

### Nova Canvas Image Request (variations / outpaint)

| Field | Type | Constraints | Notes |
|-------|------|-------------|-------|
| image / images | base64 string(s) | PNG/JPEG, no transparency | Raw base64, no format wrapper |
| prompt | string | 1-1024 chars | Required for variations and outpaint |
| similarity_strength | float | 0.2-1.0 | Variations only |
| seed | int | 0-2,147,483,646 | Optional |
| cfg_scale | float | 1.1-10.0, default 6.5 | Optional |
| n | int | 1-5 | Number of output images |
| width | int | 320-4096, divisible by 16 | Variations only (not outpaint) |
| height | int | 320-4096, divisible by 16 | Variations only (not outpaint) |
| quality | string | `standard` or `premium` | Affects pricing |
| outpainting_mode | string | `DEFAULT` or `PRECISE` | Outpaint only |
| mask_image | base64 string | Same dimensions as input | Outpaint only, mutually exclusive with mask_prompt |
| mask_prompt | string | Natural language | Outpaint only, mutually exclusive with mask_image |

### Stability AI Image Request (all services)

| Field | Type | Constraints | Notes |
|-------|------|-------------|-------|
| image | base64 string | PNG/JPEG/WebP, 64px min, 9.4MP max | All services except Style Transfer |
| init_image | base64 string | Same constraints | Style Transfer only (subject image) |
| style_image | base64 string | Same constraints | Style Transfer only (style reference) |
| prompt | string | 0-10,000 chars | Most services |
| search_prompt | string | 0-10,000 chars | Search and Replace only |
| negative_prompt | string | 0-10,000 chars | Optional, most services |
| control_strength | float | 0-1, default 0.7 | Structure, Sketch |
| fidelity | float | 0-1, default 0.5 | Style Guide |
| creativity | float | 0.1-0.5, default 0.35 | Conservative Upscale |
| composition_fidelity | float | 0-1, default 0.9 | Style Transfer |
| style_strength | float | 0-1, default 1 | Style Transfer |
| change_strength | float | 0.1-1, default 0.9 | Style Transfer |
| grow_mask | int | 0-20, default 5 | Search and Replace |
| seed | int | 0-4,294,967,294 | Optional, most services |
| output_format | string | `jpeg`, `png`, `webp`, default `png` | All services |
| style_preset | string | 17 options | Structure, Sketch, Search and Replace, Style Guide |
| aspect_ratio | string | 9 options | Style Guide only |

## Cost Calculation

### Nova Canvas

| Quality | Max Dimensions | Cost per Image |
|---------|---------------|----------------|
| Standard | up to 1024x1024 | $0.04 |
| Premium | up to 1024x1024 | $0.06 |
| Standard | up to 2048x2048 | $0.06 |
| Premium | up to 2048x2048 | $0.08 |

Total cost = cost_per_image * n (number of images requested)

### Stability AI

Estimated $0.04-0.08 per image depending on service. Exact pricing to be confirmed from AWS Bedrock pricing page and hardcoded per service.

## State Transitions

No state machines. All operations are request → response (synchronous, stateless). Failed Bedrock calls return errors immediately. No retry logic, no job tracking, no polling.
