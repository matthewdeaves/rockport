# Feature Specification: Image Generation via Bedrock

**Feature Branch**: `002-image-generation`
**Created**: 2026-03-15
**Status**: Draft
**Input**: User description: "Enable access to image generation models (text-to-image, image-to-image) via Rockport, with key-level model restrictions so Claude Code keys only see Anthropic models and other keys get full access including image generation."

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Generate Images via OpenAI-Compatible API (Priority: P1)

A developer uses the OpenAI Python/Node SDK pointed at Rockport to generate images. They call `/v1/images/generations` with a text prompt and receive a base64-encoded image. They can also provide a source image for image-to-image generation. The SDK handles all of this through the standard OpenAI interface — no Bedrock SDK or AWS credentials needed.

**Why this priority**: This is the core new capability being added.

**Independent Test**: Call `/v1/images/generations` with a text prompt via curl or OpenAI SDK, verify a base64 image is returned.

**Acceptance Scenarios**:

1. **Given** a Rockport key with image model access, **When** a user calls `/v1/images/generations` with `model: "nova-canvas"` and a text prompt, **Then** a base64-encoded image is returned.
2. **Given** a Rockport key with image model access, **When** a user calls `/v1/images/generations` with `model: "titan-image-v2"` and a text prompt, **Then** a base64-encoded image is returned.
3. **Given** an invalid or revoked key, **When** a user calls `/v1/images/generations`, **Then** the request is rejected before any Bedrock call.

---

### User Story 2 — Claude Code Keys Restricted to Anthropic Models (Priority: P1)

A developer uses Claude Code with a key created via `rockport setup-claude`. This key only has access to Anthropic models (Claude Opus, Sonnet, Haiku). Image generation models and non-Anthropic chat models do not appear in `/v1/models` for this key, and requests to them are rejected.

**Why this priority**: Prevents confusion in Claude Code (which can't use image models) and provides clean model separation.

**Independent Test**: Create a Claude Code key, verify `/v1/models` only returns Anthropic models. Attempt an image generation call, verify it's rejected.

**Acceptance Scenarios**:

1. **Given** a Claude Code key (Anthropic-only), **When** the user lists models via `/v1/models`, **Then** only Claude Opus 4.6, Sonnet 4.6, and Haiku 4.5 (and their aliases) appear.
2. **Given** a Claude Code key, **When** the user calls `/v1/images/generations`, **Then** the request is rejected with an auth error.
3. **Given** a full-access key, **When** the user lists models, **Then** all models (chat + image) appear.

---

### User Story 3 — Admin Creates Keys with Model Scope (Priority: P2)

The admin uses `rockport key create` with a `--claude-only` flag to restrict keys to Anthropic models. Without the flag, keys get full access to all models. The `setup-claude` command automatically creates Claude-only keys.

**Why this priority**: Enables the key segmentation between Claude Code and general-purpose keys.

**Independent Test**: Create keys with different model scopes, verify model listing and request routing respect the restrictions.

**Acceptance Scenarios**:

1. **Given** the admin runs `rockport key create myapp`, **Then** the key has access to all models (chat + image).
2. **Given** the admin runs `rockport key create claude --claude-only`, **Then** the key only has access to Anthropic models.
3. **Given** the admin runs `rockport setup-claude`, **Then** the generated key is automatically Claude-only.

---

### User Story 4 — Start Instance Quickly via CLI (Priority: P2)

The admin runs `rockport start` to bring up a stopped instance. The command waits for the instance to be running and services to be healthy, then confirms. A bash alias makes this even faster to invoke.

**Why this priority**: With 30-min idle shutdown, easy restart is essential for good UX.

**Independent Test**: Stop the instance, run `rockport start`, verify services come up and health check passes.

**Acceptance Scenarios**:

1. **Given** a stopped instance, **When** the admin runs `rockport start`, **Then** the instance starts and the command reports when services are ready.
2. **Given** the setup script has run, **When** the admin types `rockport-start` (alias), **Then** it invokes `rockport start`.

---

### Edge Cases

- What if a Claude Code key tries to call an image model? LiteLLM rejects it (model not in allowed list for that key).
- What if an image model is not enabled in Bedrock? LiteLLM returns the Bedrock error.
- What if the user requests an unsupported image size? LiteLLM/Bedrock returns an error.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST expose `/v1/images/generations` endpoint for text-to-image generation via LiteLLM.
- **FR-002**: System MUST support image-to-image generation where the underlying Bedrock model supports it.
- **FR-003**: System MUST include Amazon Nova Canvas, Amazon Titan Image Generator v2, and Stability SD3 Large as image models, routed to us-west-2 (widest model availability).
- **FR-004**: System MUST support per-key model restrictions via LiteLLM's built-in `models` parameter on key generation.
- **FR-005**: `rockport setup-claude` MUST create keys restricted to Anthropic models only.
- **FR-006**: `rockport key create` without flags MUST create keys with access to all models.
- **FR-007**: `rockport key create --claude-only` MUST create keys restricted to Anthropic models.
- **FR-008**: WAF MUST allow `/v1/images/generations` path.
- **FR-009**: IAM policy MUST include us-west-2 in Bedrock regions for image model access.
- **FR-010**: `rockport start` MUST wait for services to be healthy, not just instance running.
- **FR-011**: `rockport init` MUST suggest adding a `rockport-start` bash alias to the user's shell profile.
- **FR-012**: Smoke tests MUST validate image generation endpoint.

### Key Entities

- **Image Model**: A Bedrock image generation model exposed through LiteLLM with a friendly alias. Defined in config alongside chat models.
- **Model Scope**: A per-key restriction on which models the key can access. Managed via LiteLLM's `models` parameter.

### Assumptions

- LiteLLM supports `/v1/images/generations` for Bedrock Nova Canvas and Titan Image Gen v2.
- LiteLLM's per-key `models` parameter correctly filters both `/v1/models` listings and request routing.
- us-west-2 has all needed image models available.
- The admin has enabled the image models in their AWS Bedrock console for us-west-2.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can generate an image via OpenAI SDK pointed at Rockport in under 5 lines of code.
- **SC-002**: Claude Code keys cannot see or call image models.
- **SC-003**: Full-access keys can call both chat and image models.
- **SC-004**: `rockport start` brings a stopped instance to healthy state and confirms readiness.
- **SC-005**: No additional infrastructure cost beyond existing EC2 (image generation cost is Bedrock token charges only).
