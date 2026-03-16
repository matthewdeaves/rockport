# Quickstart: Multi-Model Video Generation

## Prerequisites

- Rockport deployed and healthy (`./scripts/rockport.sh status`)
- API key with sufficient budget (`./scripts/rockport.sh key create test --budget 15`)
- Luma Ray2 Marketplace subscription activated (use model once in Bedrock playground)

## Text-to-video with Ray2

```bash
curl -X POST https://llm.matthewdeaves.com/v1/videos/generations \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "luma-ray2",
    "prompt": "a tiger walking through snow",
    "duration": 5,
    "aspect_ratio": "16:9",
    "resolution": "720p"
  }'
```

Returns 202 with job ID. Poll for completion:

```bash
curl https://llm.matthewdeaves.com/v1/videos/generations/{job_id} \
  -H "Authorization: Bearer $KEY"
```

## Text-to-video with Nova Reel (unchanged)

```bash
curl -X POST https://llm.matthewdeaves.com/v1/videos/generations \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "a drone flyover of a cliff", "duration": 6}'
```

No `model` field needed — defaults to `nova-reel`.

## Ray2 portrait video (9:16)

```bash
curl -X POST https://llm.matthewdeaves.com/v1/videos/generations \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "luma-ray2",
    "prompt": "a person walking down a city street at night",
    "duration": 9,
    "aspect_ratio": "9:16",
    "resolution": "720p"
  }'
```

## Ray2 image-to-video

```bash
curl -X POST https://llm.matthewdeaves.com/v1/videos/generations \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "luma-ray2",
    "prompt": "the scene comes to life",
    "duration": 5,
    "image": "data:image/jpeg;base64,..."
  }'
```

## Check video model health

```bash
curl https://llm.matthewdeaves.com/v1/videos/health \
  -H "Authorization: Bearer $KEY"
```

## Cost comparison

| Model | Duration | Resolution | Cost |
|-------|----------|------------|------|
| nova-reel | 6s | 1280x720 | $0.48 |
| nova-reel | 12s | 1280x720 | $0.96 |
| luma-ray2 | 5s | 540p | $3.75 |
| luma-ray2 | 5s | 720p | $7.50 |
| luma-ray2 | 9s | 540p | $6.75 |
| luma-ray2 | 9s | 720p | $13.50 |
