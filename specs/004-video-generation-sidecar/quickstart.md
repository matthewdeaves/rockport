# Quickstart: Video Generation Sidecar

## Prerequisites

- Rockport deployed and healthy (`rockport status`)
- Nova Reel model enabled in Bedrock console (us-east-1)
- API key with access to all models (not `--claude-only`)
- Cloudflare Tunnel configured with video path routing (see below)

## Cloudflare Tunnel Configuration

The video sidecar runs on port 4001 alongside LiteLLM on port 4000. You need to add a path-based routing rule in the Cloudflare Tunnel:

1. Go to **Cloudflare Zero Trust** > **Networks** > **Tunnels**
2. Click your tunnel > **Public Hostname** tab
3. Add a new public hostname entry:
   - **Subdomain**: same as your LiteLLM subdomain (e.g. `llm`)
   - **Domain**: your domain (e.g. `matthewdeaves.com`)
   - **Path**: `/v1/videos`
   - **Service**: `http://localhost:4001`
4. Ensure the catch-all entry (no path) still routes to `http://localhost:4000` (LiteLLM)

The path-specific rule must appear **above** the catch-all rule in the list.

## Generate a video

```bash
# Single-shot: 6-second video
curl -X POST "https://llm.matthewdeaves.com/v1/videos/generations" \
  -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "A golden retriever running through autumn leaves in a park"}'

# Response: {"id": "550e8400-...", "status": "in_progress", ...}
```

## Poll for completion

```bash
curl "https://llm.matthewdeaves.com/v1/videos/generations/550e8400-..." \
  -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN"

# When done: {"status": "completed", "url": "https://s3...", ...}
```

## Download the video

```bash
# The url field contains a presigned S3 URL (valid for 1 hour)
curl -o video.mp4 "https://rockport-video-....s3.amazonaws.com/jobs/.../output.mp4?X-Amz-..."
```

## Multi-shot video

```bash
curl -X POST "https://llm.matthewdeaves.com/v1/videos/generations" \
  -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "shots": [
      {"prompt": "A sunrise over a calm ocean, camera slowly panning right"},
      {"prompt": "Dolphins jumping out of the water in morning light"},
      {"prompt": "A sailboat appears on the horizon, gliding peacefully"}
    ]
  }'

# Creates an 18-second video (3 shots × 6 seconds each)
# Cost: $1.44 (18 × $0.08)
```

## List your jobs

```bash
curl "https://llm.matthewdeaves.com/v1/videos/generations" \
  -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN"
```

## Pricing

- $0.08 per second of generated video
- 6-second video: $0.48
- 30-second video: $2.40
- 2-minute video: $9.60
- All videos: 1280×720, 24fps, MP4
- Videos auto-delete after 7 days
