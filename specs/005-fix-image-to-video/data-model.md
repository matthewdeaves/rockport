# Data Model: Fix Image-to-Video Support

**Date**: 2026-03-16 | **Feature**: 005-fix-image-to-video

## Entities

No new entities or schema changes. The existing `rockport_video_jobs` table already tracks image-to-video jobs identically to text-only jobs (mode, prompt, duration, status, cost).

## Data Transformations

### Image Payload Conversion

The key data transformation in this feature is converting a client-submitted data URI into Bedrock's expected format:

**Input** (from client):
```
data:image/png;base64,iVBORw0KGgoAAAANSUhEU...
```

**Output** (to Bedrock, single-shot):
```json
{
  "format": "png",
  "source": {
    "bytes": "iVBORw0KGgoAAAANSUhEU..."
  }
}
```

**Output** (to Bedrock, multi-shot per-shot):
```json
{
  "format": "png",
  "source": {
    "bytes": "iVBORw0KGgoAAAANSUhEU..."
  }
}
```

### Validation Rules

| Rule | Field | Constraint |
|------|-------|------------|
| Format | Image format | PNG or JPEG only |
| Dimensions | Image size | Exactly 1280x720 |
| Transparency | PNG alpha channel | If alpha present and fully opaque → strip; if any transparency → reject |
| Size | Raw bytes | Max 10MB |
| Duration | Single-shot + image | Must be exactly 6 seconds |

## State Transitions

No changes. Existing job state machine (in_progress → completed/failed/expired) is unchanged.
