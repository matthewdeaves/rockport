# Feature Specification: Image-to-Image via Generations Endpoint

**Feature Branch**: `003-image-to-image-docs`
**Created**: 2026-03-15
**Status**: Draft
**Input**: Document and enable image-to-image generation via `/v1/images/generations` since `/v1/images/edits` is not supported for Bedrock models in LiteLLM 1.82.2.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Image-to-Image Generation Works (Priority: P1)

A developer using the Rockport API wants to modify an existing image using a text prompt. They send a source image and a prompt to the `/v1/images/generations` endpoint and receive a transformed image back.

**Why this priority**: Core functionality that downstream apps (PixelForge) need. Without this, image editing is completely blocked.

**Independent Test**: Send a base64 source image + prompt via curl to `/v1/images/generations` and verify a modified image is returned.

**Acceptance Scenarios**:

1. **Given** a valid API key and a base64 source image, **When** the user POSTs to `/v1/images/generations` with the image and a prompt, **Then** the API returns a transformed image as b64_json.
2. **Given** a claude-only restricted key, **When** the user tries image-to-image generation, **Then** the request is rejected with a model restriction error.

---

### User Story 2 - Clear Documentation for API Consumers (Priority: P1)

A developer building an app against the Rockport API needs to know how to do image-to-image generation. The README and CLAUDE.md clearly document the correct endpoint, request format, and limitations.

**Why this priority**: Without documentation, every consumer will hit the same `/v1/images/edits` error and waste time debugging.

**Independent Test**: A developer reading the README can successfully make an image-to-image API call without external help.

**Acceptance Scenarios**:

1. **Given** the README documentation, **When** a developer follows the image-to-image example, **Then** they get a successful response.
2. **Given** the documentation, **When** a developer looks for image editing capabilities, **Then** they find a clear note that `/v1/images/edits` is not supported and the correct alternative.

---

### User Story 3 - Automated Smoke Test (Priority: P2)

The smoke test suite includes an image-to-image test that verifies the endpoint works after deployment.

**Why this priority**: Prevents future deployments from breaking image-to-image without anyone noticing.

**Independent Test**: Run the smoke test script and verify the image-to-image test passes.

**Acceptance Scenarios**:

1. **Given** a deployed Rockport instance, **When** the smoke tests run, **Then** the image-to-image test passes with a valid response.

---

### Edge Cases

- What happens when the source image is too large? (Bedrock returns a validation error)
- What happens when an unsupported model is used for image-to-image? (SD3.5 Large does not support image variations)
- What happens when the source image format is invalid? (must be base64 PNG/JPEG)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The API MUST accept image-to-image requests via `/v1/images/generations` with a source image parameter
- **FR-002**: The README MUST document the image-to-image request format with a working curl example
- **FR-003**: The README MUST clearly state that `/v1/images/edits` is not supported for Bedrock models
- **FR-004**: The CLAUDE.md MUST note the `/v1/images/edits` limitation and the correct alternative
- **FR-005**: The smoke test MUST include an image-to-image test case
- **FR-006**: A prompt MUST be generated for the PixelForge session explaining the correct API format

### Assumptions

- Nova Canvas supports IMAGE_VARIATION task type via the generations endpoint with a source image
- Titan Image v2 supports image conditioning via the generations endpoint
- SD3.5 Large may not support image-to-image (needs testing)
- The source image is passed as a base64-encoded string in the request body

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Image-to-image generation returns a valid image when given a source image and prompt
- **SC-002**: All smoke tests pass including the new image-to-image test
- **SC-003**: Documentation includes a working curl example that can be copy-pasted and run
- **SC-004**: PixelForge team has a clear prompt explaining the correct API format
