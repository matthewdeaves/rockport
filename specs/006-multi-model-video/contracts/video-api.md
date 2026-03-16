# API Contract: Video Generation (Multi-Model)

## POST /v1/videos/generations

### Request (updated)

```json
{
  "model": "nova-reel",
  "prompt": "a cat on a beach",
  "duration": 6,
  "seed": 42,
  "image": "data:image/png;base64,...",
  "shots": null
}
```

New fields (all optional):

| Field | Type | Default | Models | Description |
|-------|------|---------|--------|-------------|
| model | string | `"nova-reel"` | all | `"nova-reel"` or `"luma-ray2"` |
| aspect_ratio | string | `"16:9"` | luma-ray2 | `"16:9"`, `"9:16"`, `"1:1"`, `"4:3"`, `"3:4"`, `"21:9"`, `"9:21"` |
| resolution | string | `"720p"` | luma-ray2 | `"540p"` or `"720p"` |
| loop | bool | `false` | luma-ray2 | Whether the video should loop seamlessly |
| end_image | string | null | luma-ray2 | End frame data URI (keyframe interpolation) |

Existing fields unchanged: `prompt`, `duration`, `image`, `shots`, `seed`.

### Model-specific validation

**nova-reel**: duration 6-120 (multiples of 6), image must be exactly 1280x720, supports multi-shot, supports seed. `aspect_ratio`, `resolution`, `loop`, `end_image` ignored.

**luma-ray2**: duration 5 or 9 only, image 512x512 to 4096x4096 (max 25MB), no multi-shot, no seed. Supports `aspect_ratio`, `resolution`, `loop`, `end_image`.

### Response (updated)

```json
{
  "id": "uuid",
  "status": "in_progress",
  "model": "luma-ray2",
  "mode": "single_shot",
  "duration": 5,
  "estimated_cost": 7.50,
  "created_at": "2026-03-16T..."
}
```

New field in all responses: `model` (string).

### Error: unknown model

```json
{
  "detail": {
    "error": {
      "type": "validation_error",
      "message": "Unknown model 'foo'. Available: nova-reel, luma-ray2"
    }
  }
}
```

### Error: model doesn't support feature

```json
{
  "detail": {
    "error": {
      "type": "validation_error",
      "message": "Multi-shot mode is not supported by luma-ray2. Use nova-reel instead."
    }
  }
}
```

## GET /v1/videos/generations/{id}

Response adds `model` field. Presigned URL generation uses the correct S3 client for the model's region.

## GET /v1/videos/generations

Response adds `model` field to each job in the list.

## GET /v1/videos/health

### Response (updated)

```json
{
  "status": "healthy",
  "database": "connected",
  "models": {
    "nova-reel": {"status": "healthy", "region": "us-east-1"},
    "luma-ray2": {"status": "healthy", "region": "us-west-2"}
  }
}
```

Overall `status` is `"healthy"` if database is connected and at least one model is reachable. Individual model status reported separately so users can see if Ray2 isn't activated yet.
