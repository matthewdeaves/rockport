# Feature Specification: Image & Video Generation Enhancements

**Feature Branch**: `008-image-video-enhancements`
**Created**: 2026-03-17
**Status**: Draft
**Input**: User description: "Enhance Rockport's image and video generation proxy to help users get the best results from Bedrock models. Four areas: video prompt validation, auto-resize, Nova Canvas advanced task types, Stability AI image services."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Video Prompt Quality Guardrails (Priority: P1)

A user submits a video generation request to the Nova Reel model with a prompt containing negation words (e.g., "a knight walking forward, no sword visible"), camera keywords buried mid-prompt, or a prompt that is too short to produce good results. The sidecar detects the issue and rejects the request with a clear, actionable error message explaining what to fix and why, before any Bedrock cost is incurred.

**Why this priority**: This is the lowest-effort, highest-impact change. Every Nova Reel user benefits immediately. Prevents wasted spend on generations that will produce poor results due to known prompt pitfalls. Costs nothing to run (string matching only).

**Independent Test**: Can be fully tested by sending malformed prompts to the video sidecar and verifying rejection responses. Delivers value by preventing wasted Bedrock spend and educating users about Nova Reel prompt requirements.

**Acceptance Scenarios**:

1. **Given** a Nova Reel single-shot request, **When** the prompt contains "no", "not", "without", "don't", or "avoid" as whole words, **Then** the request is rejected with HTTP 400 and an error message explaining that Nova Reel interprets negation subjects as positive signals, with guidance to rephrase using only inclusions.
2. **Given** a Nova Reel single-shot request, **When** the prompt contains camera motion keywords (dolly, pan, tilt, track, orbit, zoom, following shot, static shot) before the final clause, **Then** the request is rejected with HTTP 400 and an error message explaining that camera keywords must be placed at the end of the prompt.
3. **Given** a Nova Reel single-shot request, **When** the prompt is fewer than 50 characters, **Then** the request is rejected with HTTP 400 explaining that short prompts give the model too much freedom, resulting in warping and morphing artefacts.
4. **Given** a Nova Reel multi-shot request, **When** any individual shot prompt triggers a validation rule, **Then** the request is rejected with HTTP 400, identifying which shot number failed and why.
5. **Given** a Luma Ray2 request with any of the above prompt patterns, **When** submitted, **Then** the request is accepted without prompt validation (these rules are Nova Reel-specific).
6. **Given** a Nova Reel request with a clean prompt (no negations, camera keywords at end, 50+ characters), **When** submitted, **Then** the request proceeds to Bedrock as normal with no additional latency.

---

### User Story 2 - Auto-resize Images for Nova Reel (Priority: P1)

A user submits a video generation request to Nova Reel with an image that is not exactly 1280x720 (e.g., 1920x1080 from a screenshot, or 512x512 from Nova Canvas). Instead of rejecting the request, the sidecar automatically scales the image to 1280x720 and proceeds, returning metadata about the transformation applied. The user can optionally specify a different resize strategy (crop variants or fit-with-padding).

**Why this priority**: The most common friction point in image-to-video workflows. Users frequently have images from other tools that aren't exactly 1280x720. Rejection forces a manual resize step that breaks workflow. This removes that friction entirely.

**Independent Test**: Can be fully tested by submitting images of various dimensions and verifying they are correctly resized before reaching Bedrock. Delivers value by eliminating the most common image-to-video error.

**Acceptance Scenarios**:

1. **Given** a Nova Reel request with a 1920x1080 PNG image and no resize_mode specified, **When** submitted, **Then** the image is scaled to 1280x720, the video generation proceeds, and the response includes metadata indicating the original dimensions and that scaling was applied.
2. **Given** a Nova Reel request with a 512x512 image and `resize_mode: "crop-center"`, **When** submitted, **Then** the image is upscaled and center-cropped to 1280x720.
3. **Given** a Nova Reel request with a 4000x3000 image and `resize_mode: "crop-top"`, **When** submitted, **Then** the image is downscaled and cropped from the top to 1280x720.
4. **Given** a Nova Reel request with a 1920x1080 image and `resize_mode: "fit"`, **When** submitted, **Then** the image is scaled to fit within 1280x720 maintaining aspect ratio, with remaining space padded in black (default). If `pad_color: "white"` is specified, padding is white.
5. **Given** a Nova Reel request with a 1280x720 image, **When** submitted, **Then** no resize is applied and the request proceeds as it does today.
6. **Given** a Nova Reel multi-shot request where individual shot images have different dimensions, **When** submitted, **Then** each shot image is independently resized using the specified or default mode.
7. **Given** a Nova Reel request with an image that is valid dimensions but exceeds 10MB after resize, **When** submitted, **Then** the request is rejected with a clear error about file size.

---

### User Story 3 - Nova Canvas Image Variation (Priority: P2)

A user wants to generate variations of an existing character image — same character in different poses, scenes, or angles — while controlling how closely the output matches the original. They submit a reference image and a text prompt to a new endpoint, along with a `similarity_strength` parameter (0.2 for creative freedom, 0.9 for tight fidelity), and receive one or more variant images back.

**Why this priority**: IMAGE_VARIATION with similarityStrength is the recommended way to generate character pose variants for animation storyboards. LiteLLM raises NotImplementedError for this task type, so this is the primary gap blocking the Canvas-to-Reel animation pipeline.

**Independent Test**: Can be fully tested by submitting a reference image with different similarity_strength values and verifying output images are returned. Delivers value by enabling character pose generation for animation workflows.

**Acceptance Scenarios**:

1. **Given** a valid API key with remaining budget, **When** a POST request is sent to `/v1/images/variations` with a reference image (data URI), text prompt, similarity_strength of 0.7, seed, and cfg_scale, **Then** the endpoint returns one or more base64-encoded images matching the requested parameters.
2. **Given** a request with `n: 3`, **When** submitted, **Then** three variant images are returned.
3. **Given** a request with similarity_strength outside 0.2-1.0 range, **When** submitted, **Then** the request is rejected with HTTP 400 and a clear error.
4. **Given** a request where the estimated cost exceeds the API key's remaining budget, **When** submitted, **Then** the request is rejected with HTTP 402.
5. **Given** a request with an invalid or revoked API key, **When** submitted, **Then** the request is rejected with HTTP 401.

---

### User Story 4 - Nova Canvas Background Removal (Priority: P2)

A user wants to isolate a character from its background for compositing — for example, extracting a character to overlay on a video or to place against a different background before submitting to Nova Reel. They submit an image and receive a PNG with transparency where the background has been removed.

**Why this priority**: Background removal is a common pre-processing step in animation workflows. Having it available through the same API avoids requiring external tools or direct Bedrock access.

**Independent Test**: Can be fully tested by submitting an image with a character on a background and verifying the output is a PNG with transparent background and preserved subject.

**Acceptance Scenarios**:

1. **Given** a valid API key with remaining budget, **When** a POST request is sent to `/v1/images/background-removal` with an image (data URI), **Then** the endpoint returns a base64-encoded PNG with the background removed (transparent alpha channel).
2. **Given** a request with an image that has no discernible foreground subject, **When** submitted, **Then** the endpoint returns a result (Bedrock handles this gracefully; the proxy does not pre-validate subject presence).
3. **Given** a request where the estimated cost exceeds the API key's remaining budget, **When** submitted, **Then** the request is rejected with HTTP 402.

---

### User Story 5 - Nova Canvas Outpainting (Priority: P2)

A user has a character image that is too small or has the wrong aspect ratio for Nova Reel (which requires 1280x720). They want to extend the image — adding more background around the character — without distorting the original content. They submit the image with a mask (or mask prompt describing what to preserve) and a text prompt describing what the extended area should look like.

**Why this priority**: Outpainting is the intelligent alternative to simple scaling — it preserves the original character at full fidelity while generating new background content to fill the 1280x720 frame. Important for maintaining character quality in the Canvas-to-Reel pipeline.

**Independent Test**: Can be fully tested by submitting a small character image with a prompt describing the surrounding scene and verifying the output extends the image coherently.

**Acceptance Scenarios**:

1. **Given** a valid API key with remaining budget, **When** a POST request is sent to `/v1/images/outpaint` with a source image, a text prompt describing the extended area, and `outpainting_mode: "PRECISE"`, **Then** the endpoint returns a base64-encoded image with the original content preserved and surrounding area filled per the prompt.
2. **Given** a request with a `mask_prompt` (e.g., "the knight character") instead of a `mask_image`, **When** submitted, **Then** the system uses Nova Canvas's mask prompt feature to automatically identify and preserve the described subject.
3. **Given** a request with an explicit `mask_image` (base64 data URI), **When** submitted, **Then** the white areas of the mask are filled with generated content while black areas are preserved.
4. **Given** a request where neither `mask_image` nor `mask_prompt` is provided, **When** submitted, **Then** the request is rejected with HTTP 400 explaining that one of the two is required.

---

### User Story 6 - Stability AI Structure Control (Priority: P3)

A user wants to generate an image that preserves the structural skeleton and pose of a reference image while applying a different visual style. They submit a control image and a text prompt describing the desired style, and receive an image that follows the spatial layout of the reference.

**Why this priority**: Structure control is the Stability AI equivalent of Nova Canvas CANNY_EDGE, useful for generating pose variants. Lower priority because CANNY_EDGE already works through LiteLLM, but Stability AI's version may produce different/better results for some use cases.

**Independent Test**: Can be fully tested by submitting a character pose image with a style prompt and verifying the output maintains the pose while changing the visual style.

**Acceptance Scenarios**:

1. **Given** a valid API key, **When** a POST request is sent to `/v1/images/structure` with a control image, text prompt, and control_strength (0.0-1.0), **Then** the endpoint returns a base64-encoded image that follows the structural layout of the control image while matching the text prompt's style description.
2. **Given** a request with control_strength of 1.0, **When** submitted, **Then** the output closely follows the input structure with minimal creative deviation.
3. **Given** a request with control_strength of 0.2, **When** submitted, **Then** the output takes more creative liberties while loosely following the input structure.

---

### User Story 7 - Stability AI Sketch-to-Image (Priority: P3)

A user has a rough sketch of a character or scene and wants to generate a polished image from it. They submit the sketch and a text prompt describing the desired output.

**Why this priority**: Useful for early-stage character design and prototyping before the animation pipeline. Lower priority because it's a convenience feature rather than a gap-filler.

**Independent Test**: Can be fully tested by submitting a rough sketch with a descriptive prompt and verifying a polished image is returned.

**Acceptance Scenarios**:

1. **Given** a valid API key, **When** a POST request is sent to `/v1/images/sketch` with a sketch image, text prompt, and control_strength, **Then** the endpoint returns a polished image based on the sketch and prompt.

---

### User Story 8 - Stability AI Style Transfer (Priority: P3)

A user wants to apply the visual style of one image (e.g., a specific game's art style) to generate new images. They submit a style reference image and a text prompt.

**Why this priority**: Enables consistent art style across multiple character or scene images, important for professional animation pipelines.

**Independent Test**: Can be fully tested by submitting a style reference image with a content prompt and verifying the output matches the style.

**Acceptance Scenarios**:

1. **Given** a valid API key, **When** a POST request is sent to `/v1/images/style-transfer` with a style image and text prompt, **Then** the endpoint returns an image in the style of the reference image with the content described by the prompt.

---

### User Story 9 - Stability AI Background Removal (Priority: P3)

A user wants to remove the background from an image using Stability AI's model (as an alternative to Nova Canvas background removal). They submit an image and receive a PNG with transparency.

**Why this priority**: Provides an alternative to Nova Canvas background removal. Users may prefer one model's results over the other depending on the image.

**Independent Test**: Can be fully tested by submitting an image and verifying the background is removed.

**Acceptance Scenarios**:

1. **Given** a valid API key, **When** a POST request is sent to `/v1/images/remove-background` with an image, **Then** the endpoint returns a PNG with the background removed.

---

### User Story 10 - Stability AI Search and Replace (Priority: P3)

A user wants to find and replace specific elements in an image — for example, swapping a character's weapon or changing their armour colour — without regenerating the entire image.

**Why this priority**: Useful for iterating on character designs without starting from scratch.

**Independent Test**: Can be fully tested by submitting an image with a search prompt and replacement prompt and verifying the targeted element is changed.

**Acceptance Scenarios**:

1. **Given** a valid API key, **When** a POST request is sent to `/v1/images/search-replace` with an image, search_prompt, and replacement prompt, **Then** the endpoint returns an image with the matched element replaced.

---

### User Story 11 - Stability AI Conservative Upscale (Priority: P3)

A user wants to upscale an image to a higher resolution (e.g., to meet Nova Reel's 1280x720 requirement) without introducing AI artefacts. They submit an image and a prompt describing the content (for quality guidance).

**Why this priority**: Conservative upscale is higher quality than simple Pillow resize for images that need to be enlarged. Useful when the auto-resize default (scale) would produce blurry results from small source images.

**Independent Test**: Can be fully tested by submitting a small image and verifying the output is a larger, clean image.

**Acceptance Scenarios**:

1. **Given** a valid API key, **When** a POST request is sent to `/v1/images/upscale` with a small image and descriptive prompt, **Then** the endpoint returns a higher-resolution image with preserved detail.

---

### User Story 12 - Stability AI Style Guide (Priority: P3)

A user wants to generate multiple images that all share the same visual style, maintaining consistency across a set of character poses or scene frames for an animation storyboard.

**Why this priority**: Style consistency across storyboard frames is important for professional animation pipelines. This provides an alternative to seed-based consistency with Nova Canvas.

**Independent Test**: Can be fully tested by submitting a style reference with multiple prompts and verifying consistent style across outputs.

**Acceptance Scenarios**:

1. **Given** a valid API key, **When** a POST request is sent to `/v1/images/style-guide` with a style reference image and text prompt, **Then** the endpoint returns an image that matches the reference style.

---

### Edge Cases

- What happens when a Nova Reel prompt contains a legitimate use of "not" within a proper noun or compound word (e.g., "Nottingham", "knotted rope")? The negation detector must avoid false positives on substrings.
- What happens when an image is exactly 1x1 pixel? The auto-resize should still apply but the result will be a solid-colour 1280x720 frame.
- What happens when a user submits a WebP or GIF image to a Nova Canvas endpoint? The format must be validated and rejected with a clear error (PNG/JPEG only).
- What happens when the Stability AI Marketplace subscription hasn't been activated? The endpoint should return a clear error from Bedrock rather than a generic 500.
- What happens when the us-east-1 or us-west-2 Bedrock endpoint is experiencing throttling? Rate limit errors from Bedrock should be surfaced to the client.
- What happens when both `mask_image` and `mask_prompt` are provided to the outpainting endpoint? One must take precedence (mask_image) or the request should be rejected.
- What happens when the sidecar receives a request for `/v1/images/generations` (which should route to LiteLLM on port 4000, not the sidecar)? The tunnel routing must ensure this path never reaches the sidecar.

## Clarifications

### Session 2026-03-17

- Q: Should `--claude-only` keys be blocked from the new image service endpoints (Nova Canvas and Stability AI)? → A: Yes, block `--claude-only` keys from all new image endpoints. These use Amazon and Stability AI models, not Anthropic models.
- Q: How should "final clause" be defined for camera keyword positioning validation? → A: After the last comma or period (clause boundary). Camera keywords are valid only if they appear after the last comma or period in the prompt.

## Requirements *(mandatory)*

### Functional Requirements

**Video Prompt Validation**

- **FR-001**: System MUST reject Nova Reel prompts containing negation words ("no", "not", "without", "don't", "avoid") as whole words, with an HTTP 400 response explaining that Nova Reel interprets negation subjects as positive signals.
- **FR-002**: System MUST reject Nova Reel prompts where camera motion keywords (dolly, pan, tilt, track, orbit, zoom, following shot, static shot) appear before the final clause of the prompt (defined as: after the last comma or period), with HTTP 400 guidance to move them to the end.
- **FR-003**: System MUST reject Nova Reel prompts shorter than 50 characters with HTTP 400 explaining that short prompts produce poor results.
- **FR-004**: System MUST apply prompt validation to each individual shot prompt in multi-shot Nova Reel requests, identifying the failing shot number in the error response.
- **FR-005**: System MUST NOT apply prompt validation rules to Luma Ray2 requests.
- **FR-006**: System MUST avoid false positives on negation detection — words like "Nottingham", "knotted", "another" that contain negation substrings must not trigger rejection.

**Auto-resize**

- **FR-007**: System MUST automatically scale images to 1280x720 by default when they are not exactly 1280x720, rather than rejecting them.
- **FR-008**: System MUST support a `resize_mode` parameter with values: `scale` (default), `crop-center`, `crop-top`, `crop-bottom`, and `fit`.
- **FR-009**: System MUST support a `pad_color` parameter (for `fit` mode) accepting `black` (default) or `white`.
- **FR-010**: System MUST include resize metadata in the response (original dimensions, resize mode applied) when an image was resized.
- **FR-011**: System MUST validate image format (PNG/JPEG) and file size (10MB max) after resize, and reject if either fails.
- **FR-012**: System MUST still validate opacity requirements (no transparent pixels) after resize.
- **FR-013**: System MUST apply auto-resize independently to each shot image in multi-shot requests.

**Nova Canvas Endpoints**

- **FR-014**: System MUST provide a `/v1/images/variations` endpoint that invokes Nova Canvas IMAGE_VARIATION with configurable `similarity_strength` (0.2-1.0), `seed`, `cfg_scale`, and `n` (number of images).
- **FR-015**: System MUST provide a `/v1/images/background-removal` endpoint that invokes Nova Canvas BACKGROUND_REMOVAL and returns a PNG with transparency.
- **FR-016**: System MUST provide a `/v1/images/outpaint` endpoint that invokes Nova Canvas OUTPAINTING with configurable `outpainting_mode` (DEFAULT/PRECISE) and either `mask_image` or `mask_prompt`.
- **FR-017**: All Nova Canvas endpoints MUST authenticate requests using the existing LiteLLM `/key/info` mechanism.
- **FR-018**: All Nova Canvas endpoints MUST track spend in LiteLLM_SpendLogs and LiteLLM_VerificationToken tables.
- **FR-019**: All Nova Canvas endpoints MUST enforce budget limits, rejecting requests with HTTP 402 when estimated cost exceeds remaining budget.

**Stability AI Endpoints**

- **FR-020**: System MUST provide `/v1/images/structure`, `/v1/images/sketch`, `/v1/images/style-transfer`, `/v1/images/remove-background`, `/v1/images/search-replace`, `/v1/images/upscale`, and `/v1/images/style-guide` endpoints.
- **FR-021**: All Stability AI endpoints MUST authenticate and track spend using the same mechanism as Nova Canvas endpoints.
- **FR-022**: All Stability AI endpoints MUST use the us-west-2 Bedrock client.
- **FR-022a**: All new image endpoints (Nova Canvas and Stability AI) MUST reject requests from keys created with `--claude-only`, returning HTTP 403 with a clear error explaining these endpoints require unrestricted keys.

**Infrastructure**

- **FR-023**: The Cloudflare WAF MUST allowlist all new image endpoint paths.
- **FR-024**: The Cloudflare Tunnel MUST route new `/v1/images/*` paths (except `/v1/images/generations`) to the sidecar on port 4001.
- **FR-025**: The IAM policy MUST include Bedrock invoke permissions for Stability AI model IDs in us-west-2.
- **FR-026**: Smoke tests MUST cover at least one request per new endpoint category (prompt validation, auto-resize, Nova Canvas, Stability AI).

### Key Entities

- **Prompt Validation Rule**: A named check (negation, camera-position, min-length) with a pattern, a scope (Nova Reel only), and an error message template.
- **Resize Operation**: A transformation applied to an input image, defined by mode (scale/crop-center/crop-top/crop-bottom/fit), target dimensions (1280x720), and optional pad colour.
- **Image Service Request**: A synchronous Bedrock invocation with an input image, task-specific parameters, authentication context, and spend tracking. Unlike video jobs (async with polling), image service requests return results in the HTTP response body.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of Nova Reel prompts containing negation words, misplaced camera keywords, or fewer than 50 characters are rejected before reaching Bedrock, with zero Bedrock spend incurred on invalid prompts.
- **SC-002**: Users can submit images of any reasonable dimension (up to source model limits) for Nova Reel video generation without manual pre-processing, with the system automatically producing a 1280x720 input image.
- **SC-003**: All three Nova Canvas advanced operations (variation, background removal, outpainting) are accessible through the proxy with the same authentication and spend tracking as existing endpoints.
- **SC-004**: All seven Stability AI image services are accessible through the proxy with authentication and spend tracking.
- **SC-005**: No existing functionality (LiteLLM image generation, video generation, chat) is affected by the new endpoints.
- **SC-006**: Every new endpoint returns clear, actionable error messages for invalid inputs — a user can fix their request based solely on the error response without consulting documentation.
- **SC-007**: Spend from all new image endpoints is visible in the unified spend tracking (`rockport.sh spend` commands) alongside chat and video spend.

## Assumptions

- Nova Canvas pricing for IMAGE_VARIATION, BACKGROUND_REMOVAL, and OUTPAINTING follows the same per-image pricing as TEXT_IMAGE generation. Exact costs will be confirmed during implementation and hardcoded in the sidecar's cost calculation.
- Stability AI image service model IDs and API shapes are stable on Bedrock and match current documentation. If any service is not yet available or has a different API shape, it will be noted during implementation and deferred.
- The existing sidecar's 256MB MemoryMax is sufficient for synchronous image processing. If Pillow operations on large images (e.g., 4096x4096 for Stability AI) cause OOM, the limit will need to be increased.
- Camera keyword detection defines "final clause" as the text after the last comma or period in the prompt. Camera keywords appearing anywhere before that boundary trigger rejection.
- The negation word detector uses whole-word matching with word boundary detection to avoid false positives on substrings.
- Stability AI models require a one-time Marketplace subscription activation (same pattern as SD3.5 Large). This is a manual prerequisite, not automated by the proxy.

## Out of Scope

- Nova Lite prompt rewriting (excluded — adds latency, cost, and LLM dependency to the video endpoint).
- Pipeline orchestration (Canvas-to-Reel in one call) — deferred to a future feature. Will be documented in a future ideas file.
- Changes to the existing LiteLLM image generation passthrough (`/v1/images/generations` on port 4000).
- Changes to existing video generation endpoint behaviour (except adding prompt validation).
- Fine-tuning Nova Canvas models (documented in the prompting guide but out of scope for the proxy).
