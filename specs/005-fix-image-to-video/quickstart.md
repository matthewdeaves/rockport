# Quickstart: Fix Image-to-Video Support

**Date**: 2026-03-16 | **Feature**: 005-fix-image-to-video

## What's Changing

Bug fix in `sidecar/video_api.py` — correcting Bedrock API field names for image-to-video requests. No new files, no schema changes, no infrastructure changes.

## Files to Modify

1. **`sidecar/video_api.py`** — All changes are here:
   - `validate_image()` — Add alpha/transparency check
   - `parse_image_data_uri()` — New helper to extract format + raw base64 from data URI
   - `create_video()` — Fix Bedrock request body construction for both single-shot and multi-shot with images
   - Duration enforcement — Reject single-shot + image when duration != 6

2. **`CLAUDE.md`** — Update notes about image-to-video support

## Testing

```bash
# Single-shot image-to-video (PNG)
curl -X POST https://llm.matthewdeaves.com/v1/videos/generations \
  -H "Authorization: Bearer sk-..." \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Camera slowly pans across the scene",
    "image": "data:image/png;base64,iVBORw0KGgo..."
  }'

# Multi-shot with image on first shot
curl -X POST https://llm.matthewdeaves.com/v1/videos/generations \
  -H "Authorization: Bearer sk-..." \
  -H "Content-Type: application/json" \
  -d '{
    "shots": [
      {"prompt": "Aerial view of a coastline", "image": "data:image/png;base64,..."},
      {"prompt": "Camera descends toward the beach"}
    ]
  }'

# Should fail: single-shot with image and duration > 6
curl -X POST https://llm.matthewdeaves.com/v1/videos/generations \
  -H "Authorization: Bearer sk-..." \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Zoom into the scene",
    "image": "data:image/png;base64,...",
    "duration": 12
  }'
# Expected: 400 "Single-shot with image is fixed at 6 seconds"
```

## Deployment

After code changes:
```bash
./scripts/rockport.sh config push
```
This restarts the video sidecar with the updated code.
