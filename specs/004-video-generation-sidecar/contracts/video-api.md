# Video Generation API Contract

Base URL: `https://{tunnel-domain}/v1/videos`

All endpoints require `Authorization: Bearer <virtual-key>` header.

---

## POST /v1/videos/generations

Submit a video generation job.

### Request — Single-Shot Mode

```json
{
  "prompt": "A serene mountain landscape with clouds drifting past at sunset",
  "duration": 12,
  "image": "data:image/jpeg;base64,/9j/4AAQ...",
  "seed": 42
}
```

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| prompt | string | Yes | — | 1-4000 characters |
| duration | integer | No | 6 | Multiple of 6, range 6-120 |
| image | string | No | — | Base64 data URI, 1280x720, PNG or JPEG |
| seed | integer | No | random | 0-2147483646 |

### Request — Multi-Shot Mode

```json
{
  "shots": [
    {
      "prompt": "A cat sitting on a windowsill watching rain",
      "image": "data:image/jpeg;base64,..."
    },
    {
      "prompt": "The cat jumps down and walks across the room"
    },
    {
      "prompt": "The cat curls up on a cozy blanket by the fireplace"
    }
  ],
  "seed": 42
}
```

| Field | Type | Required | Default | Constraints |
|-------|------|----------|---------|-------------|
| shots | array | Yes (for multi-shot) | — | 2-20 items |
| shots[].prompt | string | Yes | — | 1-512 characters |
| shots[].image | string | No | — | Base64 data URI, 1280x720, PNG or JPEG |
| seed | integer | No | random | 0-2147483646 |

**Mode detection**: If `shots` is present, multi-shot mode. If `prompt` is present (without `shots`), single-shot mode. Both present → 400 error.

### Response — 202 Accepted

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "in_progress",
  "mode": "single_shot",
  "duration": 12,
  "estimated_cost": 0.96,
  "created_at": "2026-03-16T14:30:00Z"
}
```

### Error Responses

**400 Bad Request** — validation failure:
```json
{
  "error": {
    "type": "validation_error",
    "message": "Duration must be a multiple of 6 seconds (got 10)"
  }
}
```

**402 Payment Required** — budget exceeded:
```json
{
  "error": {
    "type": "budget_exceeded",
    "message": "Estimated cost $2.40 exceeds remaining budget $1.00",
    "estimated_cost": 2.40,
    "remaining_budget": 1.00
  }
}
```

**429 Too Many Requests** — concurrent job limit:
```json
{
  "error": {
    "type": "concurrent_limit",
    "message": "Concurrent job limit reached (3/3 in progress)",
    "in_progress": 3,
    "limit": 3
  }
}
```

**401 Unauthorized** — invalid API key:
```json
{
  "error": {
    "type": "authentication_error",
    "message": "Invalid API key"
  }
}
```

---

## GET /v1/videos/generations/{id}

Poll job status.

### Response — 200 OK (in progress)

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "in_progress",
  "mode": "single_shot",
  "duration": 12,
  "estimated_cost": 0.96,
  "created_at": "2026-03-16T14:30:00Z"
}
```

### Response — 200 OK (completed)

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "completed",
  "mode": "single_shot",
  "duration": 12,
  "cost": 0.96,
  "url": "https://rockport-video-123456789-us-east-1.s3.amazonaws.com/jobs/550e8400.../output.mp4?X-Amz-...",
  "url_expires_at": "2026-03-16T15:30:00Z",
  "created_at": "2026-03-16T14:30:00Z",
  "completed_at": "2026-03-16T14:31:30Z"
}
```

### Response — 200 OK (failed)

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "failed",
  "mode": "single_shot",
  "duration": 12,
  "cost": 0,
  "error": "Video generation failed: content policy violation",
  "created_at": "2026-03-16T14:30:00Z",
  "completed_at": "2026-03-16T14:31:00Z"
}
```

### Response — 200 OK (expired)

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "expired",
  "mode": "single_shot",
  "duration": 12,
  "cost": 0.96,
  "error": "Video file has been deleted (7-day retention period expired)",
  "created_at": "2026-03-16T14:30:00Z",
  "completed_at": "2026-03-16T14:31:30Z"
}
```

### Error Responses

**404 Not Found** — job doesn't exist or belongs to another key:
```json
{
  "error": {
    "type": "not_found",
    "message": "Job not found"
  }
}
```

---

## GET /v1/videos/generations

List recent jobs for the authenticated key.

### Query Parameters

| Param | Type | Default | Description |
|-------|------|---------|-------------|
| limit | integer | 20 | Max results (1-100) |
| status | string | — | Filter by status: in_progress, completed, failed, expired |

### Response — 200 OK

```json
{
  "data": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "status": "completed",
      "mode": "multi_shot",
      "duration": 18,
      "cost": 1.44,
      "created_at": "2026-03-16T14:30:00Z",
      "completed_at": "2026-03-16T14:33:00Z"
    }
  ],
  "total": 1
}
```

Note: List endpoint does not include `url` — poll individual job for download URL.

---

## GET /v1/videos/health

Health check for the sidecar service.

### Response — 200 OK

```json
{
  "status": "healthy",
  "database": "connected",
  "bedrock": "reachable"
}
```
