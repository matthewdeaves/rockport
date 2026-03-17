# Research: Image & Video Generation Enhancements

**Date**: 2026-03-17
**Feature**: 008-image-video-enhancements

## Nova Canvas Advanced Task Types — Bedrock API

### Decision: Use raw base64 strings (no format wrapper) for all Nova Canvas image inputs
**Rationale**: Nova Canvas IMAGE_VARIATION, BACKGROUND_REMOVAL, and OUTPAINTING all accept images as plain base64-encoded strings in JSON fields — NOT the `{format, source: {bytes}}` wrapper used by Nova Reel video. The existing video sidecar's `validate_image_nova_reel` returns the wrapped format; new image endpoints must use unwrapped base64.
**Alternatives considered**: Reusing the video sidecar's image format wrapper — rejected because Bedrock would reject the request.

### Decision: IMAGE_VARIATION accepts 1-5 reference images, not just one
**Rationale**: The `imageVariationParams.images` field is an array of 1-5 base64 strings. The spec describes single-image input but the API supports blending multiple references. Expose this as an array in the endpoint.
**Alternatives considered**: Restricting to single image — rejected because multi-image blending is useful for character consistency workflows.

### Decision: OUTPAINTING does not accept output dimensions
**Rationale**: Per AWS docs, width/height should NOT be provided for outpainting — output preserves input dimensions. To get 1280x720 output, users must provide a 1280x720 input (with transparent/masked regions to fill). This means outpainting is for extending content within existing dimensions, not for resizing.
**Alternatives considered**: Passing width/height to Bedrock anyway — rejected because docs explicitly say not to.

### Decision: BACKGROUND_REMOVAL has no configurable parameters
**Rationale**: The only input is `image` (base64). No prompt, no seed, no dimensions, no quality setting. This is the simplest endpoint.

### Decision: Nova Canvas pricing is per-image, uniform across task types
**Rationale**: Standard quality up to 1024x1024 = $0.04/image. Premium or up to 2048x2048 = $0.06/image. Premium at 2048x2048 = $0.08/image. BACKGROUND_REMOVAL always produces 1 image.

## Stability AI Image Services — Bedrock API

### Decision: All 7 services use cross-region model IDs with `us.` prefix
**Rationale**: Model IDs follow the pattern `us.stability.stable-image-{service}-v1:0`. Available in us-west-2 (Oregon), us-east-1, us-east-2. Rockport uses us-west-2 for Stability AI models already.

### Model ID Registry

| Service | Model ID |
|---------|----------|
| Structure | `us.stability.stable-image-control-structure-v1:0` |
| Sketch | `us.stability.stable-image-control-sketch-v1:0` |
| Style Transfer | `us.stability.stable-style-transfer-v1:0` |
| Remove Background | `us.stability.stable-image-remove-background-v1:0` |
| Search and Replace | `us.stability.stable-image-search-replace-v1:0` |
| Conservative Upscale | `us.stability.stable-conservative-upscale-v1:0` |
| Style Guide | `us.stability.stable-image-style-guide-v1:0` |

### Decision: Subscribing to any one service enrolls all 13
**Rationale**: A single Marketplace subscription activates all Stability AI Image Services. No per-service activation needed.

### Decision: Style Transfer uses different field names than other services
**Rationale**: Style Transfer uses `init_image` (subject) + `style_image` (reference), while all other services use `image`. Style Transfer also has three strength parameters (`composition_fidelity`, `style_strength`, `change_strength`) instead of `control_strength` or `fidelity`. The endpoint contract must reflect this.

### Decision: All services accept WebP in addition to PNG/JPEG
**Rationale**: Stability AI services accept JPEG, PNG, and WebP input (unlike Nova Canvas which is PNG/JPEG only). Output format is configurable via `output_format` (jpeg/png/webp, default png).

### Decision: Stability AI services support `style_preset` parameter
**Rationale**: 17 presets available (3d-model, analog-film, anime, cinematic, comic-book, digital-art, enhance, fantasy-art, isometric, line-art, low-poly, modeling-compound, neon-punk, origami, photographic, pixel-art, tile-texture). Applicable to Structure, Sketch, Search and Replace, Style Guide. NOT available for Remove Background, Conservative Upscale, or Style Transfer.

### Decision: Universal image constraints for Stability AI
**Rationale**: Min 64px per side, max 9,437,184 total pixels (~3072x3072), aspect ratio 1:2.5 to 2.5:1. Conservative Upscale input max is 1 megapixel (output up to 4K).

### Decision: Stability AI pricing needs runtime confirmation
**Rationale**: Exact per-service pricing is on the AWS Bedrock pricing page but could not be extracted via web scraping (dynamically rendered). Known reference points: SD3.5 Large = $0.08/image, Stable Image Core = ~$0.03/image. Will hardcode estimated costs and verify on first deploy.

## Tunnel Routing — `/v1/images/*` Split

### Decision: Use Cloudflare Tunnel path matching to split image routes
**Rationale**: `/v1/images/generations` must continue routing to LiteLLM (port 4000). All other `/v1/images/*` paths route to the sidecar (port 4001). Cloudflare Tunnel supports multiple ingress rules with path matching — more specific paths take precedence. Add `/v1/images/generations` → port 4000 BEFORE the catch-all `/v1/images/*` → port 4001 rule.
**Alternatives considered**: Using a separate path prefix (e.g., `/v1/canvas/*`) — rejected because it breaks the clean `/v1/images/*` namespace.

## Memory Constraints

### Decision: Keep sidecar at 256MB MemoryMax initially, monitor
**Rationale**: Synchronous image operations load one image into Pillow at a time (for validation/resize). A 4096x4096 RGBA image is ~64MB in memory. With FastAPI overhead, 256MB should suffice for single concurrent requests. If OOM occurs under concurrent load, increase to 384MB or 512MB. The t3.small has 2GB total; LiteLLM uses 1280MB; PostgreSQL uses ~100-150MB; 256MB for sidecar leaves ~200-300MB for OS.
