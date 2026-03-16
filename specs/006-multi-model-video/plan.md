# Implementation Plan: Multi-Model Video Generation

**Branch**: `006-multi-model-video` | **Date**: 2026-03-16 | **Spec**: [spec.md](spec.md)

## Summary

Extend the video generation sidecar to support Luma AI Ray2 alongside Nova Reel. Add a `model` parameter to the API, per-model validation/routing/pricing, a second S3 bucket in us-west-2, and IAM policy updates. Existing Nova Reel behavior is fully backward compatible.

## Technical Context

**Language/Version**: Python 3.11 + FastAPI, boto3, Pillow, psycopg2, pydantic
**Primary Dependencies**: FastAPI, boto3 (multi-region clients), Pillow, psycopg2, pydantic
**Storage**: PostgreSQL 15 (existing `rockport_video_jobs` table + schema migration), S3 (existing us-east-1 bucket + new us-west-2 bucket)
**Testing**: bash smoke tests (`tests/smoke-test.sh`)
**Target Platform**: Linux EC2 (t3.small, Amazon Linux 2023)
**Project Type**: Web service (FastAPI sidecar)
**Performance Goals**: Same as existing — async job submission, lazy polling
**Constraints**: 256MB MemoryMax for sidecar, 2GB total instance RAM
**Scale/Scope**: ~10-20 video jobs/day, single operator

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Cost Minimization | PASS | No new compute. Second S3 bucket adds ~$0/month (lifecycle deletes after 7 days). Ray2 Marketplace subscription is free — only pay per invocation. |
| II. Security | PASS | New bucket mirrors existing security (SSE-S3, public access block, DenyNonSSL). IAM policy extended minimally. |
| III. LiteLLM-First | PASS | Video sidecar is already an accepted exception (LiteLLM doesn't support Bedrock async invoke). This extends existing sidecar code, not new custom code. |
| IV. Scope Containment | PASS | Extends existing video generation feature. No new services, dashboards, or out-of-scope functionality. |
| V. AWS London + Cloudflare | PASS | Compute stays in eu-west-2. us-west-2 is only for Ray2 Bedrock API + S3 output (same pattern as us-east-1 for Nova Reel). |

## Project Structure

### Documentation (this feature)

```text
specs/006-multi-model-video/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── video-api.md
└── tasks.md
```

### Source Code (repository root)

```text
sidecar/
├── video_api.py          # Add model parameter, per-model validation, multi-region clients
├── db.py                 # Add model column, update insert/query/spend functions
terraform/
├── s3.tf                 # Add us-west-2 video bucket (mirror of us-east-1)
├── main.tf               # Add us-west-2 async invoke IAM permissions + S3 policy
tests/
└── smoke-test.sh         # Add Ray2 model selection + text-to-video tests
config/
└── rockport-video.service # Add VIDEO_BUCKET_US_WEST_2 env var
scripts/
└── bootstrap.sh          # Add ALTER TABLE for model column migration
```

**Structure Decision**: No new files — extends existing sidecar, terraform, and test files. The only new Terraform resources are the us-west-2 S3 bucket and its associated configuration (mirroring the existing us-east-1 pattern).
