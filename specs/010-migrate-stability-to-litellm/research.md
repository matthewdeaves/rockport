# Research: Migrate Stability AI Image Endpoints to LiteLLM Native

**Date**: 2026-03-19
**Feature**: 010-migrate-stability-to-litellm

## Research 1: LiteLLM Image Edit Model ID Format

**Decision**: Use model IDs WITHOUT the `us.` cross-region prefix in litellm-config.yaml.

**Rationale**: LiteLLM's `_is_stability_edit_model()` method in `stability_transformation.py` checks for exact model ID patterns like `stability.stable-image-control-structure-v1:0`. The `us.` prefix is a Bedrock cross-region inference profile convention. LiteLLM handles the Bedrock API call internally using the `aws_region_name` from the config, so the model ID should be the base Bedrock model ID without region prefix. However, our sidecar currently uses `us.` prefixed IDs (e.g., `us.stability.stable-image-control-structure-v1:0`) when calling Bedrock directly from us-west-2. LiteLLM's config should use `stability.stable-image-control-structure-v1:0` (without prefix) and let LiteLLM's Bedrock handler route to the correct region via `aws_region_name: us-west-2`.

**Alternatives considered**:
- Using `us.` prefixed IDs: Would fail LiteLLM's `_is_stability_edit_model()` detection.
- Using `bedrock/us.stability.*` format: LiteLLM's routing logic strips the `bedrock/` prefix but the `us.` would still cause detection issues.

## Research 2: LiteLLM image_edit Config Format

**Decision**: Add model entries with `model_info.mode: image_edit` and `litellm_params.model: bedrock/stability.*` format.

**Rationale**: This matches the existing image_generation entries in litellm-config.yaml (e.g., `sd3.5-large` uses `bedrock/stability.sd3-5-large-v1:0` with `mode: image_generation`). The image_edit mode tells LiteLLM to route requests through the `/v1/images/edits` handler instead of the `/v1/images/generations` handler. The `bedrock/` prefix tells LiteLLM which provider to use.

**Alternatives considered**:
- No `mode` field: LiteLLM might default to chat completion routing, causing errors.
- Using `image_generation` mode: Would route to wrong handler.

## Research 3: Tunnel Routing Changes

**Decision**: Change tunnel ingress to route `/v1/images/edits*` to LiteLLM (port 4000) and narrow the sidecar catch-all `/v1/images/*` to only match the 3 Nova Canvas paths.

**Rationale**: Currently the tunnel has:
1. `/v1/videos*` → sidecar (:4001)
2. `/v1/images/generations*` → LiteLLM (:4000)
3. `/v1/images/*` → sidecar (:4001) — catch-all for all other image paths
4. Default → LiteLLM (:4000)

After migration, `/v1/images/edits` must go to LiteLLM. The simplest approach is:
1. `/v1/videos*` → sidecar (:4001)
2. `/v1/images/generations*` → LiteLLM (:4000)
3. `/v1/images/edits*` → LiteLLM (:4000)
4. `/v1/images/*` → sidecar (:4001) — now only catches variations, background-removal, outpaint
5. Default → LiteLLM (:4000)

This preserves the existing pattern and only adds one new rule. The `/v1/images/*` catch-all still works because the 3 Nova Canvas endpoints are the only remaining sidecar image paths.

**Alternatives considered**:
- Replacing the `/v1/images/*` catch-all with 3 explicit paths: More precise but more rules to maintain. The catch-all is fine since WAF blocks any unlisted paths anyway.
- Removing the `/v1/images/*` catch-all entirely and adding 3 explicit sidecar routes: Better if we later add more LiteLLM image endpoints under `/v1/images/`, but adds complexity now.

## Research 4: WAF Rule Changes

**Decision**: Add `/v1/images/edits` to the WAF allowlist. The existing `/v1/images/` prefix rule already covers it, so no WAF change is actually needed.

**Rationale**: The current WAF rule includes `not starts_with(http.request.uri.path, "/v1/images/")` which already allows ALL paths under `/v1/images/`, including `/v1/images/edits`. The 13 removed sidecar paths (e.g., `/v1/images/structure`) would still pass the WAF, but they would hit the sidecar's catch-all tunnel route and return 404 since those endpoints no longer exist. This is acceptable behavior (404 vs WAF block is functionally equivalent for security).

**Alternatives considered**:
- Tightening WAF to only allow specific `/v1/images/` subpaths: More precise but adds complexity to the WAF expression for no security benefit (sidecar returns 404 anyway).
- No change at all: This is the chosen approach — the existing WAF rule already allows the needed paths.

## Research 5: Smoke Test Changes

**Decision**: Replace sidecar Stability AI endpoint tests (tests 22-29) with LiteLLM `/v1/images/edits` tests. Keep Nova Canvas tests (19-21) unchanged.

**Rationale**: Current smoke tests 22-29 test that individual sidecar Stability AI endpoints are reachable. After migration, these endpoints will return 404. Replace them with tests that verify `/v1/images/edits` routes correctly to LiteLLM for Stability AI models. Test 18 (which currently checks that `/v1/images/edits` returns 404 from sidecar) should be updated to expect a successful routing to LiteLLM instead.

**Alternatives considered**:
- Testing all 13 models: Too expensive (13 x $0.04 = $0.52 per smoke run). Test 1-2 representative models.
- Only testing routing (no real Bedrock call): Cheaper, but doesn't verify end-to-end. A validation-error test (free) that confirms LiteLLM recognizes the model is sufficient.

## Research 6: User-Facing Model Names for Image Edit

**Decision**: Use descriptive names matching the operation: `stability-structure`, `stability-sketch`, `stability-style-transfer`, `stability-remove-background`, `stability-search-replace`, `stability-upscale`, `stability-style-guide`, `stability-inpaint`, `stability-erase`, `stability-creative-upscale`, `stability-fast-upscale`, `stability-search-recolor`, `stability-outpaint`.

**Rationale**: The `model_name` field in litellm-config.yaml defines the user-facing name used in API requests. Following the existing convention (e.g., `nova-canvas`, `sd3.5-large`, `stable-image-ultra`), these names should be clean, descriptive, and prefixed with `stability-` to clearly identify the provider. Users will pass `model=stability-inpaint` in their `/v1/images/edits` request.

**Alternatives considered**:
- Using raw Bedrock model IDs: Too verbose (`stability.stable-image-inpaint-v1:0`).
- Using short names without prefix (`inpaint`, `upscale`): Too generic, could conflict with future providers.

## Research 7: README Documentation Impact

**Decision**: Significant README rewrite needed for the image services section.

**Rationale**: The README currently has:
- Line 16: Lists "structure, sketch, style transfer, upscale, inpaint, erase, search & recolor, and more (Stability AI)" as sidecar features
- Lines 32, 46: References "Stability AI sidecar services" for Marketplace subscription
- Line 242: States "/v1/images/edits is not supported" — this becomes the primary Stability AI endpoint
- Lines 246-272: Full endpoint table listing all 13 Stability AI sidecar endpoints with prices
- Section headers reference "Advanced Image Operations" as sidecar features

All of this must be rewritten to reflect that Stability AI operations now go through LiteLLM's `/v1/images/edits` and only Nova Canvas operations remain on the sidecar.
