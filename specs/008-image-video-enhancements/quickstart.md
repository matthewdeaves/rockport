# Quickstart: Image & Video Generation Enhancements

## Prerequisites

- Rockport deployed and running (`./scripts/rockport.sh status` shows healthy)
- API key with unrestricted access (NOT `--claude-only`)
- Stability AI Marketplace subscription activated (one-time, via Bedrock console)

## Video Prompt Validation

Prompt validation is automatic for all Nova Reel requests. No client changes needed.

```bash
# This will be rejected (negation word "no")
curl -s -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"nova-reel","prompt":"a knight walking, no sword visible","duration":6}'
# → 400: "Nova Reel prompt contains negation word 'no'..."

# This will succeed
curl -s -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"nova-reel","prompt":"Armoured knight walking steadily forward in side profile, arms swinging in opposition, static shot.","duration":6}'
```

## Auto-resize Images

Submit any dimension image — it will be scaled to 1280x720 automatically.

```bash
# 1920x1080 image auto-scaled to 1280x720
curl -s -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"nova-reel","prompt":"Knight walking steadily, arms swinging, side profile, static shot.","image":"data:image/png;base64,...","duration":6}'

# Use fit mode with white padding
curl -s -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"nova-reel","prompt":"...","image":"data:image/png;base64,...","resize_mode":"fit","pad_color":"white","duration":6}'
```

## Nova Canvas Image Variation

Generate character pose variants from a reference image.

```bash
curl -s -X POST "$BASE_URL/v1/images/variations" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "images": ["data:image/png;base64,..."],
    "prompt": "armoured knight, side profile, mid-stride walking pose, game art style",
    "similarity_strength": 0.7,
    "seed": 57,
    "width": 1280,
    "height": 720,
    "n": 3
  }'
```

## Nova Canvas Background Removal

```bash
curl -s -X POST "$BASE_URL/v1/images/background-removal" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"image": "data:image/png;base64,..."}'
```

## Nova Canvas Outpainting

Extend a character image to fill 1280x720 with generated background.

```bash
curl -s -X POST "$BASE_URL/v1/images/outpaint" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "image": "data:image/png;base64,...",
    "prompt": "stone castle courtyard extending to both sides, medieval game art style",
    "mask_prompt": "the knight character",
    "outpainting_mode": "PRECISE",
    "seed": 57
  }'
```

## Stability AI Examples

### Structure Control (preserve pose, change style)
```bash
curl -s -X POST "$BASE_URL/v1/images/structure" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "image": "data:image/png;base64,...",
    "prompt": "armoured knight in pixel art style, side view",
    "control_strength": 0.7,
    "style_preset": "pixel-art"
  }'
```

### Remove Background
```bash
curl -s -X POST "$BASE_URL/v1/images/remove-background" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"image": "data:image/png;base64,..."}'
```

### Conservative Upscale (small image → 4K)
```bash
curl -s -X POST "$BASE_URL/v1/images/upscale" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "image": "data:image/png;base64,...",
    "prompt": "detailed character art, sharp lines",
    "creativity": 0.2
  }'
```

### Style Guide (consistent style across images)
```bash
curl -s -X POST "$BASE_URL/v1/images/style-guide" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "image": "data:image/png;base64,...",
    "prompt": "knight character standing in a courtyard, full body",
    "aspect_ratio": "16:9",
    "fidelity": 0.7,
    "style_preset": "digital-art"
  }'
```

## Typical Animation Pipeline Workflow

1. Generate or provide a character reference image
2. Use `/v1/images/variations` to create pose variants (idle, walk, run, jump) with consistent seed
3. Use `/v1/images/background-removal` to isolate characters if needed
4. Use `/v1/images/outpaint` to extend images to 1280x720 if needed
5. Submit to `/v1/videos/generations` as Nova Reel multi-shot storyboard with per-shot images
6. Poll `/v1/videos/generations/{job_id}` until complete
7. Download video from presigned URL
