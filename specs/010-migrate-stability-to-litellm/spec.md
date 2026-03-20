# Feature Specification: Migrate Stability AI Image Endpoints to LiteLLM Native

**Feature Branch**: `010-migrate-stability-to-litellm`
**Created**: 2026-03-19
**Status**: Draft
**Input**: Migrate 13 Stability AI image editing endpoints from the sidecar to LiteLLM's native `/v1/images/edits` support, removing duplicate code and simplifying infrastructure.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Use Stability AI Image Operations via LiteLLM Native Endpoint (Priority: P1)

As the sole operator, I want to use all 13 Stability AI image editing operations (structure control, sketch, style transfer, background removal, search-replace, upscale, style guide, inpainting, object erasure, creative upscale, fast upscale, search recolor, outpaint) through LiteLLM's standard `/v1/images/edits` endpoint instead of the sidecar's custom endpoints, so that image editing is handled by the proxy with built-in auth, budget enforcement, and spend tracking — eliminating duplicated infrastructure.

**Why this priority**: This is the core migration. Every other change depends on these operations working through LiteLLM natively. Without this, nothing else matters.

**Independent Test**: Can be fully tested by sending a multipart form request to `/v1/images/edits` with each of the 13 Stability AI model names and verifying the operation completes successfully with correct spend logging.

**Acceptance Scenarios**:

1. **Given** a valid API key and a deployed instance with the 13 Stability AI models configured, **When** the user sends a POST to `/v1/images/edits` with a Stability AI model name and an image file, **Then** the system returns a successfully edited image in the response with spend logged to unified tracking.
2. **Given** a `--claude-only` restricted API key, **When** the user sends a POST to `/v1/images/edits` with any Stability AI model, **Then** the system returns an error because the key's model list does not include Stability AI models.
3. **Given** a valid API key with a budget limit already reached, **When** the user sends a request for a Stability AI operation, **Then** the system rejects the request due to insufficient budget.
4. **Given** the 13 Stability AI models configured, **When** the user lists available models, **Then** all 13 Stability AI image edit models appear in the response.

---

### User Story 2 - Nova Canvas Operations Continue Working via Sidecar (Priority: P1)

As the sole operator, I want the 3 Nova Canvas image operations (variations, background removal, outpainting) to continue working through the sidecar's custom endpoints unchanged, because LiteLLM does not support these Nova Canvas task types natively.

**Why this priority**: Equal to P1 because these operations must not break during the migration. Nova Canvas endpoints are the sidecar's remaining image responsibility.

**Independent Test**: Can be fully tested by sending requests to `/v1/images/variations`, `/v1/images/background-removal`, and `/v1/images/outpaint` and verifying each returns correct results.

**Acceptance Scenarios**:

1. **Given** a deployed instance after migration, **When** the user sends a POST to `/v1/images/variations` with a valid image, **Then** the system returns an image variation via the sidecar.
2. **Given** a deployed instance after migration, **When** the user sends a POST to `/v1/images/background-removal` with a valid image, **Then** the system returns the image with background removed.
3. **Given** a deployed instance after migration, **When** the user sends a POST to `/v1/images/outpaint` with a valid image and expansion parameters, **Then** the system returns an outpainted image.

---

### User Story 3 - Sidecar Code and Infrastructure Cleaned Up (Priority: P2)

As the project maintainer, I want all Stability AI endpoint code, helper functions, and associated infrastructure (WAF rules, tunnel routes) removed from the sidecar and simplified, so that the codebase is smaller, easier to maintain, and accurately reflects the system architecture.

**Why this priority**: This is the cleanup that delivers the long-term value of the migration — reduced code, simpler infrastructure, and accurate documentation.

**Independent Test**: Can be tested by verifying the sidecar code no longer contains any Stability AI endpoints or helpers, WAF rules only allow necessary paths, tunnel routes are simplified, and all documentation/diagrams accurately reflect the new architecture.

**Acceptance Scenarios**:

1. **Given** the migration is complete, **When** inspecting the sidecar image code, **Then** only Nova Canvas endpoints (variations, background-removal, outpaint) and their required shared helpers remain — all Stability AI endpoints and Stability-only helpers are removed.
2. **Given** the migration is complete, **When** inspecting the WAF configuration, **Then** the existing `/v1/images/` prefix rule covers both `/v1/images/edits` (routed to the proxy) and the 3 Nova Canvas sidecar paths, with no WAF expression changes needed. WAF comments accurately document the new routing.
3. **Given** the migration is complete, **When** inspecting the tunnel configuration, **Then** routing sends image edit requests to the proxy and only routes Nova Canvas and video paths to the sidecar.
4. **Given** the migration is complete, **When** inspecting all documentation and diagrams, **Then** all references accurately describe the new architecture where Stability AI operations go through the proxy and only Nova Canvas + video remain on the sidecar.

---

### User Story 4 - Smoke Tests Validate New Architecture (Priority: P2)

As the project maintainer, I want the smoke test suite updated to validate that Stability AI operations work through the proxy's image edits endpoint and Nova Canvas operations work through the sidecar, so that CI/CD catches regressions.

**Why this priority**: Tests are essential for deploy confidence but are a validation layer, not core functionality.

**Independent Test**: Can be tested by running the smoke test suite after deployment and verifying all image-related checks pass.

**Acceptance Scenarios**:

1. **Given** a deployed instance, **When** running the smoke test suite, **Then** at least one Stability AI operation is tested via the image edits endpoint and succeeds.
2. **Given** a deployed instance, **When** running the smoke test suite, **Then** Nova Canvas operations are tested via the sidecar endpoints and succeed.
3. **Given** a deployed instance with the old sidecar Stability AI paths removed, **When** the smoke test sends a request to a removed path, **Then** the request is blocked or returns not found (confirming old paths no longer work).

---

### Edge Cases

- What happens when a request is sent to a removed sidecar path (e.g., `/v1/images/inpaint`)? It should be blocked by WAF or return not found — not silently fail or route to the wrong service.
- What happens when the proxy restarts? Stability AI image edit models should be available immediately after restart without additional configuration.
- What happens when a Stability AI model requires a Marketplace subscription that hasn't been activated? The proxy should pass through the upstream error clearly.
- How does the proxy handle the cross-region prefix for Stability AI model IDs? The configuration must use the correct model IDs that the proxy's detection method expects.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST configure all 13 Stability AI image edit models in the proxy configuration with image edit mode and the correct region (us-west-2).
- **FR-002**: System MUST route image edit requests to the proxy (port 4000), not the sidecar.
- **FR-003**: System MUST remove all 13 Stability AI endpoint functions from the sidecar image code.
- **FR-004**: System MUST remove Stability-AI-only helper functions and constants from the sidecar, while preserving any helpers shared with Nova Canvas endpoints.
- **FR-005**: System MUST preserve the 3 Nova Canvas endpoints (variations, background-removal, outpaint) and all shared infrastructure they depend on (authentication, budget checking, data URI parsing, image validation).
- **FR-006**: System MUST verify WAF rules allow `/v1/images/edits` through the existing `/v1/images/` prefix rule. No WAF expression changes are required — the 13 Stability AI sidecar paths were never explicitly listed (all covered by the prefix catch-all). WAF comments should be updated to document the new routing.
- **FR-007**: System MUST update tunnel configuration so image edit requests route to the proxy.
- **FR-008**: System MUST update smoke tests to validate Stability AI operations via the image edits endpoint.
- **FR-009**: System MUST update project documentation to accurately describe which image operations go through the proxy vs the sidecar.
- **FR-010**: System MUST update architecture diagrams to reflect the new routing.
- **FR-011**: System MUST update the project README if it references sidecar image operations.
- **FR-012**: System MUST verify CLI tooling (`scripts/rockport.sh`) has no references to Stability AI endpoints or sidecar image paths. No code changes expected — confirmed via grep that no such references exist.
- **FR-013**: System MUST ensure restricted keys (claude-only) cannot access Stability AI models — enforced by the proxy's model-level access controls.
- **FR-014**: System MUST use the correct Stability AI model IDs that match the proxy's model detection (the IDs the proxy expects for image edit routing).

### Key Entities

- **Image Edit Model Configuration**: A model entry in the proxy config with image edit mode, mapping a user-facing model name to a Bedrock Stability AI model ID with region configuration.
- **Sidecar Image Endpoint**: A route in the sidecar that handles a specific image operation by calling Bedrock directly — being reduced from 16 to 3 endpoints.
- **WAF Allowlist Rule**: A rule that permits specific URL paths through to the origin — being updated to reflect the new routing.
- **Tunnel Route**: An ingress rule that maps URL paths to backend services (proxy on :4000 or sidecar on :4001).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All 13 Stability AI image operations produce correct results when called via the image edits endpoint with the appropriate model name.
- **SC-002**: Spend for Stability AI image operations appears in unified spend tracking (visible via the admin CLI spend commands).
- **SC-003**: The 3 Nova Canvas sidecar endpoints continue to function identically to before the migration.
- **SC-004**: Sidecar image code is reduced by at least 60% (from 16 endpoints + helpers to 3 endpoints + shared helpers).
- **SC-005**: Smoke tests pass covering both proxy-native Stability AI operations and sidecar Nova Canvas operations.
- **SC-006**: All documentation (project docs, README, architecture diagrams) accurately describes the post-migration architecture with no stale references to removed sidecar Stability AI endpoints.
- **SC-007**: Requests to removed sidecar paths (e.g., `/v1/images/structure`) are blocked or return not found.

## Assumptions

- The current proxy version (1.82.3) correctly handles all 13 Stability AI operations via Bedrock in image edit mode without additional configuration beyond model entries.
- The proxy's built-in spend tracking for image edit operations writes to the same tracking tables used by other operations, making spend visible through existing CLI commands.
- The `--claude-only` key restriction is naturally enforced by the proxy's model access controls — keys created with `--claude-only` only have Anthropic models in their allowed list, so they cannot access Stability AI models.
- The proxy's image edit endpoint accepts the same parameters the sidecar passed to Bedrock (prompt, negative_prompt, seed, control_strength, creativity, masks, aspect_ratio, etc.) via multipart form fields.
- No changes to IAM policies are needed — the instance role already has Bedrock invoke permissions for Stability AI models in us-west-2.
