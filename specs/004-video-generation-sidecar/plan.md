# Implementation Plan: Video Generation Sidecar API

**Branch**: `004-video-generation-sidecar` | **Date**: 2026-03-16 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/004-video-generation-sidecar/spec.md`

## Summary

Add video generation to Rockport via a lightweight FastAPI sidecar service running alongside LiteLLM on the same EC2 instance. The sidecar handles Amazon Nova Reel's async video generation workflow (StartAsyncInvoke → poll → S3 output), exposes OpenAI-style REST endpoints, and writes spend data directly into LiteLLM's PostgreSQL tables for unified cost tracking. Supports both single-shot (one prompt, 6-120s) and multi-shot (2-20 per-shot prompts) video generation.

## Technical Context

**Language/Version**: Python 3.11 (already installed on EC2 instance)
**Primary Dependencies**: FastAPI, uvicorn, boto3, psycopg2 (FastAPI/uvicorn already installed as LiteLLM dependencies; boto3 available via AWS CLI; psycopg2 needs install)
**Storage**: PostgreSQL 15 (existing instance, new `rockport_video_jobs` table) + S3 (new bucket in us-east-1 for video output)
**Testing**: bash smoke tests (matching existing pattern in `tests/smoke-test.sh`)
**Target Platform**: Amazon Linux 2023 on EC2 t4g.small (ARM64)
**Project Type**: Web service (REST API sidecar)
**Performance Goals**: <2s job submission response; video generation time determined by Bedrock (~90s for 6s video)
**Constraints**: 256MB memory limit for sidecar; must coexist with LiteLLM (1280MB) + cloudflared (256MB) on 2GB instance + 512MB swap
**Scale/Scope**: 1 operator, handful of accounts, ~10-20 video jobs/day max

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Cost Minimization | PASS | S3 cost <$0.50/month. No new compute. Same EC2 instance. |
| II. Security | PASS with deviation | IAM expands to include `bedrock:StartAsyncInvoke`, `GetAsyncInvoke`, `ListAsyncInvokes` + S3 permissions. Role still not exposed to end users. Auth delegates to LiteLLM's existing key system. |
| III. LiteLLM-First | PASS with deviation | LiteLLM provably cannot handle Bedrock async video generation. Sidecar is the minimum custom code needed. Auth and spend tracking integrate with LiteLLM rather than replacing it. |
| IV. Scope Containment | PASS with deviation | Video generation serves the core use case (Bedrock models via proxy). No frontend, no custom auth, no webhooks. The sidecar is ~200 lines of Python wrapping Bedrock's API. |
| V. AWS London + Cloudflare | PASS | Compute stays on existing EC2 in eu-west-2. Video API calls cross-region to us-east-1 (same pattern as existing image generation). S3 bucket in us-east-1. Cloudflare Tunnel routes video paths to sidecar. |

**Post-Phase 1 re-check**: All gates still pass. Data model uses existing PostgreSQL. Contracts are REST-only (no frontend). Tunnel routing uses existing cloudflared infrastructure.

## Project Structure

### Documentation (this feature)

```text
specs/004-video-generation-sidecar/
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
├── video_api.py          # FastAPI app: endpoints, auth, validation, Bedrock client
├── db.py                 # PostgreSQL connection pool, job CRUD, spend logging
├── requirements.txt      # psycopg2-binary (only new dependency)
└── tests/
    └── test_validation.py  # Unit tests for request validation logic

config/
├── litellm-config.yaml   # (existing, unchanged)
├── litellm.service        # (existing, update MemoryMax 1536M → 1280M)
├── cloudflared.service    # (existing, unchanged)
└── rockport-video.service # New systemd unit for the sidecar

terraform/
├── main.tf               # Update: IAM policy for async invoke + S3
├── s3.tf                 # New: S3 bucket for video output
├── waf.tf                # Update: allow /v1/videos/* paths
└── variables.tf          # Update: add video_bucket_name variable

scripts/
├── bootstrap.sh          # Update: install sidecar, create DB table, start service
├── rockport.sh           # Update: config push restarts sidecar, status checks sidecar health
└── tests/
    └── smoke-test.sh     # Update: add video generation smoke tests
```

**Structure Decision**: The sidecar lives in a new `sidecar/` directory at repo root. It's a single Python module (not a package) with a thin database helper. This keeps it separate from LiteLLM's config while co-locating it with the rest of the Rockport project. No src/ or complex package structure — it's ~200 lines of code.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Custom Python service (Constitution III) | LiteLLM has no Bedrock async video support | Waiting for LiteLLM: no timeline. Forking: unmaintainable. |
| Expanded IAM permissions (Constitution II) | `StartAsyncInvoke`/`GetAsyncInvoke` required for video gen | These are standard Bedrock actions, not a security escalation |
| New S3 bucket (Constitution I) | Bedrock writes video output to S3 (no alternative) | Cost is <$0.50/month for expected usage |
| psycopg2 dependency | Direct PostgreSQL access for spend log writes | LiteLLM's API doesn't expose a write endpoint for SpendLogs |
