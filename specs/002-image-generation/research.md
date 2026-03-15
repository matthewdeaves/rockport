# Research: Image Generation via Bedrock

## Decision 1: Image Model Region

**Decision**: Route image generation models to us-west-2 (Oregon).

**Rationale**: us-west-2 has the widest selection of image models on Bedrock — Nova Canvas, Titan Image Gen v2, Stability SD3 Large, and SD3.5 Large. eu-west-1 only has Nova Canvas and Titan Image Gen v2. The EC2 instance stays in eu-west-2 (London); only the Bedrock API calls for image models go to us-west-2. LiteLLM already supports per-model `aws_region_name` in the config.

**Alternatives considered**:
- eu-west-1 (Ireland): Closer (~10ms vs ~140ms) but fewer models. Image generation takes seconds anyway, so latency is negligible.
- Moving EC2 to us-west-2: Unnecessary — only the Bedrock API calls need to reach that region.

## Decision 2: Image Models to Include

**Decision**: Nova Canvas, Titan Image Gen v2, and SD3 Large.

**Rationale**:
- **Amazon Nova Canvas** (`amazon.nova-canvas-v1:0`): Text-to-image, image-to-image, inpainting, outpainting, background removal. Confirmed LiteLLM support.
- **Amazon Titan Image Generator v2** (`amazon.titan-image-generator-v2:0`): Text-to-image, image-to-image, inpainting, outpainting, variations. Confirmed LiteLLM support.
- **Stability SD3 Large** (`stability.sd3-large-v1:0`): Text-to-image. LiteLLM has listed support. us-west-2 only.
- **Stability SDXL**: EOL since May 2025 — excluded.
- **Stable Image Ultra/Core**: LiteLLM does not yet support the newer task-based API format (GitHub issue #17886). Exclude until supported.

**Alternatives considered**:
- Including only Amazon models: Safer but limits choice.
- Including all Stability models: Blocked by LiteLLM compatibility for Ultra/Core.

## Decision 3: Key Model Restrictions

**Decision**: Use LiteLLM's built-in `models` parameter on `/key/generate`.

**Rationale**: LiteLLM natively supports passing a `models` array when creating a key. When set, the key can only access those models, and `/v1/models` only returns them. No custom code needed.

- Claude Code keys: `models: ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5-20251001", "claude-sonnet-4-5-20250929", "claude-opus-4-5-20251101"]`
- General keys: No `models` parameter (full access)

**Alternatives considered**:
- Separate LiteLLM instances: Overkill for key-level separation.
- Model groups/teams: More complex than needed for two tiers.

## Decision 4: WAF Changes

**Decision**: Add `/v1/images/generations` to the Cloudflare WAF allowlist.

**Rationale**: Single line addition to the existing WAF rule in `terraform/waf.tf`.

## Decision 5: IAM Changes

**Decision**: Add `us-west-2` to the `bedrock_regions` local in `terraform/main.tf`.

**Rationale**: The IAM policy already uses a `bedrock_regions` list. Adding us-west-2 covers all image models. Same actions, just an additional region.

## Decision 6: CLI Start Command Enhancement

**Decision**: Enhance `rockport start` to wait for health check, not just EC2 running state. Add bash alias via setup script.

**Rationale**: Currently `cmd_start()` waits for `instance-running` then says "Services will be ready in ~60 seconds." Better UX: poll the health endpoint until it responds, then confirm.

## Decision 7: Smoke Test Updates

**Decision**: Add image generation test to `tests/smoke-test.sh`.

**Rationale**: Validates the new endpoint end-to-end. Should use a simple, cheap prompt to minimise Bedrock cost per test run.
