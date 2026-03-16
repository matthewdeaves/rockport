# Feature Specification: Fix Image-to-Video Support

**Feature Branch**: `005-fix-image-to-video`
**Created**: 2026-03-16
**Status**: Draft
**Input**: User description: "Fix image-to-video support in the video generation sidecar. The sidecar already has partial scaffolding for image input but the Bedrock API field names are wrong."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Single-Shot Image Animation (Priority: P1)

A user submits a 1280x720 image with a text prompt to animate it into a 6-second video. The sidecar sends the correct Bedrock API payload, the job completes, and the user receives a presigned URL to the resulting MP4.

**Why this priority**: This is the core use case — animating a static image is the primary reason users want image-to-video. Single-shot is the simplest mode and the most common workflow.

**Independent Test**: Can be tested by sending a POST to `/v1/videos/generations` with a `prompt`, `image` (data URI), and verifying the Bedrock request body contains `images` (array) with proper `{format, source: {bytes}}` structure.

**Acceptance Scenarios**:

1. **Given** a valid 1280x720 PNG image as a data URI and a text prompt, **When** the user submits a single-shot video request, **Then** the sidecar sends a Bedrock `TEXT_VIDEO` request with `textToVideoParams.images` as an array of `{format: "png", source: {bytes: "<raw-base64>"}}` and the job is created successfully.
2. **Given** a valid 1280x720 JPEG image as a data URI and a text prompt, **When** the user submits a single-shot video request, **Then** the sidecar correctly identifies the format as `"jpeg"` and sends it in the proper structure.
3. **Given** a single-shot request with an image, **When** no explicit duration is provided, **Then** the duration defaults to 6 seconds.
4. **Given** a single-shot request with an image, **When** a duration other than 6 is provided, **Then** the request is rejected with a clear error message explaining that image-conditioned single-shot videos are fixed at 6 seconds.

---

### User Story 2 - Multi-Shot Image Animation (Priority: P2)

A user submits a multi-shot request where one or more shots include reference images. The sidecar uses the correct `MULTI_SHOT_MANUAL` task type and formats each shot's image correctly.

**Why this priority**: Multi-shot with images enables storyboarding with visual keyframes — a powerful creative workflow, but less common than simple single-shot animation.

**Independent Test**: Can be tested by sending a POST with `shots` array where some shots have images, and verifying the Bedrock request uses `MULTI_SHOT_MANUAL` taskType with `multiShotManualParams` and per-shot `image` objects.

**Acceptance Scenarios**:

1. **Given** a multi-shot request with 3 shots where shot 2 has a PNG image, **When** submitted, **Then** the sidecar sends a `MULTI_SHOT_MANUAL` request with `multiShotManualParams.shots` where shot 2 has `image: {format: "png", source: {bytes: "<raw-base64>"}}`.
2. **Given** a multi-shot request with images on multiple shots, **When** submitted, **Then** each shot's image is independently validated (1280x720, PNG/JPEG) and correctly formatted.
3. **Given** a multi-shot request with no images on any shot, **When** submitted, **Then** the sidecar still uses `MULTI_SHOT_MANUAL` taskType with text-only shots.

---

### User Story 3 - Image Validation and Error Handling (Priority: P2)

Users who submit invalid images (wrong size, wrong format, too large, malformed data URI) receive clear, actionable error messages before any Bedrock API call is made.

**Why this priority**: Good error messages prevent wasted time and confusion. Since images must meet strict requirements (1280x720, PNG/JPEG, no transparency), users need clear feedback.

**Independent Test**: Can be tested by sending requests with various invalid images and verifying appropriate 400-status error responses.

**Acceptance Scenarios**:

1. **Given** an image that is not 1280x720, **When** submitted, **Then** the request is rejected with an error stating the required dimensions.
2. **Given** an image in an unsupported format (e.g., GIF, WebP), **When** submitted, **Then** the request is rejected with an error listing supported formats.
3. **Given** a malformed data URI (missing prefix, invalid base64), **When** submitted, **Then** the request is rejected with a descriptive error.
4. **Given** a PNG with an alpha channel where all pixels are fully opaque, **When** submitted, **Then** the alpha channel is silently stripped and the request proceeds normally.
5. **Given** a PNG with actual transparent or translucent pixels, **When** submitted, **Then** the request is rejected with an error explaining that transparent images are not supported.

---

### Edge Cases

- What happens when a user sends an image with a single-shot request and duration > 6? The request must be rejected with a clear error.
- What happens when a multi-shot request has 1 shot? Already rejected (existing 2-20 validation).
- What happens when the data URI uses an unexpected MIME type like `data:image/webp;base64,...`? Should be rejected during image format check.
- What happens when a multi-shot request mixes shots with and without images? This is valid and should work correctly.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST send single-shot image requests using `textToVideoParams.images` as an array of `{format, source: {bytes}}` objects.
- **FR-002**: System MUST send multi-shot requests using taskType `MULTI_SHOT_MANUAL` with `multiShotManualParams.shots`, formatting per-shot images as `image: {format, source: {bytes}}` objects.
- **FR-003**: System MUST strip data URI headers and extract the format string (`png` or `jpeg`) before sending raw base64 bytes to Bedrock.
- **FR-004**: System MUST enforce duration of exactly 6 seconds when a single-shot request includes an image.
- **FR-005**: System MUST check PNG images for alpha channels: if all pixels are fully opaque (alpha=255), strip the alpha channel and proceed; if any pixel has transparency or translucency, reject with a descriptive error. Per AWS Nova Reel docs: "PNG images may contain an additional alpha channel, but that channel must not contain any transparent or translucent pixels."
- **FR-006**: System MUST accept both PNG and JPEG images at exactly 1280x720 resolution. *(Pre-satisfied by existing `validate_image()` — no new code needed.)*
- **FR-007**: System MUST continue to support text-only single-shot requests (6-120s) and text-only multi-shot requests (2-20 shots) without regression. *(Verified at each checkpoint — no dedicated task needed.)*

### Key Entities

- **Image Payload**: A base64-encoded image submitted as a data URI, validated for format (PNG/JPEG), dimensions (1280x720), and transparency, then converted to Bedrock's `{format, source: {bytes}}` structure.
- **Task Type**: Bedrock discriminator — `TEXT_VIDEO` for single-shot (text-only or with image), `MULTI_SHOT_MANUAL` for multi-shot (with or without images).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Single-shot image-to-video requests produce a valid 6-second MP4 video from Bedrock without errors.
- **SC-002**: Multi-shot requests with per-shot images produce the expected multi-scene video with visual continuity from reference images.
- **SC-003**: All existing text-only video generation workflows continue to work without modification.
- **SC-004**: Invalid image submissions (wrong size, wrong format, transparency, malformed) are rejected with descriptive errors before any Bedrock API call is made.
- **SC-005**: Duration validation correctly prevents users from requesting >6s single-shot videos with images, providing a clear error message.

## Clarifications

### Session 2026-03-16

- Q: Should PNGs with alpha channels but fully opaque pixels be rejected or stripped? → A: Strip alpha if fully opaque, reject only if any pixel has actual transparency (Option B). AWS docs confirm alpha channels are allowed if all pixels are opaque.
- Q: Should the existing 10MB file size limit be raised to match AWS's 25MB limit? → A: Keep existing 10MB limit. Images are sent inline as base64, so smaller limit keeps request payloads manageable.

## Assumptions

- Users will provide images as data URIs in the existing `image` field on requests and shots (no change to the API contract for callers).
- The existing `validate_image` function's Pillow-based checks for format, dimensions, and file size (10MB) are correct and only need augmentation for alpha channel handling (strip if opaque, reject if transparent).
- No database schema changes are needed — the existing job tracking and spend logging work for image-to-video jobs identically to text-only jobs.
- S3 output handling and presigned URL generation are unaffected — Bedrock produces the same output structure regardless of whether an image was provided.
