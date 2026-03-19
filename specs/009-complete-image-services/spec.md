# Feature Specification: Complete Image Services

**Feature Branch**: `009-complete-image-services`
**Created**: 2026-03-19
**Status**: Draft
**Input**: Add all missing Stability AI image services, new base models, Nova Canvas style presets, and automated multi-shot video to Rockport

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Edit Generated Images with Inpainting and Erasing (Priority: P1)

A user generates a character image and wants to fix artifacts or replace specific regions. They use the inpaint endpoint to mask an area and describe what should replace it, or the erase endpoint to cleanly remove an unwanted object from the image.

**Why this priority**: Inpainting and erasing are the most requested image editing operations and directly support the sprite generation pipeline — fixing inconsistencies between animation frames.

**Independent Test**: Can be fully tested by sending an image with a mask to `/v1/images/inpaint` and verifying the masked region is replaced according to the prompt. Erase can be tested by sending an image with a mask and verifying the object is removed cleanly.

**Acceptance Scenarios**:

1. **Given** a valid API key and an image with a mask image, **When** I POST to `/v1/images/inpaint` with a prompt describing the replacement, **Then** I receive an image where the masked region has been replaced according to the prompt.
2. **Given** a valid API key and an image with a mask, **When** I POST to `/v1/images/erase`, **Then** I receive an image where the masked region has been cleanly removed.
3. **Given** a `--claude-only` restricted key, **When** I call either endpoint, **Then** I receive a 403 error.
4. **Given** a key that has exceeded its budget, **When** I call either endpoint, **Then** I receive a 402 error.

---

### User Story 2 - Upscale Images at Different Quality Tiers (Priority: P1)

A user has a generated image and wants to upscale it before further processing. They can choose creative upscale (high quality, up to 4K, with prompt guidance) or fast upscale (quick 4x, no prompt needed). The existing conservative upscale remains available.

**Why this priority**: Upscaling is critical for the sprite pipeline — generating at 512x512 then upscaling before pixel art conversion gives more detail to work with.

**Independent Test**: Can be tested by sending a small image to `/v1/images/creative-upscale` with a prompt and verifying the output is significantly larger. Fast upscale tested by sending an image to `/v1/images/fast-upscale` and verifying 4x resolution increase.

**Acceptance Scenarios**:

1. **Given** a valid API key and a small image (under 1 megapixel), **When** I POST to `/v1/images/creative-upscale` with a prompt, **Then** I receive a high-resolution image up to 4K.
2. **Given** a valid API key and a small image (32-1536px per side), **When** I POST to `/v1/images/fast-upscale`, **Then** I receive an image at 4x the input resolution.
3. **Given** an image exceeding the maximum input size for creative upscale, **When** I call the endpoint, **Then** I receive a clear validation error with the size limit.

---

### User Story 3 - Recolour and Replace Objects in Images (Priority: P2)

A user wants to change the colour of a specific object in an image without regenerating the entire image. They use search-and-recolor to find and recolour objects by description.

**Why this priority**: Recolouring supports creating character variations (different team colours, equipment tints) from a single base generation.

**Independent Test**: Can be tested by sending an image with a select_prompt identifying the object and a prompt describing the desired colour, then verifying the targeted object changes colour.

**Acceptance Scenarios**:

1. **Given** a valid API key, an image, a select_prompt ("the armor"), and a prompt ("bright blue armor"), **When** I POST to `/v1/images/search-recolor`, **Then** I receive an image where the identified object's colour has changed.
2. **Given** missing required parameters (no select_prompt), **When** I call the endpoint, **Then** I receive a validation error.

---

### User Story 4 - Extend Images with Stability Outpainting (Priority: P2)

A user wants to extend an image beyond its original borders. They specify pixel amounts to extend in each direction (left, right, up, down).

**Why this priority**: Complements the existing Nova Canvas outpaint with a different model and approach (directional pixel extensions vs mask-based).

**Independent Test**: Can be tested by sending an image with at least one non-zero directional extension value to `/v1/images/stability-outpaint` and verifying the output image is larger.

**Acceptance Scenarios**:

1. **Given** a valid API key and an image, **When** I POST to `/v1/images/stability-outpaint` with `right: 200`, **Then** I receive an image extended 200 pixels to the right with coherent generated content.
2. **Given** all directional values set to 0 or omitted, **When** I call the endpoint, **Then** I receive a validation error requiring at least one non-zero direction.

---

### User Story 5 - Generate Images with New Base Models (Priority: P2)

A user wants to generate images using Stable Image Ultra (highest quality) or Stable Image Core (cheapest, for quick drafts) through the standard image generation endpoint.

**Why this priority**: Expands the quality/cost spectrum — iterate cheaply with Core, produce final renders with Ultra.

**Independent Test**: Can be tested by calling `/v1/images/generations` with the new model names and a prompt, verifying images are returned.

**Acceptance Scenarios**:

1. **Given** a valid API key, **When** I POST to `/v1/images/generations` with `model: "stable-image-ultra"` and a prompt, **Then** I receive a high-quality generated image.
2. **Given** a valid API key, **When** I POST with `model: "stable-image-core"` and a prompt, **Then** I receive a generated image.
3. **Given** Ultra with an image parameter and strength value, **When** I call the endpoint, **Then** I receive an image-to-image result.

---

### User Story 6 - Use Nova Canvas Style Presets (Priority: P3)

A user generating images through Nova Canvas wants to apply a built-in style preset to guide the visual style without writing complex prompts.

**Why this priority**: Low effort to expose (just a parameter) and adds creative flexibility to existing functionality.

**Independent Test**: Can be tested by calling Nova Canvas with a style preset parameter and verifying the output style differs from the default.

**Acceptance Scenarios**:

1. **Given** a valid API key, **When** I call Nova Canvas with `style: "3D_ANIMATED_FAMILY_FILM"`, **Then** I receive an image in 3D animated style.
2. **Given** an invalid style preset value, **When** I call the endpoint, **Then** I receive an error listing valid presets.

---

### User Story 7 - Generate Longer Videos with Automated Multi-Shot (Priority: P3)

A user wants to generate a longer Nova Reel video from a single descriptive prompt without manually writing individual shot prompts.

**Why this priority**: Simplifies longer video creation — manual multi-shot requires per-shot prompts for each 6-second segment.

**Independent Test**: Can be tested by calling the video generation endpoint with automated multi-shot mode and a long prompt, verifying a video longer than 6 seconds is produced.

**Acceptance Scenarios**:

1. **Given** a valid API key and a descriptive prompt (up to 4000 characters), **When** I request automated multi-shot video, **Then** I receive a video between 12 and 120 seconds.
2. **Given** a prompt shorter than the minimum length, **When** I request automated multi-shot, **Then** I receive a validation error.

---

### User Story 8 - Complete Parameter Coverage on Existing Endpoints (Priority: P2)

Existing Stability AI endpoints are missing parameters that the Bedrock API supports. Users should have access to the full feature set of each model without needing to use the AWS API directly.

**Why this priority**: Users cannot access the full capabilities of models they're already paying for. Missing parameters limit creative control.

**Independent Test**: Can be tested by calling existing endpoints with previously unsupported parameters and verifying they are accepted and affect the output.

**Acceptance Scenarios**:

1. **Given** the existing Stability Structure endpoint now supports `aspect_ratio`, **When** I include `aspect_ratio: "16:9"` in a request, **Then** the output respects the specified aspect ratio.
2. **Given** the Nova Canvas variations endpoint now supports `negativeText`, **When** I include a negative prompt, **Then** the output avoids the described content.

**Gaps identified in existing endpoints**:
- Nova Canvas variations: missing `negativeText`
- Nova Canvas outpaint: missing `negativeText`, `quality` not validated, `mask_prompt` has no max_length
- Stability Structure: missing `aspect_ratio`
- Stability Sketch: missing `aspect_ratio`
- Stability Search & Replace: missing `aspect_ratio`
- Stability Upscale (Conservative): `style_preset` correctly omitted (not supported by this model)
- Stability Style Transfer: `style_preset` correctly omitted (not supported by this model)

---

### Edge Cases

- What happens when the mask image dimensions don't match the source image for inpaint/erase? Return a clear validation error.
- What happens when the Marketplace subscription hasn't been activated for a new model? Return the Bedrock error message rather than a generic 500.
- What happens when a user sends WebP to an endpoint that only accepts PNG/JPEG? Return a validation error listing accepted formats.
- What happens when creative upscale receives an image already at or above 1 megapixel? Return a validation error with the size limit.
- What happens when a user passes an invalid Nova Canvas style preset? Return an error listing the 8 valid presets.
- What happens when Stability outpaint extension values exceed 2000 pixels? Return a validation error.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide an inpaint endpoint accepting image, mask (image or alpha channel), prompt, and optional parameters (grow_mask 0-20, negative_prompt, seed, output_format, style_preset).
- **FR-002**: System MUST provide an erase endpoint accepting image and mask, with optional grow_mask (0-20), seed, and output_format. No prompt parameter.
- **FR-003**: System MUST provide a creative upscale endpoint accepting image (under 1 megapixel) and prompt, with optional creativity (0.1-0.5), negative_prompt, seed, output_format, and style_preset.
- **FR-004**: System MUST provide a fast upscale endpoint accepting only image (32-1536px per side) and optional output_format. No prompt, no seed, no negative_prompt.
- **FR-005**: System MUST provide a search-and-recolor endpoint accepting image, prompt (desired colour), select_prompt (object to find), and optional negative_prompt, seed, output_format, grow_mask (0-20), and style_preset.
- **FR-006**: System MUST provide a Stability outpaint endpoint at a non-conflicting path, accepting image, optional prompt, directional extensions (left/right/up/down 0-2000 each, at least one non-zero), creativity (0.1-1.0), seed, output_format, and style_preset (17 presets).
- **FR-007**: System MUST add Stable Image Ultra as an image generation model accepting prompt, optional aspect_ratio (9 options), output_format (PNG/JPEG only), seed, negative_prompt, and optional image-to-image mode (image + strength 0-1).
- **FR-008**: System MUST add Stable Image Core as an image generation model accepting prompt, optional aspect_ratio (9 options), output_format (PNG/JPEG only), seed, and negative_prompt. Text-to-image only.
- **FR-009**: System MUST expose Nova Canvas style presets as a pass-through parameter. Valid values: 3D_ANIMATED_FAMILY_FILM, DESIGN_SKETCH, FLAT_VECTOR_ILLUSTRATION, GRAPHIC_NOVEL_ILLUSTRATION, MAXIMALISM, MIDCENTURY_RETRO, PHOTOREALISM, SOFT_DIGITAL_PAINTING.
- **FR-010**: System MUST support automated multi-shot video generation accepting a single prompt (up to 4000 characters) and producing videos between 12-120 seconds.
- **FR-011**: All new sidecar endpoints MUST enforce authentication, budget checking, and block `--claude-only` restricted keys.
- **FR-012**: All new endpoints MUST log spend to the unified spend tracking system.
- **FR-013**: All new endpoints MUST return clear, descriptive error messages for invalid inputs.
- **FR-014**: All new endpoints MUST be verifiable via smoke tests using intentionally invalid input to confirm routing without incurring API costs.
- **FR-015**: Existing Stability Structure, Sketch, and Search & Replace endpoints MUST be updated to accept an optional `aspect_ratio` parameter (9 options: 16:9, 1:1, 21:9, 2:3, 3:2, 4:5, 5:4, 9:16, 9:21).
- **FR-016**: Existing Nova Canvas variations endpoint MUST be updated to accept an optional `negative_text` parameter.
- **FR-017**: Existing Nova Canvas outpaint endpoint MUST validate the `quality` parameter (standard/premium) and add `max_length` validation on `mask_prompt`.
### Key Entities

- **Image Service Endpoint**: A sidecar endpoint that validates input, calls a Stability AI model, logs spend, and returns the result.
- **LiteLLM Image Model**: A text-to-image model configured in the proxy, accessible through the standard image generation endpoint.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All 6 new sidecar endpoints return valid image responses when called with correct input.
- **SC-002**: All new endpoints correctly reject requests from `--claude-only` keys and over-budget keys.
- **SC-003**: Spend for all new operations appears in the unified spend tracking.
- **SC-004**: Stable Image Ultra and Core produce images through the standard generation endpoint.
- **SC-005**: Nova Canvas style presets produce visually distinct output for different preset values.
- **SC-006**: Automated multi-shot video produces videos longer than 6 seconds from a single prompt.
- **SC-007**: Smoke tests pass for all new endpoints, confirming routing and validation without API costs.
- **SC-008**: A fresh deployment with Marketplace subscribe permissions can use all new models without manual intervention.

## Assumptions

- The existing Marketplace subscribe IAM permission covers all new models.
- The existing WAF wildcard (`/v1/images/*`) covers all new endpoint paths.
- The existing tunnel routing (`/v1/images/*` to sidecar) covers all new sidecar endpoints.
- The existing IAM policy for `bedrock:InvokeModel` on `foundation-model/*` covers all new model IDs.
- The Stability outpaint path (`/v1/images/stability-outpaint`) avoids the Nova Canvas outpaint conflict.

## Scope Boundaries

**In scope**: Adding endpoints, config, and tests for all models listed above.

**Out of scope**: Nova Canvas virtual try-on, UI/client changes, PixelForge integration.
