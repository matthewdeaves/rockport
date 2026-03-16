# Data Model: Video Generation Sidecar

## Entities

### rockport_video_jobs (new PostgreSQL table)

Stores video generation job metadata. Lives in the same `litellm` database alongside LiteLLM's tables.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| id | UUID | PK, DEFAULT gen_random_uuid() | Job identifier returned to clients |
| api_key_hash | VARCHAR(128) | NOT NULL, INDEX | SHA-256 hash of the virtual API key (matches LiteLLM's hashing) |
| invocation_arn | VARCHAR(512) | UNIQUE, NOT NULL | Bedrock async invocation ARN |
| status | VARCHAR(20) | NOT NULL, DEFAULT 'in_progress' | One of: in_progress, completed, failed, expired |
| mode | VARCHAR(20) | NOT NULL | One of: single_shot, multi_shot |
| prompt | TEXT | NOT NULL | Single-shot: the text prompt. Multi-shot: JSON array of shot prompts |
| num_shots | INTEGER | NOT NULL, DEFAULT 1 | Number of shots (1 for single-shot, 2-20 for multi-shot) |
| duration_seconds | INTEGER | NOT NULL | Total video duration in seconds |
| cost | DECIMAL(10,4) | DEFAULT 0 | Calculated cost (duration × $0.08) |
| s3_uri | VARCHAR(512) | | S3 URI of the generated video (set on completion) |
| error_message | TEXT | | Error details (set on failure) |
| created_at | TIMESTAMP WITH TIME ZONE | NOT NULL, DEFAULT NOW() | Job submission time |
| completed_at | TIMESTAMP WITH TIME ZONE | | Job completion time |

**Indexes**:
- `idx_video_jobs_api_key_hash` on `api_key_hash` (for list queries scoped to a key)
- `idx_video_jobs_status` on `status` (for polling in-progress jobs)
- `idx_video_jobs_created_at` on `created_at` (for ordering in list queries)

### LiteLLM_SpendLogs (existing table — write-only from sidecar)

The sidecar inserts rows into this existing table when video jobs complete. Key fields used:

| Column | Value for video jobs |
|--------|---------------------|
| api_key | Hashed API key (same as api_key_hash) |
| model | "nova-reel" |
| model_group | "nova-reel" |
| spend | cost in USD (duration × 0.08) |
| total_tokens | 0 (not applicable for video) |
| startTime | Job created_at |
| metadata | `{"video_job_id": "<uuid>", "duration_seconds": N, "mode": "single_shot|multi_shot"}` |

### LiteLLM_VerificationToken (existing table — update spend column)

The sidecar increments the `spend` column on the key's row when a video job completes. This ensures LiteLLM's budget enforcement sees video costs.

## State Transitions

```
                    ┌──────────────┐
   Submit request → │ in_progress  │
                    └──────┬───────┘
                           │
                    Poll Bedrock
                           │
                    ┌──────┴───────┐
                    │              │
              ┌─────▼─────┐  ┌────▼────┐
              │ completed  │  │  failed │
              └─────┬──────┘  └─────────┘
                    │
             7-day retention
                    │
              ┌─────▼─────┐
              │  expired   │
              └────────────┘
```

- **in_progress → completed**: Bedrock reports success, sidecar records cost in SpendLogs + VerificationToken
- **in_progress → failed**: Bedrock reports failure, sidecar records error message, no cost charged
- **completed → expired**: S3 lifecycle deletes the video file after 7 days; sidecar detects missing file on next poll

## S3 Structure

```
s3://rockport-video-{account_id}-{region}/
└── jobs/
    └── {job_uuid}/
        └── output.mp4    ← written by Bedrock
```

- Lifecycle policy: delete objects after 7 days
- Bucket in us-east-1 (same region as Nova Reel)
- Encryption: SSE-S3 (AES-256)
- Public access: blocked
