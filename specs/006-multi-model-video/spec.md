# Feature Specification: Multi-Model Video Generation

**Feature Branch**: `006-multi-model-video`
**Created**: 2026-03-16
**Status**: Draft
**Input**: Extend video sidecar to support multiple Bedrock video models (Nova Reel + Luma Ray2)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Choose a Video Model (Priority: P1)

A user submits a video generation request and specifies which model to use via a `model` parameter. If omitted, the system defaults to Nova Reel. The user can choose Luma Ray2 for different creative styles, aspect ratios, or resolution options.

**Why this priority**: Core feature — without model selection, there's no multi-model support.

**Independent Test**: Submit a video request with `"model": "luma-ray2"` and verify it routes to Ray2; submit without `model` and verify it defaults to Nova Reel.

**Acceptance Scenarios**:

1. **Given** a valid API key, **When** I submit a video request with `"model": "luma-ray2"`, **Then** the job is created using Luma Ray2 and returns 202 with the model name in the response.
2. **Given** a valid API key, **When** I submit a video request with no `model` field, **Then** the job defaults to Nova Reel (backward compatible).
3. **Given** a valid API key, **When** I submit a video request with `"model": "nova-reel"`, **Then** the job uses Nova Reel explicitly.
4. **Given** a valid API key, **When** I submit with `"model": "nonexistent-model"`, **Then** the system returns a 400 error listing available video models.

---

### User Story 2 - Ray2 Text-to-Video with Aspect Ratio and Resolution Options (Priority: P1)

A user generates a video with Luma Ray2, choosing from multiple aspect ratios (16:9, 9:16, 1:1, 4:3, 3:4, 21:9, 9:21) and resolutions (540p, 720p), with 5s or 9s duration. This gives creative flexibility not available with Nova Reel's fixed 1280x720 16:9 output.

**Why this priority**: Ray2's differentiating features — without aspect ratio and resolution support, there's little reason to add it.

**Independent Test**: Submit a Ray2 text-to-video request with various aspect ratios and resolutions, verify the output matches.

**Acceptance Scenarios**:

1. **Given** a valid API key, **When** I submit `"model": "luma-ray2", "prompt": "...", "duration": 5, "aspect_ratio": "9:16", "resolution": "720p"`, **Then** a portrait video job is created.
2. **Given** a valid API key, **When** I submit a Ray2 request with `"duration": 12`, **Then** the system returns 400 because Ray2 only supports 5 or 9 seconds.
3. **Given** a valid API key, **When** I submit a Ray2 request with `"aspect_ratio": "2:1"`, **Then** the system returns 400 listing valid aspect ratios.
4. **Given** a valid API key, **When** I submit a Ray2 request without `aspect_ratio` or `resolution`, **Then** sensible defaults are applied (16:9, 720p).

---

### User Story 3 - Ray2 Image-to-Video (Priority: P2)

A user provides a reference image (start frame) when creating a Ray2 video. Ray2 also supports an optional end frame, allowing interpolation between two images.

**Why this priority**: Image-to-video is a secondary mode. Text-to-video is the primary use case.

**Independent Test**: Submit a Ray2 request with an `image` field containing a valid image data URI, verify the job is created.

**Acceptance Scenarios**:

1. **Given** a valid API key and a JPEG image, **When** I submit a Ray2 request with an `image` field, **Then** the image is used as the start frame.
2. **Given** a valid API key and two images, **When** I submit a Ray2 request with `image` (start) and `end_image` (end), **Then** both are used as keyframes.
3. **Given** a valid API key, **When** I submit a Ray2 request with an image smaller than 512x512, **Then** the system returns 400 with a dimension error.
4. **Given** a valid API key, **When** I submit a Ray2 request with an image larger than 25MB, **Then** the system returns 400 with a size error.

---

### User Story 4 - Model-Aware Cost Tracking and Budget Enforcement (Priority: P1)

Video costs vary dramatically between models ($0.08/s for Nova Reel vs $0.75-1.50/s for Ray2). The budget check must use the correct per-model, per-resolution cost so users aren't surprised and budget limits work correctly.

**Why this priority**: Without correct cost tracking, budget enforcement is broken and spend reporting is wrong.

**Independent Test**: Submit a Ray2 720p 5s request with a key that has $5 remaining budget. Verify it's rejected (cost would be $7.50). Then submit a Nova Reel 6s request with the same key. Verify it's accepted ($0.48).

**Acceptance Scenarios**:

1. **Given** a key with $5 remaining budget, **When** I submit a Ray2 720p 5s request (cost $7.50), **Then** the system returns 402 with the estimated cost and remaining budget.
2. **Given** a key with $5 remaining budget, **When** I submit a Ray2 540p 5s request (cost $3.75), **Then** the job is accepted.
3. **Given** a completed Ray2 job, **When** I check spend via the CLI, **Then** the correct Ray2 cost is reflected in the spend totals.

---

### User Story 5 - List Available Video Models (Priority: P2)

A user can query which video models are available and their status. The health endpoint reports per-model Bedrock reachability.

**Why this priority**: Discoverability — users need to know what's available. Not needed for core functionality.

**Independent Test**: Call the health endpoint and verify both models appear with their status.

**Acceptance Scenarios**:

1. **Given** a valid API key, **When** I call the video health endpoint, **Then** the response includes status for each video model (Nova Reel and Ray2).
2. **Given** Ray2 is not activated (no Marketplace subscription), **When** I call health, **Then** Ray2 shows as unavailable while Nova Reel shows as healthy.

---

### Edge Cases

- What happens when a user submits multi-shot mode with Ray2? (Return 400 — Ray2 doesn't support multi-shot)
- What happens when Ray2 Marketplace subscription hasn't been activated? (Return 400 explaining the model requires activation)
- What happens when a user submits a `seed` parameter with Ray2? (Ignore it — Ray2 doesn't support seeds)
- What happens when a user submits Nova Reel request with Ray2-only parameters like `aspect_ratio`? (Ignore unknown parameters for the selected model)
- What happens when the `loop` parameter is used with Nova Reel? (Ignore it — only Ray2 supports loop)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST accept an optional `model` field on `POST /v1/videos/generations` with values `nova-reel` (default) and `luma-ray2`.
- **FR-002**: System MUST validate request parameters against the selected model's constraints (duration, resolution, aspect ratio, image dimensions).
- **FR-003**: System MUST route requests to the correct Bedrock region (us-east-1 for Nova Reel, us-west-2 for Ray2).
- **FR-004**: System MUST calculate costs using the correct per-model pricing (Nova Reel: $0.08/s; Ray2: $0.75/s at 540p, $1.50/s at 720p).
- **FR-005**: System MUST enforce budget limits using model-specific cost estimates before submitting to Bedrock.
- **FR-006**: System MUST store the model name in the video jobs table and include it in all API responses (list, poll, submit).
- **FR-007**: System MUST support Ray2 text-to-video with configurable aspect ratio (16:9, 9:16, 1:1, 4:3, 3:4, 21:9, 9:21), resolution (540p, 720p), and duration (5s, 9s).
- **FR-008**: System MUST support Ray2 image-to-video with a start frame image, and optionally an end frame image.
- **FR-009**: System MUST reject multi-shot requests when the selected model is Ray2 (multi-shot is Nova Reel only).
- **FR-010**: System MUST return a 400 error with available models when an unknown model is specified.
- **FR-011**: System MUST report per-model health status on the video health endpoint.
- **FR-012**: System MUST validate Ray2 images are between 512x512 and 4096x4096 pixels and under 25MB.
- **FR-013**: System MUST support the `loop` parameter for Ray2 requests (ignored for Nova Reel).
- **FR-014**: All existing Nova Reel functionality (single-shot, multi-shot, image-to-video, seed, concurrent limits) MUST continue to work unchanged.
- **FR-015**: System MUST provision a second S3 bucket in us-west-2 for Ray2 output, with identical security to the existing us-east-1 bucket (encryption, public access block, DenyNonSSL policy, 7-day lifecycle).
- **FR-016**: System MUST grant the EC2 instance role async invoke permissions for us-west-2 and S3 access to the new bucket.

### Key Entities

- **Video Model**: A supported video generation model with its ID, region, constraints (durations, resolutions, aspect ratios), pricing, and image requirements.
- **Video Job**: Extended with a `model` field identifying which model was used. All other fields remain the same.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can generate videos with both Nova Reel and Luma Ray2 through the same API endpoint.
- **SC-002**: Existing Nova Reel requests (without a `model` field) continue to work identically — full backward compatibility.
- **SC-003**: Budget enforcement correctly rejects Ray2 requests that would exceed the key's remaining budget at Ray2 pricing.
- **SC-004**: Spend tracking accurately reflects per-model costs in the CLI spend reports.
- **SC-005**: The health endpoint reports reachability for each video model independently.
- **SC-006**: All 18 existing smoke tests continue to pass without modification.
- **SC-007**: New smoke tests cover Ray2 text-to-video submission and model selection.

## Assumptions

- Luma Ray2 Marketplace subscription will be activated manually before first use (same pattern as SD3.5 Large for images).
- Ray2 defaults to 16:9 aspect ratio and 720p resolution when not specified.
- The concurrent job limit (default 3) applies across all models per key, not per-model.
- Ray2's significantly higher cost ($0.75-1.50/s vs $0.08/s) is acceptable and will be clearly visible in cost estimates and spend tracking.
- Bedrock async invoke requires the S3 output bucket to be in the same region as the model. A second S3 bucket in us-west-2 is needed for Ray2 output, with identical security configuration (SSE-S3, public access blocked, DenyNonSSL policy, 7-day lifecycle).

## Clarifications

### Session 2026-03-16

- Q: Can Ray2 (us-west-2) write to the existing us-east-1 S3 bucket? → A: No. Bedrock requires same-region S3 buckets. Create a second bucket in us-west-2 with identical security (SSE-S3, public access blocked, DenyNonSSL policy, 7-day lifecycle).
- Q: Should default per-key budget ($5/day) be raised for Ray2's higher costs? → A: No. Keep $5/day default. Users who want Ray2 can create keys with higher budgets. Clear cost estimates in 402 rejections are sufficient.
- Q: Should Ray2 require explicit opt-in per key? → A: No. All keys can use Ray2 by default. Budget enforcement is the guardrail.
