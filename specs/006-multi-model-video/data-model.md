# Data Model: Multi-Model Video Generation

## Entity: Video Model (runtime, not persisted)

Defines a supported video generation model and its constraints. Stored as a Python dict/dataclass in `video_api.py`, not in the database.

| Field | Type | Description |
|-------|------|-------------|
| id | string | User-facing name: `nova-reel`, `luma-ray2` |
| bedrock_model_id | string | Bedrock model ID: `amazon.nova-reel-v1:1`, `luma.ray-v2:0` |
| region | string | Bedrock region: `us-east-1`, `us-west-2` |
| durations | list[int] | Allowed durations in seconds: `[6,12,...,120]` or `[5,9]` |
| duration_must_be_multiple_of | int or None | `6` for Nova Reel, `None` for Ray2 |
| resolutions | list[string] or None | `None` for Nova Reel (fixed), `["540p","720p"]` for Ray2 |
| aspect_ratios | list[string] or None | `None` for Nova Reel (fixed 16:9), `["16:9","9:16","1:1","4:3","3:4","21:9","9:21"]` for Ray2 |
| supports_multi_shot | bool | `True` for Nova Reel, `False` for Ray2 |
| supports_loop | bool | `False` for Nova Reel, `True` for Ray2 |
| supports_seed | bool | `True` for Nova Reel, `False` for Ray2 |
| supports_end_image | bool | `False` for Nova Reel, `True` for Ray2 |
| cost_per_second | dict | `{None: 0.08}` for Nova Reel, `{"540p": 0.75, "720p": 1.50}` for Ray2 |
| image_min_pixels | tuple or None | `(1280,720)` exact for Nova Reel, `(512,512)` min for Ray2 |
| image_max_pixels | tuple or None | `(1280,720)` exact for Nova Reel, `(4096,4096)` max for Ray2 |
| image_max_bytes | int | `10MB` for Nova Reel, `25MB` for Ray2 |
| default_resolution | string or None | `None` for Nova Reel, `"720p"` for Ray2 |
| default_aspect_ratio | string or None | `None` for Nova Reel, `"16:9"` for Ray2 |

## Entity: Video Job (persisted — `rockport_video_jobs` table)

### Schema change

Add column: `model VARCHAR(30) NOT NULL DEFAULT 'nova-reel'`

The DEFAULT ensures existing rows are backfilled and existing code that inserts without specifying model continues to work during migration.

### Updated schema

| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | NOT NULL | gen_random_uuid() | Primary key |
| api_key_hash | VARCHAR(128) | NOT NULL | — | |
| invocation_arn | VARCHAR(512) | UNIQUE NOT NULL | — | |
| status | VARCHAR(20) | NOT NULL | 'in_progress' | |
| **model** | **VARCHAR(30)** | **NOT NULL** | **'nova-reel'** | **NEW** |
| mode | VARCHAR(20) | NOT NULL | — | |
| prompt | TEXT | NOT NULL | — | |
| num_shots | INTEGER | NOT NULL | 1 | |
| duration_seconds | INTEGER | NOT NULL | — | |
| cost | DECIMAL(10,4) | — | 0 | |
| s3_uri | VARCHAR(512) | — | — | |
| error_message | TEXT | — | — | |
| created_at | TIMESTAMPTZ | NOT NULL | NOW() | |
| completed_at | TIMESTAMPTZ | — | — | |

### State transitions

No change from existing: `in_progress` → `completed` | `failed` → `expired`
