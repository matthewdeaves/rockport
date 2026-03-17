# Contract: Auto-resize for Nova Reel Images

Applies to existing `POST /v1/videos/generations` endpoint. No new endpoints.

## Request Changes

Two new optional fields added to `VideoGenerationRequest`:

```json
{
  "model": "nova-reel",
  "prompt": "...",
  "image": "data:image/png;base64,...",
  "resize_mode": "scale",
  "pad_color": "black",
  "duration": 6
}
```

For multi-shot, `resize_mode` and `pad_color` apply globally to all shot images.

| Field | Type | Default | Values | Notes |
|-------|------|---------|--------|-------|
| `resize_mode` | string | `scale` | `scale`, `crop-center`, `crop-top`, `crop-bottom`, `fit` | Optional |
| `pad_color` | string | `black` | `black`, `white` | Only used with `fit` mode |

### Resize Modes

- **`scale`**: Resize to exactly 1280x720. May change aspect ratio.
- **`crop-center`**: Scale to cover 1280x720, then center-crop the excess.
- **`crop-top`**: Scale to cover 1280x720, then crop from the top edge.
- **`crop-bottom`**: Scale to cover 1280x720, then crop from the bottom edge.
- **`fit`**: Scale to fit within 1280x720 maintaining aspect ratio. Pad remaining space with `pad_color`.

## Response Changes

When resize is applied, the video generation response includes resize metadata:

```json
{
  "id": "job-uuid",
  "status": "in_progress",
  "model": "nova-reel",
  "resize_applied": {
    "original_width": 1920,
    "original_height": 1080,
    "mode": "scale"
  },
  "duration": 6,
  "estimated_cost": 0.48
}
```

`resize_applied` is `null` when the image was already 1280x720.

For multi-shot, `resize_applied` is an array (one entry per shot that had an image, `null` for shots without images).

## Behaviour

- Images already 1280x720 pass through unchanged (no resize_applied metadata).
- Format validation (PNG/JPEG), opacity check (no transparent pixels), and size check (10MB max) happen AFTER resize.
- Alpha channel stripping for fully-opaque PNGs still applies after resize.
- Invalid `resize_mode` or `pad_color` values return HTTP 400.
